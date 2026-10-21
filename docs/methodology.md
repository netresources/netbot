# How NetBot measures

NetBot runs one collection every 5 minutes (a launchd job on the Mac). Each run reads the dish, runs NetBot's own
network checks, and, only if the router add-on is on, reads the router. It writes one sample to
`~/NetBot/data/YYYY-MM.jsonl`, updates the alerts, and rebuilds the dashboard. Everything is read-only: NetBot never
reboots, stows, or changes settings on the dish or the router, and it never logs in to any account.

Every number on the dashboard carries a source mark:

| Mark | Meaning |
|---|---|
| `DISH` | reported by the dish itself |
| `DISH · CALC` | calculated by NetBot from values the dish reported (medians, counts) |
| `CALC` | measured and calculated by NetBot on this computer |
| `ROUTER` | reported by the router (router add-on only) |

## The dish
NetBot asks the dish for its status over the dish's local network interface at its fixed local address
(`192.168.100.1`, port 9200). This uses a small open-source library that the installer downloads at one pinned
version and checks against a pinned sha256 before use. NetBot records:

- **Status:** connection state (for example CONNECTED or SEARCHING) and uptime. A drop in uptime counts as a reboot.
- **Latency and ping drop:** the dish's own round-trip latency to its network and the share of its pings that were dropped.
- **Throughput:** current download and upload use, in Mbps. This is how much the household is using right now,
  not the capacity of the link, so a low value is never an alert by itself.
- **Obstruction:** the share of the sky view the dish reports as blocked, and whether it is blocked right now.
- **Alerts:** every alert flag the dish reports (for example thermal throttle, motors stuck, water detected).
- **Firmware:** software and hardware versions and whether an update is waiting to install.
- **15-minute history:** outage seconds and ping drop from the dish's own short history.

The dish's serial number is never stored.

## Network checks (this computer)
These are NetBot's own measurements, so they still work when the dish can't be reached or the router can't be read.
They use only tools that ship with the operating system.

- **Gateway ping:** 10 pings (0.2 s apart) to the default gateway of this computer. The panel shows the median round trip.
  The gateway's address is used for the test but not stored.
- **Internet latency:** 10 pings to each internet target in `config.toml` (`[network] internet_targets`; by default two
  public DNS resolvers). The median round trip and the jitter (the average change between consecutive round trips) are stored.
- **Packet loss:** the share of those internet pings that got no reply.
- **Speed test:** the operating system's built-in network quality test (`networkQuality` on macOS 12 and newer),
  at most once every 6 hours (`speedtest_every_h`). Download and upload in Mbps. Set `speedtest = "off"` to turn it off.

## Router add-on (optional)
When it is on, NetBot reads the router's local management interface for WAN status, connection type, the number of
connected devices, the weakest Wi-Fi signal, and firmware and hardware versions. The router password, if one is
needed, is kept only in the macOS Keychain. The synced copy leaves out the device list.

## Status rules
The dashboard shows each status as a color, a shape, and a word: OK (filled dot), WARN (triangle), ALERT (diamond),
NO DATA (ring). "Last hour" means the samples from the last 60 minutes.

| Panel | WARN | ALERT |
|---|---|---|
| Dish status | not CONNECTED now, or any outage over 60 s in the last hour | dish unreachable, or not CONNECTED for the last 3 samples (15+ min) |
| Dish latency | median latency over 60 ms or mean ping drop over 2% (last hour) | over 100 ms or over 5% |
| Dish obstruction | over 0.5% obstructed | over 2% |
| Dish alerts | any other alert flag, one reboot in 24 h, or signal below the noise floor | a critical alert (thermal shutdown, motors stuck, mast not near vertical, unexpected location, power supply thermal throttle, water detected) or 2+ reboots in 24 h |
| Dish firmware | update waiting | manual update required, or unsupported software |
| Dish throughput | never | never |
| Gateway ping | none (no agreed threshold yet) | the gateway does not answer |
| Internet latency | median over 60 ms (last hour) | over 100 ms, or no replies at all |
| Packet loss | mean loss over 2% (last hour) | over 5% |
| Speed test | 7-day median download under 100 Mbps | under 50 Mbps |
| Router stats | router past its maker's end of support | WAN not connected, or router unreachable |
| Collector | no sample for 20+ minutes | no sample for 60+ minutes |

A new ALERT raises one macOS notification (not repeated until it clears). Overnight quiet hours (22:00 to 06:00 by
default) hold back everything except a dish connection outage.

## Charts
- **Dish, last 24 hours:** each 5-minute sample of latency, ping drop, and download throughput.
- **Dish, last 7 days:** the hourly median of the same values, plus obstruction.
- **Network, last 24 hours:** gateway ping, internet latency, packet loss, and the speed tests of the last 7 days.
- **Router connected devices:** last 24 hours, only with the router add-on.

Each metric keeps one color in every chart. The colors come from the theme files in `netbot/theme/`.
