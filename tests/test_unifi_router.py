import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "netbot"))
import unifi_router as U

CFG = {"router": {"enabled": True, "type": "unifi"}, "unifi": {"host": "10.0.0.1", "api_key_env": "NETBOT_TEST_UNIFI_KEY"}}
P = "/proxy/network"
INTEG = {
    f"{P}/integration/v1/sites": {"data": [{"id": "s1", "internalReference": "default", "name": "Default"}]},
    f"{P}/integration/v1/sites/s1/devices?limit=200": {"data": [
        {"id": "ap1", "model": "U6-Pro", "state": "ONLINE", "features": ["accessPoint"]},
        {"id": "gw1", "model": "UCG-Ultra", "state": "ONLINE", "features": ["switching"]}]},
    f"{P}/integration/v1/sites/s1/devices/gw1": {"firmwareVersion": "4.1.13", "firmwareUpdatable": False},
    f"{P}/integration/v1/sites/s1/clients?limit=1": {"data": [{}], "totalCount": 23},
}
LEGACY = {
    f"{P}/api/s/default/stat/health": {"data": [{"subsystem": "wan", "status": "ok"},
        {"subsystem": "wlan", "num_user": 10, "num_guest": 2}, {"subsystem": "lan", "num_user": 5}]},
    f"{P}/api/s/default/stat/device": {"data": [{"type": "uap", "model": "U6"},
        {"type": "udm", "model": "UDMPRO", "version": "4.0.6", "upgradable": True}]},
}

def fake(routes, calls):
    def factory(cfg, key):
        assert key == "secret-not-printed"
        def get(path):
            calls.append(path)
            if path not in routes:
                raise U.HttpError(404)
            r = routes[path]
            if isinstance(r, Exception):
                raise r
            return r
        return get
    return factory

class T(unittest.TestCase):
    def setUp(self): os.environ["NETBOT_TEST_UNIFI_KEY"] = "secret-not-printed"
    def tearDown(self): os.environ.pop("NETBOT_TEST_UNIFI_KEY", None)

    def run_s(self, routes, cfg=CFG, reach=True):
        calls = []
        r = U.sample(cfg, getter_factory=fake(routes, calls), reach=lambda c: reach)
        self.assertNotIn("secret-not-printed", repr(r))
        return r, calls

    def test_integration_plus_legacy_wan(self):
        r, calls = self.run_s({**INTEG, **LEGACY})
        self.assertEqual((r["vendor"], r["model"], r["reachable"], r["wan_status"], r["client_count"], r["firmware"]),
                         ("unifi", "UCG-Ultra", True, "Connected", 23, "4.1.13"))
        self.assertFalse(r["update_available"]); self.assertEqual(r["api"], "integration")
        self.assertEqual(r["wan_source"], "health")

    def test_integration_only_wan_from_gateway_state(self):
        r, _ = self.run_s(INTEG)
        self.assertEqual(r["wan_status"], "Connected"); self.assertEqual(r["wan_source"], "gateway_state")
        self.assertIn("legacy", r["partial"])

    def test_legacy_only(self):
        r, _ = self.run_s(LEGACY)
        self.assertEqual((r["api"], r["model"], r["firmware"], r["client_count"], r["wan_status"]),
                         ("legacy", "UDMPRO", "4.0.6", 17, "Connected"))
        self.assertTrue(r["update_available"])

    def test_wan_down(self):
        routes = {**INTEG, **LEGACY, f"{P}/api/s/default/stat/health": {"data": [{"subsystem": "wan", "status": "error"}]}}
        self.assertEqual(self.run_s(routes)[0]["wan_status"], "Disconnected")

    def test_key_rejected(self):
        r, _ = self.run_s({f"{P}/integration/v1/sites": U.HttpError(401)})
        self.assertFalse(r["reachable"]); self.assertIn("rejected", r["error"])

    def test_all_fail(self):
        r, _ = self.run_s({})
        self.assertFalse(r["reachable"]); self.assertEqual(r["skipped"], "unreachable")

    def test_off_network_gray_skip(self):
        r, calls = self.run_s(INTEG, reach=False)
        self.assertEqual(r["skipped"], "off_lan"); self.assertEqual(calls, [])

    def test_not_configured(self):
        r, _ = self.run_s(INTEG, cfg={"router": {"type": "unifi"}})
        self.assertEqual(r["skipped"], "not_configured")

    def test_missing_key(self):
        os.environ.pop("NETBOT_TEST_UNIFI_KEY")
        cfg = {"unifi": {"host": "10.0.0.1", "api_key_env": "NETBOT_TEST_UNIFI_KEY", "keychain_service": "netbot-test-nonexistent-zz"}}
        r = U.sample(cfg, getter_factory=fake({}, []), reach=lambda c: True)
        self.assertIn("Keychain", r["error"])

    def test_get_only(self):
        _, calls = self.run_s({**INTEG, **LEGACY})
        self.assertTrue(all(c.startswith(P) for c in calls))

    def test_selfhosted_prefix(self):
        cfg = {"unifi": {"host": "h", "path_prefix": "", "api_key_env": "NETBOT_TEST_UNIFI_KEY"}}
        routes = {k[len(P):]: v for k, v in {**INTEG, **LEGACY}.items()}
        r, _ = self.run_s(routes, cfg=cfg)
        self.assertEqual(r["client_count"], 23)

class Dispatch(unittest.TestCase):
    def test_auto_unchanged_without_unifi(self):
        import collect
        self.assertEqual(collect.resolve_router_vendor({"router": {"type": "auto"}}, "linksys"), "linksys")
        self.assertEqual(collect.resolve_router_vendor({"router": {"type": "auto"}}, "kit"), "kit")
    def test_auto_unifi_unreachable_falls_back(self):
        import collect
        cfg = {"router": {"type": "auto"}, "unifi": {"host": "192.0.2.1", "port": 9}}
        self.assertEqual(collect.resolve_router_vendor(cfg, "kit"), "kit")

if __name__ == "__main__":
    unittest.main()
