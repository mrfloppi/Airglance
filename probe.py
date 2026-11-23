"""Probe: Can we read Amazon Smart Air Quality Monitor values via the Alexa cloud?

Usage:  .venv/bin/python probe.py [--domain amazon.de]

First run: starts a local login proxy. Open the printed URL in your browser and
log in on Amazon's own page (password + 2FA are typed by you, never stored).
Session cookies + OAuth tokens are then saved in ./.auth (chmod 600) so later
runs need no login.
"""

import argparse
import asyncio
import json
import os
import stat
import sys
from pathlib import Path

import aiohttp
import httpx

from alexapy import AlexaAPI, AlexaLogin, AlexaProxy

# Workaround: authcaptureproxy forwards multipart form posts as an aiohttp
# MultipartWriter, which httpx>=0.28 rejects ("sync request with AsyncClient").
# Serialize it to bytes + Content-Type before httpx sees it.
_orig_request = httpx.AsyncClient.request


async def _patched_request(self, method, url, *args, data=None, headers=None, **kw):
    if isinstance(data, aiohttp.MultipartWriter):
        body = await data.as_bytes()
        headers = {k: v for k, v in dict(headers or {}).items() if k.lower() not in ("content-type", "content-length")}
        headers["Content-Type"] = data.content_type
        kw["content"] = body
        return await _orig_request(self, method, url, *args, headers=headers, **kw)
    return await _orig_request(self, method, url, *args, data=data, headers=headers, **kw)


httpx.AsyncClient.request = _patched_request

BASE = Path(__file__).resolve().parent
# Data location: AQM_DATA_DIR (set by the Mac app) or the project folder
DATA = Path(os.environ.get("AQM_DATA_DIR") or BASE)
AUTH = DATA / ".auth"
OUT = DATA / "probe_output"
OAUTH_FILE = AUTH / "oauth.json"
CONFIG_FILE = AUTH / "config.json"
PROXY_PORT = 8765


def outputpath(name: str) -> str:
    return str(AUTH / name)


def save_private(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2))
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)


def load_json(path: Path) -> dict:
    return json.loads(path.read_text()) if path.exists() else {}


async def get_login(domain: str) -> AlexaLogin:
    AUTH.mkdir(exist_ok=True)
    os.chmod(AUTH, stat.S_IRWXU)
    cfg = load_json(CONFIG_FILE)
    email = cfg.get("email") or os.environ.get("AQM_EMAIL", "")
    if not email:
        if not sys.stdin or not sys.stdin.isatty():
            raise RuntimeError("No Amazon account configured: run 'probe.py' once in a terminal")
        email = input("E-Mail deines Amazon-Kontos: ").strip()
    save_private(CONFIG_FILE, {"email": email, "domain": domain})

    login = AlexaLogin(
        url=domain,
        email=email,
        password="",  # never handled by this script; you type it on Amazon's page
        outputpath=outputpath,
        oauth=load_json(OAUTH_FILE),
    )

    # 1) Try saved session
    if OAUTH_FILE.exists() or any(AUTH.glob("*.cookies*")):
        await login.load_cookie()
        if await login.test_loggedin():
            print("✓ Gespeicherte Sitzung gültig")
            persist_oauth(login)
            return login
        print("Gespeicherte Sitzung abgelaufen – neuer Login nötig.")

    # 2) Browser login through local proxy
    proxy = AlexaProxy(login, f"http://127.0.0.1:{PROXY_PORT}")
    await proxy.start_proxy(host="127.0.0.1")
    print("\n>>> Öffne diese URL im Browser und melde dich bei Amazon an:")
    print(f"    {proxy.access_url()}\n")
    print("Warte auf erfolgreichen Login …")
    while not (login.authorization_code or login.access_token):
        await asyncio.sleep(1)
    await asyncio.sleep(1)
    await proxy.stop_proxy()

    if not await login.test_loggedin():
        # RuntimeError (not sys.exit): the server's poll loop must survive a failed login
        raise RuntimeError("login_not_confirmed")
    print("✓ Login erfolgreich")
    persist_oauth(login)
    return login


def persist_oauth(login: AlexaLogin) -> None:
    save_private(
        OAUTH_FILE,
        {
            "access_token": login.access_token,
            "refresh_token": login.refresh_token,
            "mac_dms": login.mac_dms,
            "expires_in": login.expires_in,
        },
    )


def looks_like_aqm(ep: dict) -> bool:
    la = ep.get("legacyAppliance") or {}
    blob = json.dumps(la).lower() + json.dumps(ep.get("model") or {}).lower()
    return any(k in blob for k in ("air quality", "luftqualit", "aqm", "air_quality"))


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--domain", default="amazon.de")
    args = ap.parse_args()

    OUT.mkdir(exist_ok=True)
    login = await get_login(args.domain)
    try:
        endpoints = await AlexaAPI.get_devices_gql(login) or []
        (OUT / "endpoints.json").write_text(json.dumps(endpoints, indent=2))
        print(f"\n{len(endpoints)} Smart-Home-Endpunkte gefunden:")
        for ep in endpoints:
            la = ep.get("legacyAppliance") or {}
            mark = "  <-- AQM?" if looks_like_aqm(ep) else ""
            print(f"  - {la.get('friendlyName')!r} [{la.get('modelName')}] {la.get('applianceTypes')}{mark}")

        aqms = [ep for ep in endpoints if looks_like_aqm(ep)]
        if not aqms:
            print("\n✗ Kein Air Quality Monitor erkannt. Siehe probe_output/endpoints.json")
            return

        entity_ids = [ep["legacyAppliance"]["entityId"] for ep in aqms if ep["legacyAppliance"].get("entityId")]
        appliance_ids = [ep["legacyAppliance"]["applianceId"] for ep in aqms]
        state = await AlexaAPI.get_entity_state(login, entity_ids=entity_ids, appliance_ids=appliance_ids)
        (OUT / "state.json").write_text(json.dumps(state, indent=2))

        print("\nAktuelle Messwerte:")
        found = 0
        for dev in (state or {}).get("deviceStates", []):
            for raw in dev.get("capabilityStates", []):
                cap = json.loads(raw) if isinstance(raw, str) else raw
                inst = cap.get("instance", "")
                print(f"  {cap.get('namespace')}.{cap.get('name')} {inst}: {cap.get('value')}  ({cap.get('timeOfSample')})")
                found += 1
        for err in (state or {}).get("errors", []):
            print("  Fehler:", err)
        print("\n✓ Daten erhalten!" if found else "\n✗ Keine Messwerte im State. Siehe probe_output/state.json")
    finally:
        await login.close()


if __name__ == "__main__":
    asyncio.run(main())
