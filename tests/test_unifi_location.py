import os, sys, unittest
from unittest import mock
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "netbot"))
import unifi_router as U
import collect

CFG = {"router": {"enabled": True, "type": "auto"}, "unifi": {"host": "192.168.1.1"}}


class Loc(unittest.TestCase):
    def test_tcp_closed_means_not_here(self):
        with mock.patch.object(U.socket, "create_connection", side_effect=OSError):
            self.assertFalse(U.host_reachable(CFG))

    def test_other_device_on_same_ip_is_not_unifi(self):
        with mock.patch.object(U.socket, "create_connection"), mock.patch.object(U, "_is_unifi_os", return_value=False):
            self.assertFalse(U.host_reachable(CFG))

    def test_unifi_os_signature(self):
        with mock.patch.object(U.socket, "create_connection"), mock.patch.object(U, "_is_unifi_os", return_value=True):
            self.assertTrue(U.host_reachable(CFG))

    def test_auto_picks_unifi_when_host_is_unifi_os(self):
        with mock.patch.object(U, "host_reachable", return_value=True):
            self.assertEqual(collect.resolve_router_vendor(CFG, "kit"), "unifi")

    def test_auto_unchanged_at_home(self):
        with mock.patch.object(U, "host_reachable", return_value=False):
            self.assertEqual(collect.resolve_router_vendor(CFG, "linksys"), "linksys")
            self.assertEqual(collect.resolve_router_vendor(CFG, "kit"), "kit")

    def test_no_unifi_config_unchanged(self):
        cfg = {"router": {"enabled": True, "type": "auto"}}
        self.assertEqual(collect.resolve_router_vendor(cfg, "linksys"), "linksys")


if __name__ == "__main__":
    unittest.main()
