#!/usr/bin/env bash
# Tests for .archon/scripts/supervisor-ctl.sh (owner decision 2026-10-20, D15; ROADMAP R20: rollback is
# `supervisor-ctl.sh pause` or `uninstall`). systemctl is a stub on PATH that logs its calls; the unit folder and the
# state folder are throwaway. Installing is never done by the script: `install`, `live` and `recover-on` only print.
# Usage: bash .archon/scripts/test/supervisor-ctl.test.sh   (exit 0 = all pass)
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ctl=$repo/.archon/scripts/supervisor-ctl.sh
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
check() { # check <name> <condition exit code> [<detail>]
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; [ -n "${3:-}" ] && sed 's/^/    /' <<< "$3"; fi
}
export C=$root/c; mkdir -p "$C" "$root/bin" "$root/units"
cat > "$root/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$C/log"
case "$*" in *is-enabled*) echo enabled ;; *is-active*) echo active ;; esac
exit 0
STUB
cat > "$root/bin/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >> "$C/log"; exit 1
STUB
chmod +x "$root/bin/"*
export PATH=$root/bin:$PATH SUPERVISOR_STATE_DIR=$root/state SUPERVISOR_UNIT_DIR=$root/units SUPERVISOR_MAIN=$repo
export MERGE_QUEUE_DIR=$root/mq READY_RUNS_DIR=$root/mq/ready

bash "$ctl" 2> /dev/null; check "1 no command exits 2" $([ $? -eq 2 ]; echo $?)
bash "$ctl" start 2> /dev/null; check "1 an unknown command exits 2" $([ $? -eq 2 ]; echo $?)

o=$(bash "$ctl" status); rc=$?
check "2 status works before install" $([ "$rc" -eq 0 ] && grep -q '^mode: shadow' <<< "$o" && grep -q '^timer: not installed' <<< "$o"; echo $?) "$o"
cp "$repo/.archon/systemd/delegator-supervisor."{service,timer} "$root/units/"
o=$(bash "$ctl" status)
check "2 status asks systemd about an installed timer" $(grep -q '^timer: installed, enabled and active' <<< "$o"; echo $?) "$o"

bash "$ctl" pause > /dev/null
check "3 pause creates the paused file" $([ -f "$root/state/paused" ] && bash "$ctl" status | grep -xe 'mode: paused' > /dev/null; echo $?)
bash "$ctl" resume > /dev/null
check "3 resume removes it" $([ ! -e "$root/state/paused" ] && bash "$ctl" status | grep -xe 'mode: shadow' > /dev/null; echo $?)

: > "$C/log"
for c in install live recover-on; do
  o=$(bash "$ctl" "$c"); rc=$?
  check "4 $c prints and exits 0" $([ "$rc" -eq 0 ] && [ -n "$o" ]; echo $?)
done
check "4 install, live and recover-on run nothing" $([ ! -s "$C/log" ]; echo $?) "$(cat "$C/log")"
check "4 install prints the enable command" $(bash "$ctl" install | grep -q 'systemctl --user enable --now delegator-supervisor.timer'; echo $?)
check "4 live prints the root-owned flag" $(bash "$ctl" live | grep -q 'sudo install -o root -g root -m 644 /dev/null /etc/delegator-supervisor/live'; echo $?)
check "4 recover-on prints the recover flag" $(bash "$ctl" recover-on | grep -q '/etc/delegator-supervisor/recover'; echo $?)
check "4 enable appears only in the printed install text" $([ "$(grep -cE 'systemctl --user (enable|start)' "$ctl")" = 1 ] && grep -qx 'systemctl --user enable --now \$timer' "$ctl"; echo $?)

: > "$C/log"; mkdir -p "$root/state"; touch "$root/state/tick.log"
bash "$ctl" uninstall > /dev/null; rc=$?
check "5 uninstall exits 0" "$rc"
check "5 it disables and stops the timer, then reloads" $(grep -qx 'systemctl --user disable --now delegator-supervisor.timer' "$C/log" && grep -qx 'systemctl --user daemon-reload' "$C/log"; echo $?) "$(cat "$C/log")"
check "5 it removes the unit files and keeps the state" $([ ! -e "$root/units/delegator-supervisor.timer" ] && [ ! -e "$root/units/delegator-supervisor.service" ] && [ -f "$root/state/tick.log" ]; echo $?)
bash "$ctl" uninstall > /dev/null; check "5 uninstall twice is fine" $([ $? -eq 0 ]; echo $?)

echo "supervisor-ctl: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
