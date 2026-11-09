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
    "paths": {"data_dir": "~/NetBot/data", "sync_dir": "", DISH_PATHS_KEY: "~/NetBot/" + DISH_LIB_DIR,
              # 0 = sync every collector run (legacy). 240 = every 4 hours.
              "onedrive_sync_interval_min": 0,
              # When True, a newly raised ALERT forces an immediate OneDrive sync.
              "onedrive_sync_on_alert": True},
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

def dish_enabled(cfg):
    """[dish] enabled (default true). False skips dish polling, dish tiles, alerts, and charts."""
    v = ((cfg or {}).get(DISH_CFG_SECTION) or {}).get("enabled", True)
    if isinstance(v, str):
        return v.strip().lower() not in ("false", "0", "no", "off")
    return bool(v)

def p(s):
    return Path(os.path.expanduser(s)) if s else None

def month_file(data_dir, ts=None):
    return Path(data_dir) / time.strftime("%Y-%m.jsonl", time.localtime(ts or time.time()))

def append_jsonl(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(obj, separators=(",", ":")) + "\n")

def _os_replace_retry(tmp, path, retries=8):
    """os.replace with backoff for OneDrive CloudStorage EDEADLK (errno 11)."""
    tmp, path = Path(tmp), Path(path)
    delay = 0.05
    last = None
    for _ in range(retries):
        try:
            os.replace(tmp, path)
            return
        except OSError as exc:
            last = exc
            if getattr(exc, "errno", None) not in (11, getattr(__import__("errno"), "EDEADLK", 11), getattr(__import__("errno"), "EAGAIN", 35)):
                raise
            time.sleep(delay)
            delay = min(delay * 2, 1.0)
    if last is not None:
        raise last
    raise OSError("os.replace failed")


def write_json_atomic(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path = Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2), encoding="utf-8")
    _os_replace_retry(tmp, path)

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


def slim_row(sample):
    # Synced copies keep router summaries only: no per-client records, no public WAN IP.
    out = dict(sample)
    r = out.get("router")
    if isinstance(r, dict):
        out["router"] = {k: v for k, v in r.items() if k not in ("clients", "wan_ip")}
    return out


def _sync_month_names(ts):
    lt = time.localtime(time.time() if ts is None else ts)
    names = [time.strftime("%Y-%m.jsonl", lt)]
    if lt.tm_mday <= 2:  # 1st and 2nd also refresh the previous month
        y, m = lt.tm_year, lt.tm_mon - 1
        if m == 0:
            y, m = y - 1, 12
        names.insert(0, f"{y:04d}-{m:02d}.jsonl")
    return names


def _write_jsonl_atomic(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path = Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text("".join(json.dumps(r, separators=(",", ":")) + "\n" for r in rows), encoding="utf-8")
    _os_replace_retry(tmp, path)


def sync_history(data_dir, sync_dir, ts=None):
    """Copy slim monthly JSONL into sync_dir. Returns the month file names written."""
    data_dir, sync_dir = Path(data_dir), Path(sync_dir)
    sync_dir.mkdir(parents=True, exist_ok=True)
    state_path = sync_dir / ".history_sync_state.json"
    try:
        state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {}
    except ValueError:
        state = {}
    if not isinstance(state, dict):
        state = {}
    written = []
    for name in _sync_month_names(ts):
        src = data_dir / name
        if not src.exists():
            continue
        dst = sync_dir / name
        st = src.stat()
        prev = state.get(name)
        if (dst.exists() and isinstance(prev, dict) and prev.get("size") == st.st_size
                and prev.get("mtime_ns") == st.st_mtime_ns):
            continue
        rows = []
        for line in src.read_text(encoding="utf-8").splitlines():
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict):
                rows.append(slim_row(obj))
        _write_jsonl_atomic(dst, rows)
        state[name] = {"size": st.st_size, "mtime_ns": st.st_mtime_ns}
        written.append(name)
    if written:
        write_json_atomic(state_path, state)
    return written

# ---- OneDrive batch sync (local-first; gate cloud writes) ----
ONEDRIVE_SYNC_STATE = ".onedrive_sync_state.json"


def local_alerts_dir(cfg):
    """Alerts live next to data_dir (e.g. ~/NetBot/alerts), not in the synced copy."""
    return p(cfg["paths"]["data_dir"]).parent / "alerts"


def local_dashboard_dir(cfg):
    return p(cfg["paths"]["data_dir"]).parent / "dashboard"


def onedrive_sync_interval_min(cfg):
    v = (cfg.get("paths") or {}).get("onedrive_sync_interval_min", 0)
    try:
        return max(0, int(v))
    except (TypeError, ValueError):
        return 0


def onedrive_sync_on_alert(cfg):
    v = (cfg.get("paths") or {}).get("onedrive_sync_on_alert", True)
    if isinstance(v, str):
        return v.strip().lower() not in ("false", "0", "no", "off")
    return bool(v)


def _onedrive_state_path(cfg):
    return p(cfg["paths"]["data_dir"]) / ONEDRIVE_SYNC_STATE


def read_onedrive_sync_state(cfg):
    path = _onedrive_state_path(cfg)
    try:
        st = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    except ValueError:
        st = {}
    return st if isinstance(st, dict) else {}


def write_onedrive_sync_state(cfg, last_sync_ts, month=None):
    month = month or time.strftime("%Y-%m", time.localtime(last_sync_ts))
    write_json_atomic(_onedrive_state_path(cfg), {
        "last_sync_ts": float(last_sync_ts),
        "last_sync_month": month,
        "last_sync_iso": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(last_sync_ts)),
    })


def should_sync_onedrive(cfg, now=None, force=False):
    """True when OneDrive should be written this run.

    Reasons: no sync_dir -> False; interval 0 -> every run; force (e.g. new ALERT);
    never synced; interval elapsed; calendar month rolled over since last sync.
    """
    if not p((cfg.get("paths") or {}).get("sync_dir")):
        return False
    if force:
        return True
    interval = onedrive_sync_interval_min(cfg)
    if interval <= 0:
        return True
    now = time.time() if now is None else float(now)
    st = read_onedrive_sync_state(cfg)
    last = st.get("last_sync_ts")
    if not isinstance(last, (int, float)):
        return True
    cur_month = time.strftime("%Y-%m", time.localtime(now))
    if st.get("last_sync_month") != cur_month:
        return True
    return (now - float(last)) >= interval * 60


def write_text_atomic(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    _os_replace_retry(tmp, path)


def copy_file_atomic(src, dst):
    src, dst = Path(src), Path(dst)
    if not src.is_file():
        return False
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_suffix(dst.suffix + ".tmp")
    tmp.write_bytes(src.read_bytes())
    _os_replace_retry(tmp, dst)
    return True


def sync_alerts_to_onedrive(cfg, sync_dir):
    """Copy local alerts/active.json and ALERT-*.json into sync_dir/alerts (atomic)."""
    local = local_alerts_dir(cfg)
    remote = Path(sync_dir) / "alerts"
    remote.mkdir(parents=True, exist_ok=True)
    copied = []
    if not local.is_dir():
        return copied
    for name in ["active.json", *sorted(fp.name for fp in local.glob("ALERT-*.json"))]:
        src = local / name
        if src.is_file() and copy_file_atomic(src, remote / name):
            copied.append(name)
    return copied


def push_onedrive(cfg, sample, ts=None, force=False):
    """Write all OneDrive artifacts if the gate allows. Returns True if a sync ran.

    Catches up history (full slim month rewrite), latest.json, heartbeat, alerts,
    dashboard.png, and updates the local .onedrive_sync_state.json.
    """
    import sys
    sync = p((cfg.get("paths") or {}).get("sync_dir"))
    if not sync:
        return False
    now = float(ts if ts is not None else time.time())
    if not should_sync_onedrive(cfg, now=now, force=force):
        return False
    data_dir = p(cfg["paths"]["data_dir"])
    sync.mkdir(parents=True, exist_ok=True)
    if cfg["paths"].get("sync_history", True):
        try:
            sync_history(data_dir, sync, now)
        except Exception as e:  # noqa: BLE001
            print(f"history sync failed: {type(e).__name__}: {e}", file=sys.stderr)
    write_json_atomic(sync / "latest.json", slim_row(sample))
    iso = sample.get("iso") or time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now))
    write_text_atomic(sync / "heartbeat", iso + "\n")
    sync_alerts_to_onedrive(cfg, sync)
    png = local_dashboard_dir(cfg) / "dashboard.png"
    if png.is_file():
        copy_file_atomic(png, sync / "dashboard.png")
    write_onedrive_sync_state(cfg, now)
    return True
