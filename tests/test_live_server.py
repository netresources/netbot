#!/usr/bin/env python3
"""Live page server: allowlist, traversal, methods, access key, JSON, and the polling page."""
import ast, hashlib, http.client, io, ipaddress, json, os, re, sys, tempfile, threading, time, unittest, urllib.parse
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "netbot"))
import live_data          # noqa: E402
import live_server        # noqa: E402
import make_dashboard     # noqa: E402
import theme_tokens as TH  # noqa: E402
import ui_text as T       # noqa: E402

NOW = time.mktime((2026, 10, 19, 6, 45, 0, 0, 0, -1))
SENTINEL = "SENTINEL-OUTSIDE-FILE"
EXT_URL = re.compile(r"https?://", re.I)
IPV4 = re.compile(r"(?:\d{1,3}\.){3}\d{1,3}")


def hdr(headers, name):
    for key, val in headers:
        if key.lower() == name.lower():
            return val
    return ""


class LiveCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="nb-live-")
        self.servers = []
        self.files = []
        self._env = os.environ.get("NETBOT_CONFIG")

    def tearDown(self):
        for srv in self.servers:
            try:
                srv.shutdown()
            except Exception:
                pass
            try:
                srv.server_close()
            except Exception:
                pass
        for path in self.files:
            try:
                os.unlink(path)
            except OSError:
                pass
        if self._env is None:
            os.environ.pop("NETBOT_CONFIG", None)
        else:
            os.environ["NETBOT_CONFIG"] = self._env

    def fill(self):
        import mock_data
        data = Path(self.tmp) / "data"
        mock_data.main(str(data), NOW)
        cfg = {
            "paths": {"data_dir": str(data), "sync_dir": ""},
            "live": {"lan": False, "port": 8765},
            "network": {"internet_targets": "localhost"},
            "alerts": {"quiet_start": 22, "quiet_end": 6},
            "router": {"enabled": True},
        }
        return data, cfg

    def start(self, **kw):
        bind = kw.pop("bind", live_server.default_bind_host())
        srv = live_server.create_server(bind, 0, **kw)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.servers.append(srv)
        return srv

    def request(self, srv, method, path, headers=None):
        host, port = srv.server_address
        last = None
        for _ in range(25):
            try:
                conn = http.client.HTTPConnection(host, port, timeout=5)
                conn.request(method, path, headers=headers or {})
                resp = conn.getresponse()
                body = resp.read()
                got = resp.getheaders()
                status = resp.status
                conn.close()
                return status, got, body
            except OSError as exc:
                last = exc
                time.sleep(0.05)
        raise last

    def keyfile(self):
        path = Path(self.tmp) / "config" / "live-access.key"
        self.files.append(str(path))
        self.files.append(str(path) + ".rotating")
        return path


class RouteAndMethodTests(LiveCase):
    def test_allowlist_and_unknown_paths(self):
        data, cfg = self.fill()
        status, history = live_data.write(cfg, now=NOW)
        srv = self.start(data_dir=data, cfg=cfg, status_file=status, history_file=history)
        for path in ("/", "/index.html", "/assets/tokens.css", "/assets/netbot-theme.css",
                     "/assets/netbot-live.css", "/assets/uplot.js", "/assets/live.js",
                     "/api/status.json", "/api/history.json", "/api/access.json"):
            code, headers, body = self.request(srv, "GET", path)
            self.assertEqual(code, 200, path)
            self.assertIn("default-src 'self'", hdr(headers, "Content-Security-Policy"))
            self.assertEqual(hdr(headers, "X-Content-Type-Options"), "nosniff")
            self.assertEqual(hdr(headers, "Referrer-Policy"), "no-referrer")
            self.assertEqual(hdr(headers, "X-Frame-Options"), "DENY")
            self.assertTrue(body)
        code, _, body = self.request(srv, "GET", "/favicon.ico")
        self.assertEqual(code, 404)
        self.assertNotIn(b"Index of", body)
        code, _, body = self.request(srv, "GET", "/assets/")
        self.assertEqual(code, 404)
        self.assertNotIn(b"tokens.css", body)
        code, headers, _ = self.request(srv, "HEAD", "/")
        self.assertEqual(code, 200)
        self.assertEqual(_, b"")
        self.assertGreater(int(hdr(headers, "Content-Length")), 0)
        code, headers, _ = self.request(srv, "GET", "/api/status.json")
        self.assertEqual(hdr(headers, "Cache-Control"), "no-store")
        code, headers, body = self.request(srv, "GET", "/")
        self.assertEqual(hdr(headers, "Cache-Control"), "no-store")
        self.assertIn(b"<title>NetBot: Connection Monitor</title>", body)
        self.assertIn(b"Connection Monitor", body)
        self.assertNotIn(b"__PRODUCT_TITLE__", body)

    def test_methods_are_rejected(self):
        srv = self.start()
        for method in ("POST", "PUT", "DELETE", "PATCH", "OPTIONS", "TRACE"):
            code, headers, _ = self.request(srv, method, "/api/status.json")
            self.assertEqual(code, 405, method)
            allow = hdr(headers, "Allow")
            self.assertIn("GET", allow)
            self.assertIn("HEAD", allow)

    def test_path_traversal_is_not_found(self):
        outside = Path(self.tmp) / "secret.txt"
        outside.write_text(SENTINEL, encoding="utf-8")
        self.files.append(str(outside))
        srv = self.start()
        paths = (
            "/%2e%2e/" + outside.name,
            "/%2e%2e%2f" + outside.name,
            "/%252e%252e/" + outside.name,
            "/assets/%2e%2e/%2e%2e/" + outside.name,
            "/assets/../../" + outside.name,
            "/assets/..\\..\\" + outside.name,
            "/assets/..%5c..%5c" + outside.name,
            "/%2e%2e/%2e%2e/%2e%2e/" + outside.name,
        )
        for path in paths:
            code, _, body = self.request(srv, "GET", path)
            self.assertEqual(code, 404, path)
            self.assertNotIn(SENTINEL.encode(), body)
            self.assertNotIn(b"..", body)

    def test_symlink_outside_the_map_is_not_served(self):
        outside = Path(self.tmp) / "secret.txt"
        outside.write_text(SENTINEL, encoding="utf-8")
        self.files.append(str(outside))
        folder = Path(self.tmp) / "live"
        folder.mkdir()
        link = folder / "status.json"
        os.symlink(outside, link)
        srv = self.start(status_file=link, history_file=folder / "history.json", data_dir=Path(self.tmp) / "data")
        code, _, body = self.request(srv, "GET", "/api/status.json")
        self.assertEqual(code, 404)
        self.assertNotIn(SENTINEL.encode(), body)
        asset = Path(self.tmp) / "sub"
        asset.mkdir()
        evil = asset / "evil.js"
        os.symlink(outside, evil)
        with mock.patch.dict(live_server.FILES, {"livejs": evil}):
            srv2 = self.start()
            code, _, body = self.request(srv2, "GET", "/assets/live.js")
            self.assertEqual(code, 404)
            self.assertNotIn(SENTINEL.encode(), body)

    def test_default_bind_is_loopback(self):
        host = live_server.default_bind_host()
        self.assertTrue(ipaddress.ip_address(host).is_loopback)
        srv = self.start()
        self.assertTrue(ipaddress.ip_address(srv.server_address[0]).is_loopback)
        src = (ROOT / "netbot" / "live_server.py").read_text(encoding="utf-8")
        nets = live_server._HOME_NETS
        self.assertEqual(sorted(set(IPV4.findall(src))), sorted(str(net.network_address) for net in nets))
        self.assertIn("hmac.compare_digest", src)
        self.assertIn("token_urlsafe(32)", src)
        self.assertIn("0o600", src)
        plan = live_server.listener_plan({"live": {"lan": False, "port": 8765}, "network": {}})
        self.assertEqual(len(plan), 1)
        self.assertTrue(ipaddress.ip_address(plan[0]["host"]).is_loopback)
        self.assertFalse(plan[0]["lan_mode"])
        self.assertFalse(plan[0]["reveal"])

    def test_lan_plan_does_not_listen_on_every_interface(self):
        self.assertIsNone(live_server.lan_ipv4({"network": {"internet_targets": "localhost"}}))
        cfg = {"live": {"lan": True, "port": 8765}, "network": {"internet_targets": "localhost"}}
        missing = live_server.listener_plan(cfg)
        self.assertEqual(len(missing), 1)
        self.assertEqual(missing[0]["note"], "no-address")
        self.assertFalse(missing[0]["reveal"])
        self.assertTrue(ipaddress.ip_address(missing[0]["host"]).is_loopback)
        fake = "10.0.0.1"
        with mock.patch("live_server.lan_ipv4", return_value=fake):
            plan = live_server.listener_plan(cfg)
        self.assertEqual(len(plan), 2)
        self.assertTrue(plan[0]["reveal"])
        self.assertFalse(plan[0]["lan_mode"])
        self.assertTrue(plan[1]["lan_mode"])
        self.assertFalse(plan[1]["reveal"])
        self.assertFalse(ipaddress.ip_address(plan[1]["host"]).is_unspecified)
        self.assertFalse(ipaddress.ip_address(plan[1]["host"]).is_loopback)

    def test_lan_ipv4_accepts_only_private_ranges(self):
        class Sock:
            ip = ""

            def __init__(self, *args, **kwargs):
                pass

            def connect(self, address):
                return None

            def getsockname(self):
                return (Sock.ip, 9)

            def close(self):
                return None

        cfg = {"network": {"internet_targets": "probe"}}
        accept = (
            "10.0.0.1", "10.255.255.254",
            "172.16.0.1", "172.31.255.254",
            "192.168.0.1", "192.168.255.254",
        )
        reject = (
            "11.0.0.0", "172.15.255.255", "172.32.0.1", "192.169.0.0",
            "100.64.0.1", "169.254.1.1", "203.0.113.9",
        )
        for ip in accept:
            Sock.ip = ip
            err = io.StringIO()
            with mock.patch("socket.socket", Sock), mock.patch("sys.stderr", err):
                got = live_server.lan_ipv4(cfg)
            self.assertEqual(got, ip)
            self.assertNotIn("No LAN listener", err.getvalue())
        for ip in reject:
            Sock.ip = ip
            err = io.StringIO()
            with mock.patch("socket.socket", Sock), mock.patch("sys.stderr", err):
                got = live_server.lan_ipv4(cfg)
            self.assertIsNone(got, ip)
            self.assertIn(ip, err.getvalue())
            self.assertIn("No LAN listener", err.getvalue())
        for ip in ("127.0.0.1", "0.0.0.0"):
            Sock.ip = ip
            err = io.StringIO()
            with mock.patch("socket.socket", Sock), mock.patch("sys.stderr", err):
                self.assertIsNone(live_server.lan_ipv4(cfg), ip)
            self.assertEqual(err.getvalue(), "", ip)
        Sock.ip = "100.64.0.1"
        err = io.StringIO()
        lan_cfg = {"live": {"lan": True, "port": 8765}, "network": {"internet_targets": "probe"}}
        with mock.patch("socket.socket", Sock), mock.patch("sys.stderr", err):
            plan = live_server.listener_plan(lan_cfg)
        self.assertEqual(len(plan), 1)
        self.assertTrue(ipaddress.ip_address(plan[0]["host"]).is_loopback)
        self.assertFalse(plan[0]["lan_mode"])
        self.assertFalse(plan[0]["reveal"])
        self.assertIn("No LAN listener", err.getvalue())

    def test_bind_refuses_non_private_addresses(self):
        cfg = {"live": {"lan": True, "port": 8765}, "network": {}}
        for ip in ("10.0.0.1", "10.255.255.254", "172.16.0.1", "172.31.255.254",
                   "192.168.0.1", "192.168.255.254", "127.0.0.1"):
            plan = live_server.listener_plan(cfg, bind=ip)
            self.assertEqual(plan[0]["host"], ip)
            self.assertEqual(len(plan), 1)
        local = live_server.listener_plan(cfg, bind="localhost")
        self.assertTrue(ipaddress.ip_address(local[0]["host"]).is_loopback)
        for ip in ("11.0.0.0", "172.15.255.255", "172.32.0.1", "192.169.0.0",
                   "100.64.0.1", "169.254.1.1", "203.0.113.9"):
            with self.assertRaises(OSError) as caught:
                live_server.listener_plan(cfg, bind=ip)
            self.assertIn(ip, str(caught.exception))
            self.assertIn("refusing", str(caught.exception))
        with self.assertRaises(OSError):
            live_server.listener_plan(cfg, bind="0.0.0.0")


class AccessKeyTests(LiveCase):
    def test_key_file_mode_rotation_and_compare_digest(self):
        path = self.keyfile()
        first = live_server.ensure_key(path)
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        self.assertTrue(live_server.keys_match(first, first))
        self.assertFalse(live_server.keys_match("", ""))
        self.assertFalse(live_server.keys_match(first, ""))
        second = live_server.rotate_key(path)
        self.assertNotEqual(first, second)
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        self.assertEqual(live_server.read_key(path), second)
        self.assertFalse(live_server.keys_match(first, second))
        link = Path(self.tmp) / "alias.key"
        os.symlink(path, link)
        with self.assertRaises(OSError):
            live_server.ensure_key(link)
        calls = []
        real = __import__("hmac").compare_digest

        def wrap(a, b):
            calls.append(1)
            return real(a, b)

        data, cfg = self.fill()
        srv = self.start(lan_mode=True, reveal_link=False, lan_enabled=True, key_file=path,
                         data_dir=data, cfg=cfg)
        with mock.patch("hmac.compare_digest", wrap):
            self.request(srv, "GET", "/")
            self.request(srv, "GET", "/?key=not-the-key")
            self.request(srv, "GET", "/?key=" + urllib.parse.quote(second))
        self.assertGreaterEqual(len(calls), 3)

    def test_lan_mode_requires_the_key_and_sets_the_cookie(self):
        path = self.keyfile()
        key = live_server.ensure_key(path)
        data, cfg = self.fill()
        status, history = live_data.write(cfg, now=NOW)
        srv = self.start(lan_mode=True, reveal_link=False, lan_enabled=True, key_file=path,
                         data_dir=data, cfg=cfg, status_file=status, history_file=history)
        code, headers, body = self.request(srv, "GET", "/api/status.json")
        self.assertEqual(code, 401)
        self.assertEqual(hdr(headers, "Set-Cookie"), "")
        self.assertNotIn(key.encode(), body)
        code, headers, body = self.request(srv, "GET", "/?key=not-the-key")
        self.assertEqual(code, 401)
        self.assertEqual(hdr(headers, "Set-Cookie"), "")
        code, headers, body = self.request(srv, "GET", "/not-a-route?key=" + urllib.parse.quote(key))
        self.assertEqual(code, 404)
        self.assertEqual(hdr(headers, "Set-Cookie"), "")
        self.assertNotIn(key.encode(), body)
        code, headers, body = self.request(srv, "GET", "/?key=" + urllib.parse.quote(key))
        self.assertEqual(code, 303, body)
        self.assertNotIn("key=", hdr(headers, "Location"))
        cookie = hdr(headers, "Set-Cookie")
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=Strict", cookie)
        self.assertIn("Path=/", cookie)
        self.assertNotIn("Secure", cookie)
        self.assertTrue(cookie.startswith(live_server.COOKIE + "="))
        code, headers, _ = self.request(srv, "GET", "/?key=not-the-key", headers={"Cookie": cookie.split(";", 1)[0]})
        self.assertEqual(code, 401)
        code, headers, body = self.request(srv, "GET", "/", headers={"Cookie": cookie.split(";", 1)[0]})
        self.assertEqual(code, 200)
        self.assertNotIn(key.encode(), body)
        self.assertIn(b"Home Wi-Fi access", body)
        code, _, body = self.request(srv, "GET", "/api/access.json", headers={"Cookie": cookie.split(";", 1)[0]})
        self.assertEqual(code, 200)
        access = json.loads(body)
        self.assertTrue(access["lan"])
        self.assertFalse(access["reveal"])
        self.assertNotIn("link", access)
        self.assertNotIn(key, body.decode("utf-8"))
        old = key
        new = live_server.rotate_key(path)
        code, _, _ = self.request(srv, "GET", "/?key=" + urllib.parse.quote(old))
        self.assertEqual(code, 401)
        code, headers, _ = self.request(srv, "GET", "/?key=" + urllib.parse.quote(new))
        self.assertEqual(code, 303)
        self.assertIn(new, hdr(headers, "Set-Cookie"))

    def test_loopback_page_can_reveal_the_link_and_the_lan_page_does_not(self):
        path = self.keyfile()
        key = live_server.ensure_key(path)
        data, cfg = self.fill()
        local = self.start(lan_mode=False, reveal_link=True, lan_enabled=True, key_file=path,
                           data_dir=data, cfg=cfg, link_host="192.168.0.1")
        code, _, page = self.request(local, "GET", "/")
        self.assertEqual(code, 200)
        self.assertNotIn(key.encode(), page)
        code, _, body = self.request(local, "GET", "/api/access.json")
        self.assertEqual(code, 200)
        access = json.loads(body)
        self.assertTrue(access["reveal"])
        self.assertTrue(access["link"].startswith("http://192.168.0.1:"))
        self.assertIn(key, access["link"])
        self.assertNotIn("192.168.x.x", access["link"])
        remote = self.start(lan_mode=True, reveal_link=False, lan_enabled=True, key_file=path, data_dir=data, cfg=cfg)
        code, _, body = self.request(remote, "GET", "/api/access.json?key=" + urllib.parse.quote(key))
        self.assertIn(code, (303, 200))
        if code == 200:
            self.assertNotIn(key, body.decode("utf-8"))

    def test_localhost_page_uses_the_detected_lan_address_and_port(self):
        path = self.keyfile()
        key = live_server.ensure_key(path)
        data = Path(self.tmp) / "data"
        data.mkdir()
        cfg = {
            "paths": {"data_dir": str(data)},
            "live": {"lan": True, "port": 8765},
            "network": {"internet_targets": "probe"},
        }
        host = "10.0.0.1"
        with mock.patch("live_server.lan_ipv4", return_value=host) as probe:
            srv = self.start(lan_mode=False, reveal_link=True, lan_enabled=True, key_file=path,
                             data_dir=data, cfg=cfg, link_host="127.0.0.1")
            code, _, body = self.request(srv, "GET", "/api/access.json")
        self.assertEqual(code, 200)
        access = json.loads(body)
        self.assertEqual(access["link"], live_server.make_link(host, 8765, key))
        self.assertNotIn("127.0.0.1", access["link"])
        self.assertNotIn("192.168.x.x", access["link"])
        probe.assert_called()

    def test_access_poll_reuses_the_detected_lan_address(self):
        path = self.keyfile()
        key = live_server.ensure_key(path)
        data = Path(self.tmp) / "data"
        data.mkdir()
        cfg = {
            "paths": {"data_dir": str(data)},
            "live": {"lan": True, "port": 8765},
            "network": {"internet_targets": "probe"},
        }
        host = "10.0.0.1"
        with mock.patch("live_server.lan_ipv4", return_value=host) as probe:
            srv = self.start(lan_mode=False, reveal_link=True, lan_enabled=True, key_file=path,
                             data_dir=data, cfg=cfg, link_host="127.0.0.1")
            code, _, body = self.request(srv, "GET", "/api/access.json")
            self.assertEqual(code, 200)
            link = live_server.make_link(host, 8765, key)
            self.assertEqual(json.loads(body)["link"], link)
            code, _, body = self.request(srv, "GET", "/api/access.json")
            self.assertEqual(code, 200)
            self.assertEqual(json.loads(body)["link"], link)
            self.assertEqual(probe.call_count, 1)
            expires, cached = srv._lan_ipv4_cached
            self.assertEqual(cached, host)
            self.assertGreater(expires, time.monotonic())
            srv._lan_ipv4_cached = (time.monotonic() - live_server._LAN_IPV4_TTL_S, cached)
            code, _, body = self.request(srv, "GET", "/api/access.json")
            self.assertEqual(code, 200)
            self.assertEqual(json.loads(body)["link"], link)
            self.assertEqual(probe.call_count, 2)

    def test_explicit_lan_host_accepts_only_private_addresses(self):
        accept = (
            "10.0.0.1", "10.255.255.254",
            "172.16.0.1", "172.31.255.254",
            "192.168.0.1", "192.168.255.254",
        )
        reject = (
            "11.0.0.0", "172.15.255.255", "172.32.0.1", "192.169.0.0",
            "100.64.0.1", "169.254.1.1", "203.0.113.9",
            "127.0.0.1", "0.0.0.0",
            "home-lan", "localhost", "",
        )
        for ip in accept:
            self.assertEqual(live_server._explicit_lan_host(ip), ip)
            self.assertEqual(live_server._explicit_lan_host(" " + ip), ip)
        for host in reject:
            self.assertIsNone(live_server._explicit_lan_host(host), host)
        self.assertIsNone(live_server._explicit_lan_host(None))

    def test_explicit_private_host_is_not_replaced(self):
        path = self.keyfile()
        key = live_server.ensure_key(path)
        data, cfg = self.fill()
        cfg["live"]["lan"] = True
        host = "192.168.0.1"
        with mock.patch("live_server.lan_ipv4") as probe:
            srv = self.start(lan_mode=False, reveal_link=True, lan_enabled=True, key_file=path,
                             data_dir=data, cfg=cfg, link_host=host)
            code, _, body = self.request(srv, "GET", "/api/access.json")
        self.assertEqual(code, 200)
        access = json.loads(body)
        self.assertEqual(access["link"], live_server.make_link(host, 8765, key))
        probe.assert_not_called()

    def test_mock_mode_shows_a_placeholder_lan_link(self):
        path = self.keyfile()
        key = live_server.ensure_key(path)
        data, cfg = self.fill()
        cfg["live"]["lan"] = True
        with mock.patch("live_server.lan_ipv4") as probe:
            srv = self.start(lan_mode=False, reveal_link=True, lan_enabled=True, key_file=path,
                             data_dir=data, cfg=cfg, link_host="127.0.0.1")
            code, _, body = self.request(srv, "GET", "/api/access.json")
        self.assertEqual(code, 200)
        access = json.loads(body)
        self.assertEqual(access["link"], live_server.make_link("192.168.x.x", 8765, key))
        self.assertNotIn("127.0.0.1", access["link"])
        probe.assert_not_called()

    def test_no_private_address_omits_the_link(self):
        path = self.keyfile()
        key = live_server.ensure_key(path)
        data = Path(self.tmp) / "data"
        data.mkdir()
        cfg = {
            "paths": {"data_dir": str(data)},
            "live": {"lan": True, "port": 8765},
            "network": {"internet_targets": "localhost"},
        }
        srv = self.start(lan_mode=False, reveal_link=True, lan_enabled=True, key_file=path,
                         data_dir=data, cfg=cfg, link_host="127.0.0.1")
        code, _, body = self.request(srv, "GET", "/api/access.json")
        self.assertEqual(code, 200)
        access = json.loads(body)
        self.assertTrue(access["lan"])
        self.assertTrue(access["reveal"])
        self.assertNotIn("link", access)
        self.assertEqual(access.get("note"), "no-address")
        self.assertNotIn(key, body.decode("utf-8"))
        self.assertNotIn("127.0.0.1", body.decode("utf-8"))
        page = (ROOT / "netbot/live_page/index.html").read_text(encoding="utf-8")
        js = (ROOT / "netbot/live_page/live.js").read_text(encoding="utf-8")
        sentence = "No private home-network address was found, so this page has no Wi-Fi link."
        self.assertIn(sentence, page)
        self.assertIn('id="link-no-address"', page)
        self.assertIn('byId("link-no-address")', js)
        self.assertIn('access.note === "no-address"', js)
        self.assertNotIn("|| access.reveal", js)
        self.assertIn("localPage && access.reveal && access.link", js)
        self.assertIn("|| (localPage && access.reveal)", js)
        self.assertNotIn("127.0.0.1", js)

    def test_print_link_omits_the_key_when_access_is_off_or_there_is_no_address(self):
        cfg_path = Path(self.tmp) / "config.toml"
        cfg_path.write_text("lan = false\n", encoding="utf-8")
        os.environ["NETBOT_CONFIG"] = str(cfg_path)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch("sys.stdout", out), mock.patch("sys.stderr", err):
            code = live_server.print_link({"live": {"lan": False, "port": 8765}, "network": {}, "paths": {"data_dir": self.tmp}})
        self.assertEqual(code, 0)
        self.assertIn("http://localhost:8765/", out.getvalue())
        self.assertNotIn("key=", out.getvalue())
        keyfile = cfg_path.parent / "live-access.key"
        self.files.append(str(keyfile))
        self.assertFalse(keyfile.exists())
        out, err = io.StringIO(), io.StringIO()
        with mock.patch("sys.stdout", out), mock.patch("sys.stderr", err):
            code = live_server.print_link({"live": {"lan": True, "port": 8765},
                                           "network": {"internet_targets": "localhost"},
                                           "paths": {"data_dir": self.tmp}})
        self.assertEqual(code, 1)
        self.assertFalse(keyfile.exists())
        self.assertNotIn("key=", out.getvalue() + err.getvalue())
        self.assertIn("does not create a key", err.getvalue())
        token = live_server.ensure_key(keyfile)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch("sys.stdout", out), mock.patch("sys.stderr", err):
            code = live_server.print_link({"live": {"lan": True, "port": 8765},
                                           "network": {"internet_targets": "localhost"},
                                           "paths": {"data_dir": self.tmp}})
        self.assertEqual(code, 0)
        self.assertNotIn("key=", out.getvalue())
        self.assertNotIn(token, out.getvalue())
        self.assertNotIn(token, err.getvalue())
        self.assertEqual(live_server.read_key(keyfile), token)

    def test_print_link_does_not_create_a_key(self):
        cfg_path = Path(self.tmp) / "config.toml"
        cfg_path.write_text("[live]\nlan = true\n", encoding="utf-8")
        os.environ["NETBOT_CONFIG"] = str(cfg_path)
        keyfile = cfg_path.parent / "live-access.key"
        self.files.append(str(keyfile))
        host = "192.168.0.1"
        cfg = {"live": {"lan": True, "port": 8765}, "network": {}, "paths": {"data_dir": self.tmp}}
        out, err = io.StringIO(), io.StringIO()
        with mock.patch("live_server.lan_ipv4", return_value=host), mock.patch("sys.stdout", out), mock.patch("sys.stderr", err):
            code = live_server.print_link(cfg)
        self.assertEqual(code, 1)
        self.assertFalse(keyfile.exists())
        self.assertNotIn("key=", out.getvalue())
        self.assertIn("does not create a key", err.getvalue())
        token = live_server.ensure_key(keyfile)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch("live_server.lan_ipv4", return_value=host), mock.patch("sys.stdout", out), mock.patch("sys.stderr", err):
            code = live_server.print_link(cfg)
        self.assertEqual(code, 0)
        self.assertIn("key=" + urllib.parse.quote(token, safe=""), out.getvalue())
        self.assertNotIn(token, err.getvalue())

    def test_ensure_key_creates_mode_0600_and_leaves_an_existing_key(self):
        path = self.keyfile()
        token = live_server.ensure_key(path)
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        self.assertEqual(path.read_text(encoding="utf-8").strip(), token)
        before = path.read_bytes()
        os.chmod(path, 0o640)
        again = live_server.ensure_key(path)
        self.assertEqual(again, token)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o640)

    def test_ensure_key_keeps_the_file_that_wins_the_create_race(self):
        path = self.keyfile()
        winner = "winner-token-already-there"
        real_open = os.open

        def racing(filename, flags, mode=0o777):
            if flags & os.O_EXCL:
                fd = real_open(filename, os.O_CREAT | os.O_WRONLY, 0o600)
                os.write(fd, (winner + "\n").encode("utf-8"))
                os.close(fd)
                os.chmod(filename, 0o640)
                raise FileExistsError(filename)
            return real_open(filename, flags, mode)

        with mock.patch("os.open", side_effect=racing):
            got = live_server.ensure_key(path)
        self.assertEqual(got, winner)
        self.assertEqual(path.read_bytes(), (winner + "\n").encode("utf-8"))
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o640)

    def test_ensure_key_command_exits_0_and_does_not_print_the_key(self):
        cfg_path = Path(self.tmp) / "config.toml"
        cfg_path.write_text("[live]\nlan = true\nport = 8765\n", encoding="utf-8")
        os.environ["NETBOT_CONFIG"] = str(cfg_path)
        keyfile = cfg_path.parent / "live-access.key"
        self.files.append(str(keyfile))
        out, err = io.StringIO(), io.StringIO()
        with mock.patch("sys.stdout", out), mock.patch("sys.stderr", err):
            code = live_server.main(["--ensure-key"])
        self.assertEqual(code, 0)
        self.assertEqual(os.stat(keyfile).st_mode & 0o777, 0o600)
        token = keyfile.read_text(encoding="utf-8").strip()
        self.assertTrue(token)
        self.assertNotIn(token, out.getvalue())
        self.assertNotIn(token, err.getvalue())
        self.assertNotIn("key=", out.getvalue())
        before = keyfile.read_bytes()
        os.chmod(keyfile, 0o640)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch("sys.stdout", out), mock.patch("sys.stderr", err):
            code = live_server.main(["--ensure-key"])
        self.assertEqual(code, 0)
        self.assertEqual(keyfile.read_bytes(), before)
        self.assertEqual(os.stat(keyfile).st_mode & 0o777, 0o640)
        self.assertNotIn(token, out.getvalue() + err.getvalue())

    def test_startup_output_never_contains_the_key(self):
        path = self.keyfile()
        key = live_server.ensure_key(path)
        cfg_path = path.parent / "config.toml"
        cfg_path.write_text('[live]\nlan = true\nport = 8765\n[paths]\ndata_dir = "%s"\n' % self.tmp, encoding="utf-8")
        os.environ["NETBOT_CONFIG"] = str(cfg_path)
        host = "10.0.0.1"
        loop = live_server.default_bind_host()
        plans = [
            {"host": loop, "port": 8765, "lan_mode": False, "reveal": True,
             "lan_enabled": True, "note": "", "link_host": host},
            {"host": host, "port": 8765, "lan_mode": True, "reveal": False,
             "lan_enabled": True, "note": "", "link_host": host},
        ]

        def fake_create(*args, **kwargs):
            srv = mock.Mock()
            srv.serve_forever = mock.Mock(return_value=None)
            return srv

        out, err = io.StringIO(), io.StringIO()
        with mock.patch("live_server.listener_plan", return_value=plans), \
             mock.patch("live_server.create_server", side_effect=fake_create), \
             mock.patch("sys.stdout", out), mock.patch("sys.stderr", err):
            code = live_server.main([])
        blob = out.getvalue() + err.getvalue()
        self.assertEqual(code, 0)
        self.assertNotIn(key, blob)
        self.assertNotIn("key=", blob)
        self.assertNotIn(host, blob)


class PageAndJsonTests(LiveCase):
    def test_status_and_history_schema(self):
        data, cfg = self.fill()
        status_path, history_path = live_data.write(cfg, now=NOW)
        status = json.loads(status_path.read_text(encoding="utf-8"))
        history = json.loads(history_path.read_text(encoding="utf-8"))
        self.assertEqual(status["schema"], 1)
        self.assertEqual(status["kind"], "status")
        self.assertEqual(status["title"], T.PRODUCT_TITLE)
        self.assertEqual(status["stale_after_s"], 1200)
        self.assertEqual(status["poll_s"], 30)
        self.assertIsInstance(status["lan_access"], bool)
        self.assertIsInstance(status["sample_ts"], (int, float))
        self.assertTrue(status["tiles"])
        for tile in status["tiles"]:
            for key in ("name", "level", "word", "text", "value", "unit", "is_word"):
                self.assertIn(key, tile)
            self.assertIn(tile["level"], ("green", "yellow", "red", "gray"))
            self.assertIsInstance(tile["is_word"], bool)
        self.assertEqual(history["schema"], 1)
        self.assertEqual(history["kind"], "history")
        points = []
        for section in history["sections"]:
            self.assertIn("label", section)
            for chart in section["charts"]:
                self.assertIn(chart["metric"], ("latency", "ping-drop", "throughput", "obstruction",
                                                 "gateway-ping", "internet-latency", "packet-loss",
                                                 "speed-test", "router-devices"))
                for point in chart["points"]:
                    self.assertIsInstance(point, list)
                    self.assertEqual(len(point), 2)
                    points.append(point)
        self.assertGreaterEqual(len(points), 2)
        blob = status_path.read_text(encoding="utf-8") + history_path.read_text(encoding="utf-8")
        self.assertNotIn("?key=", blob)
        self.assertIsNone(EXT_URL.search(blob))
        srv = self.start(data_dir=data, cfg=cfg, status_file=status_path, history_file=history_path)
        code, _, body = self.request(srv, "GET", "/api/status.json")
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)["kind"], "status")

    def test_legacy_dish_key_is_read_in_memory(self):
        from migrate_legacy import LEGACY_KEY
        from dish_constants import DISH_DATA_KEY
        from netbot_common import read_samples
        data = Path(self.tmp) / "data"
        data.mkdir()
        legacy = {
            "reachable": True, "state": "CONNECTED", "uptime_s": 7200,
            "software_version": "2026.10.02", "pop_ping_latency_ms": 20,
            "pop_ping_drop_rate": 0, "downlink_bps": 1_000_000, "uplink_bps": 200_000,
            "fraction_obstructed": 0, "alerts": [], "update_pending": False,
            "hist_latency_median_ms": 20, "hist_ping_drop_rate": 0,
            "not_for_the_page": "LEAVE-UNMAPPED",
        }
        row = {"ts": NOW, LEGACY_KEY: legacy}
        path = data / "2026-10.jsonl"
        path.write_text(json.dumps(row) + "\n", encoding="utf-8")
        before = path.read_bytes()
        cfg = {"paths": {"data_dir": str(data), "sync_dir": ""}, "live": {}, "network": {}, "router": {}}
        status = live_data.build_status(read_samples(data, 0), NOW, cfg)
        by_name = {tile["name"]: tile for tile in status["tiles"]}
        self.assertEqual(by_name[T.TILE_DISH_STATUS]["value"], "CONNECTED")
        self.assertEqual(by_name[T.TILE_DISH_LATENCY]["value"], "20")
        self.assertEqual(by_name[T.TILE_DISH_LATENCY]["unit"], "ms")
        self.assertNotIn("LEAVE-UNMAPPED", json.dumps(status))
        history = live_data.build_history(read_samples(data, 0), NOW)
        points = [p for sec in history["sections"] for ch in sec["charts"] if ch["metric"] == "latency" for p in ch["points"]]
        self.assertTrue(any(p[1] == 20 for p in points))
        both = {"ts": NOW, LEGACY_KEY: dict(legacy), DISH_DATA_KEY: {"reachable": False, "state": "SEARCHING"}}
        won = live_data.build_status([both], NOW, cfg)
        won_status = {tile["name"]: tile for tile in won["tiles"]}[T.TILE_DISH_STATUS]["value"]
        self.assertEqual(won_status, "UNREACHABLE")
        self.assertEqual(both.get(DISH_DATA_KEY), {"reachable": False, "state": "SEARCHING"})
        self.assertNotIn(DISH_DATA_KEY, row)
        live_data.write(cfg, now=NOW)
        self.assertEqual(path.read_bytes(), before)

    def test_page_and_assets_have_no_external_urls(self):
        script = (ROOT / "tests/check_anonymous.sh").read_text(encoding="utf-8")
        pin_path = re.search(r'^UPLOT_PIN_PATH = "([^"]+)"', script, re.M).group(1)
        pin_sha = re.search(r'^UPLOT_PIN_SHA256 = "([0-9a-f]{64})"', script, re.M).group(1)
        own = [
            ROOT / "netbot/live_page/index.html",
            ROOT / "netbot/live_page/live.js",
            ROOT / "netbot/theme/netbot-live.css",
        ]
        for path in own:
            text = path.read_text(encoding="utf-8")
            self.assertIsNone(EXT_URL.search(text), path.name)
            for banned in ("jsdelivr", "unpkg", "cdnjs"):
                self.assertNotIn(banned, text.lower())
        shipped = (ROOT / pin_path).read_bytes()
        self.assertEqual(hashlib.sha256(shipped).hexdigest(), pin_sha)
        for banned in (b"jsdelivr", b"unpkg", b"cdnjs"):
            self.assertNotIn(banned, shipped.lower())
        note = (ROOT / "netbot/vendor/uplot/VENDORED.md").read_text(encoding="utf-8")
        self.assertIn(pin_sha, note)
        self.assertIn("1.6.32", note)
        lic = (ROOT / "netbot/vendor/uplot/LICENSE").read_bytes()
        self.assertIn(hashlib.sha256(lic).hexdigest(), note)
        self.assertIn("MIT", lic.decode("utf-8"))
        srv = self.start()
        for path in ("/", "/assets/live.js", "/assets/uplot.js", "/assets/tokens.css",
                     "/assets/netbot-theme.css", "/assets/netbot-live.css"):
            code, _, body = self.request(srv, "GET", path)
            self.assertEqual(code, 200, path)
            if path == "/assets/uplot.js":
                self.assertEqual(hashlib.sha256(body).hexdigest(), pin_sha)
                continue
            text = body.decode("utf-8", "replace")
            self.assertIsNone(EXT_URL.search(text), path)

    def test_aria_live_reduced_motion_and_square_mark(self):
        html = (ROOT / "netbot/live_page/index.html").read_text(encoding="utf-8")
        js = (ROOT / "netbot/live_page/live.js").read_text(encoding="utf-8")
        css = (ROOT / "netbot/theme/netbot-live.css").read_text(encoding="utf-8")
        self.assertIn('aria-label="__PRODUCT_TITLE__"', html)
        self.assertIn('<span class="nb-brand">__APP_NAME__</span>', html)
        self.assertIn('<span class="nb-title__name">__HEADING__</span>', html)
        self.assertEqual(html.count("<h1"), 1)
        self.assertIn('aria-live="polite"', html)
        self.assertIn('aria-atomic="true"', html)
        self.assertIn('role="alert"', html)
        self.assertRegex(html, r'id="live-age"[^>]*aria-hidden="true"')
        self.assertIn("word !== announced", js)
        self.assertIn('byId("live-age")', js)
        self.assertIn("prefers-reduced-motion", css)
        self.assertIn("animation: none", css)
        self.assertIn(".nb-live__mark", css)
        self.assertIn('[data-live="lost"] .nb-chip', css)
        self.assertIn('[data-live="lost"] .nb-src--calc', css)
        self.assertIn('id="offline-banner"', html)
        self.assertIn("nb-statebar--offline", html)
        self.assertIn("Offline copy · snapshot from", html)
        self.assertIn("A saved copy of the dashboard. Values do not update, and the live link isn't included.", html)
        self.assertIn('data-hide="offline"', html)
        self.assertIn('byId("offline-banner")', js)
        self.assertIn('next === "offline"', js)
        self.assertIn('"Snapshot"', js)
        self.assertIn("Offline copy · not live", js)
        self.assertNotIn(".nb-live__mark", TH.inline_css())
        self.assertIn("nb-sweep", css)
        self.assertGreaterEqual(js.find(">= 30"), 0)
        self.assertIn("<= 60", js)
        self.assertIn("10000", js)

    def test_offline_snapshot_has_no_key_or_link(self):
        import mock_data
        from netbot_common import read_samples
        data = Path(self.tmp) / "data"
        mock_data.main(str(data), NOW)
        samples = read_samples(data, NOW - 7 * 86400)
        page = make_dashboard.build_html(samples, NOW)
        key = live_server.ensure_key(self.keyfile())
        self.assertNotIn("?key=", page)
        self.assertNotIn(key, page)
        self.assertNotIn("nb-access", page)
        self.assertNotIn("nb-live", page)
        self.assertNotIn("Private link", page)
        self.assertNotIn("btn-copy", page)
        self.assertNotIn("btn-show", page)
        self.assertNotIn("live-access", page)
        self.assertNotIn("Works only on your home Wi-Fi", page)
        self.assertIn('class="nb-statebar nb-statebar--offline" role="note"', page)
        self.assertIn("Offline copy · snapshot from", page)
        self.assertIn("· not live", page)
        self.assertIn("A saved copy of the dashboard. Values do not update, and the live link isn't included.", page)
        self.assertRegex(page, r'class="nb-clock">Snapshot<b>[^<]+</b>')
        self.assertIn("Offline copy · not live", page)
        self.assertIn(f'<title>{T.PRODUCT_TITLE}</title>', page)
        self.assertIsNone(EXT_URL.search(page))

    def test_dashboard_rebuilds_every_run(self):
        src = (ROOT / "netbot" / "collect.py").read_text(encoding="utf-8")
        self.assertNotIn("tm_min", src)
        self.assertNotIn("NETBOT_FORCE_DASHBOARD", src)
        tree = ast.parse(src)
        main = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "main")

        class Finder(ast.NodeVisitor):
            def __init__(self):
                self.depth = 0
                self.calls = []

            def visit_If(self, node):
                self.depth += 1
                self.generic_visit(node)
                self.depth -= 1

            def visit_Call(self, node):
                func = node.func
                if isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name):
                    if (func.value.id, func.attr) in {("make_dashboard", "run"), ("live_data", "write")}:
                        self.calls.append((func.value.id, func.attr, self.depth))
                self.generic_visit(node)

        found = Finder()
        found.visit(main)
        self.assertIn(("make_dashboard", "run", 0), found.calls)
        self.assertIn(("live_data", "write", 0), found.calls)
        data, cfg = self.fill()
        live_data.write(cfg, now=NOW)
        live_data.write(cfg, now=NOW + 60)
        self.assertTrue((data.parent / "live" / "status.json").is_file())
        self.assertTrue((data.parent / "live" / "history.json").is_file())

    def test_plist_template_has_no_remote_url(self):
        text = (ROOT / "io.netbot.live.plist.template").read_text(encoding="utf-8")
        self.assertIn("io.netbot.live", text)
        self.assertIn("netbot.live_server", text)
        self.assertIn("<key>KeepAlive</key>", text)
        self.assertNotIn("DOCTYPE", text)
        self.assertIsNone(EXT_URL.search(text))
        self.assertIsNone(IPV4.search(text))


if __name__ == "__main__":
    unittest.main()
