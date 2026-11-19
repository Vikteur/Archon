#!/usr/bin/env bash
# Tests scripts/update-copilot-kit.sh: its options, the saved answers, the checks and its --dry-run plan.
# Never installs anything: every run either fails a check or is a --dry-run, under a scratch HOME, with a fake
# archon on the PATH and a local fake of the fork as the clone's origin.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/update-copilot-kit.sh"
command -v bun >/dev/null || { echo "test-update-copilot-kit: bun is needed" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME/.archon" "$tmp/bin" "$tmp/be" "$tmp/fe" "$tmp/api" "$tmp/plain" "$tmp/Vikteur"
g() { git -c user.email=t@t -c user.name=t "$@"; }
for r in be fe; do git -C "$tmp/$r" init -q; g -C "$tmp/$r" commit -q --allow-empty -m init; done
printf 'openapi: 3.1.0\n' > "$tmp/api/openapi.yaml"

# The fork: a bare origin with local/console, cloned to $HOME/archon with this script in it.
git init -q --bare -b local/console "$tmp/Vikteur/Archon.git"
git clone -q "$tmp/Vikteur/Archon.git" "$tmp/seed" 2>/dev/null
mkdir -p "$tmp/seed/scripts" && cp "$script" "$tmp/seed/scripts/"
g -C "$tmp/seed" checkout -q -b local/console
g -C "$tmp/seed" add -A && g -C "$tmp/seed" commit -q -m "first"
g -C "$tmp/seed" push -q origin local/console
git clone -q -b local/console "$tmp/Vikteur/Archon.git" "$HOME/archon"

# A fake archon: `workflow status --all --json` answers $FAKE_RUNS; everything else fails loudly.
cat > "$tmp/bin/archon" <<'FAKE'
#!/usr/bin/env bash
if [ "$1 $2" = "workflow status" ]; then echo "${FAKE_RUNS:-{\"runs\": []\}}"; exit 0; fi
echo "fake archon: unexpected call: $*" >&2; exit 99
FAKE
chmod +x "$tmp/bin/archon"
export PATH="$tmp/bin:$PATH"

save() {  # save <frontend> <backlog>: the answers kit setup keeps
  printf '{"backend": "%s", "frontend": "%s", "contract": "%s", "profiles": ["core", "java"], "backlog": %s}\n' \
    "$tmp/be" "$1" "$tmp/api/openapi.yaml" "$2" > "$HOME/.archon/kit-setup.json"
}

count="$tmp/count"; : > "$count"
fail() { echo "FAIL: $1" >&2; exit 1; }
contains() { case "$1" in *"$2"*) ;; *) fail "$3: output lacks '$2'. Got: $1" ;; esac; }
lacks() { case "$1" in *"$2"*) fail "$3: output has '$2'. Got: $1" ;; esac; }

# run <expected exit> <name> <args...>: prints the output
run() {
  local want="$1" name="$2" out code; shift 2
  set +e; out="$(bash "$script" "$@" </dev/null 2>&1)"; code=$?; set -e
  [ "$code" = "$want" ] || fail "$name: exit $code, want $want. Output: $out"
  echo >> "$count"
  printf '%s' "$out"
}

out="$(run 0 help --help)"
contains "$out" "--no-pull" "help"
contains "$out" "raw.githubusercontent.com/Vikteur/Archon/local/console/scripts/update-copilot-kit.sh" "help curl line"
out="$(set +e; bash <(cat "$script") --help </dev/null 2>&1)"
contains "$out" "kit-setup.json" "help through a pipe"
echo >> "$count"

out="$(run 2 unknown --bogus)";           contains "$out" "unknown option: --bogus" "unknown"
out="$(run 1 no-saved-setup --dry-run)";  contains "$out" "no saved setup" "no saved setup"

save "$tmp/fe" true
head_before="$(git -C "$HOME/archon" rev-parse HEAD)"
out="$(run 0 dry-run --archon-dir "$HOME/archon" --dry-run)"
contains "$out" "Dry run: nothing changed" "dry run"
contains "$out" "backend  $tmp/be" "saved backend"
contains "$out" "frontend $tmp/fe" "saved frontend"
contains "$out" "contract $tmp/api/openapi.yaml" "saved contract"
contains "$out" "profiles core,java, backlog on" "saved profiles and backlog"
contains "$out" "archon     up to date" "up to date"
contains "$out" "branch chore/archon-kit-<archon commit>" "default branch"
contains "$out" "no build run is running" "no runs"
contains "$out" "restart archon serve when it runs" "restart default"

# The default clone is the one the script sits in.
set +e; out="$(bash "$HOME/archon/scripts/update-copilot-kit.sh" --dry-run </dev/null 2>&1)"; code=$?; set -e
[ "$code" = 0 ] || fail "own clone: exit $code. Output: $out"
contains "$out" "archon   $HOME/archon" "own clone"
echo >> "$count"

# A new commit on the fork shows in the plan, and the dry run does not take it.
echo two > "$tmp/seed/two.txt"; g -C "$tmp/seed" add -A; g -C "$tmp/seed" commit -q -m "second change"
g -C "$tmp/seed" push -q origin local/console
out="$(run 0 pending --archon-dir "$HOME/archon" --dry-run --no-pull --no-tools --no-commit --no-restart --web --branch kit/x)"
contains "$out" "1 new commit(s) on local/console" "pending count"
contains "$out" "second change" "pending subject"
contains "$out" "pull       off" "no pull"
contains "$out" "tools off, web views on" "no tools, web"
contains "$out" "commit     off" "no commit"
contains "$out" "server     left as it is" "no restart"
[ "$(git -C "$HOME/archon" rev-parse HEAD)" = "$head_before" ] || fail "a dry run moved the clone"

# Options override the saved answers; --frontend '' means none.
out="$(run 0 override --archon-dir "$HOME/archon" --frontend '' --backend "$tmp/fe" --dry-run)"
contains "$out" "backend  $tmp/fe" "backend override"
contains "$out" "frontend (none)" "frontend none"
save "" false
out="$(run 0 saved-no-frontend --archon-dir "$HOME/archon" --dry-run)"
contains "$out" "frontend (none)" "saved no frontend"
contains "$out" "backlog off" "saved backlog off"

# The checks.
out="$(run 1 backend-not-git --archon-dir "$HOME/archon" --backend "$tmp/plain" --dry-run)"
contains "$out" "is not a git repository" "backend not git"
out="$(run 1 missing-contract --archon-dir "$HOME/archon" --contract "$tmp/api/none.yaml" --dry-run)"
contains "$out" "does not exist" "missing contract"
out="$(run 1 not-a-clone --archon-dir "$tmp/plain" --dry-run)"
contains "$out" "is not the Archon clone" "not a clone"
out="$(run 1 other-clone --archon-dir "$tmp/be" --dry-run)"
contains "$out" "not the fork" "other clone"

# A running build run stops it; a paused one (waiting for its plan approval) does not; --force goes on.
export FAKE_RUNS='{"runs": [{"status": "running"}, {"status": "paused"}]}'
out="$(run 1 running --archon-dir "$HOME/archon" --dry-run)"
contains "$out" "1 build run(s) running" "running run"
out="$(run 0 running-forced --archon-dir "$HOME/archon" --dry-run --force)"
contains "$out" "updating anyway (--force)" "forced"
export FAKE_RUNS='{"runs": [{"status": "paused"}]}'
out="$(run 0 paused --archon-dir "$HOME/archon" --dry-run)"
lacks "$out" "running on this machine" "paused run"
unset FAKE_RUNS

[ ! -e "$HOME/.archon/logs" ] || fail "a dry run wrote $HOME/.archon/logs"
[ ! -e "$HOME/.local/bin/archon-kit-update" ] || fail "a dry run linked the command"
[ -z "$(git -C "$tmp/be" status --porcelain)" ] || fail "a dry run changed the backend"

echo "test-update-copilot-kit: $(wc -l < "$count" | tr -d " ") passed"
