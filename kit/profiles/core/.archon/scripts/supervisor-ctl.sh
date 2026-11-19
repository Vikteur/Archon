#!/usr/bin/env bash
# Control the delegator supervisor (owner decision 2026-10-20, D15: a supervisor timer, shadow first; ROADMAP R20;
# docs/archon/supervisor.md). It never installs or switches anything on: installing the units and the live and
# recover flags are the owner's acts (a deployed local service), so for those it prints the commands to run.
#   supervisor-ctl.sh status      the mode, live recovery, the delegator session, the heartbeat, the timer, a judge
#                                 running, and the last 5 decisions made for the first time
#   supervisor-ctl.sh pause       create the paused file: each tick writes its heartbeat and does nothing else
#   supervisor-ctl.sh resume      remove the paused file
#   supervisor-ctl.sh uninstall   stop and disable the timer, remove the installed unit files, daemon-reload; the
#                                 session loop does not depend on the supervisor. The state folder is kept.
#   supervisor-ctl.sh install     print the install commands (runs nothing)
#   supervisor-ctl.sh live        print the commands that switch live mode on and off (runs nothing)
#   supervisor-ctl.sh recover-on  print the commands that let live mode run recover-run.sh for real once the D13
#                                 dry-run week is over (runs nothing)
# Exit codes: 0 done, 1 a step failed (uninstall: the rest still ran), 2 usage.
# Overrides: SUPERVISOR_STATE_DIR (as supervisor-tick.sh), SUPERVISOR_UNIT_DIR (~/.config/systemd/user),
# SUPERVISOR_MAIN (the main checkout, default the first `git worktree list` entry).
set -uo pipefail

usage() { echo "supervisor-ctl: $*" >&2; echo "usage: supervisor-ctl.sh status | pause | resume | uninstall | install | live | recover-on" >&2; exit 2; }
[ $# -eq 1 ] || usage "one command"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
main=${SUPERVISOR_MAIN:-$(git -C "$here" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')}
main=${main:-$(cd "$here/../.." && pwd)}
state=${SUPERVISOR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/delegator-supervisor}
units=${SUPERVISOR_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
timer=delegator-supervisor.timer
service=delegator-supervisor.service
has_systemctl() { command -v systemctl > /dev/null 2>&1; }

case "$1" in
  status)
    bash "$main/.archon/scripts/supervisor-tick.sh" status
    if [ -f "$units/$timer" ]; then
      if has_systemctl; then
        echo "timer: installed, $(systemctl --user is-enabled "$timer" 2>/dev/null || echo '?') and $(systemctl --user is-active "$timer" 2>/dev/null || echo '?')"
      else echo "timer: installed (no systemctl to ask)"; fi
    else
      echo "timer: not installed (supervisor-ctl.sh install prints how)"
    fi
    if [ -e "$state/judge.lock" ] && ! flock -n "$state/judge.lock" true 2>/dev/null; then echo "judge: running"; else echo "judge: idle"; fi
    if [ -f "$state/tick.log" ]; then
      echo "last new decisions:"
      jq -c 'select(.new == true or .kind == "judge") | {time, kind, key, result}' "$state/tick.log" 2>/dev/null | tail -n 5 | sed 's/^/  /'
    fi ;;
  pause)
    mkdir -p "$state" && touch "$state/paused" || { echo "supervisor-ctl: could not create $state/paused" >&2; exit 1; }
    echo "paused: ticks do nothing until supervisor-ctl.sh resume" ;;
  resume)
    rm -f "$state/paused" || exit 1
    echo "resumed: the next tick runs in mode $(bash "$main/.archon/scripts/supervisor-tick.sh" status | sed -n 's/^mode: //p')" ;;
  uninstall)
    rc=0
    if has_systemctl; then
      systemctl --user disable --now "$timer" > /dev/null 2>&1 || echo "supervisor-ctl: the timer was not enabled or not loaded"
    else
      echo "supervisor-ctl: no systemctl; removing the unit files only" >&2
    fi
    for u in "$timer" "$service"; do
      if [ -e "$units/$u" ] || [ -L "$units/$u" ]; then rm -f "$units/$u" || { echo "supervisor-ctl: could not remove $units/$u" >&2; rc=1; }; fi
    done
    if has_systemctl; then systemctl --user daemon-reload || rc=1; fi
    echo "uninstalled: no timer; the delegator session's own loop still works. The state folder $state is kept."
    exit "$rc" ;;
  install)
    cat <<EOF
# Install the supervisor timer (the owner runs these; supervisor-ctl.sh never does):
mkdir -p $units
cp $main/.archon/systemd/$service $main/.archon/systemd/$timer $units/
systemctl --user daemon-reload
systemctl --user enable --now $timer
loginctl show-user "\$USER" -p Linger      # Linger=yes, or: sudo loginctl enable-linger "\$USER"
bash $main/.archon/scripts/supervisor-ctl.sh status
EOF
    ;;
  live)
    cat <<'EOF'
# Live mode on (the owner, after a shadow night met the bar in docs/archon/supervisor.md):
sudo install -d -o root -g root -m 755 /etc/delegator-supervisor
sudo install -o root -g root -m 644 /dev/null /etc/delegator-supervisor/live
# Live mode off (back to shadow):
sudo rm /etc/delegator-supervisor/live
EOF
    ;;
  recover-on)
    cat <<'EOF'
# Live recovery on, once the D13 dry-run week is over (live mode logs recoveries until then):
sudo install -d -o root -g root -m 755 /etc/delegator-supervisor
sudo install -o root -g root -m 644 /dev/null /etc/delegator-supervisor/recover
# Live recovery off:
sudo rm /etc/delegator-supervisor/recover
EOF
    ;;
  -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
  *) usage "unknown command: $1" ;;
esac
