#!/usr/bin/env python3
"""Tests for netbot/migrate_legacy.py (one-time rewrite of old key names). Run: python3 tests/test_migrate_legacy.py
The old name is taken from the migration module itself, so it is written in exactly one file."""
import json, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "netbot"))
import migrate_legacy as M                                              # noqa: E402
from dish_constants import DISH_CFG_SECTION, DISH_PATHS_KEY, DISH_DATA_KEY  # noqa: E402

OLD = M.LEGACY_KEY

class Migrate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.nb_dir = Path(self.tmp.name) / "NetBot"
        self.sync = Path(self.tmp.name) / "cloud" / "NetBot"
        (self.nb_dir / "data").mkdir(parents=True)
        self.sync.mkdir(parents=True)
        self.cfg = self.nb_dir / "config.toml"
        self.cfg.write_text(f'[paths]\ndata_dir = "{self.nb_dir}/data"\nsync_dir = "{self.sync}"\n{OLD}_tools = "{self.nb_dir}/dish-lib"\n\n'
                            f'[{OLD}]\ntarget = "dish-address:9200"\n\n[router]\nenabled = false\nhost = "{OLD}-note-kept"\n')
        self.month = self.nb_dir / "data" / "2026-10.jsonl"
        rows = [{"ts": 1, OLD: {"reachable": True, "state": "CONNECTED"}, "network": {"internet_loss": 0}},
                {"ts": 2, DISH_DATA_KEY: {"reachable": True}}]          # already new: left as is
        self.month.write_text("\n".join(json.dumps(r) for r in rows) + "\nnot json\n")
        (self.sync / "latest.json").write_text(json.dumps({"ts": 1, OLD: {"reachable": True}}))

    def tearDown(self):
        self.tmp.cleanup()

    def test_rewrites_config_data_and_synced_copy(self):
        done = M.run(self.nb_dir)
        self.assertEqual({p.name for p in done}, {"config.toml", "2026-10.jsonl", "latest.json"})
        cfg = self.cfg.read_text()
        self.assertIn(f"[{DISH_CFG_SECTION}]", cfg)
        self.assertIn(f'{DISH_PATHS_KEY} = "{self.nb_dir}/dish-lib"', cfg)
        self.assertNotIn(f"[{OLD}]", cfg)
        self.assertNotIn(f"{OLD}_tools", cfg)
        self.assertIn(f'host = "{OLD}-note-kept"', cfg, "only the section header and the path key are renamed")
        lines = self.month.read_text().splitlines()
        first = json.loads(lines[0])
        self.assertEqual(first[DISH_DATA_KEY]["state"], "CONNECTED")
        self.assertNotIn(OLD, first)
        self.assertEqual(json.loads(lines[1]), {"ts": 2, DISH_DATA_KEY: {"reachable": True}})
        self.assertEqual(lines[2], "not json", "unreadable lines are kept unchanged")
        self.assertIn(DISH_DATA_KEY, json.loads((self.sync / "latest.json").read_text()))

    def test_runs_once(self):
        M.run(self.nb_dir)
        self.assertTrue((self.nb_dir / ".netbot-state" / M.MARKER).exists())
        (self.sync / "latest.json").write_text(json.dumps({OLD: {}}))
        self.assertEqual(M.run(self.nb_dir), [], "second run does nothing")
        self.assertIn(OLD, json.loads((self.sync / "latest.json").read_text()))

    def test_fresh_install_is_a_no_op(self):
        home = Path(self.tmp.name) / "fresh"
        self.assertEqual(M.run(home), [])
        self.assertTrue((home / ".netbot-state" / M.MARKER).exists())

    def test_migrated_history_feeds_the_dashboard(self):
        M.run(self.nb_dir)
        from netbot_common import read_samples
        s = read_samples(self.nb_dir / "data", 0)
        self.assertTrue(s and s[0][DISH_DATA_KEY]["reachable"])

    def test_old_name_written_in_one_line_only(self):
        src = (ROOT / "netbot" / "migrate_legacy.py").read_text().splitlines()
        self.assertEqual([l for l in src if OLD in l], [f'LEGACY_KEY = "{OLD}"'])

if __name__ == "__main__":
    unittest.main(verbosity=2)
