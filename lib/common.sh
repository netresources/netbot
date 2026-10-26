# NetBot shared helpers for install.sh and uninstall.sh (macOS). Sourced, not run.
# Logic only: every word a person sees comes from strings/messages.sh.
# Each AppleScript below starts with a "-- netbot:<kind>" tag so tests can tell dialogs apart.

NB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../strings/messages.sh
. "$NB_LIB_DIR/../strings/messages.sh"

GUI=false
if [ -z "${NETBOT_NONINTERACTIVE:-}" ] && [ "$(uname -s)" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then GUI=true; fi

STEP_NUM=0; STEP_TOTAL="${STEP_TOTAL:-0}"; STEP_NAME=""
step() { # step "title" -> prints "Step N of M: title" and remembers it for error messages
  STEP_NUM=$((STEP_NUM+1)); STEP_NAME="$1"
  # shellcheck disable=SC2059
  printf '\n\033[1m%s\033[0m\n' "$(printf "$MSG_STEP_FMT" "$STEP_NUM" "$STEP_TOTAL" "$1")"; }
say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '%s%s\n' "$MSG_OK_PREFIX" "$*"; }
warn() { printf '%s%s\n' "$MSG_WARN_PREFIX" "$*"; }
err()  { printf '%s%s\n' "$MSG_ERR_PREFIX" "$*"; }
fmt()  { local f="$1"; shift; # shellcheck disable=SC2059
  printf "$f" "$@"; }
die()  { err "$*"; exit 1; }
ask()  { # ask "question" default -> echoes answer
  local a; read -r -p "  $1 [$2]: " a || true; echo "${a:-$2}"; }

confirm() { # confirm "question" default(y/n) -> 0 if yes
  if $GUI; then
    local def="$MSG_BTN_NO"; [ "${2:-n}" = y ] && def="$MSG_BTN_YES"
    [ "$(osascript - "$1" "$MSG_TITLE" "$MSG_BTN_NO" "$MSG_BTN_YES" "$def" <<'AS' 2>/dev/null
-- netbot:confirm
on run argv
  set r to display dialog (item 1 of argv) with title (item 2 of argv) buttons {item 3 of argv, item 4 of argv} default button (item 5 of argv)
  return button returned of r
end run
AS
)" = "$MSG_BTN_YES" ]; return
  fi
  case "$(ask "$1 (y/n)" "${2:-n}")" in [Yy]*) return 0;; *) return 1;; esac; }

gui_text() { # gui_text "question" -> typed text ("" if skipped)
  osascript - "$1" "$MSG_TITLE" "$MSG_BTN_SKIP" "$MSG_BTN_OK" <<'AS' 2>/dev/null || true
-- netbot:text
on run argv
  set r to display dialog (item 1 of argv) with title (item 2 of argv) default answer "" buttons {item 3 of argv, item 4 of argv} default button (item 4 of argv)
  if button returned of r is (item 3 of argv) then return ""
  return text returned of r
end run
AS
}

gui_choose() { # gui_choose "prompt" item... -> chosen item or ""
  osascript - "$MSG_TITLE" "$@" <<'AS' 2>/dev/null | sed 's/^false$//' || true
-- netbot:choose
on run argv
  set opts to items 3 thru -1 of argv
  set r to choose from list opts with title (item 1 of argv) with prompt (item 2 of argv) default items {item 1 of opts}
  if r is false then return "false"
  return item 1 of r
end run
AS
}

gui_notice() { # gui_notice "message" [caution] -> one OK button
  $GUI || return 0
  osascript - "$1" "$MSG_TITLE" "$MSG_BTN_OK" "${2:-note}" <<'AS' >/dev/null 2>&1 || true
-- netbot:notice
on run argv
  if (item 4 of argv) is "caution" then
    display dialog (item 1 of argv) with title (item 2 of argv) buttons {item 3 of argv} default button 1 with icon caution
  else
    display dialog (item 1 of argv) with title (item 2 of argv) buttons {item 3 of argv} default button 1
  end if
end run
AS
}

gui_final_ok() { # -> 0 if the person clicked Open Dashboard
  [ "$(osascript - "$MSG_FINAL_OK" "$MSG_TITLE" "$MSG_BTN_CLOSE" "$MSG_BTN_OPEN_DASHBOARD" <<'AS' 2>/dev/null
-- netbot:final-ok
on run argv
  set r to display dialog (item 1 of argv) with title (item 2 of argv) buttons {item 3 of argv, item 4 of argv} default button (item 4 of argv)
  return button returned of r
end run
AS
)" = "$MSG_BTN_OPEN_DASHBOARD" ]; }

# Keychain helpers (macOS `security`). The password itself never passes through these.
kc_exists() { security find-generic-password -s "$1" -a "$2" >/dev/null 2>&1; }
kc_delete() { security delete-generic-password -s "$1" -a "$2" >/dev/null 2>&1; }

# launchd helpers
launchd_domain() { echo "gui/$(id -u)"; }
launchd_loaded() { launchctl print "$(launchd_domain)/$1" >/dev/null 2>&1; }

# The same comment is in io.netbot.collect.plist.template and io.netbot.live.plist.template.
# A LaunchAgent file is ours for this home when either:
#   - it has this marker and every path string is the home or a file inside it
#     (what the current installer writes), or
#   - it has no marker, the file name is exactly io.netbot.collect.plist or
#     io.netbot.live.plist, the Label string matches that file name, and every
#     Program and ProgramArguments path is inside the home (plists from before
#     the marker existed).
# Both modes also require a program executable that is an absolute path strictly
# inside the home. That executable is the Program string or, when the plist has
# no Program key, the first string in ProgramArguments. It must use a "$home/"
# prefix (the home directory itself is not enough) and it must pass
# plist_program_path_rejected (no "." or ".." segment). A bare word such as
# python or bash, a relative path, or a path outside the home is not ours.
# With neither Program nor ProgramArguments, the file is not ours.
# Later ProgramArguments strings keep the previous rule: a token with no slash
# (-c, -m, a module name) is allowed, and a path-like string must be inside
# the home the same way as before (the home itself still counts for those
# later strings).
# launchd decodes XML entities and CDATA. These parsers do not, so a plist
# that uses them is not ours: the path or key name launchd runs can differ
# from the bytes compared here. Any <key> or <string> whose text contains "&"
# is refused (&#46; is a dot, &#103; is a letter). A file that contains
# "<![CDATA[" anywhere is refused, including outside keys and strings.
# A second ProgramArguments key is refused, the same as a second Program key.
# launchd uses the last array; keeping the first argv0 would disagree.
# A program path counts as inside the home only when it is a plain absolute
# path. Relative paths, a "/../" or "/./" segment, and a trailing "/.." or "/."
# are refused before the home-prefix comparison. That comparison does not
# resolve "." or "..". The check stays on the string: macOS bash 3.2 has no
# GNU realpath and no readlink -f.
# A symlink is not ours. It is never followed.
# Anything else is left untouched. Callers name those two files and never glob.
NB_PLIST_MARKER="<!-- netbot-installer-managed -->"

plist_is_ours() { # plist_is_ours <file> <home> -> 0 when the file is NetBot's for that home
  local f="$1" home="$2"
  [ -n "${f:-}" ] && [ -n "${home:-}" ] || return 1
  if [ -L "$f" ]; then return 1; fi
  [ -f "$f" ] || return 1
  while [ "$home" != "/" ] && [ "${home%/}" != "$home" ]; do home="${home%/}"; done
  [ -n "$home" ] && [ "$home" != "/" ] || return 1
  if grep -F -q -- "$NB_PLIST_MARKER" "$f"; then
    plist_marked_ours "$f" "$home" || return 1
    return 0
  fi
  plist_legacy_ours "$f" "$home" || return 1
  return 0
}

# 0 when a Program or ProgramArguments path must be refused.
# An argument that is not a path (no slash, and not "." or "..") returns 1,
# so flags such as -m stay allowed. "." in these patterns is literal.
plist_program_path_rejected() {
  local path="$1"
  case "$path" in
    .|..|./*|../*|*/*) ;;
    *) return 1;;
  esac
  case "$path" in
    /*) ;;
    *) return 0;;
  esac
  case "$path" in
    */../*|*/./*|*/..|*/.) return 0;;
  esac
  return 1
}

# 0 when text of a <key> or <string> must be refused. launchd decodes XML
# entities and CDATA; this parser compares the raw text. "&" covers &#46;
# (a dot) and &#103; (a letter). The CDATA pattern is quoted so "[" is literal.
plist_xml_text_rejected() {
  case "$1" in
    *'&'*) return 0;;
  esac
  case "$1" in
    *'<![CDATA['*) return 0;;
  esac
  return 1
}

# 0 when the file contains a CDATA section anywhere, including outside
# <key> and <string> and inside a comment. launchd parses it; this parser
# does not. The brackets are quoted so they are literal. Pure bash 3.2.
plist_cdata_rejected() {
  local raw
  raw=$(cat "$1") || return 0
  case "$raw" in
    *'<![CDATA['*) return 0;;
  esac
  return 1
}

# Print the executable and return 0. Program's string wins when that key is
# present; otherwise the first ProgramArguments string. XML comments are
# removed first so a commented-out path cannot stand in for the real key.
# Returns 1 when neither key yields a string, when the file contains
# "<![CDATA[", when a <key> or <string> contains "&" or "<![CDATA[", when a
# second Program string is present, or when a second ProgramArguments key is
# present. Pure bash 3.2: no realpath, readlink -f, python, or plutil.
plist_program_executable() {
  local f="$1" rest line trim mode expect keybuf strbuf val pre suf prev
  local program_val="" args0="" saw_program_key=0 saw_program=0 saw_args0=0 saw_args_key=0
  if plist_cdata_rejected "$f"; then return 1; fi
  rest=$(cat "$f") || return 1
  rest="${rest//$'\r'/}"
  while :; do
    case "$rest" in
      *'<!--'*'-->'*) ;;
      *) break;;
    esac
    pre="${rest%%'<!--'*}"
    suf="${rest#*'<!--'}"
    case "$suf" in
      *'-->'*) suf="${suf#*'-->'}";;
      *) break;;
    esac
    prev="$rest"
    rest="${pre}${suf}"
    [ "$rest" != "$prev" ] || break
  done
  rest="${rest//</$'\n'<}"
  rest="${rest//>/>$'\n'}"
  mode="out"
  expect="none"
  keybuf=""
  strbuf=""
  while IFS= read -r line || [ -n "$line" ]; do
    trim="$line"
    trim="${trim#"${trim%%[![:space:]]*}"}"
    trim="${trim%"${trim##*[![:space:]]}"}"
    case "$mode" in
      key)
        case "$trim" in
          "</key>")
            keybuf="${keybuf#"${keybuf%%[![:space:]]*}"}"
            keybuf="${keybuf%"${keybuf##*[![:space:]]}"}"
            # Entity-encoded key names (Pro&#103;ram) are not the literal key.
            if plist_xml_text_rejected "$keybuf"; then return 1; fi
            case "$keybuf" in
              Program) saw_program_key=1; expect="program";;
              ProgramArguments)
                # Two ProgramArguments keys: launchd uses the last array.
                # Same refusal as a second Program string below.
                [ "$saw_args_key" -eq 0 ] || return 1
                saw_args_key=1
                expect="args"
                ;;
              *)
                case "$expect" in
                  args|program) expect="none";;
                esac
                ;;
            esac
            mode="out"; keybuf=""
            ;;
          *) keybuf="${keybuf}${line}";;
        esac
        ;;
      str)
        case "$trim" in
          "</string>")
            val="$strbuf"
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%"${val##*[![:space:]]}"}"
            # &#46; is a dot once launchd decodes it. Do not compare it raw.
            if plist_xml_text_rejected "$val"; then return 1; fi
            case "$expect" in
              program)
                # Two Program strings: launchd's choice is ambiguous.
                [ "$saw_program" -eq 0 ] || return 1
                program_val="$val"; saw_program=1; expect="none"
                ;;
              args)
                # First string of the one ProgramArguments array is argv0.
                # A second key already returned above; launchd would use that array.
                if [ "$saw_args0" -eq 0 ]; then args0="$val"; saw_args0=1; fi
                ;;
            esac
            mode="out"; strbuf=""
            ;;
          *) strbuf="${strbuf}${line}";;
        esac
        ;;
      *)
        case "$trim" in
          "<key>") mode="key"; keybuf="";;
          "<string>") mode="str"; strbuf="";;
          "</array>") [ "$expect" = "args" ] && expect="none";;
        esac
        ;;
    esac
  # Here-string: callers capture this function's stdout. A process
  # substitution here breaks under macOS bash 3.2 inside $( ).
  done <<< "$rest"
  if [ "$saw_program_key" -eq 1 ]; then
    [ "$saw_program" -eq 1 ] || return 1
    [ -n "$program_val" ] || return 1
    printf '%s\n' "$program_val"
    return 0
  fi
  if [ "$saw_args0" -eq 1 ]; then
    [ -n "$args0" ] || return 1
    printf '%s\n' "$args0"
    return 0
  fi
  return 1
}

# 0 when the executable is absolute, strictly inside home, and not rejected
# for a "." or ".." segment. The home directory itself is not strictly inside.
plist_exec_in_home() {
  local f="$1" home="$2" exe
  [ -n "${f:-}" ] && [ -n "${home:-}" ] && [ "$home" != "/" ] || return 1
  exe="$(plist_program_executable "$f")" || return 1
  [ -n "$exe" ] || return 1
  if plist_program_path_rejected "$exe"; then return 1; fi
  case "$exe" in
    /*) ;;
    *) return 1;;
  esac
  [ "$exe" != "$home" ] || return 1
  [ "${exe#"$home/"}" != "$exe" ]
}

plist_marked_ours() { # marker present: executable absolute inside home; every path-like string inside home, and at least one is
  # Also not ours: CDATA anywhere, "&" or "<![CDATA[" in a <key> or <string>,
  # or a second ProgramArguments key (launchd uses the last array).
  local f="$1" home="$2" line rest path inside saw=0 keyrest keytext args_keys=0
  if plist_cdata_rejected "$f"; then return 1; fi
  plist_exec_in_home "$f" "$home" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    keyrest="$line"
    while :; do
      case "$keyrest" in
        *"<key>"*"</key>"*) ;;
        *) break;;
      esac
      keyrest="${keyrest#*<key>}"
      keytext="${keyrest%%</key>*}"
      keyrest="${keyrest#*</key>}"
      if plist_xml_text_rejected "$keytext"; then return 1; fi
      keytext="${keytext#"${keytext%%[![:space:]]*}"}"
      keytext="${keytext%"${keytext##*[![:space:]]}"}"
      if [ "$keytext" = "ProgramArguments" ]; then
        # Two ProgramArguments keys: launchd uses the last array.
        args_keys=$((args_keys + 1))
        [ "$args_keys" -eq 1 ] || return 1
      fi
    done
    rest="$line"
    while :; do
      case "$rest" in
        *"<string>"*"</string>"*) ;;
        *) break;;
      esac
      rest="${rest#*<string>}"
      path="${rest%%</string>*}"
      rest="${rest#*</string>}"
      if plist_xml_text_rejected "$path"; then return 1; fi
      if plist_program_path_rejected "$path"; then return 1; fi
      inside=0
      if [ "$path" = "$home" ] || [ "${path#"$home/"}" != "$path" ]; then inside=1; saw=1; fi
      case "$path" in
        */*) [ "$inside" -eq 1 ] || return 1;;
      esac
    done
  done < "$f"
  [ "$saw" -eq 1 ]
}

plist_legacy_ours() { # no marker: exact file name, matching Label, executable absolute inside home
  # Also not ours: CDATA anywhere, "&" or "<![CDATA[" in a <key> or <string>,
  # or a second ProgramArguments key (launchd uses the last array).
  local f="$1" home="$2" base expected line trim rest
  local mode="out" expect="none" keybuf="" strbuf="" label_val="" saw_label=0 saw_path=0 path saw_args_key=0
  base="$(basename -- "$f")"
  case "$base" in
    io.netbot.collect.plist) expected="io.netbot.collect";;
    io.netbot.live.plist) expected="io.netbot.live";;
    *) return 1;;
  esac
  if plist_cdata_rejected "$f"; then return 1; fi
  plist_exec_in_home "$f" "$home" || return 1
  rest=$(cat "$f") || return 1
  rest="${rest//$'\r'/}"
  rest="${rest//</$'\n'<}"
  rest="${rest//>/>$'\n'}"
  while IFS= read -r line || [ -n "$line" ]; do
    trim="$line"
    trim="${trim#"${trim%%[![:space:]]*}"}"
    trim="${trim%"${trim##*[![:space:]]}"}"
    case "$mode" in
      key)
        case "$trim" in
          "</key>")
            keybuf="${keybuf#"${keybuf%%[![:space:]]*}"}"
            keybuf="${keybuf%"${keybuf##*[![:space:]]}"}"
            # Entity-encoded key names (Pro&#103;ram) are not the literal key.
            if plist_xml_text_rejected "$keybuf"; then return 1; fi
            case "$keybuf" in
              Label) expect="label";;
              Program) expect="program";;
              ProgramArguments)
                # Two ProgramArguments keys: launchd uses the last array.
                [ "$saw_args_key" -eq 0 ] || return 1
                saw_args_key=1
                expect="args"
                ;;
              *)
                case "$expect" in
                  args|label|program) expect="none";;
                esac
                ;;
            esac
            mode="out"; keybuf=""
            ;;
          *) keybuf="${keybuf}${line}";;
        esac
        ;;
      str)
        case "$trim" in
          "</string>")
            path="$strbuf"
            path="${path#"${path%%[![:space:]]*}"}"
            path="${path%"${path##*[![:space:]]}"}"
            if plist_xml_text_rejected "$path"; then return 1; fi
            case "$expect" in
              label)
                if [ "$saw_label" -eq 0 ]; then label_val="$path"; saw_label=1
                elif [ "$label_val" != "$path" ]; then return 1; fi
                expect="none"
                ;;
              program|args)
                if plist_program_path_rejected "$path"; then return 1; fi
                case "$path" in
                  */*)
                    if [ "$path" = "$home" ] || [ "${path#"$home/"}" != "$path" ]; then saw_path=1
                    else return 1; fi
                    ;;
                esac
                [ "$expect" = "program" ] && expect="none"
                ;;
            esac
            mode="out"; strbuf=""
            ;;
          *) strbuf="${strbuf}${line}";;
        esac
        ;;
      *)
        case "$trim" in
          "<key>") mode="key"; keybuf="";;
          "<string>") mode="str"; strbuf="";;
          "</array>") [ "$expect" = "args" ] && expect="none";;
        esac
        ;;
    esac
  done < <(printf '%s\n' "$rest")
  [ "$saw_label" -eq 1 ] && [ "$label_val" = "$expected" ] && [ "$saw_path" -eq 1 ]
}
