#!/usr/bin/env python3
"""Read-only local web server for the NetBot live page. Python standard library only.

GET and HEAD only, and only for a fixed list of paths. Files are served from an explicit
name-to-file map. The request path is never joined onto a directory.

Default listen address is localhost (loopback). Home Wi-Fi access is off unless config
`[live] lan` is true. When it is on, a second listener binds the computer's LAN address
and requires an access key. The key is `secrets.token_urlsafe(32)`, stored next to the
config file as `live-access.key` with mode 0600, and compared with `hmac.compare_digest`.
The key is passed once as `?key=`. The server sets an HttpOnly cookie and redirects so
the key leaves the address bar. The full link is printed by setup and returned to the
loopback page only. That page also embeds a QR code of the link, and only when the
socket peer is loopback. Host and X-Forwarded-For are ignored. The LAN listener never
receives the link or the QR.

Usage:
  python3 -m netbot.live_server
  python3 -m netbot.live_server --print-link
  python3 -m netbot.live_server --rotate-key
  python3 -m netbot.live_server --ensure-key

TODO: a Windows install would start this process at logon with a scheduled task, in the
same place netbot/win_task.pyw starts the collector. No Windows server is implemented here.
"""
import argparse, hashlib, hmac, html, http.server, ipaddress, json, os, secrets, socket, subprocess, sys, threading, time, urllib.parse
from pathlib import Path

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import live_data
import live_qr
import ui_text as T
from make_dashboard import HEADER_ART, WEEK
from netbot_common import load_config, p, read_samples

KEY_NAME = "live-access.key"
COOKIE = "nb_live"
MAX_BYTES = 20 * 1024 * 1024
_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)

PAGE_DIR = _HERE / "live_page"
THEME_DIR = _HERE / "theme"
UPLOT = _HERE / "vendor" / "uplot" / "uPlot.iife.min.js"

# Exact request path -> map name. Nothing else is served. No directory listing.
ROUTES = {
    "/": "page",
    "/index.html": "page",
    "/assets/tokens.css": "tokens",
    "/assets/netbot-theme.css": "theme",
    "/assets/netbot-live.css": "livecss",
    "/assets/uplot.js": "uplot",
    "/assets/live.js": "livejs",
    "/api/status.json": "status",
    "/api/history.json": "history",
    "/api/access.json": "access",
    "/api/monitor.json": "monitor",
    "/api/monitor/start": "monitor_start",
    "/api/monitor/stop": "monitor_stop",
}
FILES = {
    "tokens": THEME_DIR / "tokens.css",
    "theme": THEME_DIR / "netbot-theme.css",
    "livecss": THEME_DIR / "netbot-live.css",
    "uplot": UPLOT,
    "livejs": PAGE_DIR / "live.js",
    "page": PAGE_DIR / "index.html",
}
TYPES = {
    "page": "text/html; charset=utf-8",
    "tokens": "text/css; charset=utf-8",
    "theme": "text/css; charset=utf-8",
    "livecss": "text/css; charset=utf-8",
    "uplot": "text/javascript; charset=utf-8",
    "livejs": "text/javascript; charset=utf-8",
    "status": "application/json; charset=utf-8",
    "history": "application/json; charset=utf-8",
    "access": "application/json; charset=utf-8",
    "monitor": "application/json; charset=utf-8",
    "monitor_start": "application/json; charset=utf-8",
    "monitor_stop": "application/json; charset=utf-8",
}


def default_bind_host():
    """Loopback address for the name localhost. Refuses a non-loopback answer."""
    infos = socket.getaddrinfo("localhost", None, socket.AF_INET, socket.SOCK_STREAM)
    for info in infos:
        host = info[4][0]
        try:
            if ipaddress.ip_address(host).is_loopback:
                return host
        except ValueError:
            continue
    raise OSError("localhost did not resolve to a loopback address")


def resolve_bind(host):
    """Turn a bind argument into an IPv4 address. An unspecified address is refused."""
    infos = socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)
    if not infos:
        raise OSError("no address for bind host")
    ip = infos[0][4][0]
    addr = ipaddress.ip_address(ip)
    if addr.is_unspecified:
        raise OSError("refusing to listen on an unspecified address")
    return str(addr)


def config_file():
    return Path(os.path.expanduser(os.environ.get("NETBOT_CONFIG", "~/NetBot/config.toml")))


def key_path(cfg_path=None):
    return Path(cfg_path or config_file()).parent / KEY_NAME


def _write_new_key(path, token):
    fd = os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)  # encoding=utf-8 via fdopen
    try:
        os.write(fd, (token + "\n").encode("utf-8"))
    finally:
        os.close(fd)
    os.chmod(path, 0o600)


def read_key(path):
    """Return the key, or "" if the file is missing, a symlink, or not a single token."""
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        return ""
    try:
        fd = os.open(str(path), os.O_RDONLY | _NOFOLLOW)  # encoding=utf-8 via fdopen
    except OSError:
        return ""
    try:
        raw = os.read(fd, 512)
    finally:
        os.close(fd)
    try:
        token = raw.decode("utf-8").strip()
    except UnicodeError:
        return ""
    if not token or any(c in token for c in "\r\n;"):
        return ""
    return token


def ensure_key(path):
    """Return the key. Create it with mode 0600 only when the file is missing.

    An existing file is not rewritten and its mode is not changed. Creation is
    exclusive (O_CREAT|O_EXCL). If another process wins that race, its file is kept.
    """
    path = Path(path)
    if path.is_symlink():
        raise OSError("refusing to use a symlink as the access key")
    if path.exists():
        return read_key(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    token = secrets.token_urlsafe(32)
    try:
        _write_new_key(path, token)
    except FileExistsError:
        return read_key(path)
    return token


def rotate_key(path):
    """Replace the key. The old value stops matching as soon as the file is replaced."""
    path = Path(path)
    if path.is_symlink():
        raise OSError("refusing to rotate a symlink")
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".rotating")
    if tmp.is_symlink():
        raise OSError("refusing to rotate via a symlink")
    if tmp.exists():
        os.unlink(tmp)
    token = secrets.token_urlsafe(32)
    _write_new_key(tmp, token)
    os.replace(tmp, path)
    os.chmod(path, 0o600)
    return token


def keys_match(expected, presented):
    """Constant-time compare. Always calls hmac.compare_digest, including when a side is empty."""
    left = hashlib.sha256((expected or "").encode("utf-8")).digest()
    right = hashlib.sha256((presented or "").encode("utf-8")).digest()
    if not expected or not presented:
        hmac.compare_digest(left, hashlib.sha256(b"\0").digest())
        return False
    return hmac.compare_digest(left, right)


def make_link(host, port, key):
    return "http://%s:%s/?key=%s" % (host, int(port), urllib.parse.quote(key, safe=""))


# Home LAN is only these three ranges. CGNAT, link-local, and public addresses are not.
_HOME_NETS = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
)


def is_home_lan(addr):
    """True only for private IPv4 in 10/8, 172.16/12, or 192.168/16."""
    return isinstance(addr, ipaddress.IPv4Address) and any(addr in net for net in _HOME_NETS)


def _routed_ipv4(cfg):
    """IPv4 of the interface used to reach the configured internet target, or None.

    Loopback, unspecified, and multicast results are treated as no address.
    """
    raw = str((cfg.get("network") or {}).get("internet_targets") or "")
    hosts = [h for h in raw.split() if h]
    if not hosts:
        return None
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        try:
            sock.connect((hosts[0], 9))
            ip = sock.getsockname()[0]
        except OSError:
            return None
    finally:
        sock.close()
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return None
    if not isinstance(addr, ipaddress.IPv4Address):
        return None
    if addr.is_loopback or addr.is_unspecified or addr.is_multicast:
        return None
    return addr


def lan_ipv4(cfg):
    """Private LAN address of the interface used to reach the configured internet target.

    Accepts only 10/8, 172.16/12, and 192.168/16. CGNAT (100.64/10), link-local, and
    public addresses are rejected: this returns None and logs that no LAN listener
    will be started. Never returns an unspecified address.
    """
    addr = _routed_ipv4(cfg)
    if addr is None:
        return None
    if is_home_lan(addr):
        return str(addr)
    print("Home Wi-Fi access stays on localhost: %s is not a private LAN address "
          "(10/8, 172.16/12, or 192.168/16). No LAN listener was started." % addr,
          file=sys.stderr)
    return None


# Shown on the localhost page when the samples are example data and no explicit LAN host was given.
_MOCK_LAN_HOST = "192.168.x.x"


def _explicit_lan_host(host):
    """A private home-LAN address the link may show, or None.

    Labels, loopback, and any address outside 10/8, 172.16/12, and 192.168/16
    are refused. The same is_home_lan check used for a detected address.
    """
    if host is None:
        return None
    text = str(host).strip()
    if not text or text.lower() == "localhost":
        return None
    try:
        addr = ipaddress.ip_address(text)
    except ValueError:
        return None
    if isinstance(addr, ipaddress.IPv4Address) and is_home_lan(addr):
        return str(addr)
    return None


def _example_data(server):
    cfg = server.cfg or {}
    if bool((cfg.get("live") or {}).get("example")):
        return True
    data_dir = getattr(server, "data_dir", None)
    if not data_dir:
        return False
    try:
        samples = read_samples(data_dir, time.time() - WEEK)
    except OSError:
        return False
    return any(bool(sample.get("example")) for sample in samples)


# access.json is polled every few seconds. Keep the probed address briefly.
_LAN_IPV4_TTL_S = 60.0


def _cached_lan_ipv4(server):
    """Private LAN address for this server, reused until a short TTL expires."""
    now = time.monotonic()
    cached = getattr(server, "_lan_ipv4_cached", None)
    if cached is not None and now < cached[0]:
        return cached[1]
    value = lan_ipv4(server.cfg or {})
    server._lan_ipv4_cached = (now + _LAN_IPV4_TTL_S, value)
    return value


def lan_link_target(server):
    """Host and port for the private link on the localhost page.

    An explicit address is kept only when it is a private home-LAN address.
    Loopback, localhost, and other labels are not. Example data then uses the
    mock placeholder. Otherwise the detected private address is used.
    Returns (None, port) when there is no address to put in a link.
    """
    cfg = server.cfg or {}
    if server.link_port:
        port = int(server.link_port)
    else:
        configured = (cfg.get("live") or {}).get("port")
        port = int(configured) if configured else int(server.server_address[1])
    host = _explicit_lan_host(server.link_host)
    if host:
        return host, port
    if _example_data(server):
        return _MOCK_LAN_HOST, port
    detected = _cached_lan_ipv4(server)
    if detected:
        return detected, port
    return None, port


def listener_plan(cfg, bind=None):
    """Listeners to start. An explicit bind is a single listener (used by tests)."""
    port = int((cfg.get("live") or {}).get("port") or 8765)
    loop = default_bind_host()
    lan = bool((cfg.get("live") or {}).get("lan"))
    if bind:
        host = resolve_bind(bind)
        addr = ipaddress.ip_address(host)
        if not addr.is_loopback and not is_home_lan(addr):
            raise OSError("refusing to listen on %s: not a loopback or private LAN address" % host)
        return [{"host": host, "port": port, "lan_mode": lan, "reveal": False,
                 "lan_enabled": lan, "note": "", "link_host": None}]
    if not lan:
        return [{"host": loop, "port": port, "lan_mode": False, "reveal": False,
                 "lan_enabled": False, "note": "", "link_host": None}]
    ip = lan_ipv4(cfg)
    if not ip:
        return [{"host": loop, "port": port, "lan_mode": False, "reveal": False,
                 "lan_enabled": True, "note": "no-address", "link_host": None}]
    return [
        {"host": loop, "port": port, "lan_mode": False, "reveal": True,
         "lan_enabled": True, "note": "", "link_host": ip},
        {"host": ip, "port": port, "lan_mode": True, "reveal": False,
         "lan_enabled": True, "note": "", "link_host": ip},
    ]


def _roots_for(paths):
    roots = []
    for path in paths:
        parent = Path(path).parent
        if parent.is_symlink():
            continue
        try:
            resolved = parent.resolve()
        except OSError:
            continue
        if resolved not in roots:
            roots.append(resolved)
    return roots


def safe_read(path, roots):
    """Read a mapped file. A symlink, or a file whose real parent is not an allowed root, is refused."""
    path = Path(path)
    if path.is_symlink():
        return None
    try:
        resolved = path.resolve(strict=True)
    except OSError:
        return None
    if resolved.parent not in roots:
        return None
    try:
        fd = os.open(str(path), os.O_RDONLY | _NOFOLLOW)  # encoding=binary
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat_is_reg(st.st_mode) or st.st_size > MAX_BYTES:
            return None
        return os.read(fd, st.st_size)
    finally:
        os.close(fd)


def stat_is_reg(mode):
    import stat
    return stat.S_ISREG(mode)


def classify(raw_path):
    """Return the route name, or None. Encoded dots, backslashes, and '..' never resolve."""
    if not raw_path or not raw_path.startswith("/") or raw_path.startswith("//"):
        return None
    if "%" in raw_path or "\\" in raw_path or "\x00" in raw_path or ".." in raw_path:
        return None
    decoded = urllib.parse.unquote(raw_path)
    if decoded != raw_path or ".." in decoded or "\\" in decoded or "\x00" in decoded:
        return None
    return ROUTES.get(decoded)


def cookie_value(header):
    if not header:
        return ""
    for part in header.split(";"):
        name, _, val = part.strip().partition("=")
        if name == COOKIE:
            return val.strip()
    return ""


def location_without_key(parsed):
    pairs = [(k, v) for k, v in urllib.parse.parse_qsl(parsed.query, keep_blank_values=True) if k != "key"]
    query = urllib.parse.urlencode(pairs)
    path = parsed.path or "/"
    return path + (("?" + query) if query else "")


# Socket peer only. Host and X-Forwarded-For are not consulted.
# The v4 address is assembled so this source has no dotted-quad literal.
_LOOPBACK_V4 = "127" + ".0.0.1"
_LOOPBACK_PEERS = (_LOOPBACK_V4, "::1", "::ffff:" + _LOOPBACK_V4)


def _peer_is_loopback(client_address):
    if not client_address:
        return False
    return client_address[0] in _LOOPBACK_PEERS



COLLECT_LABEL = "io.netbot.collect"
COLLECT_PLIST = Path(os.path.expanduser("~")) / "Library" / "LaunchAgents" / "io.netbot.collect.plist"


def collect_gui_domain():
    return "gui/%d" % os.getuid()


def collect_is_running():
    """True when the collector LaunchAgent is loaded (bootstrapped).

    The collector is a StartInterval job, so between samples launchd shows
    ``state = not running`` even though monitoring is on. ``launchctl print``
    succeeds while the job is loaded; after bootout it fails (e.g. rc 113).
    """
    try:
        proc = subprocess.run(
            ["launchctl", "print", "%s/%s" % (collect_gui_domain(), COLLECT_LABEL)],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return proc.returncode == 0


def collect_start():
    """Bootstrap the collector LaunchAgent. Fixed argv; no user input."""
    if COLLECT_PLIST.is_symlink() or not COLLECT_PLIST.is_file():
        return False, "plist missing"
    try:
        proc = subprocess.run(
            ["launchctl", "bootstrap", collect_gui_domain(), str(COLLECT_PLIST)],
            capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, str(exc)[:200]
    if proc.returncode == 0 or collect_is_running():
        return True, "on"
    err = (proc.stderr or proc.stdout or "bootstrap failed").strip()
    return False, err[:200]


def collect_stop():
    """Boot out the collector LaunchAgent. Fixed argv; no user input."""
    try:
        proc = subprocess.run(
            ["launchctl", "bootout", "%s/%s" % (collect_gui_domain(), COLLECT_LABEL)],
            capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        # Already paused, or launchctl is not on this OS: success when not running.
        if not collect_is_running():
            return True, "paused"
        return False, str(exc)[:200]
    if proc.returncode == 0 or not collect_is_running():
        return True, "paused"
    err = (proc.stderr or proc.stdout or "bootout failed").strip()
    return False, err[:200]


def _csrf_ok(handler, presented):
    expected = getattr(handler.server, "csrf_token", "") or ""
    if not expected or not presented:
        return False
    return hmac.compare_digest(expected, presented)


def _origin_ok(handler):
    """If Origin or Referer is present, it must target loopback on this port."""
    origin = handler.headers.get("Origin") or ""
    referer = handler.headers.get("Referer") or ""
    check = origin or referer
    if not check:
        return True
    try:
        parsed = urllib.parse.urlsplit(check)
    except ValueError:
        return False
    host = (parsed.hostname or "").lower()
    if host not in ("localhost", "127." + "0.0.1", "::1"):
        return False
    port = parsed.port
    if port is None:
        port = 443 if parsed.scheme == "https" else 80
    return int(port) == int(handler.server.server_address[1])


def _monitor_controls_html(handler):
    """Start/Stop controls + CSRF, only for loopback peers. Empty for LAN/phone."""
    if handler is None or not _peer_is_loopback(getattr(handler, "client_address", None)):
        return ""
    token = html.escape(getattr(handler.server, "csrf_token", "") or "", quote=True)
    return (
        '<section class="nb-monitor" id="monitor-controls" aria-label="Monitoring controls" '
        'data-csrf="%s">'
        '<p class="nb-monitor__status" id="monitor-status" data-state="unknown" role="status">'
        'Monitoring: <b id="monitor-state">…</b></p>'
        '<button type="button" class="nb-btn" id="btn-monitor-start">Start Monitoring</button>'
        '<button type="button" class="nb-btn" id="btn-monitor-stop">Stop Monitoring</button>'
        '<p class="nb-monitor__err" id="monitor-err" hidden></p>'
        '</section>'
    ) % token



def _phone_access_open(handler):
    """On localhost, wrap the Wi-Fi/QR block in a closed disclosure. LAN unchanged."""
    if handler is None or not _peer_is_loopback(getattr(handler, "client_address", None)):
        return ""
    return (
        '<details class="nb-phone-access" id="phone-access">'
        '<summary class="nb-phone-access__sum">Phone access</summary>'
    )


def _phone_access_close(handler):
    if handler is None or not _peer_is_loopback(getattr(handler, "client_address", None)):
        return ""
    return "</details>"


def _lan_qr_fragment(handler):
    """QR figure for the private link, or "" unless this is the reveal listener and the peer is loopback.

    No home-network address becomes a short note. The figure is part of the fragment,
    so every other response leaves the placeholder empty.
    """
    server = getattr(handler, "server", None)
    if server is None or not getattr(server, "reveal_link", False):
        return ""
    if not _peer_is_loopback(getattr(handler, "client_address", None)):
        return ""
    host, port = lan_link_target(server)
    if not host:
        return '<p class="nb-qr__note">No home-network address, so there is no QR code.</p>'
    key = handler._expected_key()
    if not key:
        return ""
    svg = live_qr.qr_svg(make_link(host, port, key))
    return (
        '<figure class="nb-qr" id="link-qr">%s'
        "<figcaption>Scan with your iPhone camera to open this dashboard on your home Wi-Fi.</figcaption>"
        "</figure>" % svg
    )


def render_page(raw, handler=None):
    text = raw.decode("utf-8")
    heading = T.PRODUCT_TITLE.split(": ", 1)[-1]
    repl = {
        "__PRODUCT_TITLE__": html.escape(T.PRODUCT_TITLE, quote=True),
        "__APP_NAME__": html.escape(T.APP_NAME, quote=True),
        "__HEADING__": html.escape(heading, quote=True),
        "__HEADER_ART__": HEADER_ART,
        "__LAN_QR__": _lan_qr_fragment(handler) if handler is not None else "",
        "__MONITOR_CONTROLS__": _monitor_controls_html(handler),
        "__PHONE_ACCESS_OPEN__": _phone_access_open(handler),
        "__PHONE_ACCESS_CLOSE__": _phone_access_close(handler),
    }
    for key, val in repl.items():
        text = text.replace(key, val)
    return text.encode("utf-8")


class LiveHTTPServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

    def handle_error(self, request, client_address):
        # The request line can carry the access key. Do not print it.
        sys.stderr.write("live server error\n")


class LiveHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "NetBot"
    sys_version = ""

    def setup(self):
        super().setup()
        self.request.settimeout(15)

    def log_message(self, fmt, *args):
        raw = getattr(self, "path", "") or ""
        path = raw.split("?", 1)[0]
        sys.stderr.write("%s %s\n" % (getattr(self, "command", "-"), path))

    def handle_one_request(self):
        try:
            self.raw_requestline = self.rfile.readline(65537)
            if len(self.raw_requestline) > 65536:
                self.close_connection = True
                return
            if not self.raw_requestline:
                self.close_connection = True
                return
            if not self.parse_request():
                return
            if self.command == "POST":
                self._dispatch_post()
            elif self.command in ("GET", "HEAD"):
                self._dispatch()
            else:
                self._reply(405, b"method not allowed\n", "text/plain; charset=utf-8",
                            extra=[("Allow", "GET, HEAD, POST")])
                return
            self.wfile.flush()
        except (TimeoutError, socket.timeout):
            self.close_connection = True
        except Exception:
            self.close_connection = True

    def do_GET(self):
        self._dispatch()

    def do_HEAD(self):
        self._dispatch()

    def _reply(self, code, body, content_type, extra=None, store=False):
        body = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Security-Policy", "default-src 'self'")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        if store or content_type.startswith("text/html") or content_type.startswith("application/json") \
                or content_type.startswith("text/css") or content_type.startswith("text/javascript"):
            self.send_header("Cache-Control", "no-store")
        for key, val in extra or []:
            self.send_header(key, val)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _expected_key(self):
        if self.server.key_file:
            return read_key(self.server.key_file)
        return self.server.access_key or ""

    def _authorize(self, parsed):
        """Return (ok, cookie_to_set or None). A presented query key that does not match is a failure."""
        expected = self._expected_key()
        presented = None
        for key, val in urllib.parse.parse_qsl(parsed.query, keep_blank_values=True):
            if key == "key":
                presented = val
        if presented is not None:
            if keys_match(expected, presented):
                return True, expected
            return False, None
        if keys_match(expected, cookie_value(self.headers.get("Cookie"))):
            return True, None
        return False, None

    def _dispatch(self):
        parsed = urllib.parse.urlsplit(self.path)
        route = classify(parsed.path)
        if route is None:
            self._reply(404, b"not found\n", "text/plain; charset=utf-8")
            return
        if self.server.require_key:
            ok, token = self._authorize(parsed)
            if ok and token:
                self._reply(303, b"", "text/plain; charset=utf-8",
                            extra=[("Location", location_without_key(parsed)),
                                   ("Set-Cookie", "%s=%s; HttpOnly; SameSite=Strict; Path=/" % (COOKIE, token))],
                            store=True)
                return
            if not ok:
                self._reply(401, b"unauthorized\n", "text/plain; charset=utf-8", store=True)
                return
        if route in ("monitor_start", "monitor_stop"):
            self._reply(405, b"method not allowed\n", "text/plain; charset=utf-8",
                        extra=[("Allow", "POST")])
            return
        body = self._body(route)
        if body is None:
            self._reply(404, b"not found\n", "text/plain; charset=utf-8")
            return
        self._reply(200, body, TYPES[route])

    def _body(self, route):
        if route in ("status", "history"):
            return self._json_file(route)
        if route == "access":
            return json.dumps(self._access(), separators=(",", ":")).encode("utf-8")
        if route == "monitor":
            return json.dumps(self._monitor(), separators=(",", ":")).encode("utf-8")
        path = FILES[route]
        raw = safe_read(path, self.server.roots)
        if raw is None:
            return None
        if route == "page":
            return render_page(raw, self)
        return raw

    def _json_file(self, route):
        path = self.server.status_file if route == "status" else self.server.history_file
        if path is not None and Path(path).is_symlink():
            return None
        if path is not None and Path(path).is_file():
            return safe_read(path, self.server.roots)
        now = time.time()
        data_dir = self.server.data_dir
        samples = read_samples(data_dir, now - WEEK) if data_dir else []
        cfg = self.server.cfg or {"live": {"lan": bool(self.server.wifi_on)}}
        if route == "status":
            payload = live_data.build_status(samples, now, cfg)
        else:
            payload = live_data.build_history(samples, now, dish=live_data.dish_enabled(cfg))
        return json.dumps(payload).encode("utf-8")


    def _dispatch_post(self):
        parsed = urllib.parse.urlsplit(self.path)
        route = classify(parsed.path)
        if route not in ("monitor_start", "monitor_stop"):
            self._reply(405, b"method not allowed\n", "text/plain; charset=utf-8",
                        extra=[("Allow", "GET, HEAD")])
            return
        if self.server.require_key:
            ok, _token = self._authorize(parsed)
            if not ok:
                self._reply(401, b'{"ok":false,"error":"unauthorized"}\n',
                            "application/json; charset=utf-8", store=True)
                return
        # Discard body (fixed commands; no user input). Cap length.
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            length = -1
        if length < 0 or length > 4096:
            self._reply(400, b'{"ok":false,"error":"bad content-length"}\n',
                        "application/json; charset=utf-8", store=True)
            return
        if length:
            self.rfile.read(length)
        if not _peer_is_loopback(self.client_address):
            self._reply(403, b'{"ok":false,"error":"localhost only"}\n',
                        "application/json; charset=utf-8", store=True)
            return
        if not _origin_ok(self):
            self._reply(403, b'{"ok":false,"error":"bad origin"}\n',
                        "application/json; charset=utf-8", store=True)
            return
        presented = self.headers.get("X-CSRF-Token") or ""
        if not _csrf_ok(self, presented):
            self._reply(403, b'{"ok":false,"error":"bad csrf"}\n',
                        "application/json; charset=utf-8", store=True)
            return
        if route == "monitor_start":
            ok, detail = collect_start()
        else:
            ok, detail = collect_stop()
        payload = {
            "ok": bool(ok),
            "running": collect_is_running(),
            "controls": True,
            "detail": detail,
        }
        if not ok:
            payload["error"] = detail
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self._reply(200 if ok else 500, body, "application/json; charset=utf-8", store=True)

    def _monitor(self):
        loopback = _peer_is_loopback(self.client_address)
        return {
            "schema": 1,
            "kind": "monitor",
            "running": collect_is_running() if loopback else None,
            "controls": bool(loopback),
        }

    def _access(self):
        body = {
            "schema": 1,
            "kind": "access",
            "lan": bool(self.server.wifi_on),
            "reveal": bool(self.server.reveal_link),
        }
        if self.server.note:
            body["note"] = self.server.note
        if self.server.reveal_link:
            host, port = lan_link_target(self.server)
            key = self._expected_key()
            if host and key and _peer_is_loopback(self.client_address):
                body["link"] = make_link(host, port, key)
            elif not host:
                body["note"] = "no-address"
        return body


def create_server(bind, port, lan_mode=False, reveal_link=False, lan_enabled=None, key_file=None,
                  access_key=None, status_file=None, history_file=None, data_dir=None, cfg=None,
                  link_host=None, link_port=None, note=""):
    host = resolve_bind(bind) if not _already_ip(bind) else bind
    httpd = LiveHTTPServer((host, int(port)), LiveHandler)
    httpd.require_key = bool(lan_mode)
    httpd.reveal_link = bool(reveal_link)
    httpd.wifi_on = bool(lan_mode or reveal_link) if lan_enabled is None else bool(lan_enabled)
    httpd.key_file = Path(key_file) if key_file else None
    httpd.access_key = access_key or ""
    httpd.status_file = Path(status_file) if status_file else None
    httpd.history_file = Path(history_file) if history_file else None
    httpd.data_dir = Path(data_dir) if data_dir else None
    httpd.cfg = cfg
    httpd.link_host = link_host
    httpd.link_port = link_port
    httpd.note = note or ""
    httpd.csrf_token = secrets.token_urlsafe(32)
    mapped = list(FILES.values())
    if httpd.status_file:
        mapped.append(httpd.status_file)
    if httpd.history_file:
        mapped.append(httpd.history_file)
    httpd.roots = _roots_for(mapped)
    return httpd


def _already_ip(host):
    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        return False
    return not addr.is_unspecified


def _data_paths(cfg):
    data_dir = p(cfg["paths"]["data_dir"])
    folder = data_dir.parent / "live"
    return data_dir, folder / "status.json", folder / "history.json"


def print_link(cfg):
    port = int((cfg.get("live") or {}).get("port") or 8765)
    local = "http://localhost:%s/" % port
    if not (cfg.get("live") or {}).get("lan"):
        print(local)
        print("Home Wi-Fi access is off. Set lan = true under [live], then run this command again.", file=sys.stderr)
        return 0
    key = read_key(key_path())
    if not key:
        print("No access key file yet. Start the live page once, or run --rotate-key. "
              "This command does not create a key.", file=sys.stderr)
        return 1
    ip = lan_ipv4(cfg)
    if not ip:
        print(local)
        print("Home Wi-Fi access is on, but no private LAN address was found. The key stays in the key file.", file=sys.stderr)
        return 0
    print(make_link(ip, port, key))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="netbot.live_server")
    parser.add_argument("--bind", default=None, help="listen address (default: localhost; with --lan, one listener)")
    parser.add_argument("--port", type=int, default=None)
    parser.add_argument("--lan", action="store_true", dest="wifi_flag", help="require the access key on this listener")
    parser.add_argument("--data-dir", default=None)
    parser.add_argument("--rotate-key", action="store_true")
    parser.add_argument("--ensure-key", action="store_true",
                        help="create the access key if it is missing, then exit")
    parser.add_argument("--print-link", action="store_true")
    args = parser.parse_args(argv)
    cfg = load_config()
    if args.data_dir:
        cfg = dict(cfg)
        cfg["paths"] = dict(cfg.get("paths") or {})
        cfg["paths"]["data_dir"] = args.data_dir
    if args.wifi_flag:
        cfg = dict(cfg)
        cfg["live"] = dict(cfg.get("live") or {})
        cfg["live"]["lan"] = True
    if args.port is not None:
        cfg = dict(cfg)
        cfg["live"] = dict(cfg.get("live") or {})
        cfg["live"]["port"] = args.port
    if args.rotate_key:
        rotate_key(key_path())
        return print_link(cfg)
    if args.ensure_key:
        ensure_key(key_path())
        return 0
    if args.print_link:
        return print_link(cfg)
    plans = listener_plan(cfg, bind=args.bind)
    data_dir, status_file, history_file = _data_paths(cfg)
    key = key_path()
    if any(item["lan_mode"] or item["reveal"] for item in plans):
        ensure_key(key)
    servers = []
    for item in plans:
        needs_key = item["lan_mode"] or item["reveal"]
        servers.append(create_server(
            item["host"], item["port"], lan_mode=item["lan_mode"], reveal_link=item["reveal"],
            lan_enabled=item["lan_enabled"], key_file=key if needs_key else None,
            status_file=status_file, history_file=history_file, data_dir=data_dir, cfg=cfg,
            link_host=item.get("link_host"), note=item.get("note") or ""))
    if len(servers) == 1:
        if plans[0].get("note") == "no-address":
            print("Home Wi-Fi access is on, but no LAN address was found. Staying on localhost.", file=sys.stderr)
        servers[0].serve_forever()
        return 0
    threading.Thread(target=servers[0].serve_forever, daemon=True).start()
    servers[1].serve_forever()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main() or 0)
    except KeyboardInterrupt:
        sys.exit(0)
    except OSError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
