"""Read-only Linksys JNAP client (EA9500 and other Smart Wi-Fi routers).

Only Get* actions are allowed; anything else raises. The admin password is
fetched from the macOS Keychain with the `security` CLI (on Windows: Credential Manager) and kept in memory only.
"""
import base64, json, subprocess, sys, urllib.request, urllib.error
from datetime import date

ACTIONS = {
    "GetDeviceInfo": "http://linksys.com/jnap/core/GetDeviceInfo",  # model, firmware, list of supported services
    "GetWANStatus": "http://linksys.com/jnap/router/GetWANStatus",
    "GetDevices": "http://linksys.com/jnap/devicelist/GetDevices",
    "GetNetworkConnections": "http://linksys.com/jnap/networkconnections/GetNetworkConnections",
    "GetFirmwareUpdateSettings": "http://linksys.com/jnap/firmwareupdate/GetFirmwareUpdateSettings",
}

def keychain_password(service, account):
    """Return the password stored with:
       security add-generic-password -s <service> -a <account> -w
    On Windows the same service name is the Credential Manager target (see win_credential.py).
    Never logged, never written to disk."""
    if sys.platform == "win32":
        import win_credential
        return win_credential.read_password(service, account)
    r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", service, "-a", account, "-w"],
                       capture_output=True, text=True, timeout=10)
    if r.returncode != 0:
        raise RuntimeError(f"Keychain item '{service}' not found or access denied")
    return r.stdout.rstrip("\n")

class JNAP:
    def __init__(self, host, username="admin", password=None, timeout=8):
        self.url = f"http://{host}/JNAP/"
        self.timeout = timeout
        self.auth = None
        if password is not None:
            self.auth = "Basic " + base64.b64encode(f"{username}:{password}".encode()).decode()

    def call(self, name, body=None):
        if not name.startswith("Get") or name not in ACTIONS:
            raise PermissionError(f"NetBot is read-only; refusing JNAP action {name}")
        try:
            return self._post(ACTIONS[name], body)
        except RuntimeError as e:
            # Older firmware registers some actions under the cisco.com namespace
            if "ErrorUnknownAction" in str(e):
                return self._post(ACTIONS[name].replace("linksys.com", "cisco.com"), body)
            raise

    def _post(self, action, body):
        name = action.rsplit("/", 1)[-1]
        req = urllib.request.Request(self.url, data=json.dumps(body or {}).encode(), method="POST",
                                     headers={"Content-Type": "application/json", "X-JNAP-Action": action})
        if self.auth:
            req.add_header("X-JNAP-Authorization", self.auth)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                code, raw = r.status, r.read()
        except urllib.error.HTTPError as e:
            code, raw = e.code, e.read()
        try:
            resp = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            snippet = raw[:160].decode("utf-8", "replace").replace("\n", " ")
            raise RuntimeError(f"{name}: HTTP {code}, non-JSON reply: {snippet!r}")
        if resp.get("result") != "OK":
            raise RuntimeError(f"{name}: {resp.get('result')}")
        return resp.get("output", {})

# Source: Linksys Product End of Life, https://www.linksys.com/pages/linksys-product-end-of-life (table data in productTable.js on that page), retrieved 2026-10-20. Dates are the latest End of Support date among the model's USA/Canada SKUs. Linksys Lifecycle Policy: after EOS no firmware or security updates.
END_OF_SUPPORT = {
    "EA2700": date(2023, 12, 4),
    "EA2750": date(2024, 8, 24),
    "EA3500": date(2023, 12, 4),
    "EA4500": date(2023, 12, 4),
    "EA5800": date(2025, 4, 14),
    "EA6100": date(2026, 7, 27),
    "EA6200": date(2023, 12, 4),
    "EA6300": date(2023, 12, 4),
    "EA6350": date(2025, 8, 9),
    "EA6400": date(2025, 4, 14),
    "EA6460": date(2022, 7, 27),
    "EA6500": date(2024, 8, 24),
    "EA6700": date(2025, 4, 14),
    "EA6900": date(2025, 4, 14),
    "EA7200": date(2025, 5, 15),
    "EA7250": date(2025, 5, 15),
    "EA7300": date(2025, 5, 15),
    "EA7400": date(2024, 8, 24),
    "EA7430": date(2025, 5, 15),
    "EA7450": date(2025, 5, 15),
    "EA7500": date(2026, 3, 11),
    "EA7500V3": date(2026, 6, 11),
    "EA8100": date(2026, 6, 11),
    "EA8250": date(2026, 3, 11),
    "EA8300": date(2026, 3, 11),
    "EA8500": date(2024, 8, 24),
    "EA9200": date(2023, 12, 4),
    "EA9300": date(2026, 3, 11),
    "EA9350": date(2026, 6, 11),
    "EA9400": date(2023, 12, 4),
    "EA9500": date(2026, 3, 11),
    "EA9600": date(2025, 4, 14),
    "EA9700": date(2025, 4, 14),
    "MR7320": date(2026, 7, 26),
    "MR8250": date(2026, 7, 26),
    "MR9550": date(2026, 7, 26),
    "MX4300": date(2026, 5, 19),
    "WRT1200AC": date(2023, 12, 4),
    "WRT1900AC": date(2026, 3, 11),
    "WRT3200ACM": date(2026, 3, 11),
    "WRT32X": date(2025, 8, 9),
    "WRT32XB": date(2025, 8, 9),
}

def _end_of_support(model, today=None):
    """True when this known model is past its End of Support date, False when it is known but still supported or unlisted, None when the model number is missing."""
    if not isinstance(model, str):
        return None
    text = model.strip().upper()
    if not text:
        return None
    base = text
    # One trailing regional suffix (-UK, -CA, -AH), and only when the base is listed.
    if base not in END_OF_SUPPORT and len(text) > 3 and text[-3] == "-" and text[-2:].isalpha():
        trimmed = text[:-3]
        if trimmed in END_OF_SUPPORT:
            base = trimmed
    if base not in END_OF_SUPPORT:
        return False
    day = today if today is not None else date.today()
    return day >= END_OF_SUPPORT[base]

def summarize(j, today=None):
    """Collect a compact router snapshot. Each call is independent so one failure doesn't lose the rest.

    today is a datetime.date for the end-of-support check. Tests pass it in; the default is the current date.
    """
    out, errors = {"vendor": "linksys"}, {}
    def safe(name):
        try:
            return j.call(name)
        except Exception as e:  # noqa: BLE001
            errors[name] = str(e)[:200]
            return None
    info = safe("GetDeviceInfo")
    if info:
        out["model"] = info.get("modelNumber")
        out["hw_version"] = info.get("hardwareVersion")
        out["firmware"] = info.get("firmwareVersion")
        out["firmware_date"] = info.get("firmwareDate")
        eos = _end_of_support(info.get("modelNumber"), today)
        if eos is not None:
            out["end_of_support"] = eos
        svcs = info.get("services", [])
        # Record whether any traffic/usage service exists on this unit (answers the byte-counter question on real hardware)
        out["usage_services"] = [s for s in svcs if any(k in s.lower() for k in ("traffic", "usage", "meter", "bandwidth"))]
    wan = safe("GetWANStatus")
    if wan:
        out["wan_status"] = wan.get("wanStatus")
        out["wan_type"] = (wan.get("wanConnection") or {}).get("wanType") or wan.get("detectedWANType")
        out["wan_ip"] = (wan.get("wanConnection") or {}).get("ipAddress")
    conns = safe("GetNetworkConnections")
    devs = safe("GetDevices")
    names = {}
    if devs:
        for d in devs.get("devices", []):
            nm = d.get("friendlyName") or d.get("hostName")
            for k in d.get("knownMACAddresses", []):
                names[k.upper()] = nm or k
    if conns:
        clients = []
        for c in conns.get("connections", []):
            w = c.get("wireless") or {}
            clients.append({"mac": c.get("macAddress"), "name": names.get((c.get("macAddress") or "").upper()),
                            "mbps": c.get("negotiatedMbps"), "band": w.get("band"), "signal_dbm": w.get("signalDecibels")})
        out["clients"] = clients
        out["client_count"] = len(clients)
        sig = [c["signal_dbm"] for c in clients if isinstance(c["signal_dbm"], (int, float))]
        out["weakest_signal_dbm"] = min(sig) if sig else None
    fw = safe("GetFirmwareUpdateSettings")
    if fw:
        out["auto_update_policy"] = fw.get("updatePolicy")
    if errors:
        out["errors"] = errors
    out["reachable"] = bool(info or wan or conns)
    return out
