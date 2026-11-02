"""Read-only kit Wi-Fi *router* sample (not the dish).

Polls the router gRPC service (default host:9000). The dish stays on
192.168.100.1:9200 via dish_sample — never confuse the two.

Uses the same grpcio + yagrc reflection stack as the dish library (already in
the NetBot venv). Only get_diagnostics / get_status (read-only). No account
login, no Wi-Fi/bypass/GPS writes.
"""
from __future__ import annotations

import socket
import dish_constants
from typing import Any, Optional

# Official local API: router :9000, dish :9200
# Router Device API over local gRPC reflection (same service family as the dish; different port).
DEFAULT_HOST = "192.168.1.1"
DEFAULT_PORT = 9000
DISH_SUBNET_PREFIX = "192.168.100."


def _ipv4_ints(addr):
    try:
        parts = [int(x) for x in str(addr).split(".")]
        if len(parts) != 4 or any(p < 0 or p > 255 for p in parts):
            return None
        return parts
    except (TypeError, ValueError):
        return None


def _same_ipv4_subnet(a, b, prefix=24):
    aa, bb = _ipv4_ints(a), _ipv4_ints(b)
    if not aa or not bb:
        return False
    mask = (0xFFFFFFFF << (32 - int(prefix))) & 0xFFFFFFFF
    ai = (aa[0] << 24) | (aa[1] << 16) | (aa[2] << 8) | aa[3]
    bi = (bb[0] << 24) | (bb[1] << 16) | (bb[2] << 8) | bb[3]
    return (ai & mask) == (bi & mask)


def _tcp_open(host: str, port: int, timeout: float = 2.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def resolve_target(cfg) -> str:
    """host:port for the Kit router (never the dish).

    Prefer [router].kit_host. Else OS default gateway when TCP:9000 answers
    (typical kit Wi-Fi LAN). Else 192.168.1.1. Never use the dish subnet or
    a host that only speaks Linksys JNAP (:80 without :9000).
    """
    r = cfg.get("router") or {}
    host = str(r.get("kit_host") or r.get("kit_router_host") or "").strip()
    port = int(r.get("kit_port") or DEFAULT_PORT)
    if not host:
        try:
            from network_checks import default_gateway
            gw = default_gateway()
        except Exception:  # noqa: BLE001
            gw = None
        if gw and not str(gw).startswith(DISH_SUBNET_PREFIX) and _tcp_open(gw, port, timeout=1.2):
            host = gw
        else:
            host = DEFAULT_HOST
    if host.startswith(DISH_SUBNET_PREFIX) or host == "192.168.100.1":
        host = DEFAULT_HOST
    return f"{host}:{port}"



def _message_to_dict(msg) -> dict:
    try:
        from google.protobuf.json_format import MessageToDict
        return MessageToDict(msg, preserving_proto_field_name=True) or {}
    except Exception:  # noqa: BLE001
        return {}


def _call_handle(target: str, request_field: str, timeout: float = 8.0) -> dict:
    """Unary Handle({request_field: {}}) via reflection. Returns response as dict."""
    import grpc
    from yagrc import reflector

    channel = grpc.insecure_channel(target)
    try:
        gr = reflector.GrpcReflectionClient()
        gr.load_protocols(channel, symbols=[dish_constants.DISH_GRPC_SERVICE])
        DeviceStub = gr.service_stub_class(dish_constants.DISH_GRPC_SERVICE)
        Request = gr.message_class(".".join(dish_constants.DISH_GRPC_SERVICE.split(".")[:-1] + ["Request"]))
        stub = DeviceStub(channel)
        resp = stub.Handle(Request(**{request_field: {}}), timeout=timeout)
        return _message_to_dict(resp)
    finally:
        channel.close()


def _wan_ip_from_status(wifi_status: dict) -> Optional[str]:
    raw = wifi_status.get("ipv4_wan_address") or wifi_status.get("ipv4WanAddress")
    if not raw:
        return None
    return str(raw).split("/", 1)[0]


def _client_count_from_diagnostics(wifi_diag: dict) -> Optional[int]:
    nets = wifi_diag.get("networks") or []
    if not isinstance(nets, list) or not nets:
        return None
    total = 0
    found = False
    for n in nets:
        if not isinstance(n, dict):
            continue
        for k in ("clients_ethernet", "clients_2ghz", "clients_5ghz",
                  "clientsEthernet", "clients_2Ghz", "clients5ghz"):
            # accept snake_case from preserving_proto_field_name
            pass
        for k, v in n.items():
            if k.startswith("clients_") and isinstance(v, (int, float)):
                total += int(v)
                found = True
    return total if found else None


def _client_count_from_status(wifi_status: dict) -> Optional[int]:
    clients = wifi_status.get("clients")
    if isinstance(clients, list):
        return len(clients)
    # Fallback: count active DHCP leases (no MAC/hostname kept in sample)
    n = 0
    found = False
    for srv in wifi_status.get("dhcp_servers") or []:
        if not isinstance(srv, dict):
            continue
        for lease in srv.get("leases") or []:
            if isinstance(lease, dict) and lease.get("active"):
                n += 1
                found = True
    return n if found else None


def sample(cfg) -> dict[str, Any]:
    """Common router sample shape for the kit Wi-Fi router."""
    target = resolve_target(cfg)
    host, _, port_s = target.partition(":")
    port = int(port_s or DEFAULT_PORT)
    base: dict[str, Any] = {
        "vendor": "kit",
        "model": None,
        "reachable": False,
        "wan_status": None,
        "client_count": None,
        "firmware": None,
        "target": target,
    }
    if not _tcp_open(host, port):
        base["error"] = f"TCP {host}:{port} refused or timed out"
        base["skipped"] = "unreachable"
        return base

    errors: dict[str, str] = {}
    diag = status = None
    try:
        diag = _call_handle(target, "get_diagnostics")
    except Exception as e:  # noqa: BLE001
        errors["get_diagnostics"] = f"{type(e).__name__}: {e}"[:200]
    try:
        status = _call_handle(target, "get_status")
    except Exception as e:  # noqa: BLE001
        errors["get_status"] = f"{type(e).__name__}: {e}"[:200]

    wifi_diag = (diag or {}).get("wifi_get_diagnostics") or (diag or {}).get("wifiGetDiagnostics") or {}
    wifi_status = (status or {}).get("wifi_get_status") or (status or {}).get("wifiGetStatus") or {}
    if not wifi_diag and not wifi_status:
        base["error"] = "; ".join(f"{k}: {v}" for k, v in errors.items()) or "no wifi diagnostics/status in response"
        base["skipped"] = "unreachable"
        if errors:
            base["errors"] = errors
        return base

    hw = wifi_diag.get("hardware_version") or (wifi_status.get("device_info") or {}).get("hardware_version")
    sw = wifi_diag.get("software_version") or (wifi_status.get("device_info") or {}).get("software_version")
    hw_index = (wifi_status.get("device_info") or {}).get("hardware_index")
    if hw_index:
        base["model"] = str(hw_index).replace("_", " ").title()
    elif hw:
        base["model"] = f"Kit router {hw}"
    else:
        base["model"] = "Kit router"
    base["hw_version"] = hw
    base["firmware"] = sw
    wan_ip = _wan_ip_from_status(wifi_status)
    if wan_ip:
        base["wan_ip"] = wan_ip
        base["wan_status"] = "Connected"
    elif wifi_diag or wifi_status:
        # Router answered; WAN field missing on some firmware — do not invent "Disconnected".
        base["wan_status"] = "Connected"
    cc = _client_count_from_diagnostics(wifi_diag)
    if cc is None:
        cc = _client_count_from_status(wifi_status)
    base["client_count"] = cc
    # Extra kit-only fields (not required by common schema)
    if isinstance((wifi_status.get("device_state") or {}).get("uptime_s"), (int, float, str)):
        try:
            base["uptime_s"] = int(wifi_status["device_state"]["uptime_s"])
        except (TypeError, ValueError):
            pass
    lat = wifi_status.get("ping_latency_ms")
    if isinstance(lat, (int, float)):
        base["ping_latency_ms"] = float(lat)
    if errors:
        base["errors"] = errors
    base["reachable"] = True
    return base
