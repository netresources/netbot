# Changelog

## Unreleased (installer-polish)
- LaunchAgent ownership requires the program executable (`Program`, or the first `ProgramArguments` string when `Program` is absent) to be an absolute path inside the home. A bare name such as python or bash is not ours.
- LaunchAgent ownership refuses a plist launchd would read differently: `&` in any `<key>` or `<string>` (XML entities such as `&#46;` and `&#103;`), a `<![CDATA[` section anywhere in the file, or a second `ProgramArguments` key (launchd uses the last array).
- Live page: a read-only local server (`python3 -m netbot.live_server`) and a browser page that polls every 30 seconds. Home Wi-Fi access is off unless `[live] lan` is true; the access key is a mode-0600 file and can be rotated with `--rotate-key`. The collector rebuilds the static dashboard and writes the live JSON on every run. Charts use vendored uPlot 1.6.32 (MIT).

- Installer and uninstaller wording moved to `strings/messages.sh`; shared helpers in `lib/common.sh`. Dialog text is passed to AppleScript as arguments, so wording and style can change without touching logic.
- `install.sh`: "Step N of 9" progress, plain error messages that name the step that failed, safe to run again (reuses the download and Python environment, replaces the launchd job, keeps history). Records what it created in `~/NetBot/.netbot-state/`.
- `uninstall.sh`: removes the launchd job and plist, NetBot's program files, and the router password only if NetBot saved it. Asks before deleting history, the dashboard, and the synced copy. Safe to run more than once.
- Double-click launchers close only their own Terminal window (matched by tty) after success, keep it open with the error on failure, and do nothing if osascript is missing or not running in Terminal. `NETBOT_NO_AUTOCLOSE=1` keeps the window open.
- Tests: stateful mocks for launchctl, security, and osascript; re-install, "nothing left behind" uninstall, Keychain ownership, auto-close and failure paths. New `tests/check_anonymous.sh` scan runs as part of the suite.
- Dish monitor is the always-on core. It records every status field, alert, and software-update state the dish reports (not its serial number); new firmware alerts show up in `alerts_known`. Water-detected alerts are red; a signal below the noise floor is yellow.
- `netbot/dish_constants.py` is the only file that names the dish library or its gRPC service. Code and wording elsewhere say "dish".
- The dish library is downloaded during setup as the source tarball of one pinned commit and checked against a pinned sha256 before anything is unpacked (`lib/verify_unpack.py`). It is never bundled. git is no longer needed. The old git checkout from 0.1–0.3 is removed on upgrade.
- Config section, path key, and data key are now `[dish]`, `dish_lib`, and `dish`. `netbot/migrate_legacy.py` rewrites older config, history, and the synced copy once, during setup (nothing is deleted).
- Titles: `APP_NAME` ("NetBot") for window and dialog title bars and notifications; `PRODUCT_TITLE` ("NetBot: Connection Monitor") for the dashboard, the installer's first screen, and this README. Both live in `netbot/ui_text.py`.
- Dashboard redesign: dark theme from `netbot/theme/` (design tokens, one color per metric, matplotlib style), Dish health and Network checks sections, a "Network · last 24 hours" chart row, the router add-on section only when it is on, and statuses that always show a shape and a word. The PNG tile grid fits any number of panels. No color values outside `netbot/theme/` (tested).
- Network checks: gateway ping, internet latency and packet loss, and a speed test every 6 hours, measured on the Mac.
- Anonymity scan: the allowlist is exact file path + exact string. The scan fails if the dish library is bundled in any form, has a `--self-test`, and fails by default on brand titles, product names, logos, and any brand mention outside the final allowlist (`--report-only-brand` lists them instead).
- `docs/methodology.md` describes how each number is measured.

## 0.3.0 (unreleased)
- No Terminal typing.
  - Keep-awake uses the native macOS administrator password window (`do shell script … with administrator privileges`); Cancel is handled.
  - The router password uses a hidden-answer pop-up that saves straight to Keychain via `SecItemAdd` inside one JXA process (`netbot/keychain_dialog.js`). The Terminal `security` prompt is kept only as a fallback and for no-GUI runs.
  - `.command` windows end with "You can close this window."
- Python 3.9 support (macOS system python3 3.9.6).
  - Built-in TOML-subset parser when `tomllib` (3.11+) is missing; previously the config was silently ignored on 3.9/3.10.
  - The installer upgrades pip in the venv.
- Tests: GUI keychain and keep-awake scenario added; the suite can run on a chosen Python (`NETBOT_TEST_PYTHON`).

## 0.2.0
- Double-click installer and uninstaller: `Install NetBot.command`, `Uninstall NetBot.command`.
- macOS pop-up dialogs: cloud folder list (Local only first), Yes/No questions, router address box, final Open Dashboard or error message.
- The router password is still typed only in Terminal (macOS `security` prompt), never in a pop-up.
- Full install log at `~/NetBot/install.log`.
- Text prompts remain when there's no GUI or `NETBOT_NONINTERACTIVE=1`.
- README: double-click steps and the one-time Gatekeeper "Open Anyway" step.

## 0.1.0
- First public version.
- Read-only dish collector (an open-source dish library at one pinned commit, `0d9809e8`), every 5 minutes via launchd (`io.netbot.collect`).
- Optional router reads (router add-on). The router is auto-detected by a JSON reply to `GetDeviceInfo`. The password, only if needed, is stored in macOS Keychain.
- Static HTML dashboard with green/yellow/red tiles and 24-hour / 7-day charts, plus a PNG snapshot.
- Rule-based alerts with macOS notifications and quiet hours.
- "Current usage" tile never turns red on its own; only a speed test can.
- Handles firmware that returns 4 status groups and routers that return non-JSON pages.
- Guided `install.sh` (cloud folder picker, optional sleep setting) and `uninstall.sh`.
