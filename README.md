# NetBot: Connection Monitor

NetBot quietly checks your satellite internet dish and your connection every 5 minutes and keeps a history on your own Mac.
NetBot works with Starlink equipment, not affiliated with or endorsed by SpaceX, Starlink, Linksys, or Ubiquiti; names used only to describe compatibility.

Its dashboard shows a status (OK, WARN, ALERT, or NO DATA) for:
- **Dish health:** dish status, throughput, latency, obstruction, firmware, and alerts
- **Network checks:** gateway ping, internet latency, packet loss, and speed tests, measured by NetBot on this Mac
- **Router stats** (optional add-on, for supported routers)

It includes 24-hour and 7-day charts, and puts up a Mac notification when something is really wrong.
How each number is measured is described in [docs/methodology.md](docs/methodology.md).

**NetBot only reads.** It never reboots, stows, or changes settings on your dish or router,
and it never asks for any account login.

## As-is, no warranty, no support

NetBot is provided as-is, without warranty of any kind. There are no planned updates and no support.

## Limitation of liability

To the maximum extent permitted by law, the authors and contributors are not liable for any claim, damages, or other liability, whether direct, indirect, incidental, special, or consequential, arising from or in connection with NetBot or its use.

Use NetBot at your own risk, including any changes it makes to your network or devices (for example the background jobs it schedules, a router password it saves in Keychain or Credential Manager, or a sleep setting you let it change).
Use only on networks and devices you own or are authorized to manage.
Do not rely on it for safety.

## Install by double-clicking (no typing)
1. **Download:** click the green **Code** button, then **Download ZIP**. Double-click the ZIP to unzip it.
   You'll get a folder named `NetBot`.
2. **Read first (recommended):** open `install.sh` in TextEdit and skim it. It's short and commented.
   We deliberately don't offer a "paste this curl command" install; you should always be able to see what runs on your Mac.
3. **Double-click `Install NetBot.command`.**
   - **The first time**, macOS blocks it because it was downloaded and isn't from an identified developer.
     The message says Apple can't verify it. Click **Done** (or **OK**). Don't click Move to Trash.
   - **macOS 15 Sequoia and newer:** open **System Settings > Privacy & Security**, scroll down to **Security**.
     Next to the message about "Install NetBot.command", click **Open Anyway**, then enter your Mac password.
     The button appears for about an hour after you try to open the file. Double-click the file again, then click **Open Anyway**
     in the dialog that follows.
   - **macOS 14 Sonoma and older:** Control-click (or right-click) `Install NetBot.command`, choose **Open**, then click **Open**.
   - You only do this once per file.
4. A Terminal window opens and shows progress. Answer the pop-up questions:
   - **Where to keep a synced copy:** "Local only" is fine. You can also pick your OneDrive, iCloud Drive, Dropbox, or Google Drive.
   - **Router add-on (optional):** NetBot looks for a supported router automatically. If none is found, you can type its address or click Skip.
   - **Router password (only if your router requires one):** a pop-up with a hidden box asks for it.
     It's saved **only** in your Mac's Keychain.
   - **Keep the Mac awake while plugged in:** optional. If you say Yes, macOS shows its usual administrator password window.
     Cancel is fine; nothing changes.
   - You never need to type in the Terminal window. It only shows progress and ends with "You can close this window."
5. At the end, click **Open Dashboard** and bookmark the page. It's at `~/NetBot/dashboard/index.html`.
   If something went wrong, the final message tells you where the log is (`~/NetBot/install.log`).

If macOS asks whether "security" may use NetBot's router-password item in your Keychain, choose **Always Allow**.
That's how NetBot reads the router password without storing it anywhere else.

To remove NetBot, double-click **`Uninstall NetBot.command`**. It needs the same one-time Open Anyway step.

**Prefer Terminal?** Open the folder in Terminal and run `bash install.sh`.
Set `NETBOT_NONINTERACTIVE=1` for plain text prompts instead of pop-ups.

## What you need
- A Mac that stays on and is connected to your home network.
- A dish reachable from the Mac at `192.168.100.1` (the dish's own fixed local address).
- Optional: a router supported by the router add-on, on the same network.

## Reading the dashboard
- Every panel shows a shape and a word as well as a color: **OK** (filled dot) is fine, **WARN** (triangle) is worth a look,
  **ALERT** (diamond) is a real problem (and you'll get a notification), **NO DATA** (ring) means there is no reading yet.
- **Dish throughput** is how much your household is using right now, *not* a speed test. A low number at
  night is normal, so this panel is never ALERT on its own. The **Speed test** panel is the real speed measurement.
- **Dish firmware:** the dish updates itself automatically, usually around 3 AM. WARN means an update is waiting.
- **Router stats:** shows WARN if the router model no longer gets security updates from its maker.
- A **Collector** panel appears when the Mac hasn't taken a reading recently. It may have been asleep or off.
- Each panel says where its number comes from: `DISH` (reported by the dish), `DISH · CALC` (NetBot's calculation from dish data),
  or `CALC` (measured by NetBot on this Mac).

## Live page
NetBot also serves a live page on this computer at `http://localhost:8765/`. It reads the same numbers as the dashboard and draws the charts in the browser. The page asks the server for new values every 30 seconds. The dish is still read every 5 minutes.

The page shows one of three states:

- **Live** — the page can reach NetBot, and the last sample is under 20 minutes old (`last sample N s ago`).
- **Stale** — the last sample is 20 minutes old or older.
- **Not connected** — the page missed the server twice in a row. It keeps the last numbers, dimmed, and retries every 10 seconds.

A saved dashboard file (the copy written for your cloud folder) is a snapshot of the same readings. It does not include a private link or an access key.

Run it from a checkout with:

    python3 -m netbot.live_server

It uses `~/NetBot/config.toml`, or the file named by `NETBOT_CONFIG`. The collector writes `live/status.json` and `live/history.json` next to the data directory on every run.

## Home Wi-Fi access
Off by default. The live page then opens only on this computer, and the server listens on localhost only.

To let other devices on your home Wi-Fi open the page, set `lan = true` under `[live]` in `~/NetBot/config.toml` and start the live page again. NetBot then also listens on this computer's address on the home network, and that listener requires an access key. If no home-network address is found, it stays on localhost and does not listen on every interface.

The key is not stored in `config.toml`. It is a separate file, `~/NetBot/live-access.key`, readable only by your user.

Setup prints the private link when Home Wi-Fi access is on (`NETBOT_LIVE_LAN=1` during install, or a `lan = true` line that was already in the config). Otherwise it prints the localhost page and says access is off.

## The private link
When Home Wi-Fi access is on, the link looks like `http://<lan-address>:<port>/?key=<key>`. Open it once. NetBot sets a cookie and removes the key from the address bar. The full link is shown on the live page only when you open the page on this computer. A device that opens the home-network address does not see the key on the page. The saved snapshot never includes it.

Print the current link:

    python3 -m netbot.live_server --print-link

Rotate the key. The previous link stops working immediately, without a restart:

    python3 -m netbot.live_server --rotate-key

## Dish not found?
- If you use your own router (or the dish's router *and* another router behind it), your Mac may not reach
  `192.168.100.1`. The dish's phone app has the same problem in that case.
  - Try connecting the Mac to the Wi-Fi that's closest to the dish's router.
  - Or ask your router for a "static route to 192.168.100.1."
  - NetBot's network checks keep working either way, so you still see ping, latency, packet loss, and speed tests.
- A router placed *behind* the dish's router usually has a different address than the usual
  `192.168.1.1`, and the installer will ask you to type it. The Mac must be on that router's network to read it.

## Uninstall
Double-click `Uninstall NetBot.command` (or run `bash uninstall.sh`). This stops NetBot, removes its schedule and any Keychain item, and asks before deleting your history.
If you changed the sleep setting, the script prints the command to undo it.

## Privacy
- Everything stays on your Mac (and in your own cloud folder, if you chose one).
- The cloud copy leaves out the list of devices on your network.
- No account logins and no analytics. No information about you is sent anywhere. NetBot connects to:
  - your dish at `192.168.100.1`
  - your router. During setup, router auto-detect probes the default gateway, `192.168.1.1`, `10.0.0.1`, `192.168.0.1`, and `myrouter.local`
  - ping checks to `1.1.1.1` and `9.9.9.9` (the default targets), and to your gateway
  - a speed test at most once every 6 hours. On a Mac, the built-in `networkQuality` tool talks to Apple's servers. On Windows, the test downloads from `speed.cloudflare.com`. The 6 hours is the default of `speedtest_every_h` in `config.toml`; change that number, or set `speedtest = "off"` to turn the speed test off.
  - at setup only, the pinned dish library from GitHub codeload (`codeload.github.com`; see `netbot/dish_constants.py`) and Python packages from PyPI

## How the router password is kept safe
The password pop-up and the save into Keychain happen inside one small macOS script (`netbot/keychain_dialog.js`)
that uses Apple's Keychain functions directly. The password never appears on a command line, in a log, or in a file,
and it is never handed back to the installer. If that pop-up can't save for some reason, the installer falls back to
macOS's own `security` prompt in Terminal.

## Credits and licenses
- NetBot is released under **The Unlicense** (public domain, see `LICENSE`).
- It uses an open-source dish library (also The Unlicense), downloaded by the installer from its public source at one pinned
  version and checked against a pinned sha256 (see `netbot/dish_constants.py`). It is never bundled with NetBot.
- The dashboard colors and line art are original NetBot designs (`netbot/theme/`).
- Charts on the live page use uPlot 1.6.32, MIT license. See `netbot/vendor/uplot/VENDORED.md`.

## For tinkerers
- Settings live in `~/NetBot/config.toml`. See `config.example.toml`.
- Logs are in `~/NetBot/logs/`.
- Offline test on any Unix with Python 3: `bash tests/run_mock_install.sh`
  (set `NETBOT_TEST_PYTHON=/path/to/python3.9` to test with the same Python as macOS's built-in python3).
- Works with macOS's built-in Python 3.9 (no Homebrew needed).
