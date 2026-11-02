#!/usr/bin/env python3
"""Monitor control endpoints + v2 UI markers."""
import json, pathlib, sys, threading, time, unittest, urllib.error, urllib.request
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "netbot"))
import live_server as ls

class MonitorControls(unittest.TestCase):
    def setUp(self):
        self.httpd = ls.create_server("127.0.0.1", 0, lan_mode=False, reveal_link=False)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        time.sleep(0.05)

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def _url(self, path):
        return "http://127.0.0.1:%d%s" % (self.port, path)

    def test_monitor_json_loopback(self):
        with urllib.request.urlopen(self._url("/api/monitor.json"), timeout=3) as resp:
            self.assertEqual(resp.status, 200)
            data = json.loads(resp.read().decode())
        self.assertTrue(data.get("controls"))
        self.assertIn("running", data)

    def test_page_includes_controls_and_csrf(self):
        with urllib.request.urlopen(self._url("/"), timeout=3) as resp:
            html = resp.read().decode()
        self.assertIn("id=\"monitor-controls\"", html)
        self.assertIn("data-csrf=\"", html)
        self.assertIn(self.httpd.csrf_token, html)
        self.assertIn("Start Monitoring", html)
        self.assertIn("nb-cosmos", html)
        self.assertIn("nb-cosmos__canvas", html)
        self.assertIn("phone-access", html)
        self.assertIn("Phone access", html)
        self.assertIn("netbot-theme.css?v=", html)
        self.assertIn("live.js?v=", html)

    def test_post_without_csrf_rejected(self):
        req = urllib.request.Request(
            self._url("/api/monitor/stop"), data=b"{}", method="POST",
            headers={"Content-Type": "application/json"},
        )
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req, timeout=3)
        self.assertEqual(ctx.exception.code, 403)

    def test_post_with_csrf_stop_while_paused(self):
        req = urllib.request.Request(
            self._url("/api/monitor/stop"), data=b"{}", method="POST",
            headers={
                "Content-Type": "application/json",
                "X-CSRF-Token": self.httpd.csrf_token,
                "Origin": "http://127.0.0.1:%d" % self.port,
            },
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            self.assertEqual(resp.status, 200)
            data = json.loads(resp.read().decode())
        self.assertTrue(data.get("ok"))
        self.assertFalse(data.get("running"))

    def test_get_start_is_405(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(self._url("/api/monitor/start"), timeout=3)
        self.assertEqual(ctx.exception.code, 405)

    def test_peer_helpers(self):
        self.assertTrue(ls._peer_is_loopback(("127.0.0.1", 12345)))
        self.assertTrue(ls._peer_is_loopback(("::1", 12345)))
        self.assertFalse(ls._peer_is_loopback(("198.51.100.10", 12345)))
        self.assertFalse(ls._peer_is_loopback(("198.51.100.50", 8766)))

    def test_assets_no_store_and_query_ok(self):
        req = urllib.request.Request(self._url("/assets/netbot-theme.css?v=20261102v3c"))
        with urllib.request.urlopen(req, timeout=3) as resp:
            self.assertEqual(resp.status, 200)
            self.assertIn("no-store", (resp.headers.get("Cache-Control") or ""))
            css = resp.read().decode()
        self.assertIn("nb-router-pulse", css)
        self.assertIn("--nb-router-kit", css)
        self.assertIn("nb-router-glow", css)
        with urllib.request.urlopen(self._url("/assets/live.js?v=20261102v3c"), timeout=3) as jr:
            livejs = jr.read().decode()
        self.assertIn("data-glint-count", livejs)
        self.assertIn("nb-btn--flash", livejs)
        self.assertIn("rand(5000, 10000)", livejs)
        self.assertIn("rand(4000, 7000)", livejs)
        self.assertIn("data-glint-angle", livejs)
        self.assertIn("Math.tan(rad)", livejs)

if __name__ == "__main__":
    unittest.main()
