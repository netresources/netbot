#!/bin/bash
# Double-click to install NetBot. It runs install.sh from this same folder.
# All questions appear as pop-up windows. On success this Terminal window closes itself after a
# short pause; if something fails it stays open so you can read the error.
# Set NETBOT_NO_AUTOCLOSE=1 to always keep the window open.
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
cd "$DIR" || exit 1
. ./strings/messages.sh
. ./lib/autoclose.sh
bash ./install.sh
rc=$?
if [ "$rc" -eq 0 ]; then
  echo
  netbot_autoclose
  exit 0
fi
echo
echo "$MSG_LAUNCH_FAILED"
exit "$rc"
