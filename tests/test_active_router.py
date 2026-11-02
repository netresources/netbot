import sys, time, unittest, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "netbot"))
from live_data import active_router

NOW = time.time()

def s(router=None, lan_mode=None, age=0):
    d = {"ts": NOW - age}
    if router is not None: d["router"] = router
    if lan_mode is not None: d["lan_mode"] = lan_mode
    return d

class ActiveRouter(unittest.TestCase):
    def test_unifi_udm_se(self):
        self.assertEqual(active_router(s({"vendor": "unifi", "model": "UDMPROSE"}, "kit"), NOW), "UniFi Dream Machine SE")
    def test_unifi_other_model(self):
        self.assertEqual(active_router(s({"vendor": "unifi", "model": "UX9"}, "kit"), NOW), "UniFi UX9")
    def test_unifi_beats_path_even_when_skipped(self):
        self.assertEqual(active_router(s({"vendor": "unifi", "model": None, "skipped": "unreachable"}, "kit"), NOW), "UniFi router")
    def test_linksys(self):
        self.assertEqual(active_router(s({"vendor": "linksys"}, "linksys"), NOW), "Linksys router")
    def test_kit(self):
        self.assertEqual(active_router(s({"vendor": "kit"}, "kit"), NOW), "Kit router")
    def test_skipped_linksys_falls_back_to_path(self):
        self.assertEqual(active_router(s({"vendor": "linksys", "skipped": "off-lan"}, "kit"), NOW), "Kit router")
    def test_stale_and_missing(self):
        self.assertEqual(active_router(s({"vendor": "unifi", "model": "UDMPROSE"}, age=3600), NOW), "Unknown")
        self.assertEqual(active_router({}, NOW), "Unknown")
        self.assertEqual(active_router(s(), NOW), "Unknown")

if __name__ == "__main__":
    unittest.main()
