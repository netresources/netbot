# NetBot user-facing text for the Windows installer, uninstaller, setup dialogs and double-click launchers.
# Everything a person reads (console lines, dialog text, button labels) lives here, so wording can change
# without touching installer logic. Dot-sourced by install.ps1 and uninstall.ps1. Assignments only; no logic.
# Placeholders {0}, {1} ... are filled in with -f by the scripts. Same wording as strings/messages.sh where
# the step is the same; "Mac" becomes "PC" and Keychain becomes Windows Credential Manager.
# Saved as UTF-8 with a byte-order mark so Windows PowerShell 5.1 reads the marks below correctly.

# ---- common: app name and product title are defined once, in netbot/ui_text.py
$_nbUi = [IO.Path]::Combine($PSScriptRoot, '..', 'netbot', 'ui_text.py')
$_nbText = if (Test-Path -LiteralPath $_nbUi) { Get-Content -LiteralPath $_nbUi -Raw -Encoding UTF8 } else { '' }
$MSG = @{}
$MSG.APP_NAME = if ($_nbText -match '(?m)^APP_NAME = "(.*)"\s*$') { $Matches[1] } else { 'NetBot' }
$MSG.PRODUCT_TITLE = if ($_nbText -match '(?m)^PRODUCT_TITLE = "(.*)"\s*$') { $Matches[1] } else { $MSG.APP_NAME }
Remove-Variable _nbUi, _nbText
$MSG.TITLE = $MSG.APP_NAME                      # title bar of every installer/uninstaller dialog
$MSG.STEP_FMT = 'Step {0} of {1}: {2}'           # step number, total, step title
$MSG.OK_PREFIX = '  ✓ '
$MSG.WARN_PREFIX = '  ! '
$MSG.ERR_PREFIX = '  ✗ '
$MSG.YES_NO = '[y/n]'

# ---- install: header and steps
$MSG.INSTALL_BANNER = "$($MSG.PRODUCT_TITLE) installer"
$MSG.INSTALL_RERUN = 'NetBot is already installed here. Updating it in place; your history is kept.'
$MSG.STEP_CHECKS = 'Checking this PC'
$MSG.STEP_TOOLS = 'Getting the dish library (pinned version {0})'
$MSG.STEP_VENV = 'Creating a private Python environment'
$MSG.STEP_DISH = 'Looking for your dish at {0}'
$MSG.STEP_SYNC = 'Choosing where to keep a synced copy'
$MSG.STEP_ROUTER = 'Optional: router stats add-on'
$MSG.STEP_SCHEDULE = 'Writing settings and scheduling NetBot every 5 minutes'
$MSG.STEP_FIRST = 'Taking a first reading'
$MSG.STEP_SLEEP = 'Optional: keep this PC awake on power so monitoring has no gaps'

# ---- install: checks
$MSG.ERR_NOT_WINDOWS = "This installer is for Windows. On a Mac, use 'Install NetBot.command'."
$MSG.ERR_OLD_POWERSHELL = 'PowerShell 5.1 or newer is needed. Update Windows, then run setup again.'
$MSG.ERR_NO_PYTHON = 'Python 3.9 or newer is needed. Install it, then run setup again.'
$MSG.ERR_NO_PYTHON_2 = "Get it from the official Python website (tick 'Add python.exe to PATH'), or type  winget install Python.Python.3.12  in a terminal."
$MSG.OK_PYTHON = 'Python {0}'
$MSG.OK_POWERSHELL = 'PowerShell {0}'

# ---- install: tools and environment
$MSG.ERR_CONSTANTS = "NetBot's own files look incomplete (netbot\dish_constants.py is missing or broken). Download NetBot again."
$MSG.ERR_CLONE = 'NetBot could not download a required component. Check the internet connection, then run setup again.'
$MSG.ERR_PIN = 'The downloaded dish library is not the expected version (its checksum does not match), so NetBot stopped for safety.'
$MSG.OK_PIN = 'version {0} verified (sha256 {1}...)'
$MSG.OK_TOOLS_REUSED = 'already downloaded, reusing it'
$MSG.OK_VENV_REUSED = 'reusing the existing Python environment'
$MSG.ERR_VENV = 'Could not create the private Python environment. Repair or reinstall Python, then run setup again.'
$MSG.ERR_PIP = 'Could not install the Python packages NetBot needs. Check the internet connection and run the installer again.'
$MSG.ERR_MIGRATE = 'NetBot could not update its settings and history files to the new format. Nothing was deleted. Run the installer again.'
$MSG.OK_VENV = 'environment ready in {0}'

# ---- install: dish
$MSG.OK_DISH = 'dish found'
$MSG.WARN_DISH_1 = "Can't reach the dish at {0}:{1} right now."
$MSG.WARN_DISH_2 = "If you use your own router, see README > 'Dish not found'. NetBot will keep trying every 5 minutes."

# ---- install: sync folder
$MSG.SYNC_PROMPT = 'Where should NetBot keep a synced copy? Local only is fine.'
$MSG.SYNC_LOCAL_ONLY = 'Local only (no cloud copy)'
$MSG.SYNC_PICK = 'Choose a number'
$MSG.OK_SYNC = 'synced copy: {0}'
$MSG.OK_LOCAL = 'local only'

# ---- install: router (console)
$MSG.ROUTER_ASK = 'Do you want NetBot to also show stats from your router, if it has an add-on for it? (Optional)'
$MSG.ROUTER_MAKE_ASK = 'Router make (the brand on its label; Enter if not sure)'
$MSG.ROUTER_MODEL_ASK = 'Router model (Enter to skip)'
$MSG.ROUTER_ADDON_ASK = 'There is an add-on for your router. Turn it on now?'
$MSG.ROUTER_NO_ADDON = 'no add-on for this router yet; NetBot will use dish and network monitoring'
$MSG.ROUTER_UNSURE = 'no router chosen; NetBot will use dish and network monitoring'
$MSG.ROUTER_FOUND = 'supported router found at {0}'
$MSG.ROUTER_NOT_SUPPORTED = 'no add-on for this router (or not reachable)'
$MSG.ROUTER_TYPE_TEXT = 'Not found. Type its address (Enter to skip)'
$MSG.ROUTER_NO_ANSWER = 'No supported router answered at {0}. NetBot will watch your dish and connection for now. To add the router later, run the installer again.'
$MSG.ROUTER_NO_PW_NEEDED = 'router answers without a password, none stored'
$MSG.ROUTER_PW_ASK = 'The router needs its admin password for client details. Save it in Windows Credential Manager?'
$MSG.ROUTER_PW_TYPE = '  >>> Type your ROUTER admin password and press Enter. Nothing appears while you type; that''s normal.'
$MSG.ROUTER_PW_TYPE_AGAIN = '  >>> Type it again and press Enter.'
$MSG.ROUTER_PW_MISMATCH = 'the two passwords did not match; nothing was stored'
$MSG.ROUTER_PW_SAVED = 'router password saved in Windows Credential Manager'
$MSG.ROUTER_PW_SKIPPED = 'no password saved; NetBot will read what the router shares without one'
$MSG.ROUTER_PW_REJECTED = 'the router did not accept that password; nothing was stored'
$MSG.ROUTER_PW_SAVE_FAILED = 'could not save the password (error {0}); nothing was stored'
$MSG.ROUTER_PW_KEPT = 'a router password was already in Windows Credential Manager; NetBot will use it and leave it in place on uninstall'
$MSG.ROUTER_SKIP = 'skipping router monitoring'
$MSG.CRED_COMMENT = 'NetBot router password'

# ---- install: schedule and first reading
$MSG.OK_CONFIG = 'config: {0}'
$MSG.OK_SCHEDULED = 'scheduled (Task Scheduler: {0})'
$MSG.ERR_SCHEDULE = 'NetBot needs permission to create a scheduled task. Run setup again and choose Yes when Windows asks.'
$MSG.OK_DASHBOARD = 'dashboard: {0} (bookmark it)'
$MSG.WARN_FIRST = 'first reading failed; see {0} after 5 minutes'
$MSG.FIRST_OK = 'OK'
$MSG.FIRST_UNREACHABLE = 'not reachable: '

# ---- install: sleep
$MSG.SLEEP_ASK = 'Keep this PC awake while plugged in, so monitoring has no gaps? (The screen can still turn off.)'
$MSG.OK_SLEEP = 'PC won''t sleep while plugged in (it was set to {0} min; uninstall puts that back)'
$MSG.WARN_SLEEP = 'not changed. You can do it later in Settings > System > Power.'
$MSG.OK_UNCHANGED = 'left unchanged'

# ---- install: finish
$MSG.INSTALL_DONE = "Done. NetBot runs every 5 minutes. To remove it, double-click 'Uninstall NetBot.cmd'."
$MSG.FULL_LOG = 'Full log: {0}'
$MSG.INSTALL_FAILED = 'Install stopped during step {0} ({1}).'
$MSG.INSTALL_FAILED_HINT = "Fix the problem above, then double-click 'Install NetBot.cmd' again. It is safe to run more than once."

# ---- uninstall
$MSG.UNINSTALL_BANNER = "Removing $($MSG.PRODUCT_TITLE) from this PC"
$MSG.UN_STEP_SCHEDULE = 'Stopping NetBot'
$MSG.UN_STEP_CRED = 'Checking Windows Credential Manager'
$MSG.UN_STEP_FILES = 'Removing program files'
$MSG.UN_STEP_HISTORY = 'Your history and dashboard'
$MSG.UN_STOPPED = 'stopped and unscheduled'
$MSG.UN_NOT_SCHEDULED = 'was not scheduled (nothing to stop)'
$MSG.UN_STILL_SCHEDULED = 'Windows still lists the NetBot task; open Task Scheduler and delete {0} by hand.'
$MSG.UN_CRED_REMOVED = 'router password removed from Windows Credential Manager'
$MSG.UN_CRED_KEPT = 'left the router password in Windows Credential Manager (NetBot did not create it)'
$MSG.UN_CRED_NONE = 'no NetBot item in Windows Credential Manager'
$MSG.UN_PROGRAM_REMOVED = 'removed NetBot''s program files'
$MSG.UN_DELETE_ASK = 'NetBot is stopped. Also delete its history and dashboard in {0} (and the synced copy, if any)?'
$MSG.UN_DELETED = 'deleted {0}'
$MSG.UN_KEPT = 'kept your history and dashboard in {0}'
$MSG.UN_SYNC_KEPT = 'Your synced copy (if any) is at: {0}  (delete it yourself if you want)'
$MSG.UN_SLEEP_RESTORED = 'sleep setting put back to {0} min'
$MSG.UN_DONE = 'Done. NetBot has been removed.'
$MSG.UN_FAILED = 'Uninstall did not finish: {0}'

# ---- double-click launchers (.cmd)
$MSG.LAUNCH_DONE_CLOSING = 'Done. This window closes in a moment.'
$MSG.LAUNCH_FAILED = 'Something went wrong (see above). This window stays open so you can read it. Press any key to close it.'

# ---- setup dialogs (WINDOWS-DIALOGS.md; wording is exact). Kicker marks: ● information/OK, ◆ alert.
$MSG.BTN_CONTINUE = 'Continue'
$MSG.BTN_NOT_SURE = "I'm not sure"
$MSG.BTN_NOT_NOW = 'Not now'
$MSG.BTN_TURN_ON = 'Turn On'
$MSG.BTN_SKIP = 'Skip'
$MSG.BTN_SAVE = 'Save'
$MSG.BTN_CLOSE = 'Close'
$MSG.BTN_OPEN_DASHBOARD = 'Open Dashboard'
$MSG.BTN_SHOW_LOG = 'Show Log'
$MSG.BTN_OK = 'OK'
$MSG.D1_KICKER = '●  DISH MONITORING'
$MSG.D1_HEAD = 'Dish monitoring is on'
$MSG.D1_BODY_FOUND = "NetBot found your dish at {0}. Every 5 minutes it checks the dish's status, outages, obstruction, latency, throughput and alerts, plus ping, latency, packet loss and speed tests on your connection."
$MSG.D1_BODY_NOT_YET = "NetBot can't reach your dish at {0} right now. Dish monitoring is still on, and NetBot will keep trying every 5 minutes."
$MSG.D2_KICKER = '●  ROUTER · OPTIONAL'
$MSG.D2_HEAD = 'What router do you have?'
$MSG.D2_BODY = 'Optional. If NetBot has an add-on for your router, it can also show router stats, such as connected devices and Wi-Fi signal. The make and model are usually on a label on the router.'
$MSG.D2_MAKE = 'MAKE'
$MSG.D2_MAKE_CUE = 'Brand on the label'
$MSG.D2_MAKE_NAME = 'Router make'
$MSG.D2_MODEL = 'MODEL'
$MSG.D2_MODEL_CUE = 'For example X100'
$MSG.D2_MODEL_NAME = 'Router model'
$MSG.D2_HINT = 'Not sure? Dish and network monitoring work without it.'
$MSG.D3A_KICKER = '●  ROUTER ADD-ON FOUND'
$MSG.D3A_HEAD = 'There is an add-on for your router'
$MSG.D3A_BODY = 'NetBot can add router stats for your {0}: WAN connection, connected devices and Wi-Fi signal. You can turn it on now or later.'
$MSG.D3B_KICKER = '●  DISH + NETWORK MONITORING'
$MSG.D3B_HEAD = 'NetBot will use dish and network monitoring'
$MSG.D3B_BODY_NO_ADDON = "There is no add-on for this router yet, and that's fine. NetBot will still watch:"
$MSG.D3B_BODY_NOT_SURE = 'No problem. NetBot will still watch:'
$MSG.D3B_ITEMS = @('Dish status and alerts', 'Outages and obstruction', 'Ping, latency and loss', 'Speed tests')
$MSG.D3B_FOOT = 'You can add a router add-on later by running setup again.'
$MSG.D4_KICKER = '●  ROUTER ADD-ON · OPTIONAL'
$MSG.D4_HEAD = 'Router password (optional)'
$MSG.D4_BODY = "The router add-on can read more router stats with your router's admin password.`r`n`r`nIt is saved only on this computer, in Windows Credential Manager."
$MSG.D4_LABEL = 'ROUTER ADMIN PASSWORD'
$MSG.D4_NAME = 'Router admin password'
$MSG.D4_HINT = 'Characters are hidden as you type. Skip if you prefer. The add-on then shows only what the router shares without a password.'
$MSG.D4_ERR_EMPTY = '◆  Type the password, or choose Skip.'
$MSG.D4_ERR_SAVE = '◆  NetBot could not save the password (error {0}). Nothing was stored. Try again, or choose Skip.'
$MSG.D4_ERR_REJECTED = '◆  The router did not accept that password. Try again, or choose Skip.'
$MSG.D5_KICKER = '●  OK · INSTALLED'
$MSG.D5_HEAD = 'NetBot is installed'
$MSG.D5_BODY = 'NetBot checks your dish and connection every 5 minutes. Bookmark the dashboard so you can find it later.'
$MSG.D5_CHIP_DISH = 'DISH · ON'
$MSG.D5_CHIP_NETWORK = 'NETWORK CHECKS · ON'
$MSG.D5_CHIP_ROUTER_ON = 'ROUTER ADD-ON · ON'
$MSG.D5_CHIP_ROUTER_OFF = 'ROUTER ADD-ON · OFF'
$MSG.D6_KICKER = '◆  ALERT · INSTALL FAILED'
$MSG.D6_HEAD = 'NetBot could not finish installing'
$MSG.D6_BODY = 'NetBot stopped before it finished. Details are in:'
$MSG.D6_LOG_NAME = 'Install log location'
