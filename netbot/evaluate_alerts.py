#!/usr/bin/env python3
"""Rule-based alert evaluator. No LLM, no network. Shared by the dashboard.

Writes ~/NetBot/alerts/active.json (beside data_dir) and, when a NEW red
condition appears, ALERT-<time>.json plus a local macOS
notification. Same condition is not re-alerted until it clears.
"""
import json, statistics, subprocess, sys, time
from datetime import datetime
from netbot_common import dish_enabled, load_config, p, read_samples, write_json_atomic, local_alerts_dir
from dish_constants import DISH_DATA_KEY
import ui_text as T
NET_KEY = "network"

GREEN, YELLOW, RED, GRAY = "green", "yellow", "red", "gray"
CRIT_DISH_ALERTS = {"thermal_shutdown", "motors_stuck", "mast_not_near_vertical", "unexpected_location", "power_supply_thermal_throttle",
                    "dish_water_detected", "router_water_detected"}
WARN_DISH_ALERTS = {"thermal_throttle", "slow_ethernet_speeds", "roaming", "is_heating"}

DISH_TILE_NAMES = (T.TILE_DISH_STATUS, T.TILE_DISH_THROUGHPUT, T.TILE_DISH_LATENCY,
                   T.TILE_DISH_OBSTRUCTION, T.TILE_DISH_FIRMWARE, T.TILE_DISH_ALERTS)

def _vals(samples, key, sub=DISH_DATA_KEY):
    return [s[sub][key] for s in samples if isinstance(s.get(sub), dict) and isinstance(s[sub].get(key), (int, float))]

# Network-check thresholds. Internet latency and loss reuse the dish latency/drop thresholds (proposed in the
# style spec); gateway ping has no agreed threshold yet, so it is red only when the gateway does not answer.
NET_LATENCY_WARN_MS, NET_LATENCY_ALERT_MS = 60, 100
NET_LOSS_WARN, NET_LOSS_ALERT = 0.02, 0.05
SPEED_OK_MBPS, SPEED_WARN_MBPS = 100, 50

def network_tiles(samples, now):
    out = {}
    hour = [s for s in samples if s["ts"] >= now - 3600]
    last = (samples[-1].get(NET_KEY) if samples else None) or {}
    if not last:
        for k in (T.TILE_GATEWAY_PING, T.TILE_INTERNET_LATENCY, T.TILE_PACKET_LOSS):
            out[k] = (GRAY, "no data")
    else:
        gw = last.get("gateway_ping_ms")
        if not last.get("gateway_found"):
            out[T.TILE_GATEWAY_PING] = (GRAY, "no gateway found")
        elif last.get("gateway_loss") == 1.0 or gw is None:
            out[T.TILE_GATEWAY_PING] = (RED, "gateway not answering")
        else:
            out[T.TILE_GATEWAY_PING] = (GREEN, f"{gw:.1f} ms")
        lat = _vals(hour, "internet_latency_ms", NET_KEY)
        if lat:
            m = statistics.median(lat)
            out[T.TILE_INTERNET_LATENCY] = ((RED if m > NET_LATENCY_ALERT_MS else YELLOW if m > NET_LATENCY_WARN_MS else GREEN),
                                            f"median {m:.0f} ms, last hour")
        else:
            out[T.TILE_INTERNET_LATENCY] = (RED if last.get("internet_loss") == 1.0 else GRAY,
                                            "no replies" if last.get("internet_loss") == 1.0 else "no data")
        loss = _vals(hour, "internet_loss", NET_KEY)
        if loss:
            m = statistics.mean(loss)
            out[T.TILE_PACKET_LOSS] = ((RED if m > NET_LOSS_ALERT else YELLOW if m > NET_LOSS_WARN else GREEN), f"{m*100:.1f}% lost, last hour")
        else:
            out[T.TILE_PACKET_LOSS] = (GRAY, "no data")
    tests = _vals([s for s in samples if s["ts"] >= now - 7 * 86400], "speedtest_down_mbps", NET_KEY)
    if tests:
        m = statistics.median(tests)
        out[T.TILE_SPEED_TEST] = ((GREEN if m >= SPEED_OK_MBPS else YELLOW if m >= SPEED_WARN_MBPS else RED), f"median {m:.0f} Mbps down, 7 days")
    else:
        out[T.TILE_SPEED_TEST] = (GRAY, "no speed test yet")
    return out

def tiles(samples, now=None, dish=True):
    """Return {name: (level, text)} for the dashboard tiles, using the last hour / 7 days."""
    now = now or time.time()
    out = {}
    if not samples or now - samples[-1]["ts"] > 20 * 60:
        age = int((now - samples[-1]["ts"]) / 60) if samples else None
        out[T.TILE_COLLECTOR] = (RED if age is None or age > 60 else YELLOW, f"last sample {age} min ago" if age is not None else "no data")
    last = samples[-1] if samples else {}
    hour = [s for s in samples if s["ts"] >= now - 3600]
    sl = last.get(DISH_DATA_KEY, {}) if last else {}
    # Connection
    recent_states = [s.get(DISH_DATA_KEY, {}).get("state") for s in hour[-3:]]
    if not sl.get("reachable"):
        out[T.TILE_DISH_STATUS] = (RED, "dish unreachable")
    elif recent_states and all(st != "CONNECTED" for st in recent_states):
        out[T.TILE_DISH_STATUS] = (RED, f"{sl.get('state')} for 15+ min")
    elif sl.get("state") != "CONNECTED" or any(s.get(DISH_DATA_KEY, {}).get("hist_outage_s", 0) > 60 for s in hour):
        out[T.TILE_DISH_STATUS] = (YELLOW, sl.get("state") or "outage in last hour")
    else:
        out[T.TILE_DISH_STATUS] = (GREEN, f"connected, up {int((sl.get('uptime_s') or 0) / 3600)} h")
    # Dish throughput: instantaneous throughput is just *current usage* (idle = low), so it is never red.
    cur = sl.get("downlink_bps")
    if isinstance(cur, (int, float)):
        out[T.TILE_DISH_THROUGHPUT] = (GREEN, f"current usage {cur/1e6:.1f} Mbps down")
    else:
        out[T.TILE_DISH_THROUGHPUT] = (GRAY, "no data")
    # Latency + drop (last hour)
    lat = _vals(hour, "pop_ping_latency_ms")
    drop = _vals(hour, "pop_ping_drop_rate")
    if lat:
        ml, md = statistics.median(lat), (statistics.mean(drop) if drop else 0)
        lvl = RED if (ml > 100 or md > 0.05) else YELLOW if (ml > 60 or md > 0.02) else GREEN
        out[T.TILE_DISH_LATENCY] = (lvl, f"{ml:.0f} ms, {md*100:.1f}% drop")
    else:
        out[T.TILE_DISH_LATENCY] = (GRAY, "no data")
    # Obstructions
    ob = sl.get("fraction_obstructed")
    if ob is None:
        out[T.TILE_DISH_OBSTRUCTION] = (GRAY, "no data")
    else:
        out[T.TILE_DISH_OBSTRUCTION] = ((RED if ob > 0.02 else YELLOW if ob > 0.005 else GREEN), f"{ob*100:.2f}% obstructed")
    # Dish health
    al = set(sl.get("alerts") or [])
    day = [s for s in samples if s["ts"] >= now - 86400]
    ups = [s.get(DISH_DATA_KEY, {}).get("uptime_s") for s in day]
    reboots = sum(1 for a, b in zip(ups, ups[1:]) if isinstance(a, (int, float)) and isinstance(b, (int, float)) and b < a)
    if al & CRIT_DISH_ALERTS or reboots >= 2:
        out[T.TILE_DISH_ALERTS] = (RED, ", ".join(sorted(al)) or f"{reboots} reboots in 24 h")
    elif al or reboots:
        out[T.TILE_DISH_ALERTS] = (YELLOW, ", ".join(sorted(al)) or f"{reboots} reboot in 24 h")
    elif sl.get("is_snr_above_noise_floor") is False:
        out[T.TILE_DISH_ALERTS] = (YELLOW, "weak signal (below noise floor)")
    else:
        out[T.TILE_DISH_ALERTS] = (GREEN, "no alerts")
    # Firmware
    if "manual_update_required" in al or "unsupported_software" in al:
        out[T.TILE_DISH_FIRMWARE] = (RED, T.FIRMWARE_MANUAL_UPDATE)
    elif sl.get("update_pending"):
        ver = sl.get("software_version") or "?"
        out[T.TILE_DISH_FIRMWARE] = (YELLOW, f"{ver} · update pending, installs ~3 AM")
    else:
        out[T.TILE_DISH_FIRMWARE] = (GREEN if sl.get("software_version") else GRAY, (sl.get("software_version") or "unknown")[:30])
    if not dish:
        # [dish] enabled = false: no dish tiles, so no dish alerts or red.
        for k in DISH_TILE_NAMES:
            out.pop(k, None)
    # Network checks: NetBot's own measurements from this computer (core; the fallback when a router can't be read)
    out.update(network_tiles(samples, now))
    # Router (one tile; vendor-aware summary)
    rt = last.get("router") if last else None
    vendor = (rt.get("vendor") or "").lower() if isinstance(rt, dict) else ""
    vlabel = {"linksys": "Linksys", "kit": "Kit", "unifi": "UniFi"}.get(vendor, "")
    if rt is None:
        out[T.TILE_ROUTER] = (GRAY, "not monitored")
    elif rt.get("skipped") == "off_lan":
        # Linksys (or forced type) not on this LAN — gray, not red.
        out[T.TILE_ROUTER] = (GRAY, "off this Wi-Fi path")
    elif rt.get("skipped") == "not_configured":
        out[T.TILE_ROUTER] = (GRAY, (vlabel + " · " if vlabel else "") + "not monitored (no host set)")
    elif rt.get("skipped") == "not_implemented":
        out[T.TILE_ROUTER] = (GRAY, (vlabel + " · " if vlabel else "") + "not monitored yet")
    elif not rt.get("reachable"):
        if "Keychain" in str(rt.get("error")):
            level, text, check = RED, "Keychain item missing", "keychain"
            out[T.TILE_ROUTER] = (level, text + "\n" + check)
        elif vendor in ("kit", "unifi") or rt.get("skipped") == "unreachable":
            # Experimental Kit router API: unreachable → yellow, not a red storm.
            err = str(rt.get("error") or "unreachable")[:80]
            out[T.TILE_ROUTER] = (YELLOW, (vlabel or "Kit") + " · router unreachable\n" + err)
        else:
            level, text, check = RED, "router unreachable", "router reachable"
            out[T.TILE_ROUTER] = (level, text + "\n" + check)
    else:
        # The version string can carry the make or model, so it is never shown.
        # GetFirmwareUpdateSettings is only the auto-update policy. Nothing read-only
        # in the JNAP client says whether an update is waiting, so a missing flag is
        # not "up to date".
        if rt.get("end_of_support"):
            firmware = "past end of support"
        elif rt.get("update_available") is True:
            firmware = "update available"
        elif rt.get("update_available") is False:
            firmware = "firmware up to date"
        elif vendor in ("kit", "unifi") and rt.get("firmware"):
            firmware = "firmware ok"
        else:
            firmware = "firmware not checked"
        prefix = (vlabel + " · ") if vlabel else ""
        txt = f"{prefix}WAN {rt.get('wan_status','?')}, {rt.get('client_count','?')} clients, {firmware}"
        if rt.get("wan_status") not in (None, "Connected"):
            out[T.TILE_ROUTER] = (RED, txt + "\n" + "WAN status")
        elif rt.get("end_of_support"):
            out[T.TILE_ROUTER] = (YELLOW, txt + "\n" + "past end of support")
        elif rt.get("update_available") is True:
            out[T.TILE_ROUTER] = (YELLOW, txt + "\n" + "firmware")
        elif rt.get("update_available") is False:
            out[T.TILE_ROUTER] = (GREEN, txt)
        elif vendor in ("kit", "unifi") and rt.get("firmware"):
            out[T.TILE_ROUTER] = (GREEN, txt)
        else:
            out[T.TILE_ROUTER] = (GRAY, txt)
    return out

def _quiet(cfg):
    h = datetime.now().hour
    a = cfg["alerts"]
    return h >= a["quiet_start"] or h < a["quiet_end"]

def _notify(title, msg):
    if sys.platform == "darwin":
        subprocess.run(["/usr/bin/osascript", "-e", f'display notification {json.dumps(msg)} with title {json.dumps(title)} sound name "Basso"'],
                       capture_output=True, timeout=10)
    elif sys.platform == "win32":
        from pathlib import Path
        script = Path(__file__).resolve().parent / "win_notify.ps1"
        subprocess.Popen(["powershell", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass",
                          "-File", str(script), "-Title", title, "-Message", msg[:250]],
                         creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))

def run(cfg=None, now=None):
    cfg = cfg or load_config()
    now = now or time.time()
    samples = read_samples(p(cfg["paths"]["data_dir"]), now - 7 * 86400)
    t = tiles(samples, now, dish=dish_enabled(cfg))
    red = {k: v[1] for k, v in t.items() if v[0] == RED}
    adir = local_alerts_dir(cfg)
    state_f = adir / "active.json"
    prev = json.loads(state_f.read_text(encoding="utf-8")).get("red", {}) if state_f.exists() else {}
    new = {k: v for k, v in red.items() if k not in prev}
    # Overnight, only a dish connection outage is urgent; others wait for the morning
    if _quiet(cfg):
        new = {k: v for k, v in new.items() if k in T.QUIET_HOURS_TILES}
        red = {**{k: v for k, v in prev.items() if k in red}, **new}
    write_json_atomic(state_f, {"updated": datetime.now().astimezone().isoformat(timespec="seconds"), "red": red,
                                "tiles": {k: list(v) for k, v in t.items()}})
    if new:
        stamp = datetime.now().strftime("%Y%m%d-%H%M")
        write_json_atomic(adir / f"ALERT-{stamp}.json", {"time": datetime.now().astimezone().isoformat(timespec="seconds"), "new": new, "all_red": red})
        _notify(T.NOTIFY_TITLE, "; ".join(f"{k}: {v}" for k, v in new.items()))
    return t, new

if __name__ == "__main__":
    tiles_, new = run()
    for k, (lvl, txt) in tiles_.items():
        print(f"{lvl:6} {k}: {txt}")
    print("new alerts:", new or "none")
