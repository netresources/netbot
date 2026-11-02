"""OneDrive batch sync: interval gate, catch-up, month rollover, alert force."""
import json, os, sys, tempfile, time, unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "netbot"))
import netbot_common as N


def _cfg(root, interval=240, on_alert=True):
    data = root / "data"
    sync = root / "sync"
    data.mkdir(parents=True, exist_ok=True)
    sync.mkdir(parents=True, exist_ok=True)
    (root / "alerts").mkdir(exist_ok=True)
    (root / "dashboard").mkdir(exist_ok=True)
    return {
        "paths": {
            "data_dir": str(data),
            "sync_dir": str(sync),
            "sync_history": True,
            "onedrive_sync_interval_min": interval,
            "onedrive_sync_on_alert": on_alert,
        }
    }


class Batch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.cfg = _cfg(self.root, interval=240)
        self.now = time.mktime((2026, 11, 2, 12, 0, 0, 0, 0, -1))

    def tearDown(self):
        self.tmp.cleanup()

    def _sample(self, ts, n=0):
        return {"ts": ts, "iso": f"2026-11-02T12:00:00-06:00", "host": "mac",
                "router": {"vendor": "linksys", "clients": [{"mac": "aa"}], "wan_ip": "198.51.100.2",
                           "client_count": 1, "wan_status": "Connected"}}

    def test_interval_gates_skip(self):
        N.write_onedrive_sync_state(self.cfg, self.now - 60)  # 1 min ago
        self.assertFalse(N.should_sync_onedrive(self.cfg, now=self.now))
        self.assertFalse(N.push_onedrive(self.cfg, self._sample(self.now), self.now))
        self.assertFalse((self.root / "sync" / "latest.json").exists())

    def test_interval_elapsed_syncs(self):
        N.write_onedrive_sync_state(self.cfg, self.now - 241 * 60)
        self.assertTrue(N.should_sync_onedrive(self.cfg, now=self.now))
        ok = N.push_onedrive(self.cfg, self._sample(self.now), self.now)
        self.assertTrue(ok)
        latest = json.loads((self.root / "sync" / "latest.json").read_text())
        self.assertNotIn("clients", latest["router"])
        self.assertNotIn("wan_ip", latest["router"])
        self.assertTrue((self.root / "sync" / "heartbeat").is_file())

    def test_never_synced_does_first_push(self):
        self.assertTrue(N.should_sync_onedrive(self.cfg, now=self.now))

    def test_interval_zero_every_run(self):
        cfg = _cfg(self.root, interval=0)
        N.write_onedrive_sync_state(cfg, self.now - 1)
        self.assertTrue(N.should_sync_onedrive(cfg, now=self.now))

    def test_month_rollover_forces(self):
        # last sync was Oct 31; now Nov 2
        oct_ts = time.mktime((2026, 10, 31, 23, 0, 0, 0, 0, -1))
        N.write_onedrive_sync_state(self.cfg, oct_ts, month="2026-10")
        # only 2 hours later into Nov — still under 240 min, but month changed
        nov_ts = time.mktime((2026, 11, 1, 1, 0, 0, 0, 0, -1))
        self.assertTrue(N.should_sync_onedrive(self.cfg, now=nov_ts))

    def test_force_alert_bypasses_interval(self):
        N.write_onedrive_sync_state(self.cfg, self.now - 60)
        self.assertFalse(N.should_sync_onedrive(self.cfg, now=self.now))
        self.assertTrue(N.should_sync_onedrive(self.cfg, now=self.now, force=True))
        self.assertTrue(N.push_onedrive(self.cfg, self._sample(self.now), self.now, force=True))

    def test_on_alert_flag_read(self):
        self.assertTrue(N.onedrive_sync_on_alert(self.cfg))
        cfg = _cfg(self.root, on_alert=False)
        self.assertFalse(N.onedrive_sync_on_alert(cfg))

    def test_history_catch_up(self):
        data = self.root / "data"
        # two local samples; sync empty
        for i, off in enumerate((0, 300)):
            ts = self.now + off
            row = {"ts": ts, "iso": f"t{i}", "host": "mac",
                   "router": {"clients": [{"mac": "aa"}], "wan_ip": "198.51.100.3", "client_count": 1}}
            N.append_jsonl(N.month_file(data, ts), row)
        N.write_onedrive_sync_state(self.cfg, self.now - 241 * 60)
        sample = json.loads((data / "2026-11.jsonl").read_text().splitlines()[-1])
        N.push_onedrive(self.cfg, sample, self.now + 300)
        remote = self.root / "sync" / "2026-11.jsonl"
        self.assertTrue(remote.is_file())
        lines = remote.read_text().splitlines()
        self.assertEqual(len(lines), 2)
        for line in lines:
            obj = json.loads(line)
            self.assertNotIn("clients", obj.get("router", {}))
            self.assertNotIn("wan_ip", obj.get("router", {}))

    def test_alerts_copied_on_sync(self):
        local = self.root / "alerts"
        N.write_json_atomic(local / "active.json", {"red": {"Dish": "down"}})
        N.write_json_atomic(local / "ALERT-20261102-1200.json", {"new": {"Dish": "down"}})
        N.write_onedrive_sync_state(self.cfg, self.now - 241 * 60)
        N.push_onedrive(self.cfg, self._sample(self.now), self.now)
        self.assertTrue((self.root / "sync" / "alerts" / "active.json").is_file())
        self.assertTrue((self.root / "sync" / "alerts" / "ALERT-20261102-1200.json").is_file())

    def test_no_sync_dir_skips(self):
        cfg = {"paths": {"data_dir": str(self.root / "data"), "sync_dir": "",
                         "onedrive_sync_interval_min": 0}}
        (self.root / "data").mkdir(exist_ok=True)
        self.assertFalse(N.should_sync_onedrive(cfg, now=self.now))


if __name__ == "__main__":
    unittest.main()
