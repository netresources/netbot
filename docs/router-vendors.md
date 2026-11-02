# Router add-on — optional vendors

`[router]` in `config.toml`:

```toml
[router]
enabled = true
type = "auto"          # auto | linksys | kit | unifi  (default auto)
host = "192.168.1.1"   # Linksys JNAP host (polled only on that LAN when type=auto|linksys)
username = "admin"
keychain_service = "netbot-linksys"
# kit_host = "192.168.1.1"   # optional override; else OS gateway when not Linksys, else 192.168.1.1:9000
```

- **auto + Linksys on-LAN** → Linksys JNAP (`vendor=linksys`)
- **auto + off Linksys LAN** → kit Wi-Fi router gRPC on `:9000` (`vendor=kit`); Linksys not polled
- Dish stays `192.168.100.1:9200` (never the router)
- Common sample fields: `vendor`, `model`, `reachable`, `wan_status`, `client_count`, `firmware` (+ optional `skipped` / `error`)

## UniFi — read-only

`netbot/unifi_router.py`: GET-only calls to the UniFi Network local API with an
`X-API-KEY` header. Integration API (`/proxy/network/integration/v1/sites`,
`…/devices`, `…/clients`) for gateway model, firmware, client count; legacy
`/proxy/network/api/s/<site>/stat/health` (+ `stat/device`) for WAN status. If
legacy is refused, WAN falls back to the gateway's ONLINE state. No writes.

- `type = "unifi"` → always UniFi; off-network → gray "off this Wi-Fi path".
- `type = "auto"` → unchanged unless `[unifi].host` is set **and** answers on its port as UniFi OS; then UniFi.
- Before any authenticated call, NetBot checks an unauthenticated GET `/` for a UniFi OS signature so the key is never sent to a different device that happens to share the same IP (for example a kit Wi-Fi router at `192.168.1.1`).
- Key is read from env (`api_key_env`) or Keychain (`netbot-unifi` / account `netbot`). Never in config/logs.
- Tests: `PYTHONPATH=$PWD:$PWD/netbot python3 -m unittest discover -s tests -p 'test_unifi*.py' -v`

### UniFi setup guide

You need: the UniFi console's LAN IP (UDM/UCG/Cloud Key, or self-hosted Network app host)
and a **read-only local API key** — UniFi Network › Settings › Control Plane › Integrations
› Create API Key (or equivalent on your version). Copy the key; do not paste it in chat.

1. Store the key in Keychain on the Mac that will poll the console (prompts for it, nothing in shell history):
   `security add-generic-password -s netbot-unifi -a netbot -w`
   (paste at the prompt, Enter). Approve "Always Allow" for python when macOS asks.
2. Add to that Mac's `config.toml`:
   ```toml
   [router]
   enabled = true
   type = "unifi"            # or keep "auto" — UniFi is used when the host answers as UniFi OS
   [unifi]
   host = "192.168.1.1"      # console IP on this LAN
   site = "default"
   verify_tls = false        # console uses a self-signed cert
   # port = 443; path_prefix = "/proxy/network"   (self-hosted app: port = 8443, path_prefix = "")
   ```
3. Wait ~5 min (or run one collect cycle) and open the dashboard.
   **Pass:** green tile "UniFi · WAN Connected, N clients, firmware ok/up to date".
   Yellow "update available" is also a pass. Gray "off this Wi-Fi path" = console not reachable
   from this network. Red "Keychain item missing" = step 1 not done. Yellow "API key rejected" = wrong/expired key.
