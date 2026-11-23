"""Unit tests for the backend logic that does not need an Amazon account.

Run:  .venv/bin/python -m unittest discover -s tests -v
"""

import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

# isolate all file access in a temp dir *before* importing the app modules
TMP = tempfile.mkdtemp(prefix="aqm-test-")
os.environ["AQM_DATA_DIR"] = TMP
os.environ["AQM_PORT"] = "8099"
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import server  # noqa: E402
from aiohttp.test_utils import AioHTTPTestCase  # noqa: E402


class ClassifyTest(unittest.TestCase):
    def test_score_is_better_when_higher(self):
        self.assertEqual(server.classify("iaq", 96), ("good", None))
        self.assertEqual(server.classify("iaq", 65), ("good", None))
        self.assertEqual(server.classify("iaq", 50), ("moderate", "low"))
        self.assertEqual(server.classify("iaq", 20), ("poor", "low"))

    def test_pollutants_are_better_when_lower(self):
        self.assertEqual(server.classify("pm25", 12), ("good", None))
        self.assertEqual(server.classify("pm25", 13), ("moderate", "high"))
        self.assertEqual(server.classify("pm25", 80), ("poor", "high"))
        self.assertEqual(server.classify("co", 0), ("good", None))
        self.assertEqual(server.classify("co", 40), ("poor", "high"))

    def test_comfort_ranges_have_two_directions(self):
        self.assertEqual(server.classify("temperature", 21.5), ("good", None))
        self.assertEqual(server.classify("temperature", 25.3), ("moderate", "high"))
        self.assertEqual(server.classify("temperature", 16), ("poor", "low"))
        self.assertEqual(server.classify("humidity", 35), ("moderate", "low"))
        self.assertEqual(server.classify("humidity", 75), ("poor", "high"))

    def test_unknown_metric(self):
        self.assertEqual(server.classify("radon", 1), ("unknown", None))


class ParseStateTest(unittest.TestCase):
    def cap(self, **kw):
        return json.dumps({"timeOfSample": "2026-11-23T13:11:45Z", **kw})

    def test_maps_instances_per_device_and_converts_fahrenheit(self):
        state = {"deviceStates": [
            {"entity": {"entityId": "dev-a"}, "capabilityStates": [
                self.cap(namespace="Alexa.RangeController", instance="9", value=96.0),
                self.cap(namespace="Alexa.RangeController", instance="6", value=3.0),
                self.cap(namespace="Alexa.TemperatureSensor", value={"value": 77.0, "scale": "FAHRENHEIT"}),
                self.cap(namespace="Alexa.RangeController", instance="99", value=1.0),   # unknown -> ignored
                json.dumps({"namespace": "Alexa.RangeController", "instance": "4", "value": 50}),  # no ts -> ignored
            ]},
            {"entity": {"entityId": "dev-b"}, "capabilityStates": [
                self.cap(namespace="Alexa.RangeController", instance="4", value=51.0),
            ]},
        ]}
        rows = server.parse_state(state)
        ts = server.parse_ts("2026-11-23T13:11:45Z")
        self.assertIn(("dev-a", ts, "iaq", 96.0), rows)
        self.assertIn(("dev-a", ts, "pm25", 3.0), rows)
        self.assertIn(("dev-a", ts, "temperature", 25.0), rows)
        self.assertIn(("dev-b", ts, "humidity", 51.0), rows)
        self.assertEqual(len(rows), 4)

    def test_empty_response(self):
        self.assertEqual(server.parse_state({}), [])


class HistoryRowsTest(unittest.TestCase):
    def test_drops_zero_filled_periods_and_gaps(self):
        series = {
            "humidity": {100: 0.0, 200: 50.0, 300: 52.0, 400: 0.0},   # 100: before setup, 400: current bucket
            "co": {100: 0.0, 200: 0.0, 300: 0.0, 400: 0.0},           # real zeros are valid CO readings
            "temperature": {100: 0.0, 200: 23.0, 300: 0.0, 400: 0.0}, # 300: impossible 0 -> gap
        }
        rows, span = server.history_rows("dev", series)
        self.assertEqual(span, (200, 300))
        self.assertEqual(sorted(rows), sorted([
            ("dev", 200, "humidity", 50.0), ("dev", 300, "humidity", 52.0),
            ("dev", 200, "co", 0.0), ("dev", 300, "co", 0.0),
            ("dev", 200, "temperature", 23.0),
        ]))

    def test_no_real_data(self):
        self.assertEqual(server.history_rows("dev", {"humidity": {1: 0.0}}), ([], None))


class MigrationTest(unittest.TestCase):
    def test_single_monitor_schema_is_migrated(self):
        path = Path(TMP) / "migrate.db"
        con = sqlite3.connect(path)
        con.execute("CREATE TABLE readings (ts INTEGER NOT NULL, metric TEXT NOT NULL, value REAL NOT NULL, PRIMARY KEY (ts, metric))")
        con.executemany("INSERT INTO readings VALUES (?, ?, ?)", [(1, "iaq", 90.0), (2, "iaq", 91.0)])
        con.commit()
        con.close()
        old = server.DB_PATH
        server.DB_PATH = path
        try:
            with server.db() as con:
                cols = [r[1] for r in con.execute("PRAGMA table_info(readings)")]
                rows = con.execute("SELECT device, ts, metric, value FROM readings ORDER BY ts").fetchall()
        finally:
            server.DB_PATH = old
        self.assertEqual(cols, ["device", "ts", "metric", "value"])
        self.assertEqual(rows, [("legacy", 1, "iaq", 90.0), ("legacy", 2, "iaq", 91.0)])


class SecurityTest(AioHTTPTestCase):
    async def get_application(self):
        return server.create_app(background=False)

    def headers(self, **extra):
        return {"Host": "127.0.0.1:8099", **extra}

    async def test_status_is_readable(self):
        r = await self.client.get("/api/status", headers=self.headers())
        self.assertEqual(r.status, 200)
        self.assertIn("status", await r.json())

    async def test_foreign_host_is_rejected(self):   # DNS rebinding protection
        r = await self.client.get("/api/status", headers={"Host": "evil.example:8099"})
        self.assertEqual(r.status, 403)

    async def test_post_without_custom_header_is_rejected(self):   # CSRF protection
        r = await self.client.post("/api/logout", headers=self.headers())
        self.assertEqual(r.status, 403)

    async def test_account_validation(self):
        r = await self.client.post("/api/account", json={"email": "kein-at", "domain": "amazon.de"},
                                   headers=self.headers(**{"X-AQM": "1"}))
        self.assertEqual(r.status, 400)


if __name__ == "__main__":
    unittest.main()
