#!/usr/bin/env python3
"""Offline tests for netbot/network_checks.py and the network tiles, with fake ping/ip/networkQuality
(tests/fakebin). Usage: python3 tests/test_network_checks.py"""
import json, os, sys, tempfile, time, unittest
from datetime import date, timedelta
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "netbot"))
FAKE = ROOT / "tests" / "fakebin"
os.environ["PATH"] = f"{FAKE}{os.pathsep}{os.environ['PATH']}"
os.environ["NETBOT_PING"] = str(FAKE / "ping")
os.environ["NETBOT_NETWORKQUALITY"] = str(FAKE / "networkQuality")
import network_checks as nc
import evaluate_alerts as ev
import linksys_jnap as jnap
import theme_tokens as TH
import ui_text as T

def cfg(**net):
    base = {"gateway": "", "internet_targets": "198.51.100.7", "ping_count": 3, "speedtest": "auto", "speedtest_every_h": 6}
    base.update(net)
    return {"network": base}

class NetworkChecks(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self._plat = sys.platform
        sys.platform = "linux"           # use the fake `ip` for the default gateway

    def tearDown(self):
        sys.platform = self._plat

    def test_gateway_latency_loss_speed(self):
        s = nc.network_sample(cfg(), self.d)
        self.assertTrue(s["gateway_found"])
        self.assertNotIn("gateway", s)                          # the address is not recorded
        self.assertEqual(s["gateway_ping_ms"], 1.5)
        self.assertEqual(s["gateway_loss"], 0.0)
        self.assertEqual(s["internet_latency_ms"], 42.0)        # median of 40, 42, 44
        self.assertEqual(s["internet_jitter_ms"], 2.0)
        self.assertEqual(s["internet_loss"], 0.0)
        self.assertEqual((s["speedtest_status"], s["speedtest_down_mbps"], s["speedtest_up_mbps"]), ("ok", 182.4, 19.4))

    def test_speed_test_runs_at_most_once_per_interval(self):
        nc.network_sample(cfg(), self.d)
        self.assertEqual(nc.network_sample(cfg(), self.d)["speedtest_status"], "not due")
        Path(self.d, ".speedtest_last").write_text(f"{time.time() - 7 * 3600:.0f}\n")
        self.assertEqual(nc.network_sample(cfg(), self.d)["speedtest_status"], "ok")

    def test_speed_test_off_or_unavailable(self):
        self.assertEqual(nc.network_sample(cfg(speedtest="off"), self.d)["speedtest_status"], "off")
        os.environ["NETBOT_NETWORKQUALITY"] = "/nonexistent/networkQuality"
        try:
            self.assertIn(nc.network_sample(cfg(), self.d)["speedtest_status"], ("unavailable", "failed"))
        finally:
            os.environ["NETBOT_NETWORKQUALITY"] = str(FAKE / "networkQuality")

    def test_partial_and_total_loss(self):
        s = nc.network_sample(cfg(internet_targets="198.51.100.7 203.0.113.9", speedtest="off"), self.d)
        self.assertEqual(s["internet_loss"], 0.5)
        s = nc.network_sample(cfg(internet_targets="203.0.113.9", gateway="203.0.113.9", speedtest="off"), self.d)
        self.assertEqual((s["internet_loss"], s["internet_latency_ms"], s["gateway_loss"], s["gateway_ping_ms"]), (1.0, None, 1.0, None))

    def test_no_ping_tool(self):
        os.environ["NETBOT_PING"] = "/nonexistent/ping"
        try:
            s = nc.network_sample(cfg(speedtest="off"), self.d)
            self.assertFalse(s["reachable"])
        finally:
            os.environ["NETBOT_PING"] = str(FAKE / "ping")

class WindowsChecks(unittest.TestCase):
    """Windows ping, gateway and speed-test paths (sys.platform faked; fake tools print Windows-style output)."""
    PING_EN = ("Pinging 198.51.100.7 with 32 bytes of data:\r\nReply from 198.51.100.7: bytes=32 time=12ms TTL=57\r\n"
               "Reply from 198.51.100.7: bytes=32 time<1ms TTL=57\r\nRequest timed out.\r\n")
    PING_DE = "Antwort von 198.51.100.7: Bytes=32 Zeit=40ms TTL=57\nAntwort von 198.51.100.7: Bytes=32 Zeit=44ms TTL=57\n"
    ROUTE = ("IPv4 Route Table\n===\nActive Routes:\nNetwork Destination        Netmask          Gateway       Interface  Metric\n"
             "          0.0.0.0          0.0.0.0     198.51.100.7   198.51.100.7     25\n")

    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self._plat, sys.platform = sys.platform, "win32"
        self._env = dict(os.environ)

    def tearDown(self):
        sys.platform = self._plat
        os.environ.clear(); os.environ.update(self._env)

    def fake(self, name, out, rc=0):
        f = self.d / name
        f.write_text("#!/bin/sh\ncat <<'OUT'\n" + out + "\nOUT\nexit %d\n" % rc)
        f.chmod(0o755)
        return str(f)

    def test_windows_ping_parsing_any_language(self):
        r = nc.parse_windows_ping(self.PING_EN, 3)
        self.assertEqual((r["received"], r["rtts"]), (2, [12.0, 1.0]))
        self.assertAlmostEqual(r["loss"], 1 / 3)
        self.assertEqual(nc.parse_windows_ping(self.PING_DE, 2)["rtts"], [40.0, 44.0])
        self.assertEqual(nc.parse_windows_ping("Request timed out.\n", 2)["loss"], 1.0)

    def test_windows_gateway_and_ping_tool(self):
        os.environ["NETBOT_ROUTE"] = self.fake("route", self.ROUTE)
        self.assertEqual(nc.default_gateway(), "198.51.100.7")
        os.environ["NETBOT_PING"] = self.fake("ping", self.PING_DE)
        self.assertEqual(nc.ping("198.51.100.7", 2)["rtts"], [40.0, 44.0])

    def test_windows_speed_test_download_only(self):
        os.environ["NETBOT_NETWORKQUALITY"] = "/nonexistent/networkQuality"
        os.environ["NETBOT_POWERSHELL"] = self.fake("powershell", '{"down_mbps":160.0,"bytes":25000000,"seconds":1.25}')
        r = nc.speed_test(self.d / ".last", 6, "auto", "test-file-url")
        self.assertEqual((r["speedtest_status"], r["speedtest_down_mbps"], r.get("speedtest_up_mbps")), ("ok", 160.0, None))
        self.assertEqual(nc.speed_test(self.d / ".last", 6, "auto", "u")["speedtest_status"], "not due")

    def test_windows_speed_test_failure_and_no_url(self):
        os.environ["NETBOT_NETWORKQUALITY"] = "/nonexistent/networkQuality"
        os.environ["NETBOT_POWERSHELL"] = self.fake("powershell", '{"error":"download failed: WebException"}', rc=1)
        self.assertEqual(nc.speed_test(self.d / ".a", 6, "auto", "u")["speedtest_status"], "failed")
        self.assertEqual(nc.speed_test(self.d / ".b", 6, "auto", "")["speedtest_status"], "unavailable")

class NetworkTiles(unittest.TestCase):
    def sample(self, ts, **net):
        return {"ts": ts, "network": {"reachable": True, "gateway_found": True, "gateway_ping_ms": 1.5, "gateway_loss": 0.0,
                                      "internet_latency_ms": 40.0, "internet_loss": 0.0, **net}}

    def test_levels(self):
        now = time.time()
        t = ev.network_tiles([self.sample(now - 60, speedtest_down_mbps=182.0)], now)
        self.assertEqual({k: v[0] for k, v in t.items()}, {T.TILE_GATEWAY_PING: "green", T.TILE_INTERNET_LATENCY: "green",
                                                            T.TILE_PACKET_LOSS: "green", T.TILE_SPEED_TEST: "green"})
        t = ev.network_tiles([self.sample(now - 60, internet_latency_ms=80.0, internet_loss=0.03, speedtest_down_mbps=60.0)], now)
        self.assertEqual([t[k][0] for k in (T.TILE_INTERNET_LATENCY, T.TILE_PACKET_LOSS, T.TILE_SPEED_TEST)], ["yellow"] * 3)
        t = ev.network_tiles([self.sample(now - 60, internet_latency_ms=120.0, internet_loss=0.2, gateway_loss=1.0,
                                          gateway_ping_ms=None, speedtest_down_mbps=20.0)], now)
        self.assertEqual([t[k][0] for k in (T.TILE_GATEWAY_PING, T.TILE_INTERNET_LATENCY, T.TILE_PACKET_LOSS, T.TILE_SPEED_TEST)], ["red"] * 4)

    def test_no_data(self):
        t = ev.network_tiles([{"ts": time.time()}], time.time())
        self.assertTrue(all(v[0] == "gray" for v in t.values()))

    def test_router_tile_names_the_tripped_check(self):
        now = time.time()

        def row(**router):
            return {"ts": now, "router": router}

        tiles = ev.tiles
        level, text = tiles([row(reachable=True, wan_status="Connected", client_count=4, firmware="1.2.3")], now)[T.TILE_ROUTER]
        self.assertEqual(level, "gray")
        self.assertEqual(text, "WAN Connected, 4 clients, firmware not checked")
        self.assertNotIn("\n", text)
        self.assertNotIn("firmware up to date", text)
        self.assertEqual(TH.LEVELS["gray"][0], "--nb-nodata")
        level, text = tiles([row(reachable=True, wan_status="Connected", client_count=4,
                                  firmware="1.2.3", update_available=False)], now)[T.TILE_ROUTER]
        self.assertEqual(level, "green")
        self.assertEqual(text, "WAN Connected, 4 clients, firmware up to date")
        level, text = tiles([row(reachable=True, wan_status="Connected", client_count=4,
                                  firmware="1.2.3", update_available=True)], now)[T.TILE_ROUTER]
        self.assertEqual(level, "yellow")
        summary, check = text.split("\n")
        self.assertIn("update available", summary)
        self.assertNotIn("1.2.3", text)
        self.assertEqual(check, "firmware")
        level, text = tiles([row(reachable=True, wan_status="Connected", client_count=4,
                                  firmware="1.2.3", end_of_support=True)], now)[T.TILE_ROUTER]
        self.assertEqual(level, "yellow")
        summary, check = text.split("\n")
        self.assertIn("past end of support", summary)
        self.assertEqual(check, "past end of support")
        self.assertNotIn("EOS", text)
        self.assertNotIn("firmware up to date", text)
        level, text = tiles([row(reachable=True, wan_status="Disconnected", client_count=4, firmware="1.2.3")], now)[T.TILE_ROUTER]
        self.assertEqual(level, "red")
        self.assertIn("firmware not checked", text)
        self.assertEqual(text.split("\n")[-1], "WAN status")
        level, text = tiles([row(reachable=False, error="timeout")], now)[T.TILE_ROUTER]
        self.assertEqual(level, "red")
        self.assertEqual(text.split("\n"), ["router unreachable", "router reachable"])
        level, text = tiles([row(reachable=False, error="Keychain item missing")], now)[T.TILE_ROUTER]
        self.assertEqual(level, "red")
        self.assertEqual(text.split("\n"), ["Keychain item missing", "keychain"])
        level, text = tiles([], now)[T.TILE_ROUTER]
        self.assertEqual(level, "gray")
        self.assertEqual(text, "not monitored")
        css = (ROOT / "netbot/theme/netbot-theme.css").read_text(encoding="utf-8")
        self.assertIn(".nb-system__text {", css)
        self.assertIn("white-space: pre-line", css)

    def test_router_firmware_hides_make_and_model(self):
        now = time.time()
        router = {
            "reachable": True, "model": "EA9500", "hw_version": "1.1", "firmware": "1.1.9.210876",
            "firmware_date": "2020-01-01", "wan_status": "Connected", "client_count": 14,
        }
        level, text = ev.tiles([{"ts": now, "router": router}], now)[T.TILE_ROUTER]
        self.assertEqual(level, "gray")
        self.assertIn("firmware not checked", text)
        self.assertNotIn("firmware up to date", text)
        for hidden in ("EA9500", "1.1", "1.1.9.210876", "2020-01-01", "EOS"):
            self.assertNotIn(hidden, text)
        router["end_of_support"] = True
        level, text = ev.tiles([{"ts": now, "router": router}], now)[T.TILE_ROUTER]
        self.assertEqual(level, "yellow")
        self.assertIn("past end of support", text)
        self.assertNotIn("EOS", text)
        for hidden in ("EA9500", "1.1", "1.1.9.210876", "2020-01-01"):
            self.assertNotIn(hidden, text)
        router["end_of_support"] = False
        router["update_available"] = True
        level, text = ev.tiles([{"ts": now, "router": router}], now)[T.TILE_ROUTER]
        self.assertEqual(level, "yellow")
        self.assertIn("update available", text)
        self.assertNotIn("firmware up to date", text)
        self.assertNotIn("firmware not checked", text)
        for hidden in ("EA9500", "1.1.9.210876"):
            self.assertNotIn(hidden, text)

    def test_full_tiles_include_network_and_neutral_names(self):
        now = time.time()
        names = ev.tiles([self.sample(now - 60)], now).keys()
        for k in (T.TILE_DISH_STATUS, T.TILE_GATEWAY_PING, T.TILE_SPEED_TEST, T.TILE_ROUTER):
            self.assertIn(k, names)

class _RouterInfo:
    """Just enough of a JNAP client for summarize(): model comes from GetDeviceInfo."""
    def __init__(self, model):
        self.model = model

    def call(self, name):
        if name == "GetDeviceInfo":
            info = {"firmwareVersion": "1.2.3", "hardwareVersion": "1", "services": []}
            if self.model is not None:
                info["modelNumber"] = self.model
            return info
        if name == "GetWANStatus":
            return {"wanStatus": "Connected"}
        if name == "GetDevices":
            return {"devices": []}
        if name == "GetNetworkConnections":
            return {"connections": []}
        if name == "GetFirmwareUpdateSettings":
            return {"updatePolicy": "Auto"}
        raise AssertionError(name)


class LinksysEndOfSupport(unittest.TestCase):
    """End-of-support lives in the Linksys add-on. The model number stays out of the tile."""
    WHEN = date(2026, 10, 20)

    def tile(self, summary):
        now = time.time()
        return ev.tiles([{"ts": now, "router": summary}], now)[T.TILE_ROUTER]

    def test_ea9500_is_past_support_and_the_router_tile_is_yellow(self):
        out = jnap.summarize(_RouterInfo("EA9500"), today=self.WHEN)
        self.assertIs(out["end_of_support"], True)
        level, text = self.tile(out)
        self.assertEqual(level, "yellow")
        self.assertIn("past end of support", text)
        self.assertNotIn("EA9500", text)
        self.assertNotIn("EOS", text)

    def test_regional_suffix_matches_the_base_model(self):
        out = jnap.summarize(_RouterInfo("EA9300-CA"), today=self.WHEN)
        self.assertIs(out["end_of_support"], True)
        self.assertEqual(out["model"], "EA9300-CA")
        level, text = self.tile(out)
        self.assertEqual(level, "yellow")
        self.assertNotIn("EA9300", text)
        spaced = jnap.summarize(_RouterInfo("  ea9300-ca  "), today=self.WHEN)
        self.assertIs(spaced["end_of_support"], True)

    def test_unlisted_model_is_false_and_the_tile_is_not_yellow(self):
        out = jnap.summarize(_RouterInfo("MX5500"), today=self.WHEN)
        self.assertIs(out["end_of_support"], False)
        level, text = self.tile(out)
        self.assertNotEqual(level, "yellow")
        self.assertNotIn("past end of support", text)
        self.assertNotIn("MX5500", text)

    def test_listed_model_before_its_date_is_false(self):
        eos = jnap.END_OF_SUPPORT["EA9500"]
        out = jnap.summarize(_RouterInfo("EA9500"), today=eos - timedelta(days=1))
        self.assertIs(out["end_of_support"], False)
        level, text = self.tile(out)
        self.assertNotEqual(level, "yellow")
        self.assertNotIn("EA9500", text)

    def test_unknown_model_leaves_the_flag_unset(self):
        for model in (None, "", "   "):
            out = jnap.summarize(_RouterInfo(model), today=self.WHEN)
            self.assertNotIn("end_of_support", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
