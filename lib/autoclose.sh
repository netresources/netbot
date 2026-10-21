# NetBot: close the Terminal window a double-click launcher is running in, after a short pause.
# Sourced by the .command launchers. Called only on success; on failure the window stays open.
# It never fails the caller: no osascript, not in Terminal.app, no tty, or NETBOT_NO_AUTOCLOSE=1
# all mean "leave the window open" and return 0.
#
#   netbot_autoclose            -> 0 always; prints whether the window will close
#
# How: a detached background job waits NETBOT_AUTOCLOSE_DELAY seconds (default 2) so the launcher
# has exited, then asks Terminal to close only the window whose tab owns this tty. Other Terminal
# windows are never touched.
netbot_autoclose() {
  local delay="${NETBOT_AUTOCLOSE_DELAY:-2}" tty_path
  if [ -n "${NETBOT_NO_AUTOCLOSE:-}" ] || [ "${TERM_PROGRAM:-}" != "Apple_Terminal" ] || ! command -v osascript >/dev/null 2>&1; then
    echo "$MSG_LAUNCH_DONE_OPEN"; return 0
  fi
  tty_path="$(tty 2>/dev/null)" || tty_path=""
  case "$tty_path" in /dev/*) ;; *) echo "$MSG_LAUNCH_DONE_OPEN"; return 0;; esac
  echo "$MSG_LAUNCH_DONE_CLOSING"
  ( sleep "$delay"
    osascript - "$tty_path" <<'AS' >/dev/null 2>&1
-- netbot:autoclose
on run argv
  set target to item 1 of argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        if tty of t is target then
          close w saving no
          return
        end if
      end repeat
    end repeat
  end tell
end run
AS
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
  return 0
}
