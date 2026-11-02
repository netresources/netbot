#!/usr/bin/env python3
"""JSON for the live page. The collector writes it on every run.

Files (beside the data directory, not in the synced copy):
  <data_dir>/../live/status.json
  <data_dir>/../live/history.json

Same numbers as the static dashboard. No access key and no web address.
"""
import sys, time
from datetime import datetime
from pathlib import Path

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from netbot_common import dish_enabled, load_config, p, read_samples, write_json_atomic
from dish_constants import DISH_DATA_KEY
from migrate_legacy import LEGACY_KEY
from evaluate_alerts import tiles, CRIT_DISH_ALERTS, WARN_DISH_ALERTS
from make_dashboard import charts, readout_values, WEEK
import theme_tokens as TH
import ui_text as T

SCHEMA = 1
STALE_AFTER_S = 20 * 60
POLL_S = 30
# Fields copied in memory when a row still uses the legacy dish key. An existing dish object wins.
_LEGACY_DISH_FIELDS = (
    "reachable", "state", "uptime_s", "software_version", "pop_ping_latency_ms",
    "pop_ping_drop_rate", "downlink_bps", "uplink_bps", "fraction_obstructed",
    "alerts", "update_pending", "hist_latency_median_ms", "hist_ping_drop_rate",
)

DISH_TILES = (T.TILE_DISH_STATUS, T.TILE_DISH_THROUGHPUT, T.TILE_DISH_LATENCY,
              T.TILE_DISH_OBSTRUCTION, T.TILE_DISH_FIRMWARE, T.TILE_DISH_ALERTS)
NET_TILES = (T.TILE_GATEWAY_PING, T.TILE_INTERNET_LATENCY, T.TILE_PACKET_LOSS, T.TILE_SPEED_TEST)


def live_paths(cfg):
    data_dir = p(cfg["paths"]["data_dir"])
    folder = data_dir.parent / "live"
    return data_dir, folder / "status.json", folder / "history.json"


def _with_dish(samples):
    """Rows the dashboard can read. A legacy dish object is copied onto the dish key in memory.

    The copy is a new dict. The caller's row and the file it came from are left unchanged.
    When the dish key is already present, it wins and the legacy object is ignored.
    """
    out = []
    for row in samples:
        if not isinstance(row, dict) or DISH_DATA_KEY in row or not isinstance(row.get(LEGACY_KEY), dict):
            out.append(row)
            continue
        legacy = row[LEGACY_KEY]
        mapped = dict(row)
        mapped[DISH_DATA_KEY] = {k: legacy[k] for k in _LEGACY_DISH_FIELDS if k in legacy}
        out.append(mapped)
    return out


def _tile(name, level, text, value, wide=False):
    val, unit, is_word, metric, src = value
    _tok, cls, word, _mark = TH.LEVELS[level]
    return {
        "name": name, "level": level, "word": word, "cls": cls, "text": str(text),
        "value": val, "unit": unit, "is_word": bool(is_word), "metric": metric,
        "source": src, "wide": bool(wide),
    }


ACTIVE_ROUTER_NAMES = {"linksys": "Linksys router", "kit": "Kit router"}


UNIFI_MODEL_NAMES = {
    "UDMPROSE": "UniFi Dream Machine SE",
    "UDMPRO": "UniFi Dream Machine Pro",
    "UDMPROMAX": "UniFi Dream Machine Pro Max",
    "UDM": "UniFi Dream Machine",
    "UDR": "UniFi Dream Router",
    "UDR7": "UniFi Dream Router 7",
    "UCG": "UniFi Cloud Gateway",
    "UCGULTRA": "UniFi Cloud Gateway Ultra",
    "UCGMAX": "UniFi Cloud Gateway Max",
    "UXG": "UniFi Next-Gen Gateway",
    "UXGPRO": "UniFi Next-Gen Gateway Pro",
    "USG": "UniFi Security Gateway",
}


def unifi_label(model):
    """'UniFi Dream Machine SE' for UDMPROSE; other models 'UniFi <model>'; no model -> 'UniFi router'."""
    m = str(model or "").strip()
    if not m:
        return "UniFi router"
    key = m.upper().replace("-", "").replace(" ", "")
    if key in UNIFI_MODEL_NAMES:
        return UNIFI_MODEL_NAMES[key]
    return m if m.lower().startswith("unifi") else "UniFi " + m


def active_router(last, now):
    """Header 'Active router' label from the latest sample's router vendor / lan_mode.
    Unknown when data is missing, stale, or the vendor isn't one we name."""
    if not isinstance(last, dict) or not last:
        return "Unknown"
    ts = last.get("ts")
    if not isinstance(ts, (int, float)) or now - ts > STALE_AFTER_S:
        return "Unknown"
    rt = last.get("router")
    if isinstance(rt, dict):
        v = str(rt.get("vendor") or "").lower()
        if v == "unifi":
            # Router vendor wins over the network-path fallback for UniFi.
            return unifi_label(rt.get("model"))
        if not rt.get("skipped") and v in ACTIVE_ROUTER_NAMES:
            return ACTIVE_ROUTER_NAMES[v]
    return ACTIVE_ROUTER_NAMES.get(str(last.get("lan_mode") or "").lower(), "Unknown")


def build_status(samples, now, cfg):
    samples = _with_dish(samples)
    dish_on = dish_enabled(cfg)
    info = tiles(samples, now, dish=dish_on)
    vals = readout_values(samples, now)
    last = samples[-1] if samples else {}
    router_on = isinstance(last.get("router"), dict)
    active = set((last.get(DISH_DATA_KEY) or {}).get("alerts") or [])
    panels = []
    for name in (DISH_TILES if dish_on else ()) + NET_TILES:
        if name not in info or name not in vals:
            continue
        tile = _tile(name, info[name][0], info[name][1], vals[name], wide=name == T.TILE_DISH_ALERTS)
        if name == T.TILE_DISH_ALERTS:
            items = sorted(CRIT_DISH_ALERTS) + sorted(WARN_DISH_ALERTS)
            tile["watch"] = [{"name": a.replace("_", " "),
                              "word": "ALERT" if a in CRIT_DISH_ALERTS else "WARN",
                              "on": a in active} for a in items]
        panels.append(tile)
    collector = None
    if T.TILE_COLLECTOR in info:
        level, text = info[T.TILE_COLLECTOR]
        collector = _tile(T.TILE_COLLECTOR, level, text, (TH.LEVELS[level][2], "", True, None, T.SRC_CALC))
    router = None
    if router_on and T.TILE_ROUTER in info:
        level, text = info[T.TILE_ROUTER]
        router = _tile(T.TILE_ROUTER, level, text, (TH.LEVELS[level][2], "", True, None, T.SRC_ROUTER))
    return {
        "schema": SCHEMA,
        "kind": "status",
        "title": T.PRODUCT_TITLE,
        "generated_ts": now,
        "sample_ts": last.get("ts") if last else None,
        "sample_iso": last.get("iso") or "",
        "clock": datetime.fromtimestamp(now).strftime("%a %b %d, %I:%M %p"),
        "stale_after_s": STALE_AFTER_S,
        "poll_s": POLL_S,
        "lan_access": bool((cfg.get("live") or {}).get("lan")),
        "router_on": router_on,
        "active_router": active_router(last, now),
        "dish_on": dish_on,
        "example": any(bool(s.get("example")) for s in samples) or bool((cfg.get("live") or {}).get("example")),
        "example_text": T.EXAMPLE_BANNER,
        "tiles": panels,
        "sections": [
            {"label": T.SECTION_DISH, "names": [n for n in DISH_TILES if n in info], "collector": True},
            {"label": T.SECTION_NETWORK, "names": [n for n in NET_TILES if n in info], "collector": not dish_on},
        ][(0 if dish_on else 1):],
        "chips": [
            {"text": T.CHIP_DISH if dish_on else T.CHIP_DISH_OFF, "on": dish_on},
            {"text": T.CHIP_NETWORK, "on": True},
            {"text": T.CHIP_ROUTER.format(state="on" if router_on else "off"), "on": router_on},
        ],
        "legend": [{"mark": m, "text": d} for m, d in T.LEGEND],
        "collector": collector,
        "router": router,
    }


def build_history(samples, now, dish=True):
    samples = _with_dish(samples)
    last = samples[-1] if samples else {}
    router_on = isinstance(last.get("router"), dict)
    sections = []
    for label, src, items in charts(samples, now, router_on, dish=dish):
        sections.append({
            "label": label,
            "source": src,
            "addon": label == T.SECTION_ROUTER,
            "charts": [{
                "title": title, "metric": metric, "unit": unit, "span_s": span,
                "points": [[float(ts), float(v)] for ts, v in pts],
            } for title, metric, pts, unit, span in items],
        })
    return {"schema": SCHEMA, "kind": "history", "generated_ts": now, "sections": sections}


def write(cfg=None, now=None):
    cfg = cfg or load_config()
    now = time.time() if now is None else now
    data_dir, status_path, history_path = live_paths(cfg)
    samples = read_samples(data_dir, now - WEEK)
    write_json_atomic(status_path, build_status(samples, now, cfg))
    write_json_atomic(history_path, build_history(samples, now, dish=dish_enabled(cfg)))
    return status_path, history_path
