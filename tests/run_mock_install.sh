#!/bin/bash
# Offline test of the macOS installer, uninstaller, and double-click launchers on Linux with mocks
# (no Mac, no dish, no router). Mocks keep state, so "nothing left behind" is checked for real:
#   launchctl  -> $T/state/launchd/<label>     security -> $T/state/keychain/<service>__<account>
#   osascript  -> logs which NetBot dialog ran (by its "-- netbot:<kind>" tag) and answers it
# The package is copied to a temp folder first, so the Trash step can never touch this checkout.
# Also runs tests/check_anonymous.sh. Usage: bash tests/run_mock_install.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/guibin" "$T/ttybin" "$T/cloud/OneDrive-Example" "$T/cloud/iCloudDrive" "$T/home" \
         "$T/state/launchd" "$T/state/keychain"
PASS=0
pass() { PASS=$((PASS+1)); echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; [ -n "${2:-}" ] && [ -f "$2" ] && cat "$2"; echo "---- mock calls"; cat "$T/calls.log" 2>/dev/null; exit 1; }
check() { local what="$1"; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }

# ---- package copy (shipped files only; work folders of other team members are left out)
mkdir "$T/pkg"
tar -C "$ROOT" --exclude=.git --exclude=_review --exclude=_design --exclude='__pycache__' -cf - . | tar -C "$T/pkg" -xf -
PKG="$T/pkg"

# ---- mocks
for c in open sudo route; do printf '#!/bin/sh\necho "[mock %s] $*" >> "%s/calls.log"\n' "$c" "$T" > "$T/bin/$c"; done
cat > "$T/bin/launchctl" <<MOCK
#!/bin/sh
echo "[mock launchctl] \$*" >> "$T/calls.log"
S="$T/state/launchd"
case "\$1" in
  bootstrap) l="\$(basename "\$3" .plist)"; [ -f "\$3" ] || exit 5; [ -e "\$S/\$l" ] && exit 37; echo "\$3" > "\$S/\$l";;
  bootout)   l="\${2##*/}"; [ -e "\$S/\$l" ] || exit 3; rm -f "\$S/\$l";;
  print)     l="\${2##*/}"; [ -e "\$S/\$l" ] || exit 113;;
  *) exit 0;;
esac
MOCK
cat > "$T/bin/security" <<MOCK
#!/bin/sh
echo "[mock security] \$1" >> "$T/calls.log"
cmd="\$1"; shift; s=""; a=""; w=false
while [ \$# -gt 0 ]; do case "\$1" in -s) s="\$2"; shift;; -a) a="\$2"; shift;; -l) shift;; -w) w=true;; esac; shift; done
f="$T/state/keychain/\${s}__\${a}"
case "\$cmd" in
  add-generic-password)    echo saved > "\$f";;
  find-generic-password)   [ -f "\$f" ] || exit 44; \$w && echo "mock-password"; exit 0;;
  delete-generic-password) [ -f "\$f" ] || exit 44; rm -f "\$f";;
  *) exit 44;;
esac
MOCK
printf '#!/bin/sh\necho Darwin\n' > "$T/guibin/uname"
cat > "$T/guibin/osascript" <<MOCK
#!/bin/sh
if [ "\$1" = "-l" ]; then  # keychain_dialog.js <service> <account> <host> <title>
  echo "[mock osascript] \$*" >> "$T/calls.log"; echo saved > "$T/state/keychain/\${4}__\${5}"; echo OK; exit 0; fi
if [ "\$1" = "-e" ]; then echo "[mock osascript] -e \$*" >> "$T/calls.log"; exit 0; fi
script="\$(cat)"; shift
tag="\$(printf '%s\n' "\$script" | sed -n 's/^-- netbot:\(.*\)/\1/p' | head -1)"
echo "[mock osascript] tag=\$tag args=\$*" >> "$T/calls.log"
case "\$tag" in
  choose)   echo "OneDrive-Example";;
  final-ok) echo "Open Dashboard";;
  text)     echo "";;
  confirm)  case "\$1" in *awake*) echo "\${MOCK_AWAKE:-No}";; *delete*) echo "\${MOCK_DELETE:-Yes}";; *) echo "Yes";; esac;;
  admin-pmset) [ "\${MOCK_AWAKE:-No}" = Yes ] || exit 1;;
  *) :;;
esac
exit 0
MOCK
printf '#!/bin/sh\necho /dev/ttys009\n' > "$T/ttybin/tty"
chmod +x "$T/bin/"* "$T/guibin/"* "$T/ttybin/"*
# Optionally run everything on a specific Python (e.g. 3.9 to match macOS's system python3)
if [ -n "${NETBOT_TEST_PYTHON:-}" ]; then ln -s "$NETBOT_TEST_PYTHON" "$T/bin/python3"; fi

# ---- fake dish library tarball (the real one is downloaded by install.sh on a Mac and checked against
#      the sha256 pinned in netbot/dish_constants.py); laid out like a source tarball: <name>-<commit>/...
eval "$(python3 "$ROOT/netbot/dish_constants.py" --shell)"
LIBTOP="$T/libsrc/fake-dish-lib-$DISH_LIB_COMMIT"; mkdir -p "$LIBTOP"
cp "$ROOT/tests/fake_dish_lib.py" "$LIBTOP/$DISH_LIB_MODULE.py" && : > "$LIBTOP/requirements.txt"
tar -C "$T/libsrc" -czf "$T/dishlib.tar.gz" "fake-dish-lib-$DISH_LIB_COMMIT"
LIB_SHA="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$T/dishlib.tar.gz")"
# fake LAN on free ports (no fixed ports, so parallel runs on one computer cannot answer for each other)
python3 "$ROOT/tests/fake_lan.py" "$T/ports" &
for _ in $(seq 1 100); do [ -s "$T/ports" ] && break; sleep 0.1; done
[ -s "$T/ports" ] || { echo "FAIL: fake LAN did not start"; exit 1; }
. "$T/ports"
export NETBOT_NONINTERACTIVE=1
# fake ping / ip / networkQuality for the network checks (tests/fakebin), so nothing leaves this computer
export PATH="$T/bin:$ROOT/tests/fakebin:$PATH" NETBOT_ALLOW_NON_MAC=1 NETBOT_HOME="$T/home/NetBot" NETBOT_CLOUD_ROOT="$T/cloud" \
  NETBOT_LAUNCH_AGENTS="$T/home/LaunchAgents" NETBOT_DISH_HOST=127.0.0.1 NETBOT_DISH_PORT="$P_DISH" NETBOT_DISH_LIB_URL="file://$T/dishlib.tar.gz" \
  NETBOT_DISH_LIB_SHA256="$LIB_SHA" NETBOT_PIP_EXTRA="" NETBOT_ROUTER_CANDIDATES="127.0.0.1:$P_HTML 127.0.0.1:$P_OPEN"
[ -n "${NETBOT_TEST_PIP_UPGRADE:-}" ] || export NETBOT_SKIP_PIP_UPGRADE=1   # stay offline by default
unset TERM_PROGRAM NETBOT_NO_AUTOCLOSE
PLIST="$NETBOT_LAUNCH_AGENTS/io.netbot.collect.plist"
LIVE_PLIST="$NETBOT_LAUNCH_AGENTS/io.netbot.live.plist"
KC="$T/state/keychain/netbot-linksys__admin"
job_count() { find "$T/state/launchd" -type f | wc -l; }

assert_clean() { # nothing NetBot made is left: files, plist, launchd job, keychain item, synced copy
  local where="$1"
  check "$where: NetBot folder removed"   test ! -e "$NETBOT_HOME"
  check "$where: launchd plist removed"   test ! -e "$PLIST"
  check "$where: live plist removed"      test ! -e "$LIVE_PLIST"
  check "$where: launchd job unloaded"    test "$(job_count)" -eq 0
  check "$where: Keychain item removed"   test ! -e "$KC"
  check "$where: synced copy removed"     test ! -e "$T/cloud/OneDrive-Example/NetBot"
  check "$where: no files left in home"   test -z "$(find "$T/home" -type f)"
}

echo "Using $(python3 --version)"
echo "==== 1. install (text mode): cloud folder, router without password"
printf '1\ny\nn\n' | bash "$PKG/install.sh" > "$T/run1.log" 2>&1 || fail "install exits 0" "$T/run1.log"
check "progress shows numbered steps"     grep -q 'Step 1 of 9: Checking this Mac' "$T/run1.log"
check "progress reaches last step"        grep -q 'Step 9 of 9' "$T/run1.log"
check "router host in config"             grep -q "host = \"127.0.0.1:$P_OPEN\"" "$NETBOT_HOME/config.toml"
check "cloud folder in config"            grep -q 'OneDrive-Example/NetBot' "$NETBOT_HOME/config.toml"
check "no password used"                  grep -q 'use_password = false' "$NETBOT_HOME/config.toml"
check "plist written"                     grep -q '<string>io.netbot.collect</string>' "$PLIST"
check "launchd job loaded"                test -e "$T/state/launchd/io.netbot.collect"
check "live plist written"                grep -q '<string>io.netbot.live</string>' "$LIVE_PLIST"
check "live job loaded"                   test -e "$T/state/launchd/io.netbot.live"
check "live page url printed"             grep -q 'http://localhost:8765/' "$T/run1.log"
check "home wi-fi access off by default"  grep -q 'lan = false' "$NETBOT_HOME/config.toml"
check "dashboard built"                   test -s "$NETBOT_HOME/dashboard/index.html"
check "dashboard shows the product title"   grep -q '<title>NetBot: Connection Monitor</title>' "$NETBOT_HOME/dashboard/index.html"
check "synced latest.json"                grep -q '"reachable": true' "$T/cloud/OneDrive-Example/NetBot/latest.json"
check "no Keychain item created"          test ! -e "$KC"
check "dish library sha256 verified"      grep -q "verified (sha256 ${LIB_SHA:0:12}" "$T/run1.log"
check "dish library unpacked, top folder stripped" test -f "$NETBOT_HOME/$DISH_LIB_DIR/$DISH_LIB_MODULE.py"
check "no download left behind"           test ! -e "$NETBOT_HOME/$DISH_LIB_DIR.tar.gz" -a ! -e "$NETBOT_HOME/$DISH_LIB_DIR.new"
check "config points at the dish library" grep -q "^$DISH_PATHS_KEY = \"$NETBOT_HOME/$DISH_LIB_DIR\"" "$NETBOT_HOME/config.toml"
check "dish monitored (always on)"        python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))[sys.argv[2]]["reachable"] else 1)' "$T/cloud/OneDrive-Example/NetBot/latest.json" "$DISH_DATA_KEY"
echo "venv: $("$NETBOT_HOME/venv/bin/python" --version)"

echo "==== 2. re-install over an existing install (idempotent); old git checkout of the library is replaced"
mkdir -p "$NETBOT_HOME/$DISH_LIB_LEGACY_DIR/.git"
printf '1\ny\nn\n' | bash "$PKG/install.sh" > "$T/run2.log" 2>&1 || fail "re-install exits 0" "$T/run2.log"
check "re-run is recognized"              grep -q 'already installed here' "$T/run2.log"
check "tools reused"                      grep -q 'already downloaded, reusing it' "$T/run2.log"
check "venv reused"                       grep -q 'reusing the existing Python environment' "$T/run2.log"
check "exactly two launchd jobs"          test "$(job_count)" -eq 2
check "exactly two plists"                test "$(find "$NETBOT_LAUNCH_AGENTS" -name '*.plist' | wc -l)" -eq 2
check "old job was replaced (bootout)"    test "$(grep -c 'mock launchctl\] bootout' "$T/calls.log")" -ge 1
check "history kept (2 samples)"          test "$(cat "$NETBOT_HOME"/data/*.jsonl | wc -l)" -ge 2
check "config still valid"                grep -q "host = \"127.0.0.1:$P_OPEN\"" "$NETBOT_HOME/config.toml"
check "old library checkout removed"      test ! -e "$NETBOT_HOME/$DISH_LIB_LEGACY_DIR"
LATEST="$T/cloud/OneDrive-Example/NetBot/latest.json"
dish_field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))[sys.argv[2]].get(sys.argv[3]); print(json.dumps(v))' "$LATEST" "$DISH_DATA_KEY" "$1"; }
check "dish: all alerts the dish exposes are listed" test "$(dish_field alerts_known)" = '["dish_water_detected", "install_pending", "is_heating", "lower_signal_than_predicted", "motors_stuck", "thermal_shutdown", "thermal_throttle"]'
check "dish: GPS, signal, pointing, update state recorded" bash -c "[ '$(dish_field gps_sats)' = 11 ] && [ '$(dish_field is_snr_above_noise_floor)' = true ] && [ '$(dish_field direction_elevation)' = 64.0 ] && [ '$(dish_field software_update_state)' = '\"IDLE\"' ]"
check "dish: serial number is not recorded" test "$(dish_field id)" = null
(cd "$NETBOT_HOME/netbot" && NETBOT_CONFIG="$NETBOT_HOME/config.toml" NETBOT_FAKE_DISH_ALERTS=dish_water_detected "$NETBOT_HOME/venv/bin/python" collect.py) \
  > "$T/collect-alert.log" 2>&1 || fail "collector run with a dish alert" "$T/collect-alert.log"
net_field() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["network"].get(sys.argv[2])))' "$LATEST" "$1"; }
check "network: gateway found and pinged"  bash -c "[ '$(net_field gateway_found)' = true ] && [ '$(net_field gateway_ping_ms)' = 1.5 ]"
check "network: internet latency and loss" bash -c "[ '$(net_field internet_latency_ms)' = 42.0 ] && [ '$(net_field internet_loss)' = 0.0 ]"
check "network: speed test ran at most once" grep -q '"speedtest_status": "not due"' "$LATEST"
check "network: speed test result in history" grep -q '"speedtest_down_mbps":182.4' "$NETBOT_HOME"/data/*.jsonl
check "dish: active alert recorded"       test "$(dish_field alerts)" = '["dish_water_detected"]'
check "dish: water alert turns Dish alerts red" python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["tiles"]["Dish alerts"]; sys.exit(0 if t[0]=="red" else 1)' "$T/cloud/OneDrive-Example/NetBot/alerts/active.json"

echo "==== 3. uninstall, delete history: nothing left behind"
printf 'y\n' | bash "$PKG/uninstall.sh" > "$T/un3.log" 2>&1 || fail "uninstall exits 0" "$T/un3.log"
check "uninstall shows steps"             grep -q 'Step 1 of 4: Stopping NetBot' "$T/un3.log"
assert_clean "uninstall"
printf 'y\n' | bash "$PKG/uninstall.sh" > "$T/un3b.log" 2>&1 || fail "second uninstall exits 0" "$T/un3b.log"
check "second uninstall is harmless"      grep -q 'was not scheduled' "$T/un3b.log"

echo "==== 4. router needs a password, local only; uninstall keeping history, then again deleting it"
printf '0\ny\ny\nn\n' | NETBOT_ROUTER_CANDIDATES="127.0.0.1:$P_AUTH" bash "$PKG/install.sh" > "$T/run4.log" 2>&1 || fail "install exits 0" "$T/run4.log"
check "password used"                     grep -q "use_password = true" "$NETBOT_HOME/config.toml"
check "local only"                        grep -q 'sync_dir = ""' "$NETBOT_HOME/config.toml"
check "Keychain item created"             test -e "$KC"
printf 'n\n' | bash "$PKG/uninstall.sh" > "$T/un4.log" 2>&1 || fail "uninstall exits 0" "$T/un4.log"
check "NetBot's Keychain item removed"    test ! -e "$KC"
check "plist removed"                     test ! -e "$PLIST"
check "live plist removed"                test ! -e "$LIVE_PLIST"
check "access key removed"                test ! -e "$NETBOT_HOME/live-access.key"
check "job unloaded"                      test "$(job_count)" -eq 0
check "program files removed"             test ! -e "$NETBOT_HOME/venv" -a ! -e "$NETBOT_HOME/netbot" -a ! -e "$NETBOT_HOME/$DISH_LIB_DIR" -a ! -e "$NETBOT_HOME/$DISH_LIB_LEGACY_DIR" -a ! -e "$NETBOT_HOME/config.toml"
check "history kept on request"           test -n "$(ls "$NETBOT_HOME"/data/*.jsonl)"
printf 'y\n' | bash "$PKG/uninstall.sh" > "$T/un4b.log" 2>&1 || fail "uninstall exits 0" "$T/un4b.log"
assert_clean "uninstall after keep"

echo "==== 5. a router password NetBot did not create is used but never removed"
echo saved > "$KC"
printf '0\ny\nn\n' | NETBOT_ROUTER_CANDIDATES="127.0.0.1:$P_AUTH" bash "$PKG/install.sh" > "$T/run5.log" 2>&1 || fail "install exits 0" "$T/run5.log"
check "existing item reused"              grep -q 'already in Keychain' "$T/run5.log"
check "password used"                     grep -q "use_password = true" "$NETBOT_HOME/config.toml"
printf 'y\n' | bash "$PKG/uninstall.sh" > "$T/un5.log" 2>&1 || fail "uninstall exits 0" "$T/un5.log"
check "someone else's item left alone"    test -e "$KC"
check "uninstall says so"                 grep -q 'NetBot did not create it' "$T/un5.log"
rm -f "$KC"; assert_clean "uninstall (foreign item)"

echo "==== 6. no router found, skipped"
printf '0\ny\n\nn\n' | NETBOT_ROUTER_CANDIDATES="127.0.0.1:$P_HTML" bash "$PKG/install.sh" > "$T/run6.log" 2>&1 || fail "install exits 0" "$T/run6.log"
check "router disabled"                   grep -q 'enabled = false' "$NETBOT_HOME/config.toml"
printf 'y\n' | bash "$PKG/uninstall.sh" >/dev/null 2>&1; assert_clean "uninstall"

echo "==== 6c. home Wi-Fi on: key before bootstrap, link stays out of the log"
# lan = true outside [live] must not turn access on. The installer reads this file, then rewrites it.
mkdir -p "$NETBOT_HOME"
cat > "$NETBOT_HOME/config.toml" <<'EOF'
[router]
lan = true

[live]
lan = false
EOF
check "lan = true outside [live] is not detected" \
  bash -c "! awk 'BEGIN { section = \"\" } /^\\[/ { section = \$0 } section == \"[live]\" && /^lan = true/ { found = 1 } END { exit found ? 0 : 1 }' '$NETBOT_HOME/config.toml'"
printf '0\ny\n\nn\n' | NETBOT_ROUTER_CANDIDATES="127.0.0.1:$P_HTML" bash "$PKG/install.sh" > "$T/run6c-off.log" 2>&1 \
  || fail "install with a decoy lan = true exits 0" "$T/run6c-off.log"
check "decoy does not enable [live]"      grep -q 'lan = false' "$NETBOT_HOME/config.toml"
check "decoy does not create a key"       test ! -e "$NETBOT_HOME/live-access.key"
printf '0\ny\n\nn\n' | NETBOT_LIVE_LAN=1 NETBOT_ROUTER_CANDIDATES="127.0.0.1:$P_HTML" bash "$PKG/install.sh" > "$T/run6c.log" 2>&1 \
  || fail "install with home Wi-Fi on exits 0" "$T/run6c.log"
check "[live] section enables access"     awk 'BEGIN { section = "" } /^\[/ { section = $0 } section == "[live]" && /^lan = true/ { found = 1 } END { exit found ? 0 : 1 }' "$NETBOT_HOME/config.toml"
check "access key created"                test -s "$NETBOT_HOME/live-access.key"
check "access key mode 0600"              python3 -c 'import os,sys; m=os.stat(sys.argv[1]).st_mode & 0o777; sys.exit(0 if m==0o600 else 1)' "$NETBOT_HOME/live-access.key"
check "key is not in install.log"        python3 -c 'import pathlib,sys,urllib.parse; key=pathlib.Path(sys.argv[1]).read_text().strip(); log=pathlib.Path(sys.argv[2]).read_text(); run=pathlib.Path(sys.argv[3]).read_text(); needle="key="+urllib.parse.quote(key, safe=""); hint="run python3 -m netbot.live_server --print-link to see your link."; sys.exit(0 if key and needle not in log and key not in log and hint in log and needle not in run and key not in run and hint in run else 1)' "$NETBOT_HOME/live-access.key" "$NETBOT_HOME/install.log" "$T/run6c.log"
check "ensure-key is before live bootstrap" python3 -c 'import pathlib,sys; t=pathlib.Path(sys.argv[1]).read_text().split("LIVE_PLIST=",1)[1]; e,b,p=t.find("-m netbot.live_server --ensure-key"), t.find("launchctl bootstrap"), t.find("-m netbot.live_server --print-link"); sys.exit(0 if 0<=e<b and p<0 else 1)' "$ROOT/install.sh"
cp "$NETBOT_HOME/live-access.key" "$T/lan-key.before"
printf '0\ny\n\nn\n' | NETBOT_ROUTER_CANDIDATES="127.0.0.1:$P_HTML" bash "$PKG/install.sh" > "$T/run6c-again.log" 2>&1 \
  || fail "re-install detects [live] lan = true" "$T/run6c-again.log"
check "[live] section still detected"     awk 'BEGIN { section = "" } /^\[/ { section = $0 } section == "[live]" && /^lan = true/ { found = 1 } END { exit found ? 0 : 1 }' "$NETBOT_HOME/config.toml"
check "existing key bytes kept"           cmp -s "$T/lan-key.before" "$NETBOT_HOME/live-access.key"
check "existing key mode kept"            python3 -c 'import os,sys; m=os.stat(sys.argv[1]).st_mode & 0o777; sys.exit(0 if m==0o600 else 1)' "$NETBOT_HOME/live-access.key"
check "re-run keeps the key out of install.log" python3 -c 'import pathlib,sys,urllib.parse; key=pathlib.Path(sys.argv[1]).read_text().strip(); log=pathlib.Path(sys.argv[2]).read_text(); again=pathlib.Path(sys.argv[3]).read_text(); needle="key="+urllib.parse.quote(key, safe=""); hint="run python3 -m netbot.live_server --print-link to see your link."; sys.exit(0 if key and needle not in log and key not in log and hint in log and needle not in again and key not in again and hint in again else 1)' "$NETBOT_HOME/live-access.key" "$NETBOT_HOME/install.log" "$T/run6c-again.log"
printf 'y\n' | bash "$PKG/uninstall.sh" >/dev/null 2>&1; assert_clean "uninstall after live lan"

echo "==== 6b. upgrade from an older version: old key names are migrated once"
OLD="$(cd "$ROOT/netbot" && python3 -c 'import migrate_legacy as m; print(m.LEGACY_KEY)')"   # the old name lives only there
OLDSYNC="$T/cloud/OneDrive-Example/NetBot"; mkdir -p "$NETBOT_HOME/data" "$OLDSYNC"
printf '[paths]\ndata_dir = "%s/data"\nsync_dir = "%s"\n%s_tools = "%s/old-lib"\n\n[%s]\ntarget = "x:1"\n' \
  "$NETBOT_HOME" "$OLDSYNC" "$OLD" "$NETBOT_HOME" "$OLD" > "$NETBOT_HOME/config.toml"
printf '{"ts": %s, "%s": {"reachable": true, "state": "CONNECTED", "pop_ping_latency_ms": 30}}\n' "$(($(date +%s) - 600))" "$OLD" \
  > "$NETBOT_HOME/data/$(date +%Y-%m).jsonl"
printf '{"ts": 1, "%s": {"reachable": true}}' "$OLD" > "$OLDSYNC/latest.json"
printf '0\ny\n\nn\n' | NETBOT_ROUTER_CANDIDATES="127.0.0.1:$P_HTML" bash "$PKG/install.sh" > "$T/run6b.log" 2>&1 || fail "upgrade install exits 0" "$T/run6b.log"
check "migration ran once"                test -f "$NETBOT_HOME/.netbot-state/migrated-keys"
check "config uses the dish section"      grep -q "^\[$DISH_CFG_SECTION\]" "$NETBOT_HOME/config.toml"
check "old history rewritten, kept"       python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); sys.exit(0 if sys.argv[2] in r and sys.argv[3] not in r and r[sys.argv[2]]["state"]=="CONNECTED" else 1)' \
                                          "$NETBOT_HOME/data/$(date +%Y-%m).jsonl" "$DISH_DATA_KEY" "$OLD"
check "no old key left in home or sync"   bash -c "! grep -rqE '\"$OLD\"|\\[$OLD\\]|${OLD}_tools' '$NETBOT_HOME/data' '$NETBOT_HOME/config.toml' '$OLDSYNC'"
check "dashboard built after upgrade"     test -s "$NETBOT_HOME/dashboard/index.html"
rm -rf "$OLDSYNC"   # made by the "older version" here, not by this install, so uninstall rightly leaves it
printf 'y\n' | bash "$PKG/uninstall.sh" >/dev/null 2>&1; assert_clean "uninstall after upgrade"

echo "==== 7. GUI dialogs (mock osascript, mock Darwin)"
( unset NETBOT_NONINTERACTIVE; PATH="$T/guibin:$PATH" bash "$PKG/install.sh" < /dev/null > "$T/run7.log" 2>&1 ) || fail "GUI install exits 0" "$T/run7.log"
check "cloud picked from list"            grep -q 'OneDrive-Example/NetBot' "$NETBOT_HOME/config.toml"
check "router found"                      grep -q "host = \"127.0.0.1:$P_OPEN\"" "$NETBOT_HOME/config.toml"
check "sleep left unchanged"              grep -q 'left unchanged' "$NETBOT_HOME/install.log"
check "list dialog used"                  grep -q 'tag=choose' "$T/calls.log"
check "final dialog opens dashboard"      grep -q 'mock open.*index.html' "$T/calls.log"
check "dialog text comes from strings"    grep -q 'tag=final-ok args=NetBot is installed' "$T/calls.log"
cp "$T/calls.log" "$T/calls.log.gui7"
( unset NETBOT_NONINTERACTIVE; PATH="$T/guibin:$PATH" bash "$PKG/uninstall.sh" < /dev/null > "$T/un7.log" 2>&1 ) || fail "GUI uninstall exits 0" "$T/un7.log"
check "GUI uninstall asked before deleting" grep -q 'tag=confirm args=NetBot is stopped. Also delete' "$T/calls.log"
assert_clean "GUI uninstall"

echo "==== 8. GUI, router needs password (Keychain dialog), keep-awake Yes"
: > "$T/calls.log"
( unset NETBOT_NONINTERACTIVE; PATH="$T/guibin:$PATH" MOCK_AWAKE=Yes NETBOT_ROUTER_CANDIDATES="127.0.0.1:$P_AUTH" bash "$PKG/install.sh" < /dev/null > "$T/run8.log" 2>&1 ) || fail "GUI install exits 0" "$T/run8.log"
check "password used"                     grep -q 'use_password = true' "$NETBOT_HOME/config.toml"
check "saved via dialog"                  grep -q 'router password saved in Keychain' "$NETBOT_HOME/install.log"
check "keychain_dialog.js called"         grep -q "mock osascript\] -l JavaScript .*keychain_dialog.js netbot-linksys admin 127.0.0.1:$P_AUTH NetBot\$" "$T/calls.log"
check "admin password window for pmset"   grep -q "tag=admin-pmset" "$T/calls.log"
check "sudo not used in GUI mode"         bash -c "! grep -q 'mock sudo' '$T/calls.log'"
check "sleep changed"                     grep -q "won't sleep" "$NETBOT_HOME/install.log"
( unset NETBOT_NONINTERACTIVE; PATH="$T/guibin:$PATH" bash "$PKG/uninstall.sh" < /dev/null > "$T/un8.log" 2>&1 ) || fail "GUI uninstall exits 0" "$T/un8.log"
check "sleep restore hint shown"          grep -q 'NetBot changed the sleep setting' "$T/un8.log"
assert_clean "GUI uninstall (Keychain)"

echo "==== 9. double-click launchers: auto-close"
wait_for() { local i; for i in $(seq 1 50); do grep -q "$1" "$T/calls.log" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
# 9a: not in Terminal.app and no osascript at all (like this box): succeeds, window left open, no error
: > "$T/calls.log"
printf '0\nn\nn\n' | bash "$PKG/Install NetBot.command" > "$T/c9a.log" 2>&1 || fail "launcher exits 0 without osascript" "$T/c9a.log"
check "no-osascript: says close manually" grep -q 'You can close this window' "$T/c9a.log"
check "no-osascript: no close attempt"    bash -c "! grep -q 'tag=autoclose' '$T/calls.log'"
printf 'y\n' | NETBOT_NO_AUTOCLOSE=1 bash "$PKG/Uninstall NetBot.command" > "$T/c9a-u.log" 2>&1 || fail "uninstall launcher exits 0" "$T/c9a-u.log"
assert_clean "uninstall launcher"
# 9b: inside Terminal.app (mocked) on success: closes only the window that owns this tty
: > "$T/calls.log"
printf '0\nn\nn\n' | PATH="$T/ttybin:$T/guibin:$PATH" TERM_PROGRAM=Apple_Terminal NETBOT_AUTOCLOSE_DELAY=0 \
  bash "$PKG/Install NetBot.command" > "$T/c9b.log" 2>&1 || fail "launcher exits 0" "$T/c9b.log"
check "success: announces closing"        grep -q 'This window closes in a moment' "$T/c9b.log"
check "success: closes this tty's window" wait_for 'tag=autoclose args=/dev/ttys009'
# 9c: NETBOT_NO_AUTOCLOSE=1 keeps it open
: > "$T/calls.log"
printf '0\nn\nn\n' | PATH="$T/ttybin:$T/guibin:$PATH" TERM_PROGRAM=Apple_Terminal NETBOT_AUTOCLOSE_DELAY=0 NETBOT_NO_AUTOCLOSE=1 \
  bash "$PKG/Install NetBot.command" > "$T/c9c.log" 2>&1 || fail "launcher exits 0" "$T/c9c.log"
sleep 0.5
check "opt-out: no close attempt"         bash -c "! grep -q 'tag=autoclose' '$T/calls.log'"
# 9d: uninstall launcher in Terminal.app: trash the download folder, then close
: > "$T/calls.log"
printf 'y\n' | PATH="$T/ttybin:$T/guibin:$PATH" TERM_PROGRAM=Apple_Terminal NETBOT_AUTOCLOSE_DELAY=0 \
  bash "$PKG/Uninstall NetBot.command" > "$T/c9d.log" 2>&1 || fail "uninstall launcher exits 0" "$T/c9d.log"
check "uninstall: download folder to Trash" grep -q "tag=trash args=$PKG" "$T/calls.log"
check "uninstall: closes window"          wait_for 'tag=autoclose args=/dev/ttys009'
assert_clean "uninstall launcher (Terminal)"
# 9e: failure keeps the window open with the error and does not try to close
: > "$T/calls.log"
set +e
printf '0\nn\nn\n' | PATH="$T/ttybin:$T/guibin:$PATH" TERM_PROGRAM=Apple_Terminal NETBOT_AUTOCLOSE_DELAY=0 \
  NETBOT_DISH_LIB_SHA256=0000000000000000000000000000000000000000000000000000000000000000 bash "$PKG/Install NetBot.command" > "$T/c9e.log" 2>&1
rc=$?; set -e
sleep 0.5
check "failure: launcher exits non-zero"  test "$rc" -ne 0
check "failure: names the step"           grep -q 'Install stopped during step 2' "$T/c9e.log"
check "failure: clear reason"             grep -q 'not the expected version' "$T/c9e.log"
check "failure: window stays open"        grep -q 'This window stays open' "$T/c9e.log"
check "failure: no close attempt"         bash -c "! grep -q 'tag=autoclose' '$T/calls.log'"
check "failure: nothing unpacked on a bad checksum" test ! -e "$NETBOT_HOME/$DISH_LIB_DIR" -a ! -e "$NETBOT_HOME/$DISH_LIB_DIR.new" -a ! -e "$NETBOT_HOME/$DISH_LIB_DIR.tar.gz"
printf 'y\n' | bash "$PKG/uninstall.sh" >/dev/null 2>&1; assert_clean "cleanup after failed install"

echo "==== 10. user-facing text is kept out of the installer logic"
check "install.sh has no inline dialog text" bash -c "! grep -nE 'display dialog \"' '$ROOT/install.sh' '$ROOT/uninstall.sh' '$ROOT/lib/common.sh'"
check "all MSG_ names used are defined"   bash -c "cd '$ROOT' && for m in \$(grep -ohE '\\\$MSG_[A-Z0-9_]+' install.sh uninstall.sh lib/*.sh *.command | tr -d '\$' | sort -u); do grep -q \"^\$m=\" strings/messages.sh || { echo missing \$m; exit 1; }; done"

echo "==== 11. anonymity scan"
bash "$ROOT/tests/check_anonymous.sh" "$ROOT" > "$T/anon.log" 2>&1 || fail "anonymity scan" "$T/anon.log"
cat "$T/anon.log"
pass "anonymity scan"
# the scan really catches things: plant one of each kind in a scratch copy
mkdir -p "$T/anon" && cp "$ROOT/tests/check_anonymous.sh" "$T/anon/" && mkdir -p "$T/anon/tests" && mv "$T/anon/check_anonymous.sh" "$T/anon/tests/"
# Neutral private term, split so this file does not contain it. The terms file lives in this
# test's temp dir, outside the scanned copy, and is passed only into these checks.
priv_term="acme""widget"
terms="$T/private-terms.txt"
printf '%s\n' '# neutral fixture' '' "(?<![A-Za-z0-9])${priv_term}(?![A-Za-z0-9])" > "$terms"
chmod 600 "$terms"
# (generic samples are split with "" so this file itself stays clean for the scan)
for planted in "Built by ${priv_term} crew" "contact: someone@realcompany"".com" "see https://intranet.somecorp"".net/x" \
               "router at 172.16.4"".20"; do
  printf '%s\n' "$planted" > "$T/anon/sample.txt"
  if env NETBOT_PRIVATE_TERMS="$terms" bash "$T/anon/tests/check_anonymous.sh" "$T/anon" >/dev/null 2>&1; then fail "scan should flag: $planted"; fi
done
pass "scan flags planted identifiers, emails, hosts, IPs"
printf 'notes %sx hash a1%sb\n' "$priv_term" "$priv_term" > "$T/anon/sample.txt"
check "scan ignores lookalikes" env NETBOT_PRIVATE_TERMS="$terms" bash "$T/anon/tests/check_anonymous.sh" "$T/anon"
# allowlist entries are exact file + exact string: the same placeholders pass only in their own file
printf 'example.com 192.168.1.1 t@example.invalid\n' > "$T/anon/tests/run_mock_install.sh"
check "allowed strings pass in their own file" bash "$T/anon/tests/check_anonymous.sh" "$T/anon"
rm -f "$T/anon/tests/run_mock_install.sh"
printf 'example.com 192.168.1.1 t@example.invalid\n' > "$T/anon/sample.txt"
check "allowed strings fail in any other file" bash -c "! bash '$T/anon/tests/check_anonymous.sh' '$T/anon' >/dev/null"
printf 'NetBot: Star''link Monitor\n' > "$T/anon/sample.txt"
check "brand text fails the default (strict) scan" bash -c "! bash '$T/anon/tests/check_anonymous.sh' '$T/anon' >/dev/null"
check "brand text only listed with --report-only-brand" bash "$T/anon/tests/check_anonymous.sh" "$T/anon" --report-only-brand
rm -f "$T/anon/sample.txt"
mkdir -p "$T/anon/vendor" && : > "$T/anon/vendor/star""link_grpc.py"
check "bundled dish library fails the scan" bash -c "! bash '$T/anon/tests/check_anonymous.sh' '$T/anon' >/dev/null"
bash "$ROOT/tests/check_anonymous.sh" --self-test > "$T/anon-self.log" 2>&1 || fail "anonymity scan self-test" "$T/anon-self.log"
cat "$T/anon-self.log"
pass "anonymity scan self-test"

check "app name and product title defined once and shared" bash -c ". '$ROOT/strings/messages.sh' && cd '$ROOT/netbot' && [ \"\$MSG_TITLE\" = \"\$(python3 -c 'import ui_text; print(ui_text.APP_NAME)')\" ] && [ \"\$MSG_PRODUCT_TITLE\" = \"\$(python3 -c 'import ui_text; print(ui_text.PRODUCT_TITLE)')\" ] && [ \"\$MSG_TITLE\" = NetBot ] && [ \"\$MSG_PRODUCT_TITLE\" != NetBot ]"
check "dialog title bars use the app name"   grep -q "tag=final-ok args=NetBot is installed.* NetBot Close " "$T/calls.log.gui7"
check "installer first screen shows the product title" grep -q "NetBot: Connection Monitor installer" "$T/run7.log"
echo "==== 12. network checks and tiles (unit tests, fake ping/ip/networkQuality)"
python3 "$ROOT/tests/test_network_checks.py" > "$T/net.log" 2>&1 || fail "network check unit tests" "$T/net.log"
pass "network check unit tests ($(grep -c ' ok$' "$T/net.log") tests)"

python3 "$ROOT/tests/test_migrate_legacy.py" > "$T/mig.log" 2>&1 || fail "migration unit tests" "$T/mig.log"
pass "migration unit tests ($(grep -c ' ok$' "$T/mig.log") tests)"
echo "==== 13. dashboard theme and layout (no color values outside netbot/theme/ and the Windows dialog fixtures)"
python3 "$ROOT/tests/test_dashboard.py" > "$T/dash.log" 2>&1 || fail "dashboard tests" "$T/dash.log"
pass "dashboard tests ($(grep -c ' ok$' "$T/dash.log") ok, $(grep -c ' skipped ' "$T/dash.log") skipped)"

echo "==== 14. LaunchAgent label collisions: refuse a foreign plist, leave every other label alone"
mkdir -p "$NETBOT_LAUNCH_AGENTS"
calls_bytes() { wc -c < "$T/calls.log" | tr -d ' '; }
# (a) foreign io.netbot.collect.plist: stop before creating or changing anything
foreign_collect="$NETBOT_LAUNCH_AGENTS/io.netbot.collect.plist"
printf 'foreign collect plist, not written by this installer\n' > "$foreign_collect"
cp "$foreign_collect" "$T/foreign-collect.before"
calls_before="$(calls_bytes)"
set +e
printf '0\nn\nn\n' | bash "$PKG/install.sh" > "$T/col-a.out" 2> "$T/col-a.err"
rc=$?
set -e
check "foreign collect: install exits non-zero" test "$rc" -ne 0
check "foreign collect: stderr names the label" grep -F -q 'io.netbot.collect' "$T/col-a.err"
check "foreign collect: stderr names the file" grep -F -q "$foreign_collect" "$T/col-a.err"
check "foreign collect: stderr says nothing was changed" grep -F -q 'Nothing was changed' "$T/col-a.err"
check "foreign collect: stderr says how to resolve" grep -F -q 'Move that file out of LaunchAgents' "$T/col-a.err"
check "foreign collect: message is not on stdout" bash -c "! grep -F -q 'Nothing was changed' '$T/col-a.out'"
check "foreign collect: file byte-identical" cmp -s "$foreign_collect" "$T/foreign-collect.before"
check "foreign collect: no live plist written" test ! -e "$LIVE_PLIST"
check "foreign collect: NetBot home not created" test ! -e "$NETBOT_HOME"
check "foreign collect: install did not start" bash -c "! grep -q 'Step 1 of 9' '$T/col-a.out' '$T/col-a.err'"
check "foreign collect: no launchctl or other mock calls" test "$(calls_bytes)" -eq "$calls_before"
# (b) the same for a foreign io.netbot.live.plist
rm -f "$foreign_collect"
foreign_live="$NETBOT_LAUNCH_AGENTS/io.netbot.live.plist"
printf 'foreign live plist, not written by this installer\n' > "$foreign_live"
cp "$foreign_live" "$T/foreign-live.before"
calls_before="$(calls_bytes)"
set +e
printf '0\nn\nn\n' | bash "$PKG/install.sh" > "$T/col-b.out" 2> "$T/col-b.err"
rc=$?
set -e
check "foreign live: install exits non-zero" test "$rc" -ne 0
check "foreign live: stderr names the label" grep -F -q 'io.netbot.live' "$T/col-b.err"
check "foreign live: stderr names the file" grep -F -q "$foreign_live" "$T/col-b.err"
check "foreign live: stderr says nothing was changed" grep -F -q 'Nothing was changed' "$T/col-b.err"
check "foreign live: stderr says how to resolve" grep -F -q 'Move that file out of LaunchAgents' "$T/col-b.err"
check "foreign live: file byte-identical" cmp -s "$foreign_live" "$T/foreign-live.before"
check "foreign live: no collect plist written" test ! -e "$PLIST"
check "foreign live: NetBot home not created" test ! -e "$NETBOT_HOME"
check "foreign live: no launchctl or other mock calls" test "$(calls_bytes)" -eq "$calls_before"
# (c) other labels are not ours and are not glob-matched. Any non-NetBot label is left
# alone because the installer names its two labels exactly and never globs. The near-miss
# live name is split so ".test" is not a hostname in this file.
rm -f "$foreign_live"
other_collect="$NETBOT_LAUNCH_AGENTS/com.example.other.collect.plist"
other_live="$NETBOT_LAUNCH_AGENTS/io.netbot.live.""test.plist"
printf 'other-label collect plist\n' > "$other_collect"
printf 'other-label live test plist\n' > "$other_live"
cp "$other_collect" "$T/other-collect.before"
cp "$other_live" "$T/other-live.before"
printf '0\nn\nn\n' | bash "$PKG/install.sh" > "$T/col-c.log" 2>&1 || fail "install with other labels exits 0" "$T/col-c.log"
check "other labels: install left the collect plist byte-identical" cmp -s "$other_collect" "$T/other-collect.before"
check "other labels: install left the live-test plist byte-identical" cmp -s "$other_live" "$T/other-live.before"
check "other labels: our collect plist written" grep -F -q 'netbot-installer-managed' "$PLIST"
check "other labels: our live plist written" grep -F -q 'netbot-installer-managed' "$LIVE_PLIST"
printf 'y\n' | bash "$PKG/uninstall.sh" > "$T/col-c-un.log" 2>&1 || fail "uninstall with other labels exits 0" "$T/col-c-un.log"
check "other labels: uninstall left the collect plist byte-identical" cmp -s "$other_collect" "$T/other-collect.before"
check "other labels: uninstall left the live-test plist byte-identical" cmp -s "$other_live" "$T/other-live.before"
check "other labels: our plists removed" test ! -e "$PLIST" -a ! -e "$LIVE_PLIST"
# (d) reinstall over plists this installer wrote for this home still succeeds
printf '0\nn\nn\n' | bash "$PKG/install.sh" > "$T/col-d1.log" 2>&1 || fail "install before reinstall exits 0" "$T/col-d1.log"
printf '0\nn\nn\n' | bash "$PKG/install.sh" > "$T/col-d2.log" 2>&1 || fail "reinstall over our own plists exits 0" "$T/col-d2.log"
check "reinstall: recognized" grep -q 'already installed here' "$T/col-d2.log"
check "reinstall: collect plist still ours" grep -F -q 'netbot-installer-managed' "$PLIST"
check "reinstall: live plist still ours" grep -F -q 'netbot-installer-managed' "$LIVE_PLIST"
check "reinstall: collect plist points at this home" grep -F -q "$NETBOT_HOME/" "$PLIST"
check "reinstall: live plist points at this home" grep -F -q "$NETBOT_HOME" "$LIVE_PLIST"
check "reinstall: other collect plist still byte-identical" cmp -s "$other_collect" "$T/other-collect.before"
check "reinstall: other live-test plist still byte-identical" cmp -s "$other_live" "$T/other-live.before"

echo "==== 15. Legacy unmarked plists: upgrade ours, refuse anything else"
# Plists written before the marker. Ours only when the file name and the Label
# are exactly io.netbot.collect or io.netbot.live and every Program /
# ProgramArguments path is inside this home. The near-miss live name is split
# so ".test" is not a hostname in this file.
# (a) both legacy plists point inside this home: install replaces them with the
# marked templates, then uninstall removes them.
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <!-- legacy-unmarked-collect -->
  <key>Label</key><string>io.netbot.collect</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NETBOT_HOME/venv/bin/python</string>
    <string>$NETBOT_HOME/netbot/collect.py</string>
  </array>
</dict></plist>
EOF
cat > "$LIVE_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <!-- legacy-unmarked-live -->
  <key>Label</key><string>io.netbot.live</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NETBOT_HOME/venv/bin/python</string>
    <string>-m</string>
    <string>netbot.live_server</string>
  </array>
</dict></plist>
EOF
cp "$PLIST" "$T/legacy-collect.before"
cp "$LIVE_PLIST" "$T/legacy-live.before"
printf '0\nn\nn\n' | bash "$PKG/install.sh" > "$T/leg-a.log" 2>&1 || fail "legacy unmarked install exits 0" "$T/leg-a.log"
check "legacy unmarked: install replaced the collect plist" bash -c "! cmp -s '$PLIST' '$T/legacy-collect.before'"
check "legacy unmarked: install replaced the live plist" bash -c "! cmp -s '$LIVE_PLIST' '$T/legacy-live.before'"
check "legacy unmarked: collect plist is marked" grep -F -q 'netbot-installer-managed' "$PLIST"
check "legacy unmarked: live plist is marked" grep -F -q 'netbot-installer-managed' "$LIVE_PLIST"
check "legacy unmarked: collect sentinel gone" bash -c "! grep -F -q 'legacy-unmarked-collect' '$PLIST'"
check "legacy unmarked: live sentinel gone" bash -c "! grep -F -q 'legacy-unmarked-live' '$LIVE_PLIST'"
check "legacy unmarked: collect plist points at this home" grep -F -q "$NETBOT_HOME/" "$PLIST"
check "legacy unmarked: live plist points at this home" grep -F -q "$NETBOT_HOME" "$LIVE_PLIST"
printf 'y\n' | bash "$PKG/uninstall.sh" > "$T/leg-a-un.log" 2>&1 || fail "legacy unmarked uninstall exits 0" "$T/leg-a-un.log"
check "legacy unmarked: uninstall removed both plists" test ! -e "$PLIST" -a ! -e "$LIVE_PLIST"
# (b) legacy unmarked collect plist whose program paths point outside this home.
# Same refusal as any other foreign plist. The file stays byte-identical.
mkdir -p "$NETBOT_LAUNCH_AGENTS"
legacy_outside="$NETBOT_LAUNCH_AGENTS/io.netbot.collect.plist"
cat > "$legacy_outside" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>io.netbot.collect</string>
  <key>ProgramArguments</key>
  <array>
    <string>/outside/venv/bin/python</string>
    <string>/outside/netbot/collect.py</string>
  </array>
</dict></plist>
EOF
cp "$legacy_outside" "$T/legacy-outside.before"
calls_before="$(calls_bytes)"
set +e
printf '0\nn\nn\n' | bash "$PKG/install.sh" > "$T/leg-b.out" 2> "$T/leg-b.err"
rc=$?
set -e
check "legacy outside: install exits non-zero" test "$rc" -ne 0
check "legacy outside: stderr names the label" grep -F -q 'io.netbot.collect' "$T/leg-b.err"
check "legacy outside: stderr names the file" grep -F -q "$legacy_outside" "$T/leg-b.err"
check "legacy outside: stderr says nothing was changed" grep -F -q 'Nothing was changed' "$T/leg-b.err"
check "legacy outside: stderr says how to resolve" grep -F -q 'Move that file out of LaunchAgents' "$T/leg-b.err"
check "legacy outside: message is not on stdout" bash -c "! grep -F -q 'Nothing was changed' '$T/leg-b.out'"
check "legacy outside: file byte-identical" cmp -s "$legacy_outside" "$T/legacy-outside.before"
check "legacy outside: no live plist written" test ! -e "$LIVE_PLIST"
check "legacy outside: NetBot home not created" test ! -e "$NETBOT_HOME"
check "legacy outside: install did not start" bash -c "! grep -q 'Step 1 of 9' '$T/leg-b.out' '$T/leg-b.err'"
check "legacy outside: no launchctl or other mock calls" test "$(calls_bytes)" -eq "$calls_before"
# (c) a near-miss label is not ours. Install and uninstall leave that file
# byte-identical. The name is split so ".test" is not a hostname in this file.
rm -f "$legacy_outside"
live_test="$NETBOT_LAUNCH_AGENTS/io.netbot.live.""test.plist"
printf 'other-label live test plist\n' > "$live_test"
cp "$live_test" "$T/live-test.before"
printf '0\nn\nn\n' | bash "$PKG/install.sh" > "$T/leg-c.log" 2>&1 || fail "install with live-test plist exits 0" "$T/leg-c.log"
check "live-test: install left the plist byte-identical" cmp -s "$live_test" "$T/live-test.before"
check "live-test: our collect plist written" grep -F -q 'netbot-installer-managed' "$PLIST"
check "live-test: our live plist written" grep -F -q 'netbot-installer-managed' "$LIVE_PLIST"
printf 'y\n' | bash "$PKG/uninstall.sh" > "$T/leg-c-un.log" 2>&1 || fail "uninstall with live-test plist exits 0" "$T/leg-c-un.log"
check "live-test: uninstall left the plist byte-identical" cmp -s "$live_test" "$T/live-test.before"
check "live-test: our plists removed" test ! -e "$PLIST" -a ! -e "$LIVE_PLIST"

echo "==== 16. dot segments in program paths are not inside the home"
# The home check is a string prefix. A ProgramArguments path that starts with
# this home and then uses "..", a "/./" segment, or a trailing "/.." must be
# refused for a marked plist and for a legacy unmarked plist. Install exits
# non-zero and does not replace the file. Uninstall leaves that file as it was.
plant_program_plist() { # plant_program_plist <marked|legacy> <bad-path>
  local mode="$1" bad="$2" clean="$NETBOT_HOME/venv/bin/python" marker=""
  rm -f "$PLIST"
  if [ "$mode" = marked ]; then marker="  <!-- netbot-installer-managed -->"; fi
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
$marker
  <key>Label</key><string>io.netbot.collect</string>
  <key>ProgramArguments</key>
  <array>
    <string>$clean</string>
    <string>$bad</string>
  </array>
</dict></plist>
EOF
}
refuse_planted_plist() { # refuse_planted_plist <name>
  local name="$1"
  cp "$PLIST" "$T/${name}.before"
  calls_before="$(calls_bytes)"
  set +e
  printf '0\nn\nn\n' | bash "$PKG/install.sh" > "$T/${name}.out" 2> "$T/${name}.err"
  rc=$?
  set -e
  check "$name: install exits non-zero" test "$rc" -ne 0
  check "$name: stderr names the label" grep -F -q 'io.netbot.collect' "$T/${name}.err"
  check "$name: stderr names the file" grep -F -q "$PLIST" "$T/${name}.err"
  check "$name: stderr says nothing was changed" grep -F -q 'Nothing was changed' "$T/${name}.err"
  check "$name: stderr says how to resolve" grep -F -q 'Move that file out of LaunchAgents' "$T/${name}.err"
  check "$name: message is not on stdout" bash -c "! grep -F -q 'Nothing was changed' '$T/${name}.out'"
  check "$name: install left the plist byte-identical" cmp -s "$PLIST" "$T/${name}.before"
  check "$name: no live plist written" test ! -e "$LIVE_PLIST"
  check "$name: NetBot home not created" test ! -e "$NETBOT_HOME"
  check "$name: install did not start" bash -c "! grep -q 'Step 1 of 9' '$T/${name}.out' '$T/${name}.err'"
  check "$name: no launchctl or other mock calls" test "$(calls_bytes)" -eq "$calls_before"
  set +e
  printf 'y\n' | bash "$PKG/uninstall.sh" > "$T/${name}-un.out" 2> "$T/${name}-un.err"
  rc=$?
  set -e
  check "$name: uninstall exits 0" test "$rc" -eq 0
  check "$name: uninstall left the plist byte-identical" cmp -s "$PLIST" "$T/${name}.before"
  rm -f "$PLIST"
}
mkdir -p "$NETBOT_LAUNCH_AGENTS"
plant_program_plist marked "$NETBOT_HOME/../outside/python"
refuse_planted_plist marked-dotdot
plant_program_plist marked "$NETBOT_HOME/./venv/bin/python"
refuse_planted_plist marked-dotslash
plant_program_plist marked "$NETBOT_HOME/.."
refuse_planted_plist marked-trailing-dotdot
plant_program_plist legacy "$NETBOT_HOME/../outside/python"
refuse_planted_plist legacy-dotdot
plant_program_plist legacy "$NETBOT_HOME/./venv/bin/python"
refuse_planted_plist legacy-dotslash
plant_program_plist legacy "$NETBOT_HOME/.."
refuse_planted_plist legacy-trailing-dotdot

echo "==== 16b. program executable must be an absolute path inside the home"
# argv0 (or the Program string, when that key is present) must be absolute and
# strictly inside this home. A bare name is not ours, in marked or legacy mode.
# Later arguments keep the old rule, so these plants would have been accepted
# before: the trailing path is inside the home, and -c / "..." are not paths.
# "..." is the command string; it has no slash, so only the bare executable
# makes the plist foreign.
plant_args_plist() { # plant_args_plist <marked|legacy> <program|-> <arg>...
  local mode="$1" program="$2" marker="" program_xml="" args_xml="" arg
  shift 2
  rm -f "$PLIST"
  if [ "$mode" = marked ]; then marker="  <!-- netbot-installer-managed -->"; fi
  if [ "$program" != "-" ]; then
    program_xml="  <key>Program</key><string>${program}</string>"
  fi
  for arg in "$@"; do
    args_xml="${args_xml}    <string>${arg}</string>"$'\n'
  done
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
$marker
  <!-- planted-args -->
$program_xml
  <key>Label</key><string>io.netbot.collect</string>
  <key>ProgramArguments</key>
  <array>
${args_xml}  </array>
</dict></plist>
EOF
}
mkdir -p "$NETBOT_LAUNCH_AGENTS"
plant_args_plist marked - python "$NETBOT_HOME/x"
refuse_planted_plist marked-argv0-python
plant_args_plist legacy - python "$NETBOT_HOME/x"
refuse_planted_plist legacy-argv0-python
plant_args_plist marked - bash -c "..." "$NETBOT_HOME/x"
refuse_planted_plist marked-argv0-bash
plant_args_plist legacy - bash -c "..." "$NETBOT_HOME/x"
refuse_planted_plist legacy-argv0-bash
plant_args_plist marked python python "$NETBOT_HOME/x"
refuse_planted_plist marked-program-python
plant_args_plist legacy python python "$NETBOT_HOME/x"
refuse_planted_plist legacy-program-python
# Program is the executable when the key is present, even if argv0 is inside the home.
plant_args_plist marked python "$NETBOT_HOME/venv/bin/python" "$NETBOT_HOME/x"
refuse_planted_plist marked-program-not-argv0
plant_args_plist legacy python "$NETBOT_HOME/venv/bin/python" "$NETBOT_HOME/x"
refuse_planted_plist legacy-program-not-argv0
# Accepted: absolute venv python as argv0. Install replaces this legacy plist.
plant_args_plist legacy - "$NETBOT_HOME/venv/bin/python" "$NETBOT_HOME/netbot/collect.py"
cp "$PLIST" "$T/argv0-ok.before"
printf '0\nn\nn\n' | bash "$PKG/install.sh" > "$T/argv0-ok.log" 2>&1 || fail "absolute argv0 install exits 0" "$T/argv0-ok.log"
check "absolute argv0: install replaced the collect plist" bash -c "! cmp -s '$PLIST' '$T/argv0-ok.before'"
check "absolute argv0: collect plist is marked" grep -F -q 'netbot-installer-managed' "$PLIST"
check "absolute argv0: planted sentinel gone" bash -c "! grep -F -q 'planted-args' '$PLIST'"
check "absolute argv0: collect plist points at this home" grep -F -q "$NETBOT_HOME/" "$PLIST"
check "absolute argv0: live plist is marked" grep -F -q 'netbot-installer-managed' "$LIVE_PLIST"
check "absolute argv0: live plist points at this home" grep -F -q "$NETBOT_HOME" "$LIVE_PLIST"
printf 'y\n' | bash "$PKG/uninstall.sh" > "$T/argv0-ok-un.log" 2>&1 || fail "absolute argv0 uninstall exits 0" "$T/argv0-ok-un.log"
check "absolute argv0: uninstall removed both plists" test ! -e "$PLIST" -a ! -e "$LIVE_PLIST"
check "absolute argv0: uninstall removed the home" test ! -e "$NETBOT_HOME"

echo "==== 16c. XML entities, CDATA, and a repeated ProgramArguments key"
# launchd decodes entities and CDATA and uses the last ProgramArguments array.
# "&" in any key or string, "<![CDATA[" anywhere, or a second ProgramArguments
# key is not ours. &#46; is a dot. &#103; is the letter g. Install must not
# replace a refused file. Uninstall must leave it.
accept_planted_plist() { # accept_planted_plist <name>
  local name="$1"
  cp "$PLIST" "$T/${name}.before"
  printf '0\nn\nn\n' | bash "$PKG/install.sh" > "$T/${name}.log" 2>&1 || fail "$name install exits 0" "$T/${name}.log"
  check "$name: install replaced the collect plist" bash -c "! cmp -s '$PLIST' '$T/${name}.before'"
  check "$name: collect plist is marked" grep -F -q 'netbot-installer-managed' "$PLIST"
  check "$name: planted sentinel gone" bash -c "! grep -F -q 'planted-args' '$PLIST'"
  check "$name: collect plist points at this home" grep -F -q "$NETBOT_HOME/" "$PLIST"
  check "$name: live plist is marked" grep -F -q 'netbot-installer-managed' "$LIVE_PLIST"
  check "$name: live plist points at this home" grep -F -q "$NETBOT_HOME" "$LIVE_PLIST"
  printf 'y\n' | bash "$PKG/uninstall.sh" > "$T/${name}-un.log" 2>&1 || fail "$name uninstall exits 0" "$T/${name}-un.log"
  check "$name: uninstall removed both plists" test ! -e "$PLIST" -a ! -e "$LIVE_PLIST"
  check "$name: uninstall removed the home" test ! -e "$NETBOT_HOME"
}
plant_xml_plist() { # plant_xml_plist <marked|legacy>  (dict body on stdin)
  local mode="$1" marker=""
  rm -f "$PLIST"
  if [ "$mode" = marked ]; then marker="  <!-- netbot-installer-managed -->"; fi
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<plist version="1.0"><dict>'
    if [ -n "$marker" ]; then printf '%s\n' "$marker"; fi
    printf '%s\n' '  <!-- planted-args -->'
    cat
    printf '%s\n' '</dict></plist>'
  } > "$PLIST"
}
mkdir -p "$NETBOT_LAUNCH_AGENTS"
# Accepted: marked plist, ProgramArguments argv0 is the venv python.
plant_args_plist marked - "$NETBOT_HOME/venv/bin/python" "$NETBOT_HOME/netbot/collect.py"
accept_planted_plist marked-argv0-venv
# Accepted: Program is the venv python and argv0 is the bare word python.
plant_args_plist marked "$NETBOT_HOME/venv/bin/python" python "$NETBOT_HOME/netbot/collect.py"
accept_planted_plist marked-program-venv
plant_args_plist legacy "$NETBOT_HOME/venv/bin/python" python "$NETBOT_HOME/netbot/collect.py"
accept_planted_plist legacy-program-venv
# Refused: entity-encoded ".." as argv0, and as a later argument.
plant_args_plist marked - "$NETBOT_HOME/&#46;&#46;/evil" "$NETBOT_HOME/netbot/collect.py"
refuse_planted_plist marked-entity-dot-argv0
plant_args_plist legacy - "$NETBOT_HOME/&#46;&#46;/evil" "$NETBOT_HOME/netbot/collect.py"
refuse_planted_plist legacy-entity-dot-argv0
plant_args_plist marked - "$NETBOT_HOME/venv/bin/python" "$NETBOT_HOME/&#46;&#46;/evil"
refuse_planted_plist marked-entity-dot-arg
plant_args_plist legacy - "$NETBOT_HOME/venv/bin/python" "$NETBOT_HOME/&#46;&#46;/evil"
refuse_planted_plist legacy-entity-dot-arg
# Refused: entity-encoded Program key added to an otherwise-valid plist.
plant_xml_plist marked <<EOF
  <key>Label</key><string>io.netbot.collect</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NETBOT_HOME/venv/bin/python</string>
    <string>$NETBOT_HOME/netbot/collect.py</string>
  </array>
  <key>Pro&#103;ram</key><string>/usr/bin/evil</string>
EOF
refuse_planted_plist marked-entity-program-key
plant_xml_plist legacy <<EOF
  <key>Label</key><string>io.netbot.collect</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NETBOT_HOME/venv/bin/python</string>
    <string>$NETBOT_HOME/netbot/collect.py</string>
  </array>
  <key>Pro&#103;ram</key><string>/usr/bin/evil</string>
EOF
refuse_planted_plist legacy-entity-program-key
# Refused: a CDATA string. launchd would use the decoded text.
plant_xml_plist marked <<EOF
  <key>Label</key><string>io.netbot.collect</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NETBOT_HOME/venv/bin/python</string>
    <string><![CDATA[/usr/bin/evil]]></string>
  </array>
EOF
refuse_planted_plist marked-cdata-string
plant_xml_plist legacy <<EOF
  <key>Label</key><string>io.netbot.collect</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NETBOT_HOME/venv/bin/python</string>
    <string><![CDATA[/usr/bin/evil]]></string>
  </array>
EOF
refuse_planted_plist legacy-cdata-string
# Refused: two ProgramArguments keys. The first array is valid. launchd uses the last argv0.
plant_xml_plist marked <<EOF
  <key>Label</key><string>io.netbot.collect</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NETBOT_HOME/venv/bin/python</string>
    <string>$NETBOT_HOME/netbot/collect.py</string>
  </array>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/evil</string>
  </array>
EOF
refuse_planted_plist marked-repeat-program-arguments
plant_xml_plist legacy <<EOF
  <key>Label</key><string>io.netbot.collect</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NETBOT_HOME/venv/bin/python</string>
    <string>$NETBOT_HOME/netbot/collect.py</string>
  </array>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/evil</string>
  </array>
EOF
refuse_planted_plist legacy-repeat-program-arguments

echo "==== 17. a LaunchAgent plist that is a symlink is refused"
# The target is a regular file this installer would accept. The LaunchAgent path
# is a symlink to it. Install must exit non-zero without following or replacing
# the link. Uninstall must leave the link and the target, and warn.
mkdir -p "$NETBOT_LAUNCH_AGENTS" "$T/link-target"
link_target="$T/link-target/io.netbot.collect.plist"
cat > "$link_target" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <!-- netbot-installer-managed -->
  <key>Label</key><string>io.netbot.collect</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NETBOT_HOME/venv/bin/python</string>
    <string>$NETBOT_HOME/netbot/collect.py</string>
  </array>
  <key>WorkingDirectory</key><string>$NETBOT_HOME/netbot</string>
</dict></plist>
EOF
rm -f "$PLIST"
ln -s "$link_target" "$PLIST"
cp "$link_target" "$T/symlink-target.before"
link_text="$(readlink "$PLIST")"
calls_before="$(calls_bytes)"
set +e
printf '0\nn\nn\n' | bash "$PKG/install.sh" > "$T/sym.out" 2> "$T/sym.err"
rc=$?
set -e
check "symlink plist: install exits non-zero" test "$rc" -ne 0
check "symlink plist: stderr names the label" grep -F -q 'io.netbot.collect' "$T/sym.err"
check "symlink plist: stderr names the file" grep -F -q "$PLIST" "$T/sym.err"
check "symlink plist: stderr says nothing was changed" grep -F -q 'Nothing was changed' "$T/sym.err"
check "symlink plist: stderr says how to resolve" grep -F -q 'Move that file out of LaunchAgents' "$T/sym.err"
check "symlink plist: message is not on stdout" bash -c "! grep -F -q 'Nothing was changed' '$T/sym.out'"
check "symlink plist: plist is still a symlink" [ -L "$PLIST" ]
check "symlink plist: link text unchanged" test "$(readlink "$PLIST")" = "$link_text"
check "symlink plist: target file byte-identical" cmp -s "$link_target" "$T/symlink-target.before"
check "symlink plist: no live plist written" test ! -e "$LIVE_PLIST"
check "symlink plist: NetBot home not created" test ! -e "$NETBOT_HOME"
check "symlink plist: install did not start" bash -c "! grep -q 'Step 1 of 9' '$T/sym.out' '$T/sym.err'"
check "symlink plist: no launchctl or other mock calls" test "$(calls_bytes)" -eq "$calls_before"
set +e
printf 'y\n' | bash "$PKG/uninstall.sh" > "$T/sym-un.out" 2> "$T/sym-un.err"
rc=$?
set -e
check "symlink plist: uninstall exits 0" test "$rc" -eq 0
check "symlink plist: uninstall left the symlink" [ -L "$PLIST" ]
check "symlink plist: uninstall kept the link text" test "$(readlink "$PLIST")" = "$link_text"
check "symlink plist: uninstall left the target byte-identical" cmp -s "$link_target" "$T/symlink-target.before"
check "symlink plist: uninstall warns" grep -F -q 'symlink' "$T/sym-un.out"
check "symlink plist: warning names the file" grep -F -q "$PLIST" "$T/sym-un.out"
echo "---- $PASS checks passed"
echo "ALL MOCK INSTALL TESTS PASSED"
