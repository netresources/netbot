#!/usr/bin/env python3
"""NetBot collector. Run by launchd (io.netbot.collect) every 5 minutes. Read-only.

Writes:
  <data_dir>/YYYY-MM.jsonl   one sample per run (local, full history)
  <sync_dir>/latest.json     latest sample (OneDrive)
  <sync_dir>/heartbeat       ISO timestamp of last run
Then runs the alert evaluator, rebuilds the dashboard, and writes the live-page JSON.
"""
import importlib, sys, time, traceback
from datetime import datetime
from netbot_common import load_config, p, month_file, append_jsonl, write_json_atomic
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

def router_sample(cfg):
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

def main():
    cfg = load_config()
    ts = time.time()
    sample = {"ts": ts, "iso": datetime.now().astimezone().isoformat(timespec="seconds"), "host": "windows" if sys.platform == "win32" else "mac"}
    # The dish monitor and the network checks are NetBot's core and always run; the router add-on only when enabled.
    data_dir = p(cfg["paths"]["data_dir"])
    for key, fn, enabled in ((DISH_DATA_KEY, dish_sample, True),
                             ("network", lambda c: network_sample(c, data_dir), True),
                             ("router", router_sample, cfg["router"].get("enabled"))):
        if not enabled:
            continue
        try:
            sample[key] = fn(cfg)
        except Exception as e:  # noqa: BLE001
            sample[key] = {"reachable": False, "error": f"{type(e).__name__}: {e}"[:300]}
    append_jsonl(month_file(data_dir, ts), sample)
    sync = p(cfg["paths"].get("sync_dir"))
    if sync:
        # Never sync client MAC lists off the Mac in full; keep counts only.
        slim = dict(sample)
        if "router" in slim and isinstance(slim["router"], dict):
            slim["router"] = {k: v for k, v in slim["router"].items() if k != "clients"}
        write_json_atomic(sync / "latest.json", slim)
        (sync / "heartbeat").write_text(sample["iso"] + "\n", encoding="utf-8")
    import evaluate_alerts
    evaluate_alerts.run(cfg)
    import make_dashboard
    make_dashboard.run(cfg)
    import live_data
    live_data.write(cfg)

if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.exit(1)
