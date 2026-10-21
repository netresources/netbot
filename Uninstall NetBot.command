#!/bin/bash
# Double-click to uninstall NetBot. It runs uninstall.sh from this same folder. On success it moves
# this downloaded NetBot folder to the Trash (recoverable) and closes this Terminal window after a
# short pause. If something fails, nothing is trashed and the window stays open with the error.
# Set NETBOT_NO_AUTOCLOSE=1 to always keep the window open, NETBOT_NO_TRASH=1 to keep the folder.
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
cd "$DIR" || exit 1
. ./strings/messages.sh
. ./lib/autoclose.sh
bash ./uninstall.sh
rc=$?
if [ "$rc" -ne 0 ]; then
  echo
  echo "$MSG_LAUNCH_FAILED"
  exit "$rc"
fi
cd "$HOME" || exit 0
# Move the downloaded installer folder to the Trash via Finder, only if it really is the NetBot download.
if [ -z "${NETBOT_NO_TRASH:-}" ] && [ -f "$DIR/install.sh" ] && [ -f "$DIR/uninstall.sh" ] && command -v osascript >/dev/null 2>&1; then
  osascript - "$DIR" <<'AS' >/dev/null 2>&1 || true
-- netbot:trash
on run argv
  tell application "Finder" to delete (POSIX file (item 1 of argv) as alias)
end run
AS
fi
echo
netbot_autoclose
exit 0
