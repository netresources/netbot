"""Shared helpers: config loading, paths, JSONL I/O. Standard library only."""
import json, os, time
from pathlib import Path
from dish_constants import DISH_CFG_SECTION, DISH_HOST, DISH_LIB_DIR, DISH_PATHS_KEY, DISH_PORT

try:
    import tomllib  # Python 3.11+
except ImportError:  # Python 3.9/3.10 (e.g. macOS system python3 3.9.6)
    tomllib = None


def _parse_simple_toml(text):
    """Tiny parser for the TOML subset install.sh writes: [sections], key = "string" | int | true/false, # comments."""
    out, cur = {}, None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            cur = out.setdefault(line[1:-1].strip(), {})
            continue
        key, _, val = line.partition("=")
        key, val = key.strip(), val.strip()
        if val.startswith('"'):
            end = val.find('"', 1)
            val = val[1:end] if end > 0 else val[1:]
        else:
            val = val.split("#", 1)[0].strip()
            val = {"true": True, "false": False}.get(val, val)
            if isinstance(val, str):
                try:
                    val = int(val)
                except ValueError:
                    pass
        (cur if cur is not None else out)[key] = val
    return out

DEFAULTS = {
    "paths": {"data_dir": "~/NetBot/data", "sync_dir": "", DISH_PATHS_KEY: "~/NetBot/" + DISH_LIB_DIR},
    DISH_CFG_SECTION: {"target": f"{DISH_HOST}:{DISH_PORT}"},
    "router": {"enabled": True, "host": "192.168.1.1", "username": "admin", "keychain_service": "netbot-linksys"},
    # network checks (core, always on). internet_targets: hosts to ping, space-separated (public anycast DNS
    # resolvers by default). speedtest: "auto" (macOS networkQuality when available) or "off".
    # speedtest_url: used only on Windows, where NetBot times one download of this file (25 MB) in PowerShell.
    "network": {"gateway": "", "internet_targets": "1.1.1.1 9.9.9.9", "ping_count": 10,
                "speedtest": "auto", "speedtest_every_h": 6,
                "speedtest_url": "https://speed.cloudflare.com/__down?bytes=25000000"},
    "alerts": {"quiet_start": 22, "quiet_end": 6},
    # Live page. lan is Home Wi-Fi access (off by default). The access key is not stored here.
    "live": {"lan": False, "port": 8765},
}

def load_config(path=None):
    cfg = json.loads(json.dumps(DEFAULTS))
    path = Path(os.path.expanduser(path or os.environ.get("NETBOT_CONFIG", "~/NetBot/config.toml")))
    if path.exists():
        if tomllib:
            with open(path, "rb") as f:
                data = tomllib.load(f)
        else:
            data = _parse_simple_toml(path.read_text(encoding="utf-8"))
        for k, v in data.items():
            if isinstance(v, dict):
                cfg.setdefault(k, {}).update(v)
    return cfg

def p(s):
    return Path(os.path.expanduser(s)) if s else None

def month_file(data_dir, ts=None):
    return Path(data_dir) / time.strftime("%Y-%m.jsonl", time.localtime(ts or time.time()))

def append_jsonl(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(obj, separators=(",", ":")) + "\n")

def write_json_atomic(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2), encoding="utf-8")
    os.replace(tmp, path)

def read_samples(data_dir, since_ts):
    out = []
    for f in sorted(Path(data_dir).glob("*.jsonl")):
        for line in f.read_text(encoding="utf-8").splitlines():
            try:
                s = json.loads(line)
            except ValueError:
                continue
            if s.get("ts", 0) >= since_ts:
                out.append(s)
    return sorted(out, key=lambda s: s["ts"])
