#!/usr/bin/env python3
"""Generate 7 days of FAKE samples for offline testing. Output is labeled example data."""
import math, random, sys, time
from pathlib import Path
from netbot_common import append_jsonl, month_file
from dish_constants import DISH_DATA_KEY

def main(data_dir, now=None):
    random.seed(7)
    now = now or time.time()
    t, uptime = now - 7 * 86400, 200000
    while t <= now:
        h = time.localtime(t).tm_hour
        busy = 19 <= h <= 23
        out = random.random() < 0.004
        uptime = 0 if (abs(t - (now - 3.2 * 86400)) < 150) else uptime + 300
        s = {"ts": t, "example": True, DISH_DATA_KEY: {
            "reachable": True, "state": "SEARCHING" if out else "CONNECTED", "uptime_s": uptime,
            "software_version": "2026.10.02.mr60001", "hardware_version": "rev4_prod2",
            "pop_ping_latency_ms": max(18, random.gauss(48 if busy else 34, 6) + (25 if out else 0)),
            "pop_ping_drop_rate": min(1, abs(random.gauss(0.004, 0.004)) + (0.3 if out else 0)),
            "downlink_bps": max(5e6, random.gauss(140e6 if busy else 210e6, 35e6)),
            "uplink_bps": max(1e6, random.gauss(18e6, 4e6)),
            "fraction_obstructed": 0.003 + 0.0004 * math.sin(t / 86400),
            "currently_obstructed": False, "alerts": [], "update_pending": t > now - 6 * 3600,
            "hist_outage_s": 45 if out else 0},
            "network": {"reachable": True, "gateway_found": True, "gateway_ping_ms": max(0.8, random.gauss(1.6, 0.3)),
                        "gateway_loss": 0.0, "internet_latency_ms": max(20, random.gauss(46 if busy else 38, 5) + (25 if out else 0)),
                        "internet_jitter_ms": abs(random.gauss(3, 1)), "internet_loss": 0.3 if out else (0.005 if random.random() < 0.2 else 0.0),
                        **({"speedtest_status": "ok", "speedtest_down_mbps": round(random.gauss(182, 20), 1),
                            "speedtest_up_mbps": round(random.gauss(19.4, 2), 1)} if int(t) % 21600 < 300 else {"speedtest_status": "not due"})},
            "router": {"reachable": True, "model": "EA9500", "hw_version": "1.1", "firmware": "1.1.9.210876",
                       "wan_status": "Connected", "wan_type": "DHCP", "client_count": random.randint(14, 19),
                       "weakest_signal_dbm": random.randint(-78, -66)}}
        append_jsonl(month_file(Path(data_dir), t), s)
        t += 300

if __name__ == "__main__":
    main(sys.argv[1])
