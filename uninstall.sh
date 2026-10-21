#!/bin/bash
# Removes NetBot from this Mac. Please read before running:  bash uninstall.sh
# Removes: NetBot's own launchd jobs and their plists for this home (marked plists this installer
# writes, and older unmarked plists it still recognizes), NetBot's program files, the live access
# key, and the router password in Keychain only if NetBot saved it. Asks before deleting your
# history, dashboard, and synced copy.
# Any other LaunchAgent, including a file that reuses one of our labels but is not ours, is left as it was.
# A symlink at one of our plist paths is left as it was, and a warning is printed. It is never followed.
# Safe to run more than once. Wording lives in strings/messages.sh; helpers in lib/common.sh.
set -euo pipefail
NB_HOME="${NETBOT_HOME:-$HOME/NetBot}"
AGENTS_DIR="${NETBOT_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
LABEL="io.netbot.collect"
LIVE_LABEL="io.netbot.live"
KC_SERVICE="netbot-linksys"
KC_ACCOUNT="admin"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SRC_DIR/lib/common.sh"
STATE="$NB_HOME/.netbot-state"
STEP_TOTAL=4

on_exit() { local rc=$?; [ "$rc" -eq 0 ] || err "$(fmt "$MSG_UN_FAILED" "$rc")"; }
trap on_exit EXIT
say "$MSG_UNINSTALL_BANNER"

# ---------------------------------------------------------------- 1. stop the schedule
step "$MSG_UN_STEP_SCHEDULE"
was_loaded=false
still_loaded=false
# Exact file names only. Never a glob, and never a plist plist_is_ours does not accept for this home.
# A symlink is left in place. It is not followed, unloaded, or removed.
unload_our_plist() {
  local f="$1" base label
  [ -n "${f:-}" ] || return 0
  base="$(basename -- "$f")"
  case "$base" in
    "$LABEL.plist"|"$LIVE_LABEL.plist") ;;
    *) return 0;;
  esac
  if [ -L "$f" ]; then
    warn "$(fmt "$MSG_WARN_UN_PLIST_SYMLINK" "$f")"
    return 0
  fi
  plist_is_ours "$f" "$NB_HOME" || return 0
  label="${base%.plist}"
  case "$label" in
    "$LABEL"|"$LIVE_LABEL") ;;
    *) return 0;;
  esac
  if launchd_loaded "$label"; then was_loaded=true; fi
  launchctl bootout "$(launchd_domain)/$label" 2>/dev/null || true
  rm -f -- "$f"
  if launchd_loaded "$label"; then still_loaded=true; fi
}
unload_our_plist "$AGENTS_DIR/$LABEL.plist"
unload_our_plist "$AGENTS_DIR/$LIVE_LABEL.plist"
if [ -f "$STATE/plist" ]; then
  _state_plist="$(cat "$STATE/plist")"
  [ "$_state_plist" = "$AGENTS_DIR/$LABEL.plist" ] || unload_our_plist "$_state_plist"
fi
if [ -f "$STATE/plist_live" ]; then
  _state_plist="$(cat "$STATE/plist_live")"
  [ "$_state_plist" = "$AGENTS_DIR/$LIVE_LABEL.plist" ] || unload_our_plist "$_state_plist"
fi
unset _state_plist
rm -f "$NB_HOME/live-access.key" "$NB_HOME/live-access.key.rotating"
if $still_loaded; then warn "$MSG_WARN_UN_STILL_LOADED"
elif $was_loaded; then ok "$MSG_UN_STOPPED"
else ok "$MSG_UN_NOT_SCHEDULED"; fi

# ---------------------------------------------------------------- 2. Keychain (only if NetBot created it)
step "$MSG_UN_STEP_KC"
if [ -f "$STATE/keychain_created" ]; then
  if kc_delete "$KC_SERVICE" "$KC_ACCOUNT"; then ok "$MSG_UN_KC_REMOVED"; else ok "$MSG_UN_KC_NONE"; fi
  rm -f "$STATE/keychain_created"
elif kc_exists "$KC_SERVICE" "$KC_ACCOUNT"; then ok "$MSG_UN_KC_KEPT"
else ok "$MSG_UN_KC_NONE"; fi

# ---------------------------------------------------------------- 3. program files
step "$MSG_UN_STEP_FILES"
SYNC="$(sed -n 's/^sync_dir = "\(.*\)"/\1/p' "$NB_HOME/config.toml" 2>/dev/null || true)"
PMSET_CHANGED=false; [ -f "$STATE/pmset_changed" ] && PMSET_CHANGED=true
SYNC_CREATED=(); if [ -f "$STATE/sync_dirs_created" ]; then while IFS= read -r d; do [ -n "$d" ] && SYNC_CREATED+=("$d"); done < "$STATE/sync_dirs_created"; fi
# Library folder name used by NetBot 0.1-0.3 (from the constants file; skipped if it can't be read).
LEGACY_LIB="$(python3 "$SRC_DIR/netbot/dish_constants.py" --shell 2>/dev/null | sed -n "s/^DISH_LIB_LEGACY_DIR=//p" | tr -d "'" || true)"
case "$LEGACY_LIB" in ""|*/*|.|..) LEGACY_LIB="";; esac
if [ -d "$NB_HOME" ]; then
  rm -rf "$NB_HOME/venv" "$NB_HOME/netbot" "$NB_HOME/netbot.new" "$NB_HOME/dish-lib" "$NB_HOME/dish-lib.new" "$NB_HOME/dish-lib.tar.gz" \
         ${LEGACY_LIB:+"$NB_HOME/$LEGACY_LIB"} \
         "$NB_HOME/config.toml" "$NB_HOME/config.toml.new" "$STATE"
fi
ok "$MSG_UN_PROGRAM_REMOVED"

# ---------------------------------------------------------------- 4. history (asks first)
step "$MSG_UN_STEP_HISTORY"
if [ ! -e "$NB_HOME" ]; then ok "$(fmt "$MSG_UN_DELETED" "$NB_HOME")"
elif confirm "$(fmt "$MSG_UN_DELETE_ASK" "$NB_HOME")" n; then
  rm -rf "$NB_HOME"; ok "$(fmt "$MSG_UN_DELETED" "$NB_HOME")"
  # Synced copy: only the "NetBot" folder the installer made inside the chosen cloud folder.
  for d in "${SYNC_CREATED[@]+"${SYNC_CREATED[@]}"}" "$SYNC"; do
    case "$d" in */NetBot) [ -d "$d" ] && rm -rf "$d" && ok "$(fmt "$MSG_UN_DELETED" "$d")";; esac
  done
  SYNC=""
else ok "$(fmt "$MSG_UN_KEPT" "$NB_HOME")"; fi
[ -n "$SYNC" ] && [ -d "$SYNC" ] && echo "  $(fmt "$MSG_UN_SYNC_KEPT" "$SYNC")"
if $PMSET_CHANGED; then echo "  $MSG_UN_SLEEP_HINT"; elif ! $GUI; then echo "  $MSG_UN_SLEEP_HINT_MAYBE"; fi
say "$MSG_UN_DONE"
gui_notice "$MSG_UN_FINAL_GUI"
