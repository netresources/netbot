#!/bin/bash
# Anonymity scan for the NetBot package. Fails (exit 1) if any shipped file, or any file name,
# contains an identifier that could tie the package to a person, company, or place, or a real
# email address, hostname/domain, IPv4 address, or MAC address that is not on the allowlist below.
# Every allowlist entry is an exact file path plus an exact, case-sensitive string: no wildcards,
# no suffix rules, no IP ranges. A value that is allowed in one file fails in any other file.
#
# It also fails if the third-party dish gRPC library is bundled anywhere in the package (its source
# tree or module, a wheel, an sdist/tarball/zip that contains it, or a copy under another name).
# NetBot downloads that library during setup at a pinned version; it must never ship inside NetBot.
#
# BRAND mentions (the satellite-internet brand and its maker) fail by default (strict mode). Exempt only:
#   ALLOW_BRAND_STRICT  exact strings in exact files (the gRPC service name, the README compatibility sentence)
#   ALLOW_BRAND_LINES   exact whole lines in exact files (the old key name, in the one-time migration only)
#   the pin line        the one line of the constants file that starts with PIN_LINE_PREFIX
# Everything else fails, including brand-named logo/image files and the brand in a product name,
# dashboard title, or window/dialog/notification title.
# --report-only-brand (or NETBOT_SCAN_STRICT_BRAND=0) lists brand hits without failing on them.
#
# Usage: bash tests/check_anonymous.sh [package-dir] [--report-only-brand]
#        bash tests/check_anonymous.sh --self-test     (proves the scan catches what it should)
#        NETBOT_PRIVATE_TERMS=/path/to/terms.txt bash tests/check_anonymous.sh
# Personal terms are not stored in this script. When NETBOT_PRIVATE_TERMS names an existing
# readable file, each non-blank line that does not start with # is an extra case-insensitive
# identifier regex. Unset: a warning is printed on stderr and the generic scan runs.
# Set but missing or unreadable: a warning is printed on stderr and the generic scan still runs.
# Scans: files tracked by git plus new untracked ones (or every file when not a git checkout);
#        the bundled-library check walks every file on disk that would be copied into the package.
# Skips: .git/, _review/ and _design/ (team work folders, not shipped), __pycache__/, binary files
#        for the text checks, and the pattern block of this script (between the PATTERNS markers).
set -euo pipefail
DIR="."; STRICT="${NETBOT_SCAN_STRICT_BRAND:-1}"; SELFTEST=""; [ "$STRICT" = 0 ] && STRICT=""
for a in "$@"; do case "$a" in --strict-brand) STRICT=1;; --report-only-brand) STRICT="";; --self-test) SELFTEST=1;; *) DIR="$a";; esac; done
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 - "$DIR" "$STRICT" "$SELFTEST" "$REPO" <<'PY'
import hashlib, io, ipaddress, os, re, subprocess, sys, tarfile, tempfile, zipfile

SELF = "tests/check_anonymous.sh"
SKIP_DIRS = (".git", "_review", "_design", "__pycache__")

# ---- PATTERNS-BEGIN (this block is not scanned)
# Public identifier regexes (case-insensitive). Personal terms stay out of git; a readable
# file named by NETBOT_PRIVATE_TERMS supplies those, one regex per non-blank, non-comment line.
IDENTIFIERS = [
]
BRANDS = [r"starlink", r"space\s*x"]   # case-insensitive
EMAIL = r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"
TLDS = "com|net|org|io|dev|co|us|gov|edu|mil|info|biz|me|ai|xyz|cloud|tech|uk|de|ca|au|local|lan|internal|home|arpa|invalid|test"
# (.app is left out on purpose: it collides with macOS app names such as Terminal.app)
HOST = r"(?<![A-Za-z0-9_.@-])(?:[A-Za-z0-9-]+\.)+(?:%s)(?![A-Za-z0-9-])" % TLDS
URL_PATH = r"[A-Za-z0-9_.~/-]*"            # path that follows an allowed host, compared exactly
IPV4 = r"(?<![0-9.])(?:\d{1,3}\.){3}\d{1,3}(?![0-9.])"
MAC = r"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:])"
# Hosts whose full URL (host + path) is compared, so only the one allowed link passes.
URL_CHECKED_HOSTS = {"github.com"}

# ---- allowlist: (exact file path, exact string) -> why it is there
ALLOW = {
    # hosts
    ("netbot/linksys_jnap.py", "cisco.com"):      "legacy JNAP action namespace on older router firmware (not a web request)",
    ("netbot/linksys_jnap.py", "linksys.com"):    "JNAP protocol action namespace the router API requires (not a web request)",
    ("netbot/linksys_jnap.py", "www.linksys.com"): "Linksys product end-of-life page cited as the source of End of Support dates (not a request NetBot makes)",
    ("install.sh", "linksys.com"):                "JNAP protocol action namespace the router API requires (not a web request)",
    ("install.sh", "myrouter.local"):             "the router maker's documented default local router name (auto-detect candidate)",
    ("install.ps1", "myrouter.local"):            "the router maker's documented default local router name (auto-detect candidate)",
    ("README.md", "myrouter.local"):              "the router maker's documented default local router name (auto-detect candidate)",
    ("lib/win/common.ps1", "linksys.com"):        "JNAP protocol action namespace the router API requires (not a web request)",
    ("tests/run_mock_install.sh", "example.com"): "placeholder (RFC 2606) in the lookalike test",
    ("LICENSE", "unlicense.org"):                 "public-domain license text",
    ("io.netbot.collect.plist.template", "www.apple.com"): "standard plist DOCTYPE URL",
    # the one allowed link: the pinned third-party dish library (compared as host + path)
    ("netbot/dish_constants.py", "codeload.github.com"): "where setup downloads the pinned dish library tarball",
    # emails
    ("tests/run_mock_install.sh", "t@example.invalid"): "placeholder (RFC 2606) in the allowlist test",
    # IPv4
    ("README.md", "192.168.100.1"):              "the dish's fixed local address, same for every dish",
    ("docs/methodology.md", "192.168.100.1"):    "the dish's fixed local address, same for every dish",
    ("config.example.toml", "192.168.100.1"):    "the dish's fixed local address, same for every dish",
    ("netbot/dish_constants.py", "192.168.100.1"): "the dish's fixed local address, same for every dish",
    ("README.md", "192.168.1.1"):                "common router default (example)",
    ("README.md", "10.0.0.1"):                   "common router default (auto-detect candidate)",
    ("README.md", "192.168.0.1"):                "common router default (auto-detect candidate)",
    ("README.md", "1.1.1.1"):                    "public anycast DNS resolver, default internet ping target (privacy section)",
    ("README.md", "9.9.9.9"):                    "public anycast DNS resolver, default internet ping target (privacy section)",
    ("install.sh", "192.168.1.1"):               "common router default (auto-detect candidate)",
    ("netbot/netbot_common.py", "192.168.1.1"):  "common router default (config default)",
    ("netbot/kit_router.py", "192.168.1.1"):     "common router default (kit Wi-Fi router gRPC host)",
    ("netbot/kit_router.py", "192.168.100.1"):   "the dish's fixed local address, same for every dish",
    ("netbot/unifi_router.py", "192.168.1.1"):   "common router default (example of a shared LAN address)",
    ("config.example.toml", "192.168.1.1"):      "common router default (example)",
    ("docs/router-vendors.md", "192.168.1.1"):   "common router default (example)",
    ("docs/router-vendors.md", "192.168.100.1"): "the dish's fixed local address, same for every dish",
    ("tests/test_dish_switch.py", "192.168.100.1"): "the dish's fixed local address, same for every dish",
    ("tests/test_monitor_controls.py", "127.0.0.1"): "loopback (tests)",
    ("tests/test_monitor_controls.py", "198.51.100.10"): "RFC 5737 documentation address in test data",
    ("tests/test_monitor_controls.py", "198.51.100.50"): "RFC 5737 documentation address in test data",
    ("tests/test_onedrive_batch.py", "198.51.100.2"): "RFC 5737 documentation address in test data",
    ("tests/test_onedrive_batch.py", "198.51.100.3"): "RFC 5737 documentation address in test data",
    ("tests/test_unifi_location.py", "192.168.1.1"): "common router default (tests)",
    ("tests/test_unifi_router.py", "10.0.0.1"):  "common router default (auto-detect candidate)",
    ("tests/test_unifi_router.py", "192.0.2.1"): "RFC 5737 documentation address in test data",
    ("strings/messages.sh", "192.168.1.1"):      "common router default (example in a prompt)",
    ("tests/run_mock_install.sh", "192.168.1.1"): "common router default (lookalike test)",
    ("install.sh", "192.168.0.1"):               "common router default (auto-detect candidate)",
    ("install.sh", "10.0.0.1"):                  "common router default (auto-detect candidate)",
    ("install.ps1", "192.168.1.1"):              "common router default (auto-detect candidate)",
    ("install.ps1", "192.168.0.1"):              "common router default (auto-detect candidate)",
    ("install.ps1", "10.0.0.1"):                 "common router default (auto-detect candidate)",
    ("lib/win/common.ps1", "0.0.0.0"):           "the Windows default-route prefix and the empty next-hop value (gateway lookup)",
    ("tests/fake_lan.py", "127.0.0.1"):          "loopback (tests)",
    ("tests/run_mock_install.sh", "127.0.0.1"):  "loopback (tests)",
    ("tests/fake_lan.py", "0.0.0.0"):            "placeholder firmware version in test data",
    ("tests/fake_lan.py", "198.51.100.2"):       "RFC 5737 documentation address in test data",
    ("netbot/netbot_common.py", "speed.cloudflare.com"): "public speed-test file, timed by the Windows download speed test only",
    ("README.md", "speed.cloudflare.com"):       "public speed-test host, Windows download speed test (privacy section)",
    ("README.md", "codeload.github.com"):        "where setup downloads the pinned dish library tarball (privacy section)",
    ("netbot/netbot_common.py", "1.1.1.1"):      "public anycast DNS resolver, default internet ping target (network checks)",
    ("netbot/netbot_common.py", "9.9.9.9"):      "public anycast DNS resolver, default internet ping target (network checks)",
    ("tests/fakebin/ip", "192.0.2.1"):           "RFC 5737 documentation address: fake default gateway",
    ("tests/fakebin/ping", "192.0.2.1"):         "RFC 5737 documentation address: fake default gateway",
    ("tests/fakebin/ping", "127.0.0.1"):         "loopback (tests)",
    ("tests/fakebin/ping", "203.0.113.9"):       "RFC 5737 documentation address: fake host that never answers",
    ("tests/test_network_checks.py", "198.51.100.7"): "RFC 5737 documentation address: fake internet target",
    ("tests/test_network_checks.py", "0.0.0.0"):      "the default-route row of a sample Windows route table",
    ("tests/test_network_checks.py", "203.0.113.9"):  "RFC 5737 documentation address: fake host that never answers",
    ("netbot/live_server.py", "10.0.0.0"):             "RFC 1918 private LAN range 10/8",
    ("netbot/live_server.py", "172.16.0.0"):           "RFC 1918 private LAN range 172.16/12",
    ("netbot/live_server.py", "192.168.0.0"):          "RFC 1918 private LAN range 192.168/16",
    ("tests/test_live_server.py", "10.0.0.1"):         "10/8 first usable address accepted as a private LAN address",
    ("tests/test_live_server.py", "10.255.255.254"):   "10/8 last usable address accepted as a private LAN address",
    ("tests/test_live_server.py", "11.0.0.0"):         "address just above 10/8 rejected as a home LAN address",
    ("tests/test_live_server.py", "172.16.0.1"):       "172.16/12 first usable address accepted as a private LAN address",
    ("tests/test_live_server.py", "172.31.255.254"):   "172.16/12 last usable address accepted as a private LAN address",
    ("tests/test_live_server.py", "172.32.0.1"):       "address just above 172.16/12 rejected as a home LAN address",
    ("tests/test_live_server.py", "172.15.255.255"):   "address just below 172.16/12 rejected as a home LAN address",
    ("tests/test_live_server.py", "192.168.0.1"):      "192.168/16 first usable address accepted as a private LAN address",
    ("tests/test_live_server.py", "192.168.255.254"):  "192.168/16 last usable address accepted as a private LAN address",
    ("tests/test_live_server.py", "192.169.0.0"):      "address just above 192.168/16 rejected as a home LAN address",
    ("tests/test_live_server.py", "100.64.0.1"):       "CGNAT address rejected as a home LAN address",
    ("tests/test_live_server.py", "169.254.1.1"):      "link-local address rejected as a home LAN address",
    ("tests/test_live_server.py", "127.0.0.1"):        "loopback ignored by LAN detection and accepted as a bind address",
    ("tests/test_live_server.py", "0.0.0.0"):          "unspecified address ignored by LAN detection and refused as a bind address",
    ("tests/test_live_server.py", "203.0.113.9"):      "RFC 5737 documentation address rejected as a home LAN address",
    # MAC
    ("tests/fake_lan.py", "02:00:00:00:00:01"):  "locally administered test MAC",
}

# Strict-mode brand exemptions (the final brand allowlist). Nothing else may mention the brand.
COMPAT_SENTENCE = "works with Starlink equipment, not affiliated with or endorsed by SpaceX, Starlink, Linksys, or Ubiquiti; names used only to describe compatibility"
ALLOW_BRAND_STRICT = {
    "netbot/dish_constants.py": ['DISH_GRPC_SERVICE = "SpaceX.API.Device.Device"'],  # the dish gRPC service name
    "README.md":                [COMPAT_SENTENCE],
}
# Exact whole lines (stripped of surrounding spaces). The old config/data key name lives only here.
ALLOW_BRAND_LINES = {
    "netbot/migrate_legacy.py": ['LEGACY_KEY = "starlink"'],   # read once by the one-time migration, then rewritten
}
# The pinned library name is allowed only on its pin line: the one line of the constants file that
# starts with this exact text.
PIN_LINE_FILE, PIN_LINE_PREFIX = "netbot/dish_constants.py", "DISH_LIB_PIN = "
TITLE_CONTEXT = re.compile(r"<title>|<h[1-6][\s>]|\btitle\s*[=:(]|\bwith\s+title\b|withTitle|document\.title"
                           r"|CFBundle(?:Display)?Name|\bMSG_[A-Z_]*TITLE\b|\bWindowTitle\b", re.I)
PRODUCT_NAME = re.compile(r"NetBot\W{0,3}(?:(?:for|by|from|a|an|the)\W{1,3}){0,2}(?:starlink|space\s*x)|(?:starlink|space\s*x)\W{1,3}NetBot", re.I)
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".gif", ".svg", ".ico", ".icns", ".webp", ".bmp", ".tif", ".tiff", ".heic", ".pdf")

# Bundled dish library detection
LIB_NAME = re.compile(r"starlink[-_]?grpc|spacex[/\\._-]api", re.I)       # in any path component or archive member
LIB_SIGNATURE = [re.compile(r"^\s*class\s+ChannelContext\b", re.M),         # a copy of the module under another name
                 re.compile(r"^\s*def\s+status_data\s*\(", re.M),
                 re.compile(r"^\s*def\s+history_(?:stats|bulk_data)\s*\(", re.M)]
ARCHIVE_EXT = (".whl", ".zip", ".egg", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz")
ALLOW_LIB_PATHS = {"tests/fake_dish_lib.py": "test stand-in (fake functions only), never the real library"}

def _b(*parts): return "".join(parts)   # self-test fixtures are split so this file stays clean
SELFTEST_BRAND = _b("Star", "link"); SELFTEST_MAKER = _b("Space", "X")
SELFTEST_MOD = _b("star", "link", "_grpc"); SELFTEST_PKG = _b("star", "link", "-grpc-tools")
SELFTEST_ROUTER_HOST = "myrouter.local"; SELFTEST_DISH_IP = "192.168.100.1"; SELFTEST_MAIL = "t@example.invalid"
SELFTEST_STANDIN = "tests/fake_dish_lib.py"
# Vendored uPlot. This one path is exempt from the text scan only when the sha256 matches.
# A different digest at this path fails the scan. The same bytes at any other path are scanned.
UPLOT_PIN_PATH = "netbot/vendor/uplot/uPlot.iife.min.js"
UPLOT_PIN_SHA256 = "19c8d4c6ad88929a79f4ae49d6f7161566dfd0ba3d15cc495e974f787eb78f1f"
# ---- PATTERNS-END

def brand_re(): return re.compile("|".join(BRANDS), re.I)

def private_identifiers():
    """Extra identifier regexes from NETBOT_PRIVATE_TERMS. Does not print the terms."""
    path = os.environ.get("NETBOT_PRIVATE_TERMS")
    if not path:
        print("warning: NETBOT_PRIVATE_TERMS is unset; continuing with the generic scan only", file=sys.stderr)
        return []
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read().splitlines()
    except OSError:
        print("warning: NETBOT_PRIVATE_TERMS is set but the file is missing or unreadable; continuing with the generic scan", file=sys.stderr)
        return []
    out, bad = [], False
    for line in raw:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        try:
            re.compile(s, re.I)
        except re.error:
            bad = True
            continue
        out.append(s)
    if bad:
        print("warning: NETBOT_PRIVATE_TERMS contains a line that is not a valid regex; that line was skipped", file=sys.stderr)
    return out

def walk(root):
    out = []
    for r, dirs, fs in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        out += [os.path.relpath(os.path.join(r, f), root).replace(os.sep, "/") for f in fs]
    return sorted(out)

def files(root):
    try:
        top = subprocess.run(["git", "-C", root, "rev-parse", "--show-toplevel"], capture_output=True, check=True, text=True).stdout.strip()
        if os.path.realpath(top) != os.path.realpath(root): raise RuntimeError("not the repo root")
        out = subprocess.run(["git", "-C", root, "ls-files", "-co", "--exclude-standard", "-z"], capture_output=True, check=True).stdout
        names = [n for n in out.decode().split("\0") if n]
    except Exception:
        names = walk(root)
    return sorted(n for n in names if not any(part in SKIP_DIRS for part in n.split("/")[:-1])
                  and os.path.isfile(os.path.join(root, n)))

USED = set()
def allowed(path, value):
    if (path, value) in ALLOW: USED.add((path, value)); return True
    return False

class Scan:
    def __init__(self, strict):
        self.strict, self.fail, self.brand, self.strict_hits = strict, [], [], []
    def hit(self, kind, path, ln, text, m):
        self.fail.append(f"{kind:10} {path}:{ln}: {m!r}   | {text.strip()[:110]}")
    def brand_hit(self, kind, where, m, text):
        line = f"{kind:10} {where}: {m!r}   | {text.strip()[:110]}"
        self.brand.append(line)
        self.strict_hits.append(line)

def covered(spans, a, b): return any(s <= a and b <= e for s, e in spans)
def spans_of(line, strings):
    out = []
    for s in strings:
        i = line.find(s)
        while i >= 0:
            out.append((i, i + len(s))); i = line.find(s, i + 1)
    return out

def strict_spans(path, line):
    sp = spans_of(line, ALLOW_BRAND_STRICT.get(path, []))
    USED.update((path, t) for t in ALLOW_BRAND_STRICT.get(path, []) if t in line)
    if line.strip() in ALLOW_BRAND_LINES.get(path, []):
        USED.add((path, line.strip())); sp.append((0, len(line)))
    if path == PIN_LINE_FILE and line.startswith(PIN_LINE_PREFIX):
        sp.append((0, len(line)))       # the pin line itself (only in the constants file)
    return sp

def brand_kind(path, line):
    if TITLE_CONTEXT.search(line) or (path.endswith(".md") and line.lstrip().startswith("#")): return "BRAND-TITLE"
    if PRODUCT_NAME.search(line): return "BRAND-NAME"
    return "BRAND"

def scan_text(sc, path, text, identifiers):
    B = brand_re()
    for ln, line in enumerate(text.splitlines(), 1):
        for p in identifiers:
            for m in re.finditer(p, line, re.I): sc.hit("IDENTITY", path, ln, line, m.group(0))
        for m in re.finditer(EMAIL, line):
            if not allowed(path, m.group(0)): sc.hit("EMAIL", path, ln, line, m.group(0))
        for m in re.finditer(HOST, line, re.I):
            h = m.group(0).rstrip(".")
            if h.lower() in URL_CHECKED_HOSTS:
                url = h + re.match(URL_PATH, line[m.end():]).group(0).rstrip("./")
                url_git = h + re.match(URL_PATH, line[m.end():]).group(0).rstrip("/")
                if not allowed(path, url) and not allowed(path, url_git): sc.hit("URL", path, ln, line, url_git)
            elif not allowed(path, h): sc.hit("HOST", path, ln, line, h)
        for m in re.finditer(IPV4, line):
            ip = m.group(0)
            try: ipaddress.ip_address(ip)
            except ValueError: continue
            if not allowed(path, ip): sc.hit("IP", path, ln, line, ip)
        for m in re.finditer(MAC, line):
            if not allowed(path, m.group(0)): sc.hit("MAC", path, ln, line, m.group(0))
        strict_ok = strict_spans(path, line)
        for m in B.finditer(line):
            a, b = m.span()
            if covered(strict_ok, a, b): continue
            sc.brand_hit(brand_kind(path, line), f"{path}:{ln}", m.group(0), line)

def scan_lib_bundle(sc, root):
    """Fail if the dish library is shipped in any form. Walks the disk, not just git."""
    for f in walk(root):
        if f in ALLOW_LIB_PATHS: continue
        full = os.path.join(root, f)
        if LIB_NAME.search(f): sc.fail.append(f"BUNDLED    {f}: dish library file/folder in the package"); continue
        low = f.lower()
        if low.endswith(ARCHIVE_EXT):
            try:
                if zipfile.is_zipfile(full):
                    with zipfile.ZipFile(full) as z: members = z.namelist()
                elif tarfile.is_tarfile(full):
                    with tarfile.open(full) as t: members = t.getnames()
                else: members = []
            except Exception as e:  # unreadable archive: never ship what we cannot inspect
                sc.fail.append(f"BUNDLED    {f}: archive could not be inspected ({type(e).__name__})"); continue
            bad = [x for x in members if LIB_NAME.search(x)]
            if bad: sc.fail.append(f"BUNDLED    {f}: archive contains the dish library ({bad[0]})"); continue
            if low.endswith((".whl", ".egg")): sc.fail.append(f"BUNDLED    {f}: Python package archive in the package (dependencies are downloaded, never shipped)")
            continue
        if f.endswith(".py"):
            try: text = open(full, encoding="utf-8", errors="replace").read()
            except OSError: continue
            if all(r.search(text) for r in LIB_SIGNATURE):
                sc.fail.append(f"BUNDLED    {f}: looks like a copy of the dish library module")

def scan_images(sc, f, data):
    B = re.compile(r"(?i)" + "|".join(BRANDS))
    m = B.search(f) or B.search(data.decode("latin-1"))
    if m: sc.brand_hit("BRAND-LOGO", f, m.group(0), "brand-named or brand-containing image/logo file")

def scan(root, strict):
    sc = Scan(strict); n = 0
    B = brand_re()
    identifiers = IDENTIFIERS + private_identifiers()
    for f in files(root):
        for p in identifiers:
            if re.search(p, f, re.I): sc.fail.append(f"IDENTITY   file name: {f}")
        data = open(os.path.join(root, f), "rb").read()
        if f.lower().endswith(IMAGE_EXT):
            scan_images(sc, f, data); continue
        m = B.search(f)
        if m: sc.brand_hit("BRAND-FILE", f, m.group(0), "brand in a shipped file name")
        if f == UPLOT_PIN_PATH:
            digest = hashlib.sha256(data).hexdigest()
            if digest != UPLOT_PIN_SHA256:
                sc.fail.append(f"PIN        {f}: sha256 {digest} differs from the pinned upstream file")
            else:
                n += 1
                continue
        if b"\0" in data[:8192]: continue   # binary
        text = data.decode("utf-8", "replace")
        if f == SELF:
            text = re.sub(r"# ---- PATTERNS-BEGIN.*?# ---- PATTERNS-END", lambda mm: "\n" * mm.group(0).count("\n"), text, flags=re.S)
        scan_text(sc, f, text, identifiers); n += 1
    scan_lib_bundle(sc, root)
    return sc, n

def report(sc, n, strict):
    print(f"anonymity scan: {n} files scanned (skipped: .git/, _review/, _design/, __pycache__/, binaries)")
    for line in sc.fail: print("  FAIL " + line)
    print(f"  identity/email/host/URL/IP/MAC/bundled-library hits: {len(sc.fail)}")
    if strict:
        print(f"  STRICT brand hits (anything outside the final brand allowlist): {len(sc.strict_hits)}")
        for line in sc.strict_hits: print("  STRICT " + line)
    else:
        print(f"  BRAND mentions: {len(sc.brand)} (report-only run; the default strict run fails on these)")
        for line in sc.brand: print("  FLAG " + line)
    stale = [k for k in ALLOW if k not in USED] + [(f, t) for d in (ALLOW_BRAND_STRICT, ALLOW_BRAND_LINES)
                                                    for f, ts in d.items() for t in ts if (f, t) not in USED]
    for f, t in stale: print(f"  NOTE allowlist entry not used any more (remove it): {f}: {t!r}")
    return 1 if sc.fail or (strict and sc.strict_hits) else 0

def self_test():
    ok = True
    def case(name, tree, strict, expect_fail, expect=None):
        nonlocal ok
        with tempfile.TemporaryDirectory() as d:
            for rel, content in tree.items():
                full = os.path.join(d, rel); os.makedirs(os.path.dirname(full), exist_ok=True)
                with open(full, "wb") as fh: fh.write(content if isinstance(content, bytes) else content.encode())
            sc, _ = scan(d, strict)
            failed = bool(sc.fail) or (strict and bool(sc.strict_hits))
            lines = sc.fail + sc.strict_hits
            good = failed == expect_fail and (expect is None or any(expect in l for l in lines))
            ok &= good
            print(f"  {'PASS' if good else 'FAIL'}: self-test: {name}" + ("" if good else f"  (got failed={failed}: {lines[:3]})"))
    def zbytes(member):
        b = io.BytesIO()
        with zipfile.ZipFile(b, "w") as z: z.writestr(member, "x = 1\n")
        return b.getvalue()
    def tbytes(member):
        b = io.BytesIO()
        with tarfile.open(fileobj=b, mode="w:gz") as t:
            data = b"x = 1\n"; ti = tarfile.TarInfo(member); ti.size = len(data); t.addfile(ti, io.BytesIO(data))
        return b.getvalue()
    sig = "class ChannelContext:\n    pass\ndef status_data(context=None):\n    pass\ndef history_stats(n, context=None):\n    pass\n"
    rh, dish_ip, mail = SELFTEST_ROUTER_HOST, SELFTEST_DISH_IP, SELFTEST_MAIL
    # 1. exact file + exact string
    case("allowed host in its own file passes", {"install.sh": f"h={rh}\n"}, False, False)
    case("allowed host in another file fails", {"lib/common.sh": f"h={rh}\n"}, False, True, "HOST")
    case("allowed IP in another file fails", {"lib/common.sh": f"ip={dish_ip}\n"}, False, True, "IP")
    case("allowed email in another file fails", {"README.md": f"{mail}\n"}, False, True, "EMAIL")
    case("allowed host with a different case/suffix fails", {"install.sh": f"h=x.{rh}\n"}, False, True, "HOST")
    case("allowed link with another path fails", {"README.md": _b("https://github", ".com/sparky8512/other")}, False, True, "URL")
    case("library module name in code fails (no technical exemptions)", {"netbot/collect.py": f"import {SELFTEST_MOD}\n"}, True, True, "BRAND")
    # 2. bundled dish library
    case("planted library module fails", {f"netbot/vendor/{SELFTEST_MOD}.py": "x = 1\n"}, False, True, "BUNDLED")
    case("planted library source tree fails", {f"{SELFTEST_PKG}/README.md": "x\n"}, False, True, "BUNDLED")
    case("planted wheel fails", {"deps/" + SELFTEST_PKG.replace("-", "_") + "-1.0-py3-none-any.whl": zbytes(f"{SELFTEST_MOD}.py")}, False, True, "BUNDLED")
    case("tarball with a neutral name that contains the library fails", {"deps/extras.tar.gz": tbytes(f"pkg/{SELFTEST_MOD}.py")}, False, True, "BUNDLED")
    case("copy of the library under a neutral name fails", {"netbot/dishlib.py": sig}, False, True, "BUNDLED")
    case("any wheel fails even without the name", {"deps/grpcio-1.0-py3-none-any.whl": zbytes("grpc/__init__.py")}, False, True, "BUNDLED")
    case("the test stand-in at its exact path passes", {SELFTEST_STANDIN: sig}, False, False)
    case("the test stand-in at another path fails", {"netbot/fake_x.py": sig}, False, True, "BUNDLED")
    # 3. strict brand mode
    case("compat sentence in README passes strict", {"README.md": f"NetBot {COMPAT_SENTENCE}.\n"}, True, False)
    case("compat sentence in another file fails strict", {"netbot/collect.py": f"# {COMPAT_SENTENCE}\n"}, True, True, "BRAND")
    case("brand outside the sentence in README fails strict", {"README.md": f"Checks your {SELFTEST_BRAND} dish.\n"}, True, True, "BRAND")
    case("brand mention passes only in a report-only run", {"README.md": f"Checks your {SELFTEST_BRAND} dish.\n"}, False, False)
    old_line = 'LEGACY_KEY = "' + SELFTEST_BRAND.lower() + '"'
    case("old key line in the migration file passes", {"netbot/migrate_legacy.py": f"{old_line}\n"}, True, False)
    case("old key line in any other file fails", {"netbot/collect.py": f"{old_line}\n"}, True, True, "BRAND")
    case("old key with extra text on the line fails", {"netbot/migrate_legacy.py": f"{old_line}; X = '{SELFTEST_BRAND.lower()}'\n"}, True, True, "BRAND")
    case("old key used elsewhere in the migration file fails", {"netbot/migrate_legacy.py": f"{old_line}\nK = '[{SELFTEST_BRAND.lower()}]'\n"}, True, True, "BRAND")
    case("brand in dashboard title fails strict", {"netbot/x.py": f"<title>NetBot: {SELFTEST_BRAND} Monitor</title>\n"}, True, True, "BRAND-TITLE")
    case("brand in a window title fails strict", {"lib/x.sh": f'display dialog "hi" with title "{SELFTEST_BRAND}"\n'}, True, True, "BRAND-TITLE")
    case("brand in the product name fails strict", {"CHANGELOG.md": f"- NetBot for {SELFTEST_BRAND}\n"}, True, True, "BRAND-NAME")
    case("brand-named logo file fails strict", {f"art/{SELFTEST_BRAND.lower()}-logo.png": b"\x89PNG\r\n\x1a\n\0\0"}, True, True, "BRAND-LOGO")
    case("logo whose content names the maker fails strict", {"art/emblem.svg": f"<svg><title>{SELFTEST_MAKER}</title></svg>"}, True, True, "BRAND-LOGO")
    case("service name and pin line in the constants file pass strict",
         {"netbot/dish_constants.py": 'DISH_GRPC_SERVICE = "' + SELFTEST_MAKER + '.API.Device.Device"\n'
                                      + PIN_LINE_PREFIX + f'("{SELFTEST_PKG}", "{SELFTEST_MOD}")\n'}, True, False)
    case("library name off the pin line fails strict", {"netbot/dish_constants.py": f'X = "{SELFTEST_PKG}"\n'}, True, True, "BRAND")
    # 4. identifiers from a private terms file in this test's own temp dir (neutral term, split here)
    neutral = _b("acme", "widget")
    with tempfile.TemporaryDirectory() as terms_dir:
        terms_path = os.path.join(terms_dir, "terms.txt")
        with open(terms_path, "w", encoding="utf-8") as fh:
            fh.write("# neutral fixture\n\n" + r"(?<![A-Za-z0-9])" + neutral + r"(?![A-Za-z0-9])" + "\n")
        os.chmod(terms_path, 0o600)
        prev = os.environ.get("NETBOT_PRIVATE_TERMS")
        os.environ["NETBOT_PRIVATE_TERMS"] = terms_path
        try:
            case("planted identifier fails", {"notes.txt": "made by " + neutral + "\n"}, False, True, "IDENTITY")
            case("lookalikes pass", {"notes.txt": neutral + "x hash a1" + neutral + "b\n"}, False, False)
        finally:
            if prev is None:
                os.environ.pop("NETBOT_PRIVATE_TERMS", None)
            else:
                os.environ["NETBOT_PRIVATE_TERMS"] = prev
    # 5. vendored uPlot: one path, pinned sha256
    with open(os.path.join(REPO, UPLOT_PIN_PATH), "rb") as fh:
        real = fh.read()
    if hashlib.sha256(real).hexdigest() != UPLOT_PIN_SHA256:
        ok = False
        print("  FAIL: self-test: vendored uPlot does not match UPLOT_PIN_SHA256")
    else:
        flipped = bytearray(real)
        flipped[-1] ^= 0x01
        case("pinned uPlot file passes", {UPLOT_PIN_PATH: real}, False, False)
        case("modified copy of the pinned uPlot file fails", {UPLOT_PIN_PATH: bytes(flipped)}, False, True, "PIN")
        case("same uPlot bytes at another path are scanned", {"netbot/extra.js": real}, False, True, "URL")
    print("self-test: " + ("ALL PASSED" if ok else "FAILED"))
    return 0 if ok else 1

root, strict, selftest = sys.argv[1], sys.argv[2] not in ("", "0"), bool(sys.argv[3])
REPO = sys.argv[4] if len(sys.argv) > 4 else root
if selftest: sys.exit(self_test())
os.chdir(root)
sc, n = scan(".", strict)
sys.exit(report(sc, n, strict))
PY
