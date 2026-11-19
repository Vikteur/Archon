#!/usr/bin/env bash
# Tests for .archon/scripts/notify-owner.sh with a stub curl on PATH (it never reaches the network): config checks,
# the message ntfy gets, dedupe, the daily cap, quiet hours, redaction of personal data and the exit codes; open pings
# about a subject (--about), and the info/warn bundle (--flush). Sections 1-10 send at once (NOTIFY_BUNDLE=off).
# Usage: bash .archon/scripts/test/notify-owner.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/notify-owner.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
out="$root/out"
topic=Tq9vX2mK7pLr4sW8nZ3bY6cD
token=tk_s3cr3tT0ken

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$out" 2>/dev/null; fi
}

# The stub curl keeps its stdin config, its arguments and the posted JSON, and answers $CURL_HTTP (exit $CURL_RC).
mkdir -p "$root/bin"
cat > "$root/bin/curl" <<'STUB'
#!/usr/bin/env bash
c="$STUB_DIR/calls"; n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$c"
cat > "$STUB_DIR/stdin.$n"; printf '%s\n' "$@" > "$STUB_DIR/args.$n"
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) cp "${2#@}" "$STUB_DIR/body.$n"; shift ;; -o) : > "$2"; shift ;; esac; shift
done
[ "${CURL_RC:-0}" -ne 0 ] && { printf 000; exit "$CURL_RC"; }
printf '%s' "${CURL_HTTP:-200}"
STUB
# The stub resolver: a subject listed in $root/resolved is resolved (merged, closed, green), any other is still open.
printf '#!/usr/bin/env bash\necho "$1" >> "%s/resolve.calls"; grep -qxF -- "$1" "%s/resolved"\n' "$root" "$root" > "$root/bin/resolve"
chmod +x "$root/bin/curl" "$root/bin/resolve"

fresh() { # fresh: a new config (mode 600) and an empty state; clears the env knobs
  rm -rf "$root/state" "$root/stub"; mkdir -p "$root/stub" "$root/cfg"
  printf 'NTFY_URL=https://ntfy.example.net/\nNTFY_TOPIC="%s"\nNTFY_TOKEN=%s\n' "$topic" "$token" > "$root/cfg/ntfy.env"
  chmod 600 "$root/cfg/ntfy.env"
  unset CURL_RC CURL_HTTP NOTIFY_QUIET NOTIFY_DAILY_CAP NOTIFY_DEDUPE_MIN NOTIFY_DEDUPE_MIN_ACT NOTIFY_PR_BASE
  export NOTIFY_BUNDLE=off
  : > "$root/resolved"
  NOW=1792476000   # 2026-10-20 06:00 UTC
}
ping_() { PATH="$root/bin:$PATH" STUB_DIR="$root/stub" NOTIFY_OWNER_CONFIG="$root/cfg/ntfy.env" \
  NOTIFY_OWNER_STATE="$root/state" NOTIFY_NOW="$NOW" NOTIFY_RESOLVE="$root/bin/resolve" TZ=UTC bash "$script" "$@" > "$out" 2>&1; }
calls() { cat "$root/stub/calls" 2>/dev/null || echo 0; }
body() { jq -r "$1" "$root/stub/body.${2:-$(calls)}"; }
said() { grep -qF -- "$1" "$out"; }
nosecret() { ! grep -rqF -e "$topic" -e "$token" "$out" "$root/state" "$root/stub"/args.* 2>/dev/null; }

# 1. A ping is posted as JSON to the server root: topic, priority, tags, title; the URL and token only on stdin.
fresh; ping_ act merge-held-12 "PR #12 waits for you: a STOP item is not approved"; rc=$?
check "1 delivered exits 0" $([ "$rc" -eq 0 ] && [ "$(calls)" = 1 ]; echo $?)
check "1 act is urgent with a siren tag" $([ "$(body .priority)" = 5 ] && [ "$(body '.tags[0]')" = rotating_light ]; echo $?)
check "1 the topic is in the body, the server root in the url" $([ "$(body .topic)" = "$topic" ] \
  && grep -qx 'url = "https://ntfy.example.net/"' "$root/stub/stdin.1" \
  && grep -qx "header = \"Authorization: Bearer $token\"" "$root/stub/stdin.1"; echo $?)
check "1 title carries the level and the subject" $([ "$(body .title)" = "act: PR #12 waits for you: a STOP item is not approved" ]; echo $?)
check "1 a timeout is set" $(grep -qx -- --max-time "$root/stub/args.1" && grep -qx 10 "$root/stub/args.1"; echo $?)
check "1 the topic and token are in no argument, output or log" $(nosecret; echo $?)
check "1 one JSON log line" $([ "$(wc -l < "$root/state/log.jsonl")" = 1 ] \
  && jq -e '.result == "delivered" and .key == "merge-held-12" and .level == "act"' "$root/state/log.jsonl" > /dev/null; echo $?)

# 2. Levels map to priorities; the body, when given, is the message.
fresh; ping_ info k-info "Run abcd1234 merged"; check "2 info is low" $([ "$(body .priority)" = 2 ] && [ "$(body '.tags[0]')" = information_source ]; echo $?)
ping_ warn k-warn "Retro digest: 2 incidents" "see the digest"
check "2 warn is high, the body is the message" $([ "$(body .priority)" = 4 ] && [ "$(body .message)" = "see the digest" ]; echo $?)
NTFY_PRIORITY_WARN=3 ping_ warn k-warn2 "x"; check "2 a priority override" $([ "$(body .priority)" = 3 ]; echo $?)

# 3. Tap target: a URL in the text, else PR #n with NOTIFY_PR_BASE.
fresh; ping_ act merge-wait-7 "PR #7 is ready: bash .archon/scripts/merge-ready.sh https://github.com/o/r/pull/7"
check "3 a URL in the text is the click and a view action" $([ "$(body .click)" = https://github.com/o/r/pull/7 ] \
  && [ "$(body '.actions[0].url')" = https://github.com/o/r/pull/7 ]; echo $?)
NOTIFY_PR_BASE=https://github.com/o/r/pull/ ping_ act merge-head-9 "PR #9 merged at abc"
check "3 PR #n links through NOTIFY_PR_BASE" $([ "$(body .click)" = https://github.com/o/r/pull/9 ]; echo $?)

# 4. Dedupe: same key within 30 min (info, warn) or 10 min (act) is not sent; prints deduped, exits 0.
fresh; ping_ warn same "first"; NOW=$((NOW + 600)); ping_ warn same "second"; rc=$?
check "4 a repeat within the window is deduped" $([ "$rc" -eq 0 ] && said deduped && [ "$(calls)" = 1 ] \
  && [ "$(jq -r .result "$root/state/log.jsonl" | tail -1)" = deduped ]; echo $?)
NOW=$((NOW + 1201)); ping_ warn same "third"; check "4 after the window it is sent again" $([ "$(calls)" = 2 ]; echo $?)
ping_ act same-act "a"; NOW=$((NOW + 601)); ping_ act same-act "b"; check "4 act's window is 10 min" $([ "$(calls)" = 4 ]; echo $?)
NOTIFY_DEDUPE_MIN=1 ping_ warn same "fourth"; NOW=$((NOW + 61)); NOTIFY_DEDUPE_MIN=1 ping_ warn same "fifth"
check "4 the window is configurable" $([ "$(calls)" = 6 ]; echo $?)
fresh; CURL_RC=7 ping_ act retry "x"; ping_ act retry "x"; check "4 a failed delivery does not count for dedupe" $([ "$(calls)" = 2 ]; echo $?)

# 5. Daily cap: the last allowed ping says so; the next one is not delivered (exit 3).
fresh; export NOTIFY_DAILY_CAP=2
ping_ info c1 a; ping_ info c2 b; m=$(body .message)
ping_ info c3 c; rc=$?
check "5 the cap's last ping says so" $([[ $m == *"daily cap reached"* ]]; echo $?)
check "5 past the cap: exit 3, not posted" $([ "$rc" -eq 3 ] && [ "$(calls)" = 2 ] && said "daily cap"; echo $?)
NOW=$((NOW + 86400)); ping_ info c4 d; check "5 the cap resets the next day" $([ $? -eq 0 ] && [ "$(calls)" = 3 ]; echo $?)
unset NOTIFY_DAILY_CAP

# 6. Quiet hours (off by default): info and warn go silent, act still rings.
fresh; ping_ info q1 a; check "6 no quiet hours by default" $([ "$(body .priority)" = 2 ]; echo $?)
export NOTIFY_QUIET=23-07
ping_ warn q2 a; check "6 warn at 06:00 inside 23-07 is silent" $([ "$(body .priority)" = 1 ]; echo $?)
ping_ act q3 a; check "6 act still rings" $([ "$(body .priority)" = 5 ]; echo $?)
NOW=$((NOW + 4 * 3600)); ping_ warn q4 a; check "6 warn at 10:00 rings" $([ "$(body .priority)" = 4 ]; echo $?)
unset NOTIFY_QUIET

# 7. Personal data is redacted from the subject and body (and the log), ids and PR numbers stay.
fresh; ping_ act pd-1 "PR #31 TASK-6.1 for jan.peeters@example.be, +32 470 12 34 56, BE68 5390 0754 7034, run abcd1234" \
  "call 0470/12.34.56 or see https://x.example/p?email=jan@example.be"
t=$(body .title) m=$(body .message)
check "7 an e-mail address is redacted" $([[ $t != *@* && $m != *@* && $t == *"[redacted]"* ]]; echo $?)
check "7 phone numbers and the IBAN are redacted" $([[ $t != *"470 12"* && $t != *BE68* && $m != *"0470"* ]]; echo $?)
check "7 ids, PR numbers and run ids stay" $([[ $t == *"PR #31 TASK-6.1"* && $t == *"run abcd1234"* ]]; echo $?)
check "7 a URL loses its query" $([[ $m == *"https://x.example/p" && $m != *"?"* ]]; echo $?)
check "7 the log holds no e-mail address" $(! grep -q 'example.be' "$root/state/log.jsonl"; echo $?)
ping_ info pd-2 "$(printf 'two\nlines %0400d' 0)"
check "7 one line, cut to 300 characters" $(t=$(body .title); [[ $t != *$'\n'* ]] && [ "${#t}" -le 306 ]; echo $?)

# 8. Not delivered: exit 3, the reason on stderr and in the log; never the topic.
fresh; CURL_RC=28 ping_ act net "x"; rc=$?
check "8 network error exits 3" $([ "$rc" -eq 3 ] && said "network error" && jq -e 'select(.result | test("network"))' "$root/state/log.jsonl" > /dev/null; echo $?)
fresh; CURL_HTTP=403 ping_ act http "x"; check "8 an HTTP error exits 3" $([ $? -eq 3 ] && said "HTTP 403"; echo $?)
fresh; rm "$root/cfg/ntfy.env"; ping_ act nocfg "x"; rc=$?
check "8 no config exits 3, nothing posted" $([ "$rc" -eq 3 ] && said "no config" && [ "$(calls)" = 0 ]; echo $?)
fresh; chmod 644 "$root/cfg/ntfy.env"; ping_ act perm "x"; rc=$?
check "8 a world-readable config is refused" $([ "$rc" -eq 3 ] && said "chmod 600" && [ "$(calls)" = 0 ]; echo $?)
fresh; chmod 640 "$root/cfg/ntfy.env"; ping_ act perm "x"; check "8 a group-readable config is refused" $([ $? -eq 3 ]; echo $?)
fresh; cp "$here/../notify/ntfy.env.example" "$root/cfg/ntfy.env"; chmod 600 "$root/cfg/ntfy.env"; ping_ act tpl "x"
check "8 the template's placeholder topic is refused" $([ $? -eq 3 ] && said placeholder && [ "$(calls)" = 0 ]; echo $?)
fresh; printf 'NTFY_URL=http://ntfy.example.net\nNTFY_TOPIC=%s\n' "$topic" > "$root/cfg/ntfy.env"; ping_ act http "x"
check "8 plain http is refused" $([ $? -eq 3 ] && said https; echo $?)
fresh; printf 'NTFY_URL=https://ntfy.sh\nNTFY_TOPIC=short\n' > "$root/cfg/ntfy.env"; ping_ act t "x"
check "8 a short topic is refused" $([ $? -eq 3 ] && said "20 to 64"; echo $?)
fresh; printf 'NTFY_URL=https://ntfy.sh\nNTFY_TOPIC=%s\nNTFY_URL=$(touch %s/pwned)\n' "$topic" "$root" > "$root/cfg/ntfy.env"; ping_ act inj "x"
check "8 the config is read, never run" $([ ! -e "$root/pwned" ]; echo $?)
fresh; printf 'NTFY_URL=https://ntfy.sh\nNTFY_TOPIC=%s\n' "$topic" > "$root/cfg/ntfy.env"; ping_ info notoken "x"
check "8 no token: no Authorization header" $([ $? -eq 0 ] && ! grep -q Authorization "$root/stub/stdin.1"; echo $?)
fresh; CURL_RC=28 ping_ act net "x"; CURL_HTTP=500 ping_ act net2 "x"; ping_ act nocfg2 "x"
check "8 no secret anywhere after failures" $(nosecret; echo $?)

# 9. test and check subcommands.
fresh; ping_ test; rc=$?
check "9 test sends one ping and says so" $([ "$rc" -eq 0 ] && said "delivered" && [ "$(calls)" = 1 ] && [[ $(body .title) == *"test ping"* ]]; echo $?)
ping_ test; check "9 test is never deduped" $([ "$(calls)" = 2 ]; echo $?)
ping_ check; check "9 check: ok, sends nothing, shows no topic" $([ $? -eq 0 ] && said ok && [ "$(calls)" = 2 ] && nosecret; echo $?)
rm "$root/cfg/ntfy.env"; ping_ check; check "9 check without config exits 3" $([ $? -eq 3 ]; echo $?)

# 10. Usage.
fresh
for args in "" "loud k s" "act" "act k" "act 'bad key' s" "act k ''" "act k s b extra" "test x" "check x"; do
  eval "ping_ $args"; rc=$?
  check "10 usage: '$args'" $([ "$rc" -eq 2 ] && [ "$(calls)" = 0 ]; echo $?)
done

# 11. An open ping (--about <subject>): its key is not sent again until the subject is resolved, however long it waits.
fresh; ping_ act merge-held-7 "PR #7: STOP verdict owner" --about pr:7; rc=$?
check "11 delivered, the subject options are not in the text" $([ "$rc" -eq 0 ] && [ "$(calls)" = 1 ] \
  && [ "$(body .title)" = "act: PR #7: STOP verdict owner" ]; echo $?)
NOW=$((NOW + 6 * 3600)); ping_ act merge-held-7 "PR #7: STOP verdict owner" --about pr:7; rc=$?
check "11 still open after 6 h: not sent, says open" $([ "$rc" -eq 0 ] && said open && [ "$(calls)" = 1 ] \
  && [ "$(jq -r .result "$root/state/log.jsonl" | tail -1)" = open ]; echo $?)
check "11 the log names the subject" $(jq -e 'select(.about == "pr:7")' "$root/state/log.jsonl" > /dev/null; echo $?)
echo pr:7 > "$root/resolved"; ping_ act merge-held-7 "PR #7: STOP verdict owner" --about pr:7
check "11 once resolved it is sent again" $([ "$(calls)" = 2 ]; echo $?)
fresh; ping_ act merge-held-8 "x" --about pr:8; NOW=$((NOW + 60)); ping_ act merge-held-9 "y" --about pr:9
check "11 another subject is not held back" $([ "$(calls)" = 2 ]; echo $?)
ping_ act main-red-abc1234 "main is red" --about sha:abc1234def; NOW=$((NOW + 3600)); ping_ act main-red-abc1234 "main is red" --about sha:abc1234def
check "11 one ping per red SHA" $([ "$(calls)" = 3 ]; echo $?)

# 12. --if-none-open: skipped while any ping about the same subject is open (merge-wait after merge-held).
fresh; ping_ act merge-held-7 "PR #7 held" --about pr:7; ping_ act merge-wait-7 "PR #7 waits" --about pr:7 --if-none-open; rc=$?
check "12 skipped while the PR has an open ping" $([ "$rc" -eq 0 ] && said open && [ "$(calls)" = 1 ]; echo $?)
ping_ act merge-wait-8 "PR #8 waits" --about pr:8 --if-none-open
check "12 sent when the PR has none" $([ "$(calls)" = 2 ]; echo $?)
NOW=$((NOW + 3600)); echo pr:7 > "$root/resolved"; ping_ act merge-wait-7 "PR #7 waits" --about pr:7 --if-none-open
check "12 sent once the open one is resolved" $([ "$(calls)" = 3 ]; echo $?)

# 13. The bundle: info and warn wait in the queue, act goes at once; --flush sends one ping with them all.
fresh; unset NOTIFY_BUNDLE
ping_ info run-merged-1 "Run abcd1234 merged"; rc=$?
check "13 info is queued, not sent" $([ "$rc" -eq 0 ] && said queued && [ "$(calls)" = 0 ] \
  && [ "$(jq -r .result "$root/state/log.jsonl" | tail -1)" = queued ]; echo $?)
ping_ warn retro-1 "Retro digest: 2 incidents" --about ticket:TASK-7; ping_ info run-merged-1 "Run abcd1234 merged"
check "13 a key already queued is not queued twice" $(said deduped && [ "$(calls)" = 0 ]; echo $?)
ping_ act merge-held-3 "PR #3 held"; check "13 act is sent at once" $([ "$(calls)" = 1 ]; echo $?)
NOW=$((NOW + 2 * 3600)); ping_ --flush; rc=$?
check "13 flush: one ping" $([ "$rc" -eq 0 ] && [ "$(calls)" = 2 ]; echo $?)
check "13 flush: the highest level, the count in the title" $([ "$(body .title)" = "warn: digest: 2 pings" ] && [ "$(body .priority)" = 4 ]; echo $?)
check "13 flush: one line per queued ping" $(m=$(body .message); [[ $m == *"Run abcd1234 merged"* && $m == *"Retro digest: 2 incidents"* ]] \
  && [ "$(body .message | wc -l)" = 2 ]; echo $?)
ping_ --flush; rc=$?
check "13 a second flush sends nothing" $([ "$rc" -eq 0 ] && said "nothing to flush" && [ "$(calls)" = 2 ]; echo $?)
fresh; unset NOTIFY_BUNDLE; ping_ info only-info "a"; ping_ --flush
check "13 info only: low priority" $([ "$(body .title)" = "info: digest: 1 ping" ] && [ "$(body .priority)" = 2 ]; echo $?)
fresh; unset NOTIFY_BUNDLE; ping_ info r1 "a" --about pr:4; ping_ info r2 "b" --about pr:5; echo pr:4 > "$root/resolved"; ping_ --flush
check "13 a queued ping about a resolved subject is dropped" $([ "$(calls)" = 1 ] && [ "$(body .title)" = "info: digest: 1 ping" ]  \
  && [ "$(body .message)" = "- info: b" ]; echo $?)
fresh; unset NOTIFY_BUNDLE; ping_ info r1 "a" --about pr:4; echo pr:4 > "$root/resolved"; ping_ --flush
check "13 nothing left once resolved: nothing sent" $(said "nothing to flush" && [ "$(calls)" = 0 ]; echo $?)
fresh; unset NOTIFY_BUNDLE; ping_ warn w1 "a"; CURL_RC=7 ping_ --flush; rc=$?; ping_ --flush
check "13 a failed flush exits 3 and keeps the queue" $([ "$rc" -eq 3 ] && [ "$(calls)" = 2 ] && [[ $(body .message) == *a* ]]; echo $?)
fresh; unset NOTIFY_BUNDLE; ping_ act merge-held-7 "held" --about pr:7; echo pr:7 > "$root/resolved"; : > "$root/resolve.calls"; ping_ --flush
check "13 flush checks the open pings and forgets the resolved ones" $(grep -qx pr:7 "$root/resolve.calls" && [ -z "$(ls -A "$root/state/open")" ]; echo $?)
fresh; NOTIFY_BUNDLE=off ping_ info now "a"; check "13 NOTIFY_BUNDLE=off sends at once" $([ "$(calls)" = 1 ]; echo $?)

# 14. A queue that missed its flush (no timer, the machine was off) goes out with the next ping after 14 h.
fresh; unset NOTIFY_BUNDLE; ping_ info s1 "old"; NOW=$((NOW + 15 * 3600)); ping_ info s2 "new"
check "14 a stale queue is flushed by the next ping" $([ "$(calls)" = 1 ] && [ "$(body .title)" = "info: digest: 2 pings" ]; echo $?)

# 15. Usage of the new options.
fresh
for args in "act k s --about" "act k s --about bad" "act k s --about pr:x" "act k s --if-none-open" "--flush x" "act k s --bogus"; do
  eval "ping_ $args"; rc=$?
  check "15 usage: '$args'" $([ "$rc" -eq 2 ] && [ "$(calls)" = 0 ]; echo $?)
done

echo "notify-owner: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
