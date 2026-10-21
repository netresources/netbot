#!/bin/bash
# NetBot installer for macOS. Read-only dish (+ optional Linksys) monitor.
# Please read this file before running it. Run with:  bash install.sh
# Nothing is downloaded except the pinned dish library (checked against its sha256) and Python packages from PyPI.
# Safe to run again: it updates an existing install in place and keeps your history.
# Wording shown to people lives in strings/messages.sh; helpers live in lib/common.sh.
set -euo pipefail

NB_HOME="${NETBOT_HOME:-$HOME/NetBot}"
CLOUD_ROOT="${NETBOT_CLOUD_ROOT:-$HOME/Library/CloudStorage}"
AGENTS_DIR="${NETBOT_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
LABEL="io.netbot.collect"
LIVE_LABEL="io.netbot.live"
LIVE_PORT=8765
KC_SERVICE="netbot-linksys"
KC_ACCOUNT="admin"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_EXTRA="${NETBOT_PIP_EXTRA-matplotlib}"
STEP_TOTAL=9
# shellcheck source=lib/common.sh
. "$SRC_DIR/lib/common.sh"

# Before this script creates or changes anything: our two labels only (no io.netbot.* glob).
# A plist plist_is_ours accepts for this home is replaced later. Any other file stops the install.
# A symlink stops the install too. It is never followed.
nb_foreign_launchagent=0
nb_note_foreign_launchagent() {
  local label="$1"
  local f="$AGENTS_DIR/${label}.plist"
  local msg
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then return 0; fi
  if [ -L "$f" ] || ! plist_is_ours "$f" "$NB_HOME"; then
    msg="$(fmt "$MSG_ERR_LAUNCHAGENT_FOREIGN" "$label" "$f" "$NB_HOME")"
    printf '%s%s\n' "$MSG_ERR_PREFIX" "$msg" >&2
    nb_foreign_launchagent=1
  fi
}
nb_note_foreign_launchagent "$LABEL"
nb_note_foreign_launchagent "$LIVE_LABEL"
[ "$nb_foreign_launchagent" -eq 0 ] || exit 1

STATE="$NB_HOME/.netbot-state"      # what this installer created, so uninstall removes only that
RERUN=false; [ -f "$STATE/installed" ] && RERUN=true
mkdir -p "$NB_HOME" "$STATE"
LOG="$NB_HOME/install.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== NetBot install $(date)"
say "$MSG_INSTALL_BANNER"
$RERUN && echo "  $MSG_INSTALL_RERUN"

final_fail_dialog() {
  gui_notice "$MSG_FINAL_FAIL

$MSG_FINAL_FAIL_DETAILS
$LOG" caution; }
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo
    err "$(fmt "$MSG_INSTALL_FAILED" "$STEP_NUM" "${STEP_NAME:-start}" "$rc")"
    echo "  $MSG_INSTALL_FAILED_HINT"
    echo "  $(fmt "$MSG_FULL_LOG" "$LOG")"
    final_fail_dialog
  fi
}
trap on_exit EXIT

kc_terminal_prompt() { # security reads the password from the keyboard itself (never argv, file, or log)
  osascript -e 'tell application "Terminal" to activate' >/dev/null 2>&1 || true
  echo; echo "$MSG_ROUTER_PW_TYPE_1"; echo "$MSG_ROUTER_PW_TYPE_2"
  if security add-generic-password -U -s "$KC_SERVICE" -a "$KC_ACCOUNT" -l "$MSG_KC_LABEL" -w; then
    USE_PW=true; : > "$STATE/keychain_created"; ok "$MSG_ROUTER_PW_SAVED"
  fi
}

# ---------------------------------------------------------------- 1. checks
step "$MSG_STEP_CHECKS"
if [ "$(uname -s)" != "Darwin" ] && [ -z "${NETBOT_ALLOW_NON_MAC:-}" ]; then die "$MSG_ERR_NOT_MAC"; fi
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,9) else 1)' 2>/dev/null; then
  err "$MSG_ERR_NO_PYTHON"; echo "  $MSG_ERR_NO_PYTHON_2"; exit 1; fi
ok "$(fmt "$MSG_OK_PYTHON" "$(python3 -c 'import platform; print(platform.python_version())')")"
# Dish pin, data keys, and address come from the one constants file (the only file that names the library).
eval "$(python3 "$SRC_DIR/netbot/dish_constants.py" --shell)" || die "$MSG_ERR_CONSTANTS"
LIB_URL="${NETBOT_DISH_LIB_URL:-$DISH_LIB_URL}"          # overrides exist only for the offline tests
LIB_SHA256="${NETBOT_DISH_LIB_SHA256:-$DISH_LIB_SHA256}"
DISH_HOST="${NETBOT_DISH_HOST:-$DISH_DEFAULT_HOST}"
DISH_PORT="${NETBOT_DISH_PORT:-$DISH_PORT}"                 # override only for the offline tests
mkdir -p "$NB_HOME"/{data,logs,dashboard}

# ---------------------------------------------------------------- 2. dish library (pinned + sha256, never bundled)
step "$(fmt "$MSG_STEP_TOOLS" "${DISH_LIB_COMMIT:0:10}")"
TOOLS="$NB_HOME/$DISH_LIB_DIR"
rm -rf "${NB_HOME:?}/$DISH_LIB_LEGACY_DIR"   # git checkout made by NetBot 0.1-0.3; replaced by $TOOLS
if [ -f "$TOOLS/.netbot-sha256" ] && [ "$(cat "$TOOLS/.netbot-sha256")" = "$LIB_SHA256" ] && [ -f "$TOOLS/$DISH_LIB_MODULE.py" ]; then
  ok "$MSG_OK_TOOLS_REUSED"
else
  rm -rf "$TOOLS" "$TOOLS.new" "$TOOLS.tar.gz"   # a half-finished earlier download
  curl -fsSL --retry 2 -m 120 -o "$TOOLS.tar.gz" "$LIB_URL" || { rm -f "$TOOLS.tar.gz"; die "$MSG_ERR_CLONE"; }
  # verify the exact bytes against the pinned sha256 before unpacking anything
  python3 "$SRC_DIR/lib/verify_unpack.py" "$TOOLS.tar.gz" "$LIB_SHA256" "$TOOLS.new" "$DISH_LIB_MODULE" \
    || { rm -rf "$TOOLS.tar.gz" "$TOOLS.new"; die "$MSG_ERR_PIN"; }
  printf '%s\n' "$LIB_SHA256" > "$TOOLS.new/.netbot-sha256"
  rm -f "$TOOLS.tar.gz"; mv "$TOOLS.new" "$TOOLS"
fi
ok "$(fmt "$MSG_OK_PIN" "${DISH_LIB_COMMIT:0:10}" "${LIB_SHA256:0:12}")"

# ---------------------------------------------------------------- 3. venv + code
step "$MSG_STEP_VENV"
if [ -x "$NB_HOME/venv/bin/python" ] && "$NB_HOME/venv/bin/python" -c 'import sys' 2>/dev/null; then ok "$MSG_OK_VENV_REUSED"
else rm -rf "$NB_HOME/venv"; python3 -m venv "$NB_HOME/venv"; fi
if [ -z "${NETBOT_SKIP_PIP_UPGRADE:-}" ]; then  # old pip on macOS python 3.9 may miss wheels
  "$NB_HOME/venv/bin/python" -m pip install --quiet --disable-pip-version-check --upgrade pip || die "$MSG_ERR_PIP"; fi
# shellcheck disable=SC2086
"$NB_HOME/venv/bin/pip" install --quiet --disable-pip-version-check -r "$TOOLS/requirements.txt" $PY_EXTRA || die "$MSG_ERR_PIP"
rm -rf "$NB_HOME/netbot.new"; cp -R "$SRC_DIR/netbot" "$NB_HOME/netbot.new"
rm -rf "$NB_HOME/netbot"; mv "$NB_HOME/netbot.new" "$NB_HOME/netbot"
ok "$(fmt "$MSG_OK_VENV" "$NB_HOME/venv")"

# One-time rewrite of key names used by older versions (config, history, synced copy); a no-op afterwards.
python3 "$NB_HOME/netbot/migrate_legacy.py" "$NB_HOME" || die "$MSG_ERR_MIGRATE"

# ---------------------------------------------------------------- 4. dish
step "$(fmt "$MSG_STEP_DISH" "$DISH_HOST")"
if python3 - "$DISH_HOST" "$DISH_PORT" <<'PY'
import socket, sys
s = socket.socket(); s.settimeout(3)
sys.exit(0 if s.connect_ex((sys.argv[1], int(sys.argv[2]))) == 0 else 1)
PY
then ok "$MSG_OK_DISH"
else warn "$(fmt "$MSG_WARN_DISH_1" "$DISH_HOST" "$DISH_PORT")"; warn "$MSG_WARN_DISH_2"; fi

# ---------------------------------------------------------------- 5. sync folder
step "$MSG_STEP_SYNC"
SYNC_DIR=""
opts=()
if [ -d "$CLOUD_ROOT" ]; then
  while IFS= read -r d; do opts+=("$d"); done < <(find "$CLOUD_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)
fi
if $GUI; then
  names=("$MSG_SYNC_LOCAL_ONLY"); for d in "${opts[@]+"${opts[@]}"}"; do names+=("$(basename "$d")"); done
  choice="$(gui_choose "$MSG_SYNC_PROMPT" "${names[@]}")"
  for d in "${opts[@]+"${opts[@]}"}"; do [ "$(basename "$d")" = "$choice" ] && SYNC_DIR="$d/NetBot"; done
else
  echo "  $MSG_SYNC_PROMPT"
  i=0; for d in "${opts[@]+"${opts[@]}"}"; do i=$((i+1)); echo "  $i) $(basename "$d")"; done
  echo "  0) $MSG_SYNC_LOCAL_ONLY"
  pick="$(ask "$MSG_SYNC_PICK" 0)"
  if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#opts[@]}" ]; then SYNC_DIR="${opts[$((pick-1))]}/NetBot"; fi
fi
if [ -n "$SYNC_DIR" ]; then
  [ -d "$SYNC_DIR" ] || { mkdir -p "$SYNC_DIR"; printf '%s\n' "$SYNC_DIR" >> "$STATE/sync_dirs_created"; }
  ok "$(fmt "$MSG_OK_SYNC" "$SYNC_DIR")"
else ok "$MSG_OK_LOCAL"; fi

# ---------------------------------------------------------------- 6. Linksys (optional)
step "$MSG_STEP_ROUTER"
ROUTER_HOST=""; USE_PW=false
jnap() { # jnap host action [auth-header] -> prints body
  local h=(-H "Content-Type: application/json" -H "X-JNAP-Action: http://linksys.com/jnap/$2")
  [ -n "${3:-}" ] && h+=(-H "X-JNAP-Authorization: $3")
  curl -s -m 4 -X POST "${h[@]}" -d '{}' "http://$1/JNAP/" 2>/dev/null || true; }
jnap_result() { python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("result",""))
except Exception: print("NOT_JSON")'; }
if confirm "$MSG_ROUTER_ASK" y; then
  gw="$( (route -n get default 2>/dev/null || ip route 2>/dev/null) | awk '/gateway:/{print $2} /^default/{print $3}' | head -1)"
  cands="${NETBOT_ROUTER_CANDIDATES:-$gw 192.168.1.1 10.0.0.1 192.168.0.1 myrouter.local}"
  for h in $cands; do
    [ -n "$h" ] || continue
    r="$(jnap "$h" core/GetDeviceInfo | jnap_result)"
    if [ "$r" = "OK" ]; then ROUTER_HOST="$h"; ok "$(fmt "$MSG_ROUTER_FOUND" "$h")"; break; fi
    printf '  - %s: %s\n' "$h" "$( [ "$r" = "NOT_JSON" ] && echo "$MSG_ROUTER_NOT_SUPPORTED" || echo "$r")"
  done
  if [ -z "$ROUTER_HOST" ]; then
    if $GUI; then m="$(gui_text "$MSG_ROUTER_TYPE_GUI")"
    else m="$(ask "$MSG_ROUTER_TYPE_TEXT" "")"; fi
    if [ -n "$m" ] && [ "$(jnap "$m" core/GetDeviceInfo | jnap_result)" = "OK" ]; then ROUTER_HOST="$m"; ok "$(fmt "$MSG_ROUTER_FOUND" "$m")"
    elif [ -n "$m" ]; then gui_notice "$(fmt "$MSG_ROUTER_NO_ANSWER_GUI" "$m")"; fi
  fi
  if [ -n "$ROUTER_HOST" ]; then
    r="$(jnap "$ROUTER_HOST" networkconnections/GetNetworkConnections | jnap_result)"
    if [ "$r" = "OK" ]; then ok "$MSG_ROUTER_NO_PW_NEEDED"
    elif kc_exists "$KC_SERVICE" "$KC_ACCOUNT" && [ ! -f "$STATE/keychain_created" ]; then
      USE_PW=true; ok "$MSG_ROUTER_PW_KEPT"    # someone else's item: use it, never replace or remove it
    elif $GUI; then
      # Native hidden-answer dialog + SecItemAdd inside one osascript process (see netbot/keychain_dialog.js).
      kc="$(osascript -l JavaScript "$SRC_DIR/netbot/keychain_dialog.js" "$KC_SERVICE" "$KC_ACCOUNT" "$ROUTER_HOST" "$MSG_TITLE" 2>/dev/null || echo "ERROR osascript")"
      if [ "$kc" = "OK" ] && kc_exists "$KC_SERVICE" "$KC_ACCOUNT"; then
        USE_PW=true; : > "$STATE/keychain_created"; ok "$MSG_ROUTER_PW_SAVED"
      elif [ "$kc" = "SKIPPED" ]; then warn "$MSG_ROUTER_PW_SKIPPED"
      else warn "$(fmt "$MSG_ROUTER_PW_FALLBACK" "$kc")"; kc_terminal_prompt; fi
    elif confirm "$MSG_ROUTER_PW_ASK" y; then
      kc_terminal_prompt
    fi
  else warn "$MSG_ROUTER_SKIP"; fi
fi

# ---------------------------------------------------------------- 7. config + launchd
step "$MSG_STEP_SCHEDULE"
LIVE_LAN=false
if [ "${NETBOT_LIVE_LAN:-}" = "1" ]; then LIVE_LAN=true
elif [ "${NETBOT_LIVE_LAN:-}" = "0" ]; then LIVE_LAN=false
elif [ -f "$NB_HOME/config.toml" ] && awk 'BEGIN { section = "" } /^\[/ { section = $0 } section == "[live]" && /^lan = true/ { found = 1 } END { exit found ? 0 : 1 }' "$NB_HOME/config.toml"; then LIVE_LAN=true; fi
cat > "$NB_HOME/config.toml.new" <<CFG
# Written by install.sh. No secrets in this file.
[paths]
data_dir = "$NB_HOME/data"
sync_dir = "$SYNC_DIR"
$DISH_PATHS_KEY = "$TOOLS"

# The dish monitor is always on (it is NetBot's core); this section only says where the dish is.
[$DISH_CFG_SECTION]
target = "$DISH_HOST:$DISH_PORT"

[router]
enabled = $( [ -n "$ROUTER_HOST" ] && echo true || echo false )
host = "$ROUTER_HOST"
username = "$KC_ACCOUNT"
use_password = $USE_PW
keychain_service = "$KC_SERVICE"

[alerts]
quiet_start = 22
quiet_end = 6

[live]
# Home Wi-Fi access for the live page. Off by default. The access key is not in this file.
lan = $LIVE_LAN
port = $LIVE_PORT
CFG
mv "$NB_HOME/config.toml.new" "$NB_HOME/config.toml"
ok "$(fmt "$MSG_OK_CONFIG" "$NB_HOME/config.toml")"
mkdir -p "$AGENTS_DIR"
PLIST="$AGENTS_DIR/$LABEL.plist"
sed "s|__HOME__|$NB_HOME|g" "$SRC_DIR/io.netbot.collect.plist.template" > "$PLIST.new" && mv "$PLIST.new" "$PLIST"
printf '%s\n' "$PLIST" > "$STATE/plist"
launchctl bootout "$(launchd_domain)/$LABEL" 2>/dev/null || true   # re-run: replace the old job
launchctl bootstrap "$(launchd_domain)" "$PLIST" || die "$MSG_ERR_SCHEDULE"
ok "$(fmt "$MSG_OK_SCHEDULED" "$PLIST")"
LIVE_PLIST="$AGENTS_DIR/$LIVE_LABEL.plist"
sed "s|__HOME__|$NB_HOME|g" "$SRC_DIR/io.netbot.live.plist.template" > "$LIVE_PLIST.new" && mv "$LIVE_PLIST.new" "$LIVE_PLIST"
printf '%s\n' "$LIVE_PLIST" > "$STATE/plist_live"
# Create the key before the live job starts. Do not print the link: this output is copied to install.log.
if [ "$LIVE_LAN" = true ]; then
  (cd "$NB_HOME" && PYTHONPATH="$NB_HOME" NETBOT_CONFIG="$NB_HOME/config.toml" "$NB_HOME/venv/bin/python" -m netbot.live_server --ensure-key)
fi
launchctl bootout "$(launchd_domain)/$LIVE_LABEL" 2>/dev/null || true
launchctl bootstrap "$(launchd_domain)" "$LIVE_PLIST" || die "$MSG_ERR_SCHEDULE"
ok "$(fmt "$MSG_OK_LIVE_SCHEDULED" "$LIVE_PLIST")"
if [ "$LIVE_LAN" = true ]; then
  echo "  $MSG_LIVE_PRINT_LINK"
else
  ok "$(fmt "$MSG_OK_LIVE" "http://localhost:${LIVE_PORT}/")"
  echo "  $MSG_LIVE_LAN_OFF"
fi

# ---------------------------------------------------------------- 8. test + dashboard
step "$MSG_STEP_FIRST"
if (cd "$NB_HOME/netbot" && NETBOT_CONFIG="$NB_HOME/config.toml" NETBOT_FORCE_DASHBOARD=1 "$NB_HOME/venv/bin/python" collect.py); then
  "$NB_HOME/venv/bin/python" - "$NB_HOME/data" "$MSG_FIRST_OK" "$MSG_FIRST_UNREACHABLE" "$DISH_DATA_KEY" <<'PY'
import glob, json, sys
f = sorted(glob.glob(sys.argv[1] + "/*.jsonl"))[-1]
s = json.loads(open(f).read().splitlines()[-1])
for k, label in ((sys.argv[4], "dish"), ("router", "router")):
    if k in s:
        v = s[k]; print(f"  {label:8}: {sys.argv[2] if v.get('reachable') else sys.argv[3] + str(v.get('error',''))[:90]}")
PY
  $GUI || open "$NB_HOME/dashboard/index.html" 2>/dev/null || true
  ok "$(fmt "$MSG_OK_DASHBOARD" "$NB_HOME/dashboard/index.html")"
else warn "$(fmt "$MSG_WARN_FIRST" "$NB_HOME/logs")"; fi

# ---------------------------------------------------------------- 9. sleep (optional)
step "$MSG_STEP_SLEEP"
if confirm "$MSG_SLEEP_ASK" n; then
  if $GUI; then
    if osascript - "$MSG_SLEEP_ADMIN_PROMPT" <<'AS' >/dev/null 2>&1
-- netbot:admin-pmset
on run argv
  do shell script "/usr/bin/pmset -c sleep 0" with prompt (item 1 of argv) with administrator privileges
end run
AS
    then ok "$MSG_OK_SLEEP"; : > "$STATE/pmset_changed"
    else warn "$MSG_WARN_SLEEP_CANCELLED"; fi
  else
    echo "$MSG_SLEEP_SUDO_NOTE"
    if sudo /usr/bin/pmset -c sleep 0; then ok "$MSG_OK_SLEEP"; : > "$STATE/pmset_changed"; else warn "$MSG_WARN_SLEEP"; fi
  fi
else ok "$MSG_OK_UNCHANGED"; fi

date > "$STATE/installed"
say "$MSG_INSTALL_DONE"
fmt "$MSG_FULL_LOG" "$LOG"; echo
if $GUI && gui_final_ok; then open "$NB_HOME/dashboard/index.html" || true; fi
