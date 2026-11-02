import os, sys, json, time, tempfile, unittest, pathlib
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "netbot"))
import netbot_common as C
import evaluate_alerts as E
import live_data as L
import ui_text as T

NOW = time.time()
DISH_TILES = set(E.DISH_TILE_NAMES)

def sample(dish=True):
    s = {"ts": NOW - 60, "lan_mode": "kit",
         "network": {"reachable": True, "gateway_ping_ms": 1.0, "internet_latency_ms": 10.0, "internet_loss": 0.0},
         "router": {"vendor": "unifi", "model": "UDMPROSE", "reachable": True, "wan_status": "Connected",
                    "client_count": 51, "firmware": "5.1", "update_available": False}}
    if dish:
        s["dish"] = {"reachable": False}
    return s

class Config(unittest.TestCase):
    def _load(self, text, use_tomllib):
        with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False) as f:
            f.write(text)
        saved = C.tomllib
        try:
            if not use_tomllib:
                C.tomllib = None
            return C.load_config(f.name)
        finally:
            C.tomllib = saved
            os.unlink(f.name)

    def test_default_enabled(self):
        self.assertTrue(C.dish_enabled(self._load('[dish]\ntarget = "192.168.100.1:9200"\n', False)))
        self.assertTrue(C.dish_enabled({}))

    def test_fallback_parser_reads_false(self):
        cfg = self._load('[dish]\nenabled = false\ntarget = "192.168.100.1:9200"\n', False)
        self.assertIs(cfg["dish"]["enabled"], False)
        self.assertFalse(C.dish_enabled(cfg))

    def test_tomllib_reads_false_when_available(self):
        if C.tomllib is None:
            self.skipTest("tomllib not available (Python < 3.11)")
        self.assertFalse(C.dish_enabled(self._load('[dish]\nenabled = false\n', True)))

    def test_string_values(self):
        self.assertFalse(C.dish_enabled({"dish": {"enabled": "false"}}))
        self.assertTrue(C.dish_enabled({"dish": {"enabled": "true"}}))

class Tiles(unittest.TestCase):
    def test_dish_on_keeps_dish_tiles(self):
        t = E.tiles([sample()], NOW)
        self.assertTrue(DISH_TILES <= set(t))
        self.assertEqual(t[T.TILE_DISH_STATUS][0], E.RED)

    def test_dish_off_no_dish_tiles_no_red(self):
        t = E.tiles([sample(dish=False)], NOW, dish=False)
        self.assertFalse(DISH_TILES & set(t))
        self.assertEqual(t[T.TILE_ROUTER][0], E.GREEN)
        self.assertNotIn(E.RED, [lvl for lvl, _ in t.values()])

class Status(unittest.TestCase):
    def test_status_dish_off(self):
        st = L.build_status([sample(dish=False)], NOW, {"dish": {"enabled": False}, "live": {}})
        names = {x["name"] for x in st["tiles"]}
        self.assertFalse(DISH_TILES & names)
        self.assertEqual([s["label"] for s in st["sections"]], [T.SECTION_NETWORK])
        self.assertIs(st["dish_on"], False)
        self.assertEqual(st["chips"][0], {"text": T.CHIP_DISH_OFF, "on": False})
        self.assertEqual(st["active_router"], "UniFi Dream Machine SE")
        self.assertEqual(st["router"]["level"], "green")

    def test_status_dish_on_unchanged(self):
        st = L.build_status([sample()], NOW, {"live": {}})
        self.assertEqual([s["label"] for s in st["sections"]], [T.SECTION_DISH, T.SECTION_NETWORK])
        self.assertEqual(st["sections"][0]["collector"], True)
        self.assertEqual(st["sections"][1]["collector"], False)
        self.assertEqual(st["chips"][0], {"text": T.CHIP_DISH, "on": True})
        self.assertTrue(DISH_TILES & {x["name"] for x in st["tiles"]})

    def test_history(self):
        on = [s["label"] for s in L.build_history([sample()], NOW)["sections"]]
        off = [s["label"] for s in L.build_history([sample(dish=False)], NOW, dish=False)["sections"]]
        self.assertIn(T.SECTION_DISH_24H, on)
        self.assertNotIn(T.SECTION_DISH_24H, off)
        self.assertNotIn(T.SECTION_DISH_7D, off)
        self.assertIn(T.SECTION_NETWORK_24H, off)

    def test_html_snapshot_dish_off(self):
        import make_dashboard as M
        html = M.build_html([sample(dish=False)], NOW, dish_on=False)
        self.assertNotIn(T.SECTION_DISH, html.replace(T.SECTION_DISH_24H, "").replace(T.SECTION_DISH_7D, ""))
        self.assertNotIn(T.SECTION_DISH_24H, html)
        self.assertIn(T.CHIP_DISH_OFF, html)
        self.assertIn(T.SECTION_DISH, M.build_html([sample()], NOW))

class Collect(unittest.TestCase):
    def test_collect_skips_dish_when_disabled(self):
        import collect
        d = tempfile.mkdtemp()
        cfg = C.load_config("/nonexistent")
        cfg["paths"].update({"data_dir": d + "/data", "sync_dir": ""})
        cfg["dish"]["enabled"] = False
        cfg["router"]["enabled"] = False
        called = []
        saved = (collect.load_config, collect.dish_sample, collect.network_sample)
        collect.load_config = lambda *a, **k: cfg
        collect.dish_sample = lambda c: called.append(1) or {}
        collect.network_sample = lambda c, dd: {"reachable": True}
        try:
            collect.main()
        finally:
            collect.load_config, collect.dish_sample, collect.network_sample = saved
        self.assertEqual(called, [])
        rows = [json.loads(l) for f in pathlib.Path(d, "data").glob("*.jsonl") for l in f.read_text().splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertNotIn("dish", rows[0])
        st = json.loads(pathlib.Path(d, "live", "status.json").read_text())
        self.assertFalse(DISH_TILES & {x["name"] for x in st["tiles"]})
        active = json.loads(pathlib.Path(d, "alerts", "active.json").read_text())  # local alerts beside data_dir
        self.assertFalse(DISH_TILES & set(active["red"]))

if __name__ == "__main__":
    unittest.main()
