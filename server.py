"""AirGlance backend.

Polls Amazon Smart Air Quality Monitors via the (unofficial) Alexa cloud API, stores
readings in SQLite and serves the local dashboard + JSON API.

Run:  .venv/bin/python server.py
Env:  AQM_PORT (default 8080), AQM_INTERVAL (s, default 300), AQM_DATA_DIR, AQM_PARENT_PID
"""

import asyncio
import json
import logging
import os
import sqlite3
import time
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from pathlib import Path

from aiohttp import web
from alexapy import AlexaAPI, AlexaLogin, AlexaProxy
from yarl import URL

import probe  # auth file locations, persist_oauth, httpx multipart workaround

BASE = Path(__file__).resolve().parent
STATIC = BASE / "static"
DB_PATH = Path(os.environ.get("AQM_DB") or (probe.DATA / "data" / "aqm.db"))
SETTINGS_FILE = probe.DATA / "settings.json"
INTERVAL = int(os.environ.get("AQM_INTERVAL", "300"))
PORT = int(os.environ.get("AQM_PORT", "8080"))
SELF_URL = f"http://127.0.0.1:{PORT}"
BACKFILL_EVERY = 3600  # s between history imports per monitor
SCAN_EVERY = 3600  # s between automatic device discoveries
STALE_AFTER = 20 * 60  # newest measurement older than this -> stale (monitor offline?)
LOGIN_TIMEOUT = 15 * 60  # s the login page stays available
MARKETPLACES = ["amazon.de", "amazon.com", "amazon.co.uk", "amazon.fr", "amazon.it", "amazon.es",
                "amazon.ca", "amazon.com.au", "amazon.in", "amazon.co.jp", "amazon.com.br", "amazon.com.mx"]

# RangeController instance -> metric key (from the device's capability list)
RANGE_INSTANCES = {"9": "iaq", "6": "pm25", "7": "pm10", "5": "voc", "8": "co", "4": "humidity"}

log = logging.getLogger("aqm")
WAKE = asyncio.Event()  # set to run the poll loop immediately (login done, settings changed, refresh)


class State:
    status = "starting"  # starting|needs_account|login_required|logging_in|setup_required|ok|error
    message = ""
    last_poll: float | None = None


STATE = State()


# ================================================================ helpers
def parse_ts(s: str) -> int:
    return int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp())


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def write_json(path: Path, data: dict, private: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    if private:
        os.chmod(tmp, 0o600)
    os.replace(tmp, path)


# ================================================================ traffic light
GOOD_RANGE = {  # inclusive "good" band; used for status and for "too high / too low"
    "iaq": (65, 100), "pm25": (0, 12), "pm10": (0, 54), "voc": (0, 30),
    "co": (0, 9), "temperature": (19, 24), "humidity": (40, 60),
}
MODERATE_RANGE = {
    "iaq": (35, 100), "pm25": (0, 35), "pm10": (0, 154), "voc": (0, 60),
    "co": (0, 35), "temperature": (17, 26), "humidity": (30, 70),
}


def classify(metric: str, v: float) -> tuple[str, str | None]:
    """-> (status, direction) with status good|moderate|poor and direction high|low|None."""
    if metric not in GOOD_RANGE:
        return "unknown", None
    glo, ghi = GOOD_RANGE[metric]
    mlo, mhi = MODERATE_RANGE[metric]
    if glo <= v <= ghi:
        return "good", None
    direction = "high" if v > ghi else "low"
    return ("moderate" if mlo <= v <= mhi else "poor"), direction


# ================================================================ storage
@contextmanager
def db():
    """`with db() as con:` – commits on success, rolls back on error, always closes."""
    con = _connect()
    try:
        with con:
            yield con
    finally:
        con.close()


def _connect() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(DB_PATH)
    cols = [r[1] for r in con.execute("PRAGMA table_info(readings)")]
    if cols and "device" not in cols:  # migrate single-monitor schema -> per-device rows
        log.info("Migrating database to multi-monitor schema")
        with con:
            con.execute("ALTER TABLE readings RENAME TO readings_v1")
            con.execute(
                "CREATE TABLE readings (device TEXT NOT NULL, ts INTEGER NOT NULL, metric TEXT NOT NULL,"
                " value REAL NOT NULL, PRIMARY KEY (device, ts, metric))"
            )
            con.execute("INSERT INTO readings SELECT 'legacy', ts, metric, value FROM readings_v1")
            con.execute("DROP TABLE readings_v1")
    con.execute(
        "CREATE TABLE IF NOT EXISTS readings (device TEXT NOT NULL, ts INTEGER NOT NULL, metric TEXT NOT NULL,"
        " value REAL NOT NULL, PRIMARY KEY (device, ts, metric))"
    )
    return con


def store(rows: list[tuple[str, int, str, float]]) -> None:
    with db() as con:
        con.executemany("INSERT OR IGNORE INTO readings VALUES (?, ?, ?, ?)", rows)


def newest_ts(device: str) -> int | None:
    with db() as con:
        return con.execute("SELECT MAX(ts) FROM readings WHERE device = ?", (device,)).fetchone()[0]


# ================================================================ settings (monitors)
class Settings:
    """settings.json: which monitors exist, which are shown, and their local names."""

    def __init__(self) -> None:
        d = read_json(SETTINGS_FILE)
        self.configured: bool = d.get("configured", False)
        self.monitors: dict[str, dict] = d.get("monitors", {})

    def save(self) -> None:
        write_json(SETTINGS_FILE, {"configured": self.configured, "monitors": self.monitors})

    def enabled(self) -> list[tuple[str, dict]]:
        return [(i, m) for i, m in self.monitors.items() if m.get("enabled") and not m.get("missing")]

    @staticmethod
    def display(m: dict) -> str:
        return (m.get("alias") or "").strip() or m.get("name") or "Air Quality Monitor"

    def public(self) -> list[dict]:
        out = []
        for i, m in self.monitors.items():
            newest = newest_ts(i)
            out.append({
                "id": i, "name": m.get("name"), "alias": m.get("alias", ""), "display": self.display(m),
                "enabled": bool(m.get("enabled")), "missing": bool(m.get("missing")),
                "newest_ts": newest, "stale": newest is None or time.time() - newest > STALE_AFTER,
            })
        return sorted(out, key=lambda x: (not x["enabled"], x["display"].lower()))


SETTINGS = Settings()


# ================================================================ Amazon account / login
class Account:
    """Amazon session handling. The login page (local proxy to Amazon) only runs on demand."""

    def __init__(self) -> None:
        self.login: AlexaLogin | None = None
        self.proxy: AlexaProxy | None = None
        self.proxy_url: str | None = None
        self.task: asyncio.Task | None = None
        self.error = ""

    @staticmethod
    def config() -> dict:
        return read_json(probe.CONFIG_FILE)

    def _new_login(self, oauth: dict | None = None) -> AlexaLogin:
        cfg = self.config()
        probe.AUTH.mkdir(parents=True, exist_ok=True)
        os.chmod(probe.AUTH, 0o700)
        return AlexaLogin(url=cfg.get("domain", "amazon.de"), email=cfg["email"], password="",
                          outputpath=probe.outputpath, oauth=oauth or {})

    async def restore(self) -> bool:
        """Re-use the saved session (cookies / refresh token) without user interaction."""
        if not self.config().get("email") or not (probe.OAUTH_FILE.exists() or any(probe.AUTH.glob("*cookie*"))):
            return False
        login = self._new_login(read_json(probe.OAUTH_FILE))
        try:
            await login.load_cookie()
            if await login.test_loggedin():
                probe.persist_oauth(login)
                self.login = login
                return True
        except Exception:
            log.exception("Saved session not usable")
        await login.close()
        return False

    def save_account(self, email: str, domain: str) -> None:
        write_json(probe.CONFIG_FILE, {"email": email, "domain": domain}, private=True)

    async def start_login(self) -> str:
        """Start (or reuse) the login proxy; returns the URL to open in the browser."""
        if self.proxy and self.task and not self.task.done():
            return self.proxy_url
        self.error = ""
        login = self._new_login()
        proxy = AlexaProxy(login, f"http://127.0.0.1:{probe.PROXY_PORT}")
        await proxy.start_proxy(host="127.0.0.1")
        self.proxy = proxy
        self.proxy_url = str(proxy.access_url().with_query(callback_url=f"{SELF_URL}/login/done"))
        self.task = asyncio.create_task(self._finish_login(login, proxy))
        STATE.status = "logging_in"
        return self.proxy_url

    async def _finish_login(self, login: AlexaLogin, proxy: AlexaProxy) -> None:
        try:
            deadline = time.time() + LOGIN_TIMEOUT
            while not (login.authorization_code or login.access_token):
                if time.time() > deadline:
                    raise TimeoutError("login_timeout")   # message codes are translated by the dashboard
                await asyncio.sleep(1)
            await asyncio.sleep(1)
            if not await login.test_loggedin():
                raise RuntimeError("login_not_confirmed")
            probe.persist_oauth(login)
            if self.login:
                await self.login.close()
            self.login = login
            log.info("Signed in to Amazon")
        except Exception as ex:
            log.warning("Sign-in failed: %s", ex)
            self.error = str(ex)
            await login.close()
        finally:
            try:
                await asyncio.sleep(3)  # let the proxy deliver the redirect to /login/done
                await proxy.stop_proxy()
            except (Exception, asyncio.CancelledError):
                pass
            if self.proxy is proxy:
                self.proxy = None
                self.proxy_url = None
            WAKE.set()

    async def logout(self) -> None:
        if self.task and not self.task.done():
            self.task.cancel()  # its cleanup stops the proxy
        self.proxy = None
        self.proxy_url = None
        if self.login:
            await self.login.close()
            self.login = None
        for f in probe.AUTH.glob("*"):
            if f.name != probe.CONFIG_FILE.name:  # keep e-mail/marketplace to prefill the form
                f.unlink(missing_ok=True)
        log.info("Signed out")
        WAKE.set()

    async def drop_session(self) -> None:
        if self.login:
            await self.login.close()
        self.login = None


ACCOUNT = Account()


# ================================================================ Amazon API calls
async def graphql(login: AlexaLogin, query: str, variables: dict | None = None) -> dict:
    data = {"query": query, **({"variables": variables} if variables else {})}
    resp = await AlexaAPI._static_request("post", login, "/nexus/v1/graphql", data=data)
    return await resp.json(content_type=None)


async def discover(login: AlexaLogin) -> None:
    """Find all air quality monitors in the Amazon account and merge them into the settings."""
    r = await graphql(
        login,
        "{ endpoints(endpointsQueryParams: { paginationParams: { disablePagination: true } })"
        " { items { id legacyAppliance { entityId friendlyName applianceTypes } } } }",
    )
    items = ((r.get("data") or {}).get("endpoints") or {}).get("items")
    if items is None:
        raise RuntimeError(f"Device discovery failed: {r.get('errors')}")
    found = {}
    for it in items:
        la = it.get("legacyAppliance") or {}
        if "AIR_QUALITY_MONITOR" in (la.get("applianceTypes") or []) and la.get("entityId"):
            found[la["entityId"]] = {"endpoint_id": it["id"], "name": la.get("friendlyName") or "Air Quality Monitor"}
    for i, f in found.items():
        m = SETTINGS.monitors.setdefault(i, {"enabled": False, "alias": ""})
        m.update(f)
        m.pop("missing", None)
    for i, m in SETTINGS.monitors.items():
        if i not in found:
            m["missing"] = True
    # data recorded before multi-monitor support belongs to the (only) monitor of that time
    with db() as con:
        if found and con.execute("SELECT 1 FROM readings WHERE device = 'legacy' LIMIT 1").fetchone():
            target = next(iter(found))
            con.execute("UPDATE OR IGNORE readings SET device = ? WHERE device = 'legacy'", (target,))
            con.execute("DELETE FROM readings WHERE device = 'legacy'")
            if not SETTINGS.configured:  # existing single-monitor install: keep showing it
                SETTINGS.monitors[target]["enabled"] = True
                SETTINGS.configured = True
    SETTINGS.save()
    log.info("Device discovery: %d air quality monitor(s) found", len(found))


HISTORY_QUERY = """query($i: AirQualityHistoryInput!) { airQualityHistory(airQualityHistoryInput: $i) {
  interfaceName instance resolution data { timestamp value } } }"""
# PM10 (instance 7) is not offered by Amazon's history API -> live values only
HISTORY_SERIES = [("Alexa.RangeController", i, k) for i, k in RANGE_INSTANCES.items() if k != "pm10"] + [
    ("Alexa.TemperatureSensor", None, "temperature")
]
NONZERO_METRICS = ("iaq", "humidity", "temperature")  # 0 = gap filler from Amazon, not a reading


def history_rows(device: str, series: dict[str, dict[int, float]]) -> tuple[list[tuple], tuple[int, int] | None]:
    """Clean Amazon's history: it zero-fills times without data (e.g. before the device was set up).

    Only timestamps where humidity/iaq is > 0 count as real measurements; for metrics where 0 is
    physically impossible, single zeros are dropped as gaps. Returns (rows, (first_ts, last_ts)).
    """
    ref = series.get("humidity") or series.get("iaq") or {}
    valid = {ts for ts, v in ref.items() if v > 0}
    if not valid:
        return [], None
    rows = [(device, ts, key, round(v, 2)) for key, pts in series.items() for ts, v in pts.items()
            if ts in valid and not (key in NONZERO_METRICS and v == 0)]
    return rows, (min(valid), max(valid))


async def backfill(login: AlexaLogin, device: str, endpoint_id: str, hours: int) -> int:
    """Import Amazon's stored 5-minute history; replaces live rows in the covered range."""
    end = datetime.now(UTC)
    start = end - timedelta(hours=hours)
    iso = lambda d: d.isoformat().replace("+00:00", "Z")  # noqa: E731
    series: dict[str, dict[int, float]] = {}
    for iface, inst, key in HISTORY_SERIES:
        dev = {"endpointId": endpoint_id, "interfaceName": iface, **({"instance": inst} if inst else {})}
        r = await graphql(login, HISTORY_QUERY, {"i": {"devices": [dev], "startDate": iso(start), "endDate": iso(end),
                                                       "aggregationResolution": "FIVE_MINS"}})
        hist = (r.get("data") or {}).get("airQualityHistory")
        if hist:
            series[key] = {parse_ts(p["timestamp"]): float(p["value"]) for p in hist.get("data") or []
                           if p.get("value") is not None}
    rows, span = history_rows(device, series)
    if not rows:
        return 0
    lo, hi = span
    with db() as con:
        for key in series:
            con.execute("DELETE FROM readings WHERE device = ? AND metric = ? AND ts BETWEEN ? AND ?", (device, key, lo, hi))
        con.executemany("INSERT OR REPLACE INTO readings VALUES (?, ?, ?, ?)", rows)
    return len(rows)


def parse_state(state: dict) -> list[tuple[str, int, str, float]]:
    rows = []
    for dev in state.get("deviceStates", []):
        device = (dev.get("entity") or {}).get("entityId")
        for raw in dev.get("capabilityStates") or []:
            cap = json.loads(raw) if isinstance(raw, str) else raw
            ns, inst, val, ts = cap.get("namespace"), cap.get("instance"), cap.get("value"), cap.get("timeOfSample")
            if not ts or not device:
                continue
            if ns == "Alexa.RangeController" and inst in RANGE_INSTANCES:
                rows.append((device, parse_ts(ts), RANGE_INSTANCES[inst], float(val)))
            elif ns == "Alexa.TemperatureSensor" and isinstance(val, dict):
                t = float(val["value"])
                if val.get("scale") == "FAHRENHEIT":
                    t = (t - 32) * 5 / 9
                rows.append((device, parse_ts(ts), "temperature", round(t, 2)))
    return rows


# ================================================================ poll loop
class Poller:
    last_scan = 0.0
    last_backfill: dict[str, float] = {}

    async def once(self) -> None:
        if not ACCOUNT.config().get("email"):
            STATE.status = "needs_account"
            return
        login = ACCOUNT.login
        if login is None:
            STATE.status = "logging_in" if ACCOUNT.proxy else "login_required"
            STATE.message = ACCOUNT.error
            return
        if time.time() - self.last_scan > SCAN_EVERY or not SETTINGS.monitors:
            await discover(login)
            self.last_scan = time.time()
        enabled = SETTINGS.enabled()
        if not SETTINGS.configured or not enabled:
            STATE.status = "setup_required"
            return
        for device, m in enabled:
            if time.time() - self.last_backfill.get(device, 0) > BACKFILL_EVERY and m.get("endpoint_id"):
                hours = 6 if device in self.last_backfill else 7 * 24
                try:
                    n = await backfill(login, device, m["endpoint_id"], hours)
                    log.info("History %s: %d values (%d h)", Settings.display(m), n, hours)
                except Exception:
                    log.exception("History for %s not loaded", Settings.display(m))
                self.last_backfill[device] = time.time()
        state = await AlexaAPI.get_entity_state(login, entity_ids=[d for d, _ in enabled])
        rows = parse_state(state or {})
        if not rows:
            log.warning("No readings received, checking sign-in")
            if await login.test_loggedin():
                probe.persist_oauth(login)
            else:
                await ACCOUNT.drop_session()
                STATE.status, STATE.message = "login_required", "session_expired"
                return
        else:
            store(rows)
            STATE.last_poll = time.time()
            log.info("%d values stored", len(rows))
        STATE.status, STATE.message = "ok", ""

    async def run(self) -> None:
        try:
            await ACCOUNT.restore()
        except Exception:
            log.exception("Session could not be restored")
        while True:
            try:
                await self.once()
            except Exception as ex:  # keep polling no matter what
                log.exception("Polling failed")
                STATE.status, STATE.message = "error", str(ex)
            WAKE.clear()
            try:
                await asyncio.wait_for(WAKE.wait(), timeout=INTERVAL)
            except TimeoutError:
                pass


POLLER = Poller()


# ================================================================ web: security
@web.middleware
async def guard(request: web.Request, handler):
    # only answer for our own origin (blocks DNS-rebinding) ...
    if request.host not in (f"127.0.0.1:{PORT}", f"localhost:{PORT}"):
        raise web.HTTPForbidden(text="forbidden host")
    # ... and require a custom header on state-changing calls (blocks cross-site form posts)
    if request.method == "POST" and request.headers.get("X-AQM") != "1":
        raise web.HTTPForbidden(text="missing header")
    return await handler(request)


# ================================================================ web: API
RANGES = {"6h": (6 * 3600, 0), "24h": (86400, 0), "7d": (7 * 86400, 1800), "30d": (30 * 86400, 7200)}


def device_param(req: web.Request) -> str | None:
    d = req.query.get("device")
    if d in SETTINGS.monitors:
        return d
    enabled = SETTINGS.enabled()
    return enabled[0][0] if enabled else None


def latest_for(device: str) -> dict:
    with db() as con:
        rows = con.execute(
            "SELECT r.metric, r.value, r.ts FROM readings r JOIN"
            " (SELECT metric, MAX(ts) ts FROM readings WHERE device = ? GROUP BY metric) m"
            " ON r.metric = m.metric AND r.ts = m.ts WHERE r.device = ?", (device, device)
        ).fetchall()
    out = {}
    for metric, v, ts in rows:
        status, direction = classify(metric, v)
        out[metric] = {"value": v, "ts": ts, "status": status, "direction": direction}
    return out


async def api_status(_req: web.Request) -> web.Response:
    cfg = ACCOUNT.config()
    return web.json_response({
        "status": STATE.status, "message": STATE.message, "last_poll": STATE.last_poll, "interval": INTERVAL,
        "account": {"email": cfg.get("email"), "domain": cfg.get("domain", "amazon.de")} if cfg.get("email") else None,
        "logged_in": ACCOUNT.login is not None, "login_url": f"{SELF_URL}/login",
        "configured": SETTINGS.configured, "marketplaces": MARKETPLACES,
    })


async def api_monitors(_req: web.Request) -> web.Response:
    return web.json_response(SETTINGS.public())


async def api_save_monitors(req: web.Request) -> web.Response:
    body = await req.json()
    for item in body.get("monitors", []):
        m = SETTINGS.monitors.get(item.get("id"))
        if m is not None:
            m["alias"] = str(item.get("alias", ""))[:60]
            m["enabled"] = bool(item.get("enabled"))
    SETTINGS.configured = True
    SETTINGS.save()
    WAKE.set()
    return web.json_response(SETTINGS.public())


async def api_scan(_req: web.Request) -> web.Response:
    if ACCOUNT.login is None:
        raise web.HTTPConflict(text="not_logged_in")
    await discover(ACCOUNT.login)
    POLLER.last_scan = time.time()
    return web.json_response(SETTINGS.public())


async def api_account(req: web.Request) -> web.Response:
    body = await req.json()
    email, domain = str(body.get("email", "")).strip(), str(body.get("domain", "amazon.de"))
    if "@" not in email or domain not in MARKETPLACES:
        raise web.HTTPBadRequest(text="invalid_account")
    if ACCOUNT.config().get("email") not in (None, email):
        await ACCOUNT.logout()  # different account -> old session is worthless
    ACCOUNT.save_account(email, domain)
    WAKE.set()
    return web.json_response({"login_url": f"{SELF_URL}/login"})


async def login_page(_req: web.Request) -> web.Response:
    if not ACCOUNT.config().get("email"):
        raise web.HTTPFound("/")
    raise web.HTTPFound(await ACCOUNT.start_login())


async def login_done(req: web.Request) -> web.Response:
    de = req.headers.get("Accept-Language", "").lower().startswith("de")
    title, head, text = (("Angemeldet", "Erfolgreich angemeldet",
                          "Du kannst dieses Fenster schließen – AirGlance sucht jetzt nach deinen Luftqualitätsmonitoren.")
                         if de else
                         ("Signed in", "Signed in successfully",
                          "You can close this window – AirGlance is now looking for your air quality monitors."))
    return web.Response(content_type="text/html", text=f"""<!doctype html><meta charset="utf-8">
<title>{title}</title><body style="font:15px -apple-system,system-ui;display:flex;align-items:center;
justify-content:center;height:90vh;color:#333;text-align:center"><div><div style="font-size:42px">✅</div>
<h2 style="margin:8px 0">{head}</h2><p style="color:#777">{text}</p></div>""")


async def api_logout(_req: web.Request) -> web.Response:
    await ACCOUNT.logout()
    STATE.status = "login_required"
    return web.json_response({"ok": True})


async def api_refresh(_req: web.Request) -> web.Response:
    if STATE.last_poll is None or time.time() - STATE.last_poll > 60:
        WAKE.set()
    return web.json_response({"ok": True})


async def api_latest(req: web.Request) -> web.Response:
    device = device_param(req)
    return web.json_response(latest_for(device) if device else {})


async def api_history(req: web.Request) -> web.Response:
    device = device_param(req)
    span, bucket = RANGES.get(req.query.get("range", "24h"), RANGES["24h"])
    now = int(time.time())
    since = now - span
    out: dict[str, list] = {}
    if device:
        with db() as con:
            if bucket:
                rows = con.execute(
                    "SELECT metric, (ts / ?) * ? + ? / 2 AS b, AVG(value), MIN(value), MAX(value) FROM readings"
                    " WHERE device = ? AND ts >= ? GROUP BY metric, b ORDER BY b",
                    (bucket, bucket, bucket, device, since)).fetchall()
            else:
                rows = con.execute(
                    "SELECT metric, ts, value, value, value FROM readings WHERE device = ? AND ts >= ? ORDER BY ts",
                    (device, since)).fetchall()
        for metric, ts, avg, lo, hi in rows:
            out.setdefault(metric, []).append([ts, round(avg, 2), lo, hi])
    return web.json_response({"since": since, "now": now, "series": out})


async def api_overview(_req: web.Request) -> web.Response:
    """Everything the menu-bar app needs in one call."""
    monitors = []
    for device, m in SETTINGS.enabled():
        newest = newest_ts(device)
        monitors.append({"id": device, "name": Settings.display(m), "newest_ts": newest,
                         "stale": newest is None or time.time() - newest > STALE_AFTER,
                         "metrics": latest_for(device)})
    return web.json_response({"status": STATE.status, "login_url": f"{SELF_URL}/login", "monitors": monitors})


async def index(_req: web.Request) -> web.FileResponse:
    return web.FileResponse(STATIC / "index.html", headers={"Cache-Control": "no-cache"})


# ================================================================ app
async def parent_watchdog(parent: int) -> None:
    """Exit when the Mac app that started us is gone (e.g. force-quit), so no orphan blocks the port."""
    while True:
        await asyncio.sleep(3)
        if os.getppid() != parent:
            log.info("App is gone – shutting down backend")
            os._exit(0)


async def start_background(app: web.Application) -> None:
    app["poller"] = asyncio.create_task(POLLER.run())
    if os.environ.get("AQM_PARENT_PID"):
        app["watchdog"] = asyncio.create_task(parent_watchdog(int(os.environ["AQM_PARENT_PID"])))


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    logging.getLogger("alexapy").setLevel(logging.WARNING)
    logging.getLogger("authcaptureproxy").setLevel(logging.WARNING)
    logging.getLogger("aiohttp.access").setLevel(logging.WARNING)
    with db():   # create / migrate the database before serving
        pass
    print(f"Dashboard: {SELF_URL}")
    web.run_app(create_app(), host="127.0.0.1", port=PORT, print=None)


def create_app(background: bool = True) -> web.Application:
    app = web.Application(middlewares=[guard])
    app.add_routes([
        web.get("/", index),
        web.get("/login", login_page),
        web.get("/login/done", login_done),
        web.get("/api/status", api_status),
        web.get("/api/overview", api_overview),
        web.get("/api/monitors", api_monitors),
        web.post("/api/monitors", api_save_monitors),
        web.post("/api/scan", api_scan),
        web.post("/api/account", api_account),
        web.post("/api/logout", api_logout),
        web.post("/api/refresh", api_refresh),
        web.get("/api/latest", api_latest),
        web.get("/api/history", api_history),
        web.static("/static", STATIC),
    ])
    if background:
        app.on_startup.append(start_background)
    return app


if __name__ == "__main__":
    main()
