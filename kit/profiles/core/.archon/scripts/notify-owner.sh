#!/usr/bin/env bash
# Ping the owner's phone through ntfy (https://ntfy.sh or a self-hosted server), so a ping needs no live session (owner
# decision D9, 2026-10-20: ntfy, not Archon Web Push; ROADMAP R10). Every script that pings calls this one.
#   notify-owner.sh <info|warn|act> <key> <subject> [body] [--about <subject ref>] [--if-none-open]
#   notify-owner.sh --flush  send the queued info and warn pings as one bundle (notify-digest.timer: 08:00 and 17:30)
#   notify-owner.sh test     send one test ping now (no dedupe, no cap); the owner's setup check
#   notify-owner.sh check    is the config there and safe? prints ok or why not, sends nothing
# The config lives outside the repo and only the owner creates it (a secret is a STOP item): NOTIFY_OWNER_CONFIG, else
# ~/.config/notify-owner/ntfy.env, KEY=VALUE lines from .archon/notify/ntfy.env.example. It is read, never sourced, and
# refused unless the current user owns it and no group or other bit is set (chmod 600). NTFY_URL must be https (plain
# http only to localhost). The topic and the token are never printed or logged; they reach curl on stdin, not argv.
# Level → ntfy priority and tags: info → low (2), warn → high (4), act → urgent (5); NTFY_PRIORITY_<LEVEL> overrides.
# The first https URL in the text, else "PR #<n>" with NOTIFY_PR_BASE (or origin's GitHub URL), is the tap target.
# Personal data: callers pass only ids, PR numbers, run ids and fixed phrases. As a backstop the text is redacted here
# (e-mail addresses, phone numbers, IBANs, national register numbers, URL query strings) and cut to 300/1000 chars.
# Dedupe: a key delivered within its window is not sent again: NOTIFY_DEDUPE_MIN (info, warn; 30) and
# NOTIFY_DEDUPE_MIN_ACT (10). Daily cap NOTIFY_DAILY_CAP (40) deliveries per local day; the last one says so. Quiet
# hours NOTIFY_QUIET=HH-HH (off by default): info and warn are then delivered silently (priority 1); act still rings.
# Open pings (owner decisions of 2026-10-23, docs/memory.md): --about pr:<n>, sha:<hex> or ticket:<id> names what the
# ping is about. Such a ping stays open until that subject is resolved (the pull request merged or closed, the commit
# green by local CI, the ticket Done; checked again at each repeat and at every flush, dropped after NOTIFY_OPEN_DAYS,
# 7): its key is not sent again meanwhile, whatever the window (prints "open", exit 0). --if-none-open skips the ping
# while any ping about the same subject is open. NOTIFY_RESOLVE=<command> answers "resolved?" instead (exit 0 = yes).
# The bundle: act is sent at once; info and warn wait in the queue (prints "queued", exit 0; a key already queued is
# deduped) until --flush sends them as one ping, at the highest level among them, leaving out those about a resolved
# subject. A queue older than NOTIFY_FLUSH_MAX_H (14) hours is flushed by the next ping (a missed timer).
# NOTIFY_BUNDLE=off sends info and warn at once, as before.
# Settings come from the config file; the environment overrides them (the tests do that).
# State under NOTIFY_OWNER_STATE, else ~/.local/state/notify-owner/: sent/<key> (last delivery), day/<date> (count),
# open/<key> (an open ping: subject, level, time), queue.jsonl (the bundle),
# log.jsonl (one JSON line per attempt: time, level, key, result, redacted subject; never the topic or the token).
# It never blocks or fails its caller for long: curl times out after 10 s (NOTIFY_TIMEOUT).
# Exit 0: delivered, queued, open or deduped (prints which, but delivered). Exit 3: not delivered (no or unsafe config, network or HTTP error,
# daily cap); the reason goes to stderr and the log. Exit 2: usage.
set -uo pipefail

prog=notify-owner
usage() {
  [ -n "${1:-}" ] && echo "$prog: $1" >&2
  echo "usage: notify-owner.sh <info|warn|act> <key> <subject> [body] [--about <pr:n|sha:hex|ticket:id>] [--if-none-open] | --flush | test | check" >&2
  exit 2
}

config=${NOTIFY_OWNER_CONFIG:-$HOME/.config/notify-owner/ntfy.env}
state=${NOTIFY_OWNER_STATE:-$HOME/.local/state/notify-owner}
now=${NOTIFY_NOW:-$(date +%s)}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="" level="" key="" subject="" body="" about="" if_none_open=""
case "${1:-}" in
  test) [ $# -eq 1 ] || usage "test takes no arguments"; mode=test level=info key=test
        subject="notify-owner test ping: the phone ping works" ;;
  check) [ $# -eq 1 ] || usage "check takes no arguments"; mode=check ;;
  --flush) [ $# -eq 1 ] || usage "--flush takes no arguments"; mode=flush level=info key=digest subject=digest ;;
  info|warn|act)
        level=$1; shift; pos=()
        while [ $# -gt 0 ]; do
          case "$1" in
            --about) [ $# -ge 2 ] || usage "--about needs a subject ref"; about=$2; shift ;;
            --if-none-open) if_none_open=1 ;;
            --*) usage "unknown option $1" ;;
            *) pos+=("$1") ;;
          esac
          shift
        done
        if [ ${#pos[@]} -lt 2 ] || [ ${#pos[@]} -gt 3 ]; then usage "a ping takes a level, a key, a subject and an optional body"; fi
        mode=ping key=${pos[0]} subject=${pos[1]} body=${pos[2]:-}
        [[ $key =~ ^[A-Za-z0-9._:/-]{1,200}$ ]] || usage "not a key: letters, digits and ._:/- only, 1 to 200"
        [ -n "$subject" ] || usage "the subject is empty"
        [ -z "$about" ] || [[ $about =~ ^(pr:[0-9]+|sha:[0-9a-f]{7,40}|ticket:[A-Za-z0-9._-]{1,60})$ ]] \
          || usage "not a subject ref: pr:<number>, sha:<hex> or ticket:<id>"
        [ -z "$if_none_open" ] || [ -n "$about" ] || usage "--if-none-open needs --about" ;;
  -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac

# --- redaction: the text must not carry personal data; strip control characters, cut to length --------------------
redact() { # redact <max chars> <<< text
  MAX=$1 perl -CSD -0777 -pe '
    s/[\x00-\x1f\x7f]/ /g;
    s{(https?://[^\s?#]+)[?#]\S*}{$1}g;                                        # URL query strings and fragments
    s/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/[redacted]/g;   # e-mail addresses
    s/\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?\b/[redacted]/g;    # IBANs
    s/\b\d{2}\.\d{2}\.\d{2}[- ]\d{3}\.\d{2}\b/[redacted]/g;                        # national register numbers
    s{(?<![\w+])((?:\+|00)?\d[\d ./()-]{6,}\d)(?![\w])}{
      my $m = $1; (my $d = $m) =~ s/\D//g;
      ($m =~ /^(?:\+|00|0)/ && length($d) >= 9) ? "[redacted]" : $m }ge;          # phone numbers (+32 / 0032 / 04..)
    s/ +/ /g; s/^ | $//g; $_ = substr($_, 0, $ENV{MAX});
  '
}

# --- config: read KEY=VALUE lines, never source the file --------------------------------------------------------
declare -A cfg=()
config_problem() { # prints why the config cannot be used, or nothing
  [ -f "$config" ] || { echo "no config (the owner creates it: docs/archon/notify.md)"; return; }
  local owner perm
  owner=$(stat -c %u "$config" 2>/dev/null) perm=$(stat -c %a "$config" 2>/dev/null)
  [ "$owner" = "$(id -u)" ] || { echo "the config is not owned by this user"; return; }
  [[ $perm =~ ^[0-7]*[0-7]00$ ]] || { echo "the config is readable by others (mode $perm): run chmod 600 on it"; return; }
  local line k v
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
    k=${BASH_REMATCH[2]} v=${BASH_REMATCH[3]}
    v=${v%"${v##*[![:space:]]}"}
    if [[ $v =~ ^\"(.*)\"$ ]] || [[ $v =~ ^\'(.*)\'$ ]]; then v=${BASH_REMATCH[1]}; fi
    case "$k" in NTFY_URL|NTFY_TOPIC|NTFY_TOKEN|NTFY_PRIORITY_INFO|NTFY_PRIORITY_WARN|NTFY_PRIORITY_ACT|NOTIFY_DEDUPE_MIN\
      |NOTIFY_DEDUPE_MIN_ACT|NOTIFY_DAILY_CAP|NOTIFY_QUIET|NOTIFY_PR_BASE|NOTIFY_TIMEOUT|NOTIFY_BUNDLE|NOTIFY_FLUSH_MAX_H\
      |NOTIFY_OPEN_DAYS) cfg[$k]=$v ;; esac
  done < "$config"
  local url=${cfg[NTFY_URL]:-} topic=${cfg[NTFY_TOPIC]:-}
  [ -n "$url" ] || { echo "NTFY_URL is not set in the config"; return; }
  [[ $url =~ ^https://[^/[:space:]]+(/[^[:space:]]*)?$ || $url =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]+)?(/.*)?$ ]] \
    || { echo "NTFY_URL must be an https URL (plain http only to localhost)"; return; }
  [[ $topic =~ ^[A-Za-z0-9_-]{20,64}$ ]] \
    || { echo "NTFY_TOPIC must be 20 to 64 letters, digits, - or _ (a random, unguessable name)"; return; }
  [[ ${topic,,} == *change* || ${topic,,} == *example* || ${topic,,} == *placeholder* ]] \
    && { echo "NTFY_TOPIC is still the template's placeholder"; return; }
  [[ ${cfg[NTFY_TOKEN]:-} =~ ^[A-Za-z0-9_.-]*$ ]] || { echo "NTFY_TOKEN has characters a token cannot have"; return; }
}
setting() { # setting <name> <default>: the environment, then the config, then the default
  local e=${!1:-}
  if [ -n "$e" ]; then echo "$e"; elif [ -n "${cfg[$1]:-}" ]; then echo "${cfg[$1]}"; else echo "$2"; fi
}

problem=$(config_problem)
# config_problem ran in a subshell; read the values again in this shell when the file is fine.
[ -z "$problem" ] && config_problem > /dev/null

if [ "$mode" = check ]; then
  if [ -z "$problem" ]; then echo "ok: config at $config (topic and token not shown)"; exit 0; fi
  echo "$prog: not ready: $problem" >&2; exit 3
fi

# --- state and log ------------------------------------------------------------------------------------------------
( umask 077; mkdir -p "$state/sent" "$state/day" "$state/open" ) 2>/dev/null
subject=$(redact 300 <<< "$subject")
[ -n "$body" ] && body=$(redact 1000 <<< "$body")
log_attempt() { # log_attempt <result> [http status]
  ( umask 077
    jq -cn --arg t "$(date -u -d "@$now" +%FT%TZ)" --arg l "$level" --arg k "$key" --arg r "$1" --arg h "${2:-}" \
      --arg s "$subject" --arg a "$about" '{time: $t, level: $l, key: $k, result: $r, http: $h, subject: $s}
      + (if $a == "" then {} else {about: $a} end)' >> "$state/log.jsonl"
  ) 2>/dev/null || true
}
not_delivered() { log_attempt "$1" "${2:-}"; echo "$prog: not delivered: $1" >&2; exit 3; }

[ -n "$problem" ] && not_delivered "$problem"

keyname() { printf '%s' "$1" | tr '/:' '__'; }
keyfile="$state/sent/$(keyname "$key")"
today=$(date -d "@$now" +%F)
dayfile="$state/day/$today"
queue="$state/queue.jsonl"

# One ping at a time, so two callers with the same key cannot both pass the dedupe; give up the lock after 5 s.
{ exec 9>> "$state/lock"; } 2>/dev/null && flock -w 5 9 2>/dev/null

cap=$(setting NOTIFY_DAILY_CAP 40)
count=$(cat "$dayfile" 2>/dev/null || echo 0)
[[ $count =~ ^[0-9]+$ ]] || count=0

# --- open pings: resolved when the pull request is merged or closed, the commit green, the ticket Done ------------
repo=""
origin_repo() {
  [ -n "$repo" ] && return
  local origin
  origin=$(git -C "$here" remote get-url origin 2>/dev/null || true)
  [[ $origin =~ github\.com[:/]([^/]+/[^/]+)$ ]] && repo=${BASH_REMATCH[1]%.git}
}
declare -A answered=()
resolved() { # resolved <subject ref>: exit 0 when it is resolved; an unknown answer keeps it open
  if [ -z "${answered[$1]:-}" ]; then
    answered[$1]=no
    if [ -n "${NOTIFY_RESOLVE:-}" ]; then
      "$NOTIFY_RESOLVE" "$1" > /dev/null 2>&1 && answered[$1]=yes
    else
      origin_repo
      case "$1" in
        pr:*) [ -n "$repo" ] && case "$(timeout 15 gh pr view "${1#pr:}" --repo "$repo" --json state -q .state 2>/dev/null)" in
                MERGED|CLOSED) answered[$1]=yes ;; esac ;;
        sha:*) [ -n "$repo" ] && [ "$(timeout 30 bash "$here/local-ci-status.sh" "$repo" "${1#sha:}" 2>/dev/null \
                 | awk '{ print $1; exit }')" = green ] && answered[$1]=yes ;;
        ticket:*) main=$(git -C "$here" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
                  [ -n "$main" ] && (cd "$main" && timeout 15 backlog task view "${1#ticket:}" --plain 2>/dev/null) \
                    | grep -qiE '^Status: *Done' && answered[$1]=yes ;;
      esac
    fi
  fi
  [ "${answered[$1]}" = yes ]
}
still_open() { # still_open <open file>: is that ping still open? Forgets it when resolved or older than the limit.
  local ref lvl since
  IFS=$'\t' read -r ref lvl since < "$1" 2>/dev/null || { rm -f "$1"; return 1; }
  [[ $since =~ ^[0-9]+$ ]] || since=0
  if [ $((now - since)) -ge $(( $(setting NOTIFY_OPEN_DAYS 7) * 86400 )) ] || resolved "$ref"; then rm -f "$1"; return 1; fi
}
mark_open() { [ -z "$about" ] || ( umask 077; printf '%s\t%s\t%s\n' "$about" "$level" "$now" > "$state/open/$(keyname "$key")" ) 2>/dev/null; }

# --- sending ----------------------------------------------------------------------------------------------------------
send() { # send <message>: posts $level/$subject with that message to ntfy; exits through not_delivered on a failure
  local message=$1 level_upper=${level^^} priority tags quiet click pr_base origin
  priority=$(setting "NTFY_PRIORITY_$level_upper" "$(case "$level" in info) echo 2 ;; warn) echo 4 ;; act) echo 5 ;; esac)")
  case "$level" in info) tags='["information_source"]' ;; warn) tags='["warning"]' ;; act) tags='["rotating_light"]' ;; esac
  quiet=$(setting NOTIFY_QUIET "")
  if [[ $quiet =~ ^([0-9]{1,2})-([0-9]{1,2})$ ]] && [ "$level" != act ]; then
    local from=$((10#${BASH_REMATCH[1]})) to=$((10#${BASH_REMATCH[2]})) hour=$((10#$(date -d "@$now" +%H)))
    if { [ "$from" -le "$to" ] && [ "$hour" -ge "$from" ] && [ "$hour" -lt "$to" ]; } \
      || { [ "$from" -gt "$to" ] && { [ "$hour" -ge "$from" ] || [ "$hour" -lt "$to" ]; }; }; then priority=1; fi
  fi
  [ "$mode" != test ] && [ $((count + 1)) -eq "$cap" ] && message="$message (daily cap reached: later pings today are logged only)"

  click=$(grep -oE 'https://[^ ]+' <<< "$subject $message" | head -1)
  if [ -z "$click" ] && [[ "$subject $message" =~ PR\ \#([0-9]+) ]]; then
    local pr_number=${BASH_REMATCH[1]}
    pr_base=$(setting NOTIFY_PR_BASE "")
    if [ -z "$pr_base" ]; then origin_repo; [ -n "$repo" ] && pr_base="https://github.com/$repo/pull"; fi
    [ -n "$pr_base" ] && click="${pr_base%/}/$pr_number"
  fi

  tmp=$(umask 077; mktemp -d) || not_delivered "no temporary folder"
  trap 'rm -rf "$tmp"' EXIT
  ( umask 077
    jq -n --arg topic "${cfg[NTFY_TOPIC]}" --arg title "$subject" --arg message "$message" --argjson priority "$priority" \
      --argjson tags "$tags" --arg click "$click" --arg level "$level" '
      {topic: $topic, title: ($level + ": " + $title), message: $message, priority: $priority, tags: $tags}
      + (if $click == "" then {} else {click: $click, actions: [{action: "view", label: "Open", url: $click}]} end)
    ' > "$tmp/msg.json" ) 2>/dev/null || not_delivered "the message could not be built (priority must be 1 to 5)"

  # ntfy takes JSON posted to the server root; the topic is in the body, the URL and the token go on curl's stdin.
  local url=${cfg[NTFY_URL]%/} rc
  http=$( { printf 'url = "%s/"\n' "$url"
            if [ -n "${cfg[NTFY_TOKEN]:-}" ]; then printf 'header = "Authorization: Bearer %s"\n' "${cfg[NTFY_TOKEN]}"; fi
          } | curl -sS -K - -X POST -H 'Content-Type: application/json' --data-binary @"$tmp/msg.json" \
                --connect-timeout 5 --max-time "$(setting NOTIFY_TIMEOUT 10)" -o "$tmp/resp" -w '%{http_code}' 2> "$tmp/err")
  rc=$?
  if [ "$rc" -ne 0 ]; then not_delivered "network error (curl exit $rc)" "$http"; fi
  [[ $http =~ ^2[0-9][0-9]$ ]] || not_delivered "the server answered HTTP $http" "$http"
  ( umask 077; [ "$mode" = test ] || echo $((count + 1)) > "$dayfile" ) 2>/dev/null
}

flush() { # flush: the queued pings as one, at the highest level among them, without those about a resolved subject
  local f lines kept="" n=0 line ref lvl subj top=info
  for f in "$state"/open/*; do [ -f "$f" ] && { still_open "$f" || true; }; done
  [ -s "$queue" ] || { echo "nothing to flush"; return 0; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ref=$(jq -r '.about // ""' <<< "$line" 2>/dev/null) || continue
    [ -n "$ref" ] && resolved "$ref" && continue
    lvl=$(jq -r .level <<< "$line") subj=$(jq -r .subject <<< "$line")
    [ "$lvl" = warn ] && top=warn
    kept+="- $lvl: $subj"$'\n'; n=$((n + 1))
  done < "$queue"
  if [ "$n" -eq 0 ]; then rm -f "$queue"; echo "nothing to flush"; return 0; fi
  [ "$count" -ge "$cap" ] && { level=$top key=digest subject="digest: $n"; not_delivered "daily cap of $cap pings reached"; }
  level=$top key=digest about="" subject="digest: $n ping$([ "$n" -eq 1 ] || echo s)"
  lines=${kept%$'\n'}
  send "${lines:0:3500}"
  rm -f "$queue"
  log_attempt delivered "$http"
  echo "delivered: $subject"
}

if [ "$mode" = flush ]; then flush; exit 0; fi

if [ "$mode" = ping ]; then
  # An open ping about the same subject holds this one back until the subject is resolved.
  if [ -n "$if_none_open" ]; then
    for f in "$state"/open/*; do
      [ -f "$f" ] || continue
      IFS=$'\t' read -r ref _ < "$f" 2>/dev/null || continue
      [ "$ref" = "$about" ] && still_open "$f" && { log_attempt open; echo open; exit 0; }
    done
  fi
  openfile="$state/open/$(keyname "$key")"
  if [ -f "$openfile" ] && still_open "$openfile"; then log_attempt open; echo open; exit 0; fi

  case "$level" in act) window=$(setting NOTIFY_DEDUPE_MIN_ACT 10) ;; *) window=$(setting NOTIFY_DEDUPE_MIN 30) ;; esac
  last=$(cat "$keyfile" 2>/dev/null || echo 0)
  [[ $last =~ ^[0-9]+$ ]] || last=0
  if [ $((now - last)) -lt $((window * 60)) ]; then log_attempt deduped; echo deduped; exit 0; fi

  if [ "$level" != act ] && [ "$(setting NOTIFY_BUNDLE on)" != off ]; then
    if [ -f "$queue" ] && jq -e --arg k "$key" 'select(.key == $k)' "$queue" > /dev/null 2>&1; then
      log_attempt deduped; echo deduped; exit 0
    fi
    ( umask 077; jq -cn --argjson t "$now" --arg l "$level" --arg k "$key" --arg a "$about" --arg s "$subject" \
        '{time: $t, level: $l, key: $k, about: $a, subject: $s}' >> "$queue" ) 2>/dev/null || not_delivered "the queue could not be written"
    mark_open
    log_attempt queued
    echo queued
    oldest=$(head -1 "$queue" | jq -r .time 2>/dev/null)
    if [[ $oldest =~ ^[0-9]+$ ]] && [ $((now - oldest)) -ge $(( $(setting NOTIFY_FLUSH_MAX_H 14) * 3600 )) ]; then
      ( flush ) || true
    fi
    exit 0
  fi
  [ "$count" -ge "$cap" ] && not_delivered "daily cap of $cap pings reached"
fi

send "${body:-$subject}"
( umask 077; echo "$now" > "$keyfile" ) 2>/dev/null
[ "$mode" = ping ] && mark_open
log_attempt delivered "$http"
[ "$mode" = test ] && echo "delivered: check your phone"
exit 0
