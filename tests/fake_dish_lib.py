"""Stand-in for the dish library (tests only). Returns plausible fake values.
NETBOT_FAKE_DISH_ALERTS="a,b" turns those dish alerts on."""
import os

ALERT_NAMES = ("motors_stuck", "thermal_shutdown", "thermal_throttle", "install_pending", "is_heating",
               "dish_water_detected", "lower_signal_than_predicted")

class ChannelContext:
    def __init__(self, target=None): self.target = target
    def close(self): pass

def status_data(context=None):
    on = set(filter(None, os.environ.get("NETBOT_FAKE_DISH_ALERTS", "").split(",")))
    alerts = {"alert_" + n: n in on for n in ALERT_NAMES}
    status = {"id": "ut-fake-serial", "state": "CONNECTED", "uptime": 3600, "software_version": "test-fw",
              "hardware_version": "test-hw", "pop_ping_latency_ms": 35.0, "pop_ping_drop_rate": 0.0,
              "downlink_throughput_bps": 2.0e5, "uplink_throughput_bps": 1.0e5, "fraction_obstructed": 0.001,
              "currently_obstructed": False, "obstruction_duration": None, "obstruction_interval": None,
              "seconds_to_first_nonempty_slot": 0.0, "is_snr_above_noise_floor": True, "direction_azimuth": 1.5,
              "direction_elevation": 64.0, "gps_ready": True, "gps_enabled": True, "gps_sats": 11,
              "software_update_state": "IDLE",
              "alerts": sum(1 << i for i, n in enumerate(ALERT_NAMES) if n in on)}
    return status, {"valid_s": 3600.0}, alerts, {"software_update_reboot_ready": False, "software_update_progress": 0.0}

def history_stats(parse_samples, context=None):
    return ({"samples": 900, "total_ping_drop": 0.0}, {"latency_median_ms": 34.0})
