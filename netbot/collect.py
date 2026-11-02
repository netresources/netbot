#!/usr/bin/env python3
"""NetBot collector. Run by launchd (io.netbot.collect) every 5 minutes. Read-only.

Writes:
  <data_dir>/YYYY-MM.jsonl   one sample per run (local, full history)
  local alerts + dashboard + live JSON every run
  OneDrive (latest.json, heartbeat, slim YYYY-MM.jsonl, alerts/, dashboard.png)
    only when [paths] onedrive_sync_interval_min has elapsed (default 0 = every run),
    the calendar month rolled over, or a new ALERT is raised and
    onedrive_sync_on_alert is true (default).
"""
import importlib, sys, time, traceback
from datetime import datetime
from netbot_common import (dish_enabled, load_config, p, month_file, append_jsonl,
                           onedrive_sync_on_alert, push_onedrive)
from network_checks import network_sample
from dish_constants import DISH_CFG_SECTION, DISH_DATA_KEY, DISH_GRPC_SERVICE, DISH_LIB_MODULE, DISH_PATHS_KEY

# Status fields recorded as-is from the dish (everything it reports except its serial "id").
DISH_STATUS_FIELDS = ("state", "uptime", "software_version", "hardware_version", "pop_ping_latency_ms",
                      "pop_ping_drop_rate", "downlink_throughput_bps", "uplink_throughput_bps", "fraction_obstructed",
                      "currently_obstructed", "seconds_obstructed", "obstruction_duration", "obstruction_interval",
                      "seconds_to_first_nonempty_slot", "snr", "is_snr_above_noise_floor", "direction_azimuth",
                      "direction_elevation", "gps_ready", "gps_enabled", "gps_sats", "software_update_state")
RENAMED = {"uptime": "uptime_s", "downlink_throughput_bps": "downlink_bps", "uplink_throughput_bps": "uplink_bps"}

def load_dish_lib(cfg):
    """Import the dish library that install.sh downloaded and verified (never bundled with NetBot)."""
    sys.path.insert(0, str(p(cfg["paths"][DISH_PATHS_KEY])))
    return importlib.import_module(DISH_LIB_MODULE)

def dish_sample(cfg):
    """Read-only health sample from the dish: every status field, alert, and update state it exposes."""
    lib = load_dish_lib(cfg)
    ctx = lib.ChannelContext(target=cfg[DISH_CFG_SECTION]["target"])
    try:
        try:
            res = lib.status_data(context=ctx)
        except Exception as e:  # noqa: BLE001
            raise RuntimeError(f"no answer from the dish's {DISH_GRPC_SERVICE.rsplit('.', 1)[-1]} service: {e}") from e
        status, obstruct, alerts = res[0], res[1], res[2] or {}
        swu = (res[3] if len(res) > 3 else {}) or {}
        # 15-minute history window: ping drop, latency, outages
        groups = lib.history_stats(parse_samples=900, context=ctx)
        hist = {}
        for g in groups:
            if isinstance(g, dict):
                hist.update(g)
        out = {"reachable": True}
        for k in DISH_STATUS_FIELDS:
            if k in status:
                out[RENAMED.get(k, k)] = status.get(k)
        out.update({
            # every alert the dish reports: active ones, plus the full list so new firmware alerts are visible
            "alerts": sorted(k.replace("alert_", "") for k, v in alerts.items() if v),
            "alerts_known": sorted(k.replace("alert_", "") for k in alerts),
            "alert_bits": status.get("alerts") if isinstance(status.get("alerts"), int) else None,
            "software_update_progress": swu.get("software_update_progress"),
            "software_update_reboot_ready": swu.get("software_update_reboot_ready"),
            "seconds_until_software_update_reboot_possible": swu.get("seconds_until_software_update_reboot_possible"),
            "update_pending": bool(alerts.get("alert_install_pending")) or status.get("software_update_state") in ("REBOOT_REQUIRED",) or bool(swu.get("software_update_reboot_ready")),
            "obstruction_valid_s": (obstruct or {}).get("valid_s"),
            "hist_ping_drop_rate": hist.get("total_ping_drop", 0) / max(hist.get("samples", 1) or 1, 1),
            "hist_outage_s": hist.get("count_full_ping_drop") or 0,
            "hist_latency_median_ms": hist.get("latency_median_ms") or hist.get("mean_all_ping_latency"),
            "hist_samples": hist.get("samples"),
        })
        return out
    finally:
        ctx.close()


def _ipv4_ints(addr):
    try:
        parts = [int(x) for x in str(addr).split(".")]
        if len(parts) != 4 or any(p < 0 or p > 255 for p in parts):
            return None
        return parts
    except (TypeError, ValueError):
        return None


def _same_ipv4_subnet(a, b, prefix=24):
    """True when both look like IPv4 and share the first `prefix` bits (default /24)."""
    aa, bb = _ipv4_ints(a), _ipv4_ints(b)
    if not aa or not bb:
        return False
    mask = (0xFFFFFFFF << (32 - int(prefix))) & 0xFFFFFFFF
    ai = (aa[0] << 24) | (aa[1] << 16) | (aa[2] << 8) | aa[3]
    bi = (bb[0] << 24) | (bb[1] << 16) | (bb[2] << 8) | bb[3]
    return (ai & mask) == (bi & mask)


def router_host_on_lan(cfg, timeout=1.5):
    """Reachability check for the configured router add-on host (no SSID).

    On-LAN if the OS default gateway is that host, shares its /24, or TCP:80 answers
    (Linksys JNAP is http://host/JNAP/). Used only to skip polling off-path — never
    rewrites config.toml.
    """
    import socket
    from network_checks import default_gateway
    host = str((cfg.get("router") or {}).get("host") or "").strip()
    if not host:
        return False
    gw = default_gateway()
    if gw and (gw == host or _same_ipv4_subnet(gw, host)):
        return True
    try:
        with socket.create_connection((host, 80), timeout=timeout):
            return True
    except OSError:
        return False


def linksys_router_sample(cfg):
    """Linksys JNAP vendor adapter (EA9500 and other Smart Wi-Fi)."""
    from linksys_jnap import JNAP, keychain_password, summarize
    r = cfg["router"]
    pw = None
    if r.get("use_password", True):
        try:
            pw = keychain_password(r["keychain_service"], r["username"])
        except RuntimeError:
            pw = None  # many reads (e.g. GetDeviceInfo) work without auth
    try:
        return summarize(JNAP(r["host"], r["username"], pw))
    finally:
        del pw


def resolve_router_vendor(cfg, lan_mode):
    """auto (default) follows lan_mode; explicit type=linksys|kit|unifi overrides."""
    t = str((cfg.get("router") or {}).get("type") or "auto").strip().lower()
    if t in ("linksys", "kit", "unifi"):
        return t
    # M2: auto picks UniFi only when [unifi].host is set AND reachable; otherwise unchanged.
    try:
        import unifi_router
        if unifi_router.configured(cfg) and unifi_router.host_reachable(cfg):
            return "unifi"
    except Exception:  # noqa: BLE001
        pass
    return "linksys" if lan_mode == "linksys" else "kit"


def router_sample(cfg, lan_mode="linksys"):
    """Dispatch to a vendor adapter; always returns the common router sample shape."""
    vendor = resolve_router_vendor(cfg, lan_mode)
    if vendor == "linksys":
        if not router_host_on_lan(cfg):
            return {"vendor": "linksys", "reachable": False, "skipped": "off_lan",
                    "model": None, "wan_status": None, "client_count": None, "firmware": None}
        return linksys_router_sample(cfg)
    if vendor == "kit":
        from kit_router import sample as kit_sample
        return kit_sample(cfg)
    if vendor == "unifi":
        from unifi_router import sample as unifi_sample
        return unifi_sample(cfg)
    return {"vendor": vendor, "reachable": False, "skipped": "unknown_vendor",
            "error": f"unknown router type {vendor!r}",
            "model": None, "wan_status": None, "client_count": None, "firmware": None}


def main():
    cfg = load_config()
    ts = time.time()
    sample = {"ts": ts, "iso": datetime.now().astimezone().isoformat(timespec="seconds"), "host": "windows" if sys.platform == "win32" else "mac"}
    # Dish + network checks always run. Router add-on when enabled: vendor from
    # [router].type (auto|linksys|kit|unifi) — auto follows lan_mode (Linksys host on-LAN).
    data_dir = p(cfg["paths"]["data_dir"])
    router_cfg_on = bool((cfg.get("router") or {}).get("enabled"))
    on_linksys_lan = router_host_on_lan(cfg) if router_cfg_on else False
    sample["lan_mode"] = "linksys" if on_linksys_lan else "kit"
    for key, fn, enabled in ((DISH_DATA_KEY, dish_sample, dish_enabled(cfg)),
                             ("network", lambda c: network_sample(c, data_dir), True),
                             ("router", lambda c: router_sample(c, sample["lan_mode"]), router_cfg_on)):
        if not enabled:
            continue
        try:
            sample[key] = fn(cfg)
        except Exception as e:  # noqa: BLE001
            sample[key] = {"reachable": False, "vendor": None, "error": f"{type(e).__name__}: {e}"[:300]}
    append_jsonl(month_file(data_dir, ts), sample)
    import evaluate_alerts
    _tiles, new_alerts = evaluate_alerts.run(cfg)  # local alerts dir
    import make_dashboard
    make_dashboard.run(cfg)  # local HTML + local PNG
    import live_data
    live_data.write(cfg)
    # OneDrive: gated. History catch-up + latest/heartbeat/alerts/png when due.
    force = bool(new_alerts) and onedrive_sync_on_alert(cfg)
    try:
        push_onedrive(cfg, sample, ts, force=force)
    except Exception as e:  # noqa: BLE001
        print(f"onedrive sync failed: {type(e).__name__}: {e}", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.exit(1)
