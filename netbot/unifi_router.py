"""Read-only UniFi Network router sample (UniFi).

GET requests only, to a UniFi OS console (UDM / UCG / UDR / UXG / Cloud Key) or
a self-hosted UniFi Network app. Auth is a local API key sent in the X-API-KEY
header. The key comes from an env var ([unifi].api_key_env) or the macOS
Keychain ([unifi].keychain_service, default "netbot-unifi"). It is never put in
config, logs, samples, or error text.

Primary: Integration API  {prefix}/integration/v1/sites, /sites/{id}/devices,
         /sites/{id}/devices/{id}, /sites/{id}/clients
Fallback/WAN: legacy      {prefix}/api/s/<site>/stat/health, stat/device
{prefix} defaults to "/proxy/network" (UniFi OS). Set path_prefix = "" for a
self-hosted Network app (usually port 8443).
"""
from __future__ import annotations

import json
import os
import socket
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Optional

KEYCHAIN_SERVICE = "netbot-unifi"
KEYCHAIN_ACCOUNT = "netbot"
GATEWAY_MODEL_PREFIXES = ("UDM", "UCG", "UDR", "UXG", "USG", "UDW", "UX", "EFG")
GATEWAY_LEGACY_TYPES = ("ugw", "udm", "uxg")


def _empty(**extra) -> dict:
    d = {"vendor": "unifi", "model": None, "reachable": False, "wan_status": None,
         "client_count": None, "firmware": None}
    d.update(extra)
    return d


def ucfg(cfg) -> dict:
    return cfg.get("unifi") or {}


def configured(cfg) -> bool:
    return bool(str(ucfg(cfg).get("host") or "").strip())


def _port(u) -> int:
    return int(u.get("port") or 443)


def _is_unifi_os(host: str, port: int, timeout: float = 3.0) -> bool:
    """Unauthenticated GET / (no key sent): True only if the page says 'UniFi OS'.

    A different device on the same IP (e.g. a Kit router at 192.168.1.1) must never
    receive the API key, so location-aware auto-selection requires this signature.
    """
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        req = urllib.request.Request(f"https://{host}:{port}/", method="GET")
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            body = resp.read(8192).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        try:
            body = e.read(8192).decode("utf-8", "replace")
        except Exception:  # noqa: BLE001
            return False
    except Exception:  # noqa: BLE001
        return False
    return "unifi os" in body.lower()


def host_reachable(cfg, timeout: float = 1.5) -> bool:
    """Console TCP port open AND the host identifies as UniFi OS (location-aware)."""
    u = ucfg(cfg)
    host = str(u.get("host") or "").strip()
    if not host:
        return False
    try:
        with socket.create_connection((host, _port(u)), timeout=timeout):
            pass
    except OSError:
        return False
    return _is_unifi_os(host, _port(u))


def api_key(cfg) -> Optional[str]:
    """Env var first, then Keychain. Never logged."""
    u = ucfg(cfg)
    env = str(u.get("api_key_env") or "").strip()
    if env and os.environ.get(env):
        return os.environ[env]
    if sys.platform == "win32":
        try:
            import win_credential
            return win_credential.read_password(u.get("keychain_service") or KEYCHAIN_SERVICE,
                                                u.get("keychain_account") or KEYCHAIN_ACCOUNT)
        except Exception:  # noqa: BLE001
            return None
    try:
        r = subprocess.run(["/usr/bin/security", "find-generic-password",
                            "-s", str(u.get("keychain_service") or KEYCHAIN_SERVICE),
                            "-a", str(u.get("keychain_account") or KEYCHAIN_ACCOUNT), "-w"],
                           capture_output=True, text=True, timeout=10)
    except Exception:  # noqa: BLE001
        return None
    if r.returncode != 0:
        return None
    return r.stdout.rstrip("\n") or None


class HttpError(Exception):
    def __init__(self, status: int, msg: str = ""):
        super().__init__(f"HTTP {status}{(' ' + msg) if msg else ''}")
        self.status = status


def make_getter(cfg, key: str, timeout: float = 8.0) -> Callable[[str], Any]:
    """Return get(path) -> parsed JSON. GET only."""
    u = ucfg(cfg)
    host = str(u["host"]).strip()
    base = f"https://{host}:{_port(u)}"
    ctx = ssl.create_default_context()
    if not bool(u.get("verify_tls", False)):
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

    def get(path: str):
        req = urllib.request.Request(base + path, method="GET",
                                     headers={"X-API-KEY": key, "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
                return json.loads(resp.read().decode("utf-8") or "null")
        except urllib.error.HTTPError as e:
            raise HttpError(e.code) from None
    return get


def _data(obj):
    if isinstance(obj, dict):
        return obj.get("data") if isinstance(obj.get("data"), list) else []
    return obj if isinstance(obj, list) else []


def _is_gateway_integration(d: dict) -> bool:
    feats = [str(f).lower() for f in (d.get("features") or [])]
    if "gateway" in feats or "routing" in feats:
        return True
    return str(d.get("model") or "").upper().startswith(GATEWAY_MODEL_PREFIXES)


def _pick_site(sites: list, want: str) -> Optional[dict]:
    want = (want or "default").strip()
    for s in sites:
        if want in (s.get("internalReference"), s.get("name"), s.get("id")):
            return s
    return sites[0] if len(sites) == 1 else None


def _legacy(get, prefix: str, site: str, out: dict) -> None:
    """Fill WAN (and gaps) from legacy stat/health + stat/device."""
    s = urllib.parse.quote(site, safe="")
    health = _data(get(f"{prefix}/api/s/{s}/stat/health"))
    for sub in health:
        if sub.get("subsystem") == "wan":
            st = str(sub.get("status") or "").lower()
            out["wan_status"] = "Connected" if st == "ok" else ("Disconnected" if st else None)
            out["wan_source"] = "health"
    if out.get("client_count") is None:
        n = sum(int(sub.get("num_user") or 0) + int(sub.get("num_guest") or 0)
                for sub in health if sub.get("subsystem") in ("wlan", "lan"))
        if health:
            out["client_count"] = n
    if out.get("model") is None or out.get("firmware") is None:
        for d in _data(get(f"{prefix}/api/s/{s}/stat/device")):
            if str(d.get("type") or "").lower() in GATEWAY_LEGACY_TYPES:
                out["model"] = out.get("model") or d.get("model")
                out["firmware"] = out.get("firmware") or d.get("version")
                if out.get("update_available") is None and "upgradable" in d:
                    out["update_available"] = bool(d.get("upgradable"))
                break


def summarize(get, cfg) -> dict:
    u = ucfg(cfg)
    prefix = str(u.get("path_prefix", "/proxy/network")).rstrip("/")
    site_name = str(u.get("site") or "default")
    out = _empty(reachable=True, api=None)
    errors = []
    # Integration API
    try:
        sites = _data(get(f"{prefix}/integration/v1/sites"))
        site = _pick_site(sites, site_name)
        if site is None:
            raise HttpError(404, f"site {site_name!r} not found")
        sid = site["id"]
        out["api"] = "integration"
        devs = _data(get(f"{prefix}/integration/v1/sites/{sid}/devices?limit=200"))
        gw = next((d for d in devs if _is_gateway_integration(d)), None)
        if gw:
            out["model"] = gw.get("model")
            state = str(gw.get("state") or "").upper()
            try:
                det = get(f"{prefix}/integration/v1/sites/{sid}/devices/{gw['id']}") or {}
            except HttpError:
                det = {}
            out["firmware"] = det.get("firmwareVersion") or gw.get("firmwareVersion")
            if "firmwareUpdatable" in det:
                out["update_available"] = bool(det.get("firmwareUpdatable"))
            out["_gw_state"] = state
        cl = get(f"{prefix}/integration/v1/sites/{sid}/clients?limit=1")
        if isinstance(cl, dict) and cl.get("totalCount") is not None:
            out["client_count"] = int(cl["totalCount"])
    except HttpError as e:
        if e.status in (401, 403):
            return _empty(reachable=False, skipped="unreachable",
                          error=f"UniFi API key rejected (HTTP {e.status})")
        errors.append(f"integration: {e}")
    except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
        errors.append(f"integration: {type(e).__name__}")
    # Legacy for WAN + any gaps
    try:
        _legacy(get, prefix, site_name, out)
        out["api"] = out["api"] or "legacy"
    except HttpError as e:
        errors.append(f"legacy: {e}")
    except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
        errors.append(f"legacy: {type(e).__name__}")
    gw_state = out.pop("_gw_state", None)
    if out.get("wan_status") is None and gw_state:
        out["wan_status"] = "Connected" if gw_state == "ONLINE" else "Disconnected"
        out["wan_source"] = "gateway_state"
    if out["api"] is None:
        return _empty(reachable=False, skipped="unreachable",
                      error=("UniFi API: " + "; ".join(errors))[:160])
    if errors:
        out["partial"] = "; ".join(errors)[:160]
    return out


def sample(cfg, getter_factory=make_getter, reach=host_reachable) -> dict:
    if not configured(cfg):
        return _empty(skipped="not_configured")
    if not reach(cfg):
        return _empty(skipped="off_lan")
    key = api_key(cfg)
    if not key:
        return _empty(error="Keychain item 'netbot-unifi' (or api_key_env) not found")
    try:
        return summarize(getter_factory(cfg, key), cfg)
    finally:
        del key
