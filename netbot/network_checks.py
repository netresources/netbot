#!/usr/bin/env python3
"""Network checks: NetBot's own measurements from this computer. Part of the always-on core, and the
fallback when a router can't be read. Read-only, uses only tools that ship with the OS.

  gateway ping      ping the default gateway (this computer -> home router/gateway)
  internet latency  ping the configured internet targets; median round trip and jitter
  packet loss       share of those pings that got no reply
  speed test        macOS `networkQuality` (built in since macOS 12); on Windows a download-timing test in
                    PowerShell (win_speedtest.ps1, nothing installed). At most once per speedtest_every_h.

Writes the "network" part of each sample. Config: the [network] section (all optional, see DEFAULTS in
netbot_common.py). Tool paths can be overridden for tests with NETBOT_PING / NETBOT_NETWORKQUALITY /
NETBOT_POWERSHELL. On Windows, ping output is read by its "TTL=" reply lines, which every Windows language uses.
"""
import json, os, re, shutil, statistics, subprocess, sys, time
from pathlib import Path

RTT = re.compile(r"time[=<]\s*([0-9.]+)\s*ms")
SENT_RECV = re.compile(r"(\d+)\s+packets transmitted,\s+(\d+)\s+(?:packets\s+)?received")
WIN_RTT = re.compile(r"[=<]\s*(\d+(?:[.,]\d+)?)\s*ms\b", re.I)          # "time=12ms" / "time<1ms" (any language)
WIN_GATEWAY = re.compile(r"^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\d+\.\d+\.\d+\.\d+)\s", re.M)   # `route print -4` default row

def is_windows():
    return sys.platform == "win32"

def parse_windows_ping(out, count):
    """Windows ping: one line with "TTL=" per reply; the round trip is the "=12ms" / "<1ms" on that line."""
    rtts = []
    for line in out.splitlines():
        if "TTL=" in line.upper():
            m = WIN_RTT.search(line)
            rtts.append(float(m.group(1).replace(",", ".")) if m else 0.5)
    recv = len(rtts)
    return {"sent": count, "received": recv, "loss": (1 - recv / count) if count else 1.0, "rtts": rtts}

def _run(cmd, timeout):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout
    except (OSError, subprocess.TimeoutExpired):
        return None, ""

def _tool(env, name):
    exe = os.environ.get(env) or shutil.which(name)
    return exe if exe and os.access(exe, os.X_OK) else None

def ping(host, count):
    """-> {"sent", "received", "loss", "rtts"} or None if ping could not run."""
    exe = _tool("NETBOT_PING", "ping")
    if not exe:
        return None
    if is_windows():   # -n count, -w 1000 ms reply timeout (Windows ping has no interval option; about 1 s apart)
        rc, out = _run([exe, "-n", str(count), "-w", "1000", host], timeout=count * 2.5 + 5)
        return None if rc is None else parse_windows_ping(out, count)
    # -c count, -i 0.2 s between pings (allowed without admin rights on macOS and Linux), -n numeric
    rc, out = _run([exe, "-n", "-c", str(count), "-i", "0.2", host], timeout=count * 1.5 + 5)
    if rc is None:
        return None
    rtts = [float(x) for x in RTT.findall(out)]
    m = SENT_RECV.search(out)
    sent, recv = (int(m.group(1)), int(m.group(2))) if m else (count, len(rtts))
    return {"sent": sent, "received": recv, "loss": (1 - recv / sent) if sent else 1.0, "rtts": rtts}

def default_gateway():
    """Default IPv4 gateway of this computer, or None."""
    if is_windows():
        rc, out = _run([_tool("NETBOT_ROUTE", "route") or "route", "print", "-4"], 10)
        m = WIN_GATEWAY.search(out)
    elif sys.platform == "darwin":
        rc, out = _run(["route", "-n", "get", "default"], 5)
        m = re.search(r"gateway:\s*(\S+)", out)
    else:
        rc, out = _run(["ip", "-4", "route", "show", "default"], 5)
        m = re.search(r"default via (\S+)", out)
    return m.group(1) if m else None

def _jitter(rtts):
    return statistics.mean(abs(a - b) for a, b in zip(rtts, rtts[1:])) if len(rtts) > 1 else None

def windows_speed_test(url, timeout=120):
    """Download-timing test in PowerShell (netbot/win_speedtest.ps1). Download only; no upload figure.
    -> (down_mbps, up_mbps or None) or None."""
    exe = _tool("NETBOT_POWERSHELL", "powershell") or _tool("NETBOT_POWERSHELL", "pwsh")
    script = Path(__file__).resolve().parent / "win_speedtest.ps1"
    if not exe or not script.is_file():
        return None
    rc, out = _run([exe, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(script), "-Url", url], timeout)
    try:
        r = json.loads(out.strip().splitlines()[-1])
        return float(r["down_mbps"]), None
    except (ValueError, KeyError, TypeError, IndexError):
        return None

def speed_test(state_file, every_h, mode, url=""):
    """Run networkQuality (macOS) or the Windows download test at most once per every_h hours. -> speedtest_* fields."""
    if mode == "off":
        return {"speedtest_status": "off"}
    try:
        last = float(Path(state_file).read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        last = 0.0
    if time.time() - last < float(every_h) * 3600:
        return {"speedtest_status": "not due"}
    exe = _tool("NETBOT_NETWORKQUALITY", "networkQuality")
    if not exe and not (is_windows() and url):
        return {"speedtest_status": "unavailable"}
    Path(state_file).parent.mkdir(parents=True, exist_ok=True)
    Path(state_file).write_text(f"{time.time():.0f}\n", encoding="utf-8")    # recorded first, so a failing test is not retried every 5 min
    if not exe:
        r = windows_speed_test(url)
        if r is None:
            return {"speedtest_status": "failed"}
        return {"speedtest_status": "ok", "speedtest_method": "download", "speedtest_down_mbps": round(r[0], 1),
                "speedtest_ts": time.time()}
    rc, out = _run([exe, "-c", "-s"], timeout=120)        # -c JSON output, -s down and up one after the other
    try:
        r = json.loads(out)
        down, up = float(r["dl_throughput"]) / 1e6, float(r["ul_throughput"]) / 1e6
    except (ValueError, KeyError, TypeError):
        return {"speedtest_status": "failed"}
    return {"speedtest_status": "ok", "speedtest_down_mbps": round(down, 1), "speedtest_up_mbps": round(up, 1),
            "speedtest_ts": time.time()}

def network_sample(cfg, data_dir):
    n = cfg.get("network", {})
    count = int(n.get("ping_count", 10))
    out = {"reachable": True}
    gw = n.get("gateway") or default_gateway()
    out["gateway_found"] = bool(gw)              # the address itself is not recorded
    if gw:
        g = ping(gw, count)
        if g is not None:
            out["gateway_loss"] = round(g["loss"], 4)
            out["gateway_ping_ms"] = round(statistics.median(g["rtts"]), 2) if g["rtts"] else None
    rtts, sent, recv = [], 0, 0
    for target in str(n.get("internet_targets", "")).split():
        r = ping(target, count)
        if r is None:
            continue
        rtts += r["rtts"]; sent += r["sent"]; recv += r["received"]
    if sent:
        out["internet_loss"] = round(1 - recv / sent, 4)
        out["internet_latency_ms"] = round(statistics.median(rtts), 2) if rtts else None
        out["internet_jitter_ms"] = round(_jitter(rtts), 2) if _jitter(rtts) is not None else None
    elif not _tool("NETBOT_PING", "ping"):
        out = {"reachable": False, "error": "ping is not available on this computer"}
    out.update(speed_test(Path(data_dir) / ".speedtest_last", n.get("speedtest_every_h", 6), str(n.get("speedtest", "auto")),
                          str(n.get("speedtest_url", ""))))
    return out

if __name__ == "__main__":
    from netbot_common import load_config, p
    c = load_config()
    print(json.dumps(network_sample(c, p(c["paths"]["data_dir"])), indent=2))
