# NetBot user-facing text for the macOS installer, uninstaller, and double-click launchers.
# Everything a person reads (Terminal lines, pop-up text, button labels) lives here, so the wording
# or styling can change without touching installer logic. Sourced by install.sh, uninstall.sh,
# and the .command launchers. Plain bash assignments only; no logic.
# Placeholders like %s are filled in with printf by the scripts.
# shellcheck disable=SC2034

# ---- common
# App name and product title: defined once, in netbot/ui_text.py (APP_NAME, PRODUCT_TITLE); read here so both sides match.
_nb_ui="$(dirname "${BASH_SOURCE[0]}")/../netbot/ui_text.py"
MSG_APP_NAME="$(sed -n 's/^APP_NAME = "\(.*\)"$/\1/p' "$_nb_ui" 2>/dev/null)"; MSG_APP_NAME="${MSG_APP_NAME:-NetBot}"
MSG_PRODUCT_TITLE="$(sed -n 's/^PRODUCT_TITLE = "\(.*\)"$/\1/p' "$_nb_ui" 2>/dev/null)"; MSG_PRODUCT_TITLE="${MSG_PRODUCT_TITLE:-$MSG_APP_NAME}"
unset _nb_ui
MSG_TITLE="$MSG_APP_NAME"                     # title bar of every installer/uninstaller dialog
MSG_BTN_YES="Yes"
MSG_BTN_NO="No"
MSG_BTN_OK="OK"
MSG_BTN_SKIP="Skip"
MSG_BTN_CLOSE="Close"
MSG_BTN_OPEN_DASHBOARD="Open Dashboard"
MSG_STEP_FMT="Step %s of %s: %s"            # step number, total, step title
MSG_OK_PREFIX="  ✓ "
MSG_WARN_PREFIX="  ! "
MSG_ERR_PREFIX="  ✗ "

# ---- install: header and steps
MSG_INSTALL_BANNER="$MSG_PRODUCT_TITLE installer"
MSG_INSTALL_RERUN="NetBot is already installed here. Updating it in place; your history is kept."
MSG_STEP_CHECKS="Checking this Mac"
MSG_STEP_TOOLS="Getting the dish library (pinned version %s)"
MSG_STEP_VENV="Creating a private Python environment"
MSG_STEP_DISH="Looking for your dish at %s"
MSG_STEP_SYNC="Choosing where to keep a synced copy"
MSG_STEP_ROUTER="Optional: router stats add-on"
MSG_STEP_SCHEDULE="Writing settings and scheduling NetBot every 5 minutes"
MSG_STEP_FIRST="Taking a first reading"
MSG_STEP_SLEEP="Optional: keep this Mac awake on power so monitoring has no gaps"

# ---- install: checks
MSG_ERR_NOT_MAC="NetBot's installer is for macOS only."
MSG_ERR_NO_PYTHON="Python 3.9 or newer is needed. Install Apple's Command Line Tools with:  xcode-select --install"
MSG_ERR_NO_PYTHON_2="Then run this installer again."
MSG_OK_PYTHON="python3 %s"

# ---- install: tools and environment
MSG_ERR_CONSTANTS="NetBot's own files look incomplete (netbot/dish_constants.py is missing or broken). Download NetBot again."
MSG_ERR_CLONE="Could not download the dish library. Check the internet connection and run the installer again."
MSG_ERR_PIN="The downloaded dish library is not the expected version (its checksum does not match), so NetBot stopped for safety."
MSG_OK_PIN="version %s verified (sha256 %s...)"
MSG_OK_TOOLS_REUSED="already downloaded, reusing it"
MSG_OK_VENV_REUSED="reusing the existing Python environment"
MSG_ERR_PIP="Could not install the Python packages NetBot needs. Check the internet connection and run the installer again."
MSG_ERR_MIGRATE="NetBot could not update its settings and history files to the new format. Nothing was deleted. Run the installer again."
MSG_OK_VENV="environment ready in %s"

# ---- install: dish
MSG_OK_DISH="dish found"
MSG_WARN_DISH_1="Can't reach the dish at %s:%s right now."
MSG_WARN_DISH_2="If you use your own router, see README > 'Dish not found'. NetBot will keep trying every 5 minutes."

# ---- install: sync folder
MSG_SYNC_PROMPT="Where should NetBot keep a synced copy? Local only is fine."
MSG_SYNC_LOCAL_ONLY="Local only (no cloud copy)"
MSG_SYNC_PICK="Choose a number"
MSG_OK_SYNC="synced copy: %s"
MSG_OK_LOCAL="local only"

# ---- install: router
MSG_ROUTER_ASK="Do you want NetBot to also show stats from your router, if it has an add-on for it? (Optional)"
MSG_ROUTER_FOUND="supported router found at %s"
MSG_ROUTER_NOT_SUPPORTED="no add-on for this router (or not reachable)"
MSG_ROUTER_TYPE_GUI="No supported router was found automatically. Type its address (for example 192.168.1.1), or click Skip."
MSG_ROUTER_TYPE_TEXT="Not found. Type its address (Enter to skip)"
MSG_ROUTER_NO_ANSWER_GUI="No supported router answered at %s. NetBot will watch your dish and connection for now. To add the router later, run the installer again."
MSG_ROUTER_NO_PW_NEEDED="router answers without a password, none stored"
MSG_ROUTER_PW_ASK="The router needs its admin password for client details. Save it in Keychain"
MSG_ROUTER_PW_SAVED="router password saved in Keychain"
MSG_ROUTER_PW_SKIPPED="no password saved; NetBot will read what the router shares without one"
MSG_ROUTER_PW_FALLBACK="could not save from the dialog (%s); falling back to the Terminal prompt"
MSG_ROUTER_PW_TYPE_1="  >>> Type your ROUTER admin password here and press Return."
MSG_ROUTER_PW_TYPE_2="  >>> Then type it again and press Return. Nothing appears while you type; that's normal."
MSG_ROUTER_PW_KEPT="a router password was already in Keychain; NetBot will use it and leave it in place on uninstall"
MSG_ROUTER_SKIP="skipping router monitoring"
MSG_KC_LABEL="NetBot router password"

# ---- install: schedule and first reading
MSG_OK_CONFIG="config: %s"
MSG_OK_SCHEDULED="scheduled (%s)"
MSG_ERR_SCHEDULE="macOS would not start the NetBot schedule (launchctl). Try logging out and back in, then run the installer again."
MSG_ERR_LAUNCHAGENT_FOREIGN="A LaunchAgent named %s is already at %s and was not created by this installer for the NetBot home %s. Nothing was changed: that file was not modified, unloaded, or replaced. Move that file out of LaunchAgents only if you know it is not in use (this installer will not move or delete it), then run this installer again."
MSG_OK_DASHBOARD="dashboard: %s (bookmark it)"
MSG_OK_LIVE_SCHEDULED="live page scheduled (%s)"
MSG_OK_LIVE="live page: %s"
MSG_LIVE_LAN_OFF="Home Wi-Fi access is off. This page opens only on this computer."
MSG_LIVE_PRINT_LINK="run python3 -m netbot.live_server --print-link to see your link."
MSG_WARN_FIRST="first reading failed; see %s after 5 minutes"
MSG_FIRST_OK="OK"
MSG_FIRST_UNREACHABLE="not reachable: "

# ---- install: sleep
MSG_SLEEP_ASK="Keep this Mac awake while plugged in, so monitoring has no gaps? (The screen can still sleep. macOS will ask for your Mac password.)"
MSG_SLEEP_ADMIN_PROMPT="NetBot wants to keep this Mac awake while it is plugged in (the screen can still sleep)."
MSG_SLEEP_SUDO_NOTE="  This runs: sudo pmset -c sleep 0"
MSG_OK_SLEEP="Mac won't sleep while plugged in"
MSG_WARN_SLEEP_CANCELLED="not changed (cancelled). You can do it later in System Settings > Energy/Battery."
MSG_WARN_SLEEP="not changed"
MSG_OK_UNCHANGED="left unchanged"

# ---- install: finish
MSG_INSTALL_DONE="Done. NetBot runs every 5 minutes. To remove it, double-click 'Uninstall NetBot.command'."
MSG_FULL_LOG="Full log: %s"
MSG_FINAL_OK="NetBot is installed and checks your dish every 5 minutes."
MSG_FINAL_FAIL="NetBot could not finish installing."
MSG_FINAL_FAIL_DETAILS="Details are in:"
MSG_INSTALL_FAILED="Install stopped during step %s (%s), exit code %s."
MSG_INSTALL_FAILED_HINT="Fix the problem above, then double-click 'Install NetBot.command' again. It is safe to run more than once."

# ---- uninstall
MSG_UNINSTALL_BANNER="Removing $MSG_PRODUCT_TITLE from this Mac"
MSG_UN_STEP_SCHEDULE="Stopping NetBot"
MSG_UN_STEP_KC="Checking Keychain"
MSG_UN_STEP_FILES="Removing program files"
MSG_UN_STEP_HISTORY="Your history and dashboard"
MSG_UN_STOPPED="stopped and unscheduled"
MSG_UN_NOT_SCHEDULED="was not scheduled (nothing to stop)"
MSG_WARN_UN_STILL_LOADED="macOS still lists the NetBot job; log out and back in to finish stopping it."
MSG_WARN_UN_PLIST_SYMLINK="left %s unchanged because it is a symlink"
MSG_UN_KC_REMOVED="router password removed from Keychain"
MSG_UN_KC_KEPT="left the router password in Keychain (NetBot did not create it)"
MSG_UN_KC_NONE="no NetBot Keychain item"
MSG_UN_PROGRAM_REMOVED="removed NetBot's program files"
MSG_UN_DELETE_ASK="NetBot is stopped. Also delete its history and dashboard in %s (and the synced copy, if any)?"
MSG_UN_DELETED="deleted %s"
MSG_UN_KEPT="kept your history and dashboard in %s"
MSG_UN_SYNC_KEPT="Your synced copy (if any) is at: %s  (delete it yourself if you want)"
MSG_UN_SLEEP_HINT="NetBot changed the sleep setting at install. To restore it:  sudo pmset -c sleep 10"
MSG_UN_SLEEP_HINT_MAYBE="Optional: if you changed sleep settings, restore with:  sudo pmset -c sleep 10"
MSG_UN_DONE="Done. NetBot has been removed."
MSG_UN_FINAL_GUI="NetBot has been removed from this Mac. The NetBot download folder will be moved to the Trash."
MSG_UN_FAILED="Uninstall did not finish (exit code %s). Nothing was moved to the Trash."

# ---- double-click launchers
MSG_LAUNCH_DONE_CLOSING="Done. This window closes in a moment."
MSG_LAUNCH_DONE_OPEN="Done. You can close this window."
MSG_LAUNCH_FAILED="Something went wrong (see above). This window stays open so you can read it. You can close it when you're done."
