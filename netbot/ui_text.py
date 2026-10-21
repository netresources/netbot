"""User-facing text for the Python side (dashboard, tiles, notifications). Wording lives here, not in logic.
No product, company, or service brand names: on screen the equipment is "Dish" and "Router"."""

# App name: window and dialog title bars on Mac and Windows, and notification titles. Short on purpose.
# Product title: dashboard header, page <title>, PNG title, the installer's first screen, and the README heading.
# Both are defined only here; strings/messages.sh and the Pester tests read these lines. Keep each on one line.
APP_NAME = "NetBot"
PRODUCT_TITLE = "NetBot: Connection Monitor"

# Tile names, as shown on the dashboard and used as keys in alerts/active.json and ALERT-*.json.
TILE_COLLECTOR = "Collector"
# dish (core, always on)
TILE_DISH_STATUS = "Dish status"
TILE_DISH_THROUGHPUT = "Dish throughput"
TILE_DISH_LATENCY = "Dish latency"
TILE_DISH_OBSTRUCTION = "Dish obstruction"
TILE_DISH_ALERTS = "Dish alerts"
TILE_DISH_FIRMWARE = "Dish firmware"
# network checks (core, always on; measured by NetBot on this computer)
TILE_GATEWAY_PING = "Gateway ping"
TILE_INTERNET_LATENCY = "Internet latency"
TILE_PACKET_LOSS = "Packet loss"
TILE_SPEED_TEST = "Speed test"
# router (optional add-on)
TILE_ROUTER = "Router stats"

# Tiles that may alert overnight (quiet hours): only a dish connection outage.
QUIET_HOURS_TILES = (TILE_DISH_STATUS,)

NOTIFY_TITLE = APP_NAME
FIRMWARE_MANUAL_UPDATE = "manual update required (dish app)"

# Dashboard sections and charts (STYLE-SPEC sections 6 and 10). Every dish chart starts with "Dish".
SECTION_DISH = "Dish health"
SECTION_NETWORK = "Network checks"
SECTION_DISH_24H = "Dish · last 24 hours"
SECTION_DISH_7D = "Dish · last 7 days"
SECTION_NETWORK_24H = "Network · last 24 hours"
SECTION_ROUTER = "Router stats"
CHART_DISH_LATENCY = "Dish latency (ms)"
CHART_DISH_DROP = "Dish ping drop (%)"
CHART_DISH_THROUGHPUT = "Dish throughput, down (Mbps)"
CHART_DISH_LATENCY_7D = "Dish latency, hourly median (ms)"
CHART_DISH_DROP_7D = "Dish ping drop, hourly median (%)"
CHART_DISH_THROUGHPUT_7D = "Dish throughput, hourly median (Mbps)"
CHART_DISH_OBSTRUCTED_7D = "Dish obstructed (%)"
CHART_GATEWAY_PING = "Gateway ping (ms)"
CHART_INTERNET_LATENCY = "Internet latency (ms)"
CHART_PACKET_LOSS = "Packet loss (%)"
CHART_SPEED_TEST = "Speed test, down, last 7 days (Mbps)"
CHART_ROUTER_DEVICES = "Router connected devices (count)"
EXAMPLE_BANNER = "Example data, not a real measurement"
EXAMPLE_MARK = "EXAMPLE DATA"
UPDATED = "Updated {when} (local time)"
NO_DATA = "no data"
# Source marks: DISH = reported by the dish; CALC = measured and calculated by NetBot on this computer.
SRC_DISH, SRC_DISH_CALC, SRC_CALC, SRC_ROUTER = "DISH", "DISH · CALC", "CALC", "ROUTER"
LEGEND = ((SRC_DISH, "reported by the dish"), (SRC_DISH_CALC, "calculated by NetBot from dish data"),
          (SRC_CALC, "measured and calculated by NetBot on this computer"))
CHIP_DISH, CHIP_NETWORK, CHIP_ROUTER = "Dish · on", "Network checks · on", "Router add-on · {state}"
