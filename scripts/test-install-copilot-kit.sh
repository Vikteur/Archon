#!/usr/bin/env bash
# Tests scripts/install-copilot-kit.sh: its argument and path checks, and its --dry-run plan.
# Never installs anything: every run either fails a check or is a --dry-run, under a scratch HOME.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/install-copilot-kit.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME" "$tmp/be" "$tmp/fe" "$tmp/api" "$tmp/plain"
git -C "$tmp/be" init -q
git -C "$tmp/fe" init -q
printf 'openapi: 3.1.0\ninfo: {title: t, version: "1"}\npaths: {}\n' > "$tmp/api/openapi.yaml"
printf '{"openapi": "3.1.0"}\n' > "$tmp/api/openapi.json"
printf 'swagger: "2.0"\n' > "$tmp/api/old.yaml"
printf 'openapi: 3.1.0\n' > "$tmp/api/spec.txt"

count="$tmp/count"; : > "$count"
fail() { echo "FAIL: $1" >&2; exit 1; }
contains() { case "$1" in *"$2"*) ;; *) fail "$3: output lacks '$2'. Got: $1" ;; esac; }

# run <expected exit> <name> <args...>: prints the output
run() {
  local want="$1" name="$2" out code; shift 2
  set +e; out="$(bash "$script" "$@" </dev/null 2>&1)"; code=$?; set -e
  [ "$code" = "$want" ] || fail "$name: exit $code, want $want. Output: $out"
  echo >> "$count"
  printf '%s' "$out"
}

out="$(run 0 help --help)"
contains "$out" "--backend <path>" "help"
contains "$out" "raw.githubusercontent.com/Vikteur/Archon/local/console/scripts/install-copilot-kit.sh" "help curl line"

# The help must not need the script file: under `bash <(curl ...)` it cannot be read again.
out="$(set +e; bash <(cat "$script") --help </dev/null 2>&1)"
contains "$out" "--contract <file>" "help through a pipe"
echo >> "$count"

out="$(run 2 unknown --bogus)";                                   contains "$out" "unknown option: --bogus" "unknown"
out="$(run 1 no-backend --contract "$tmp/api/openapi.yaml")";     contains "$out" "--backend is required" "no backend"
out="$(run 1 no-contract --backend "$tmp/be")";                   contains "$out" "--contract is required" "no contract"
out="$(run 1 backend-not-git --backend "$tmp/plain" --contract "$tmp/api/openapi.yaml" --dry-run)"
contains "$out" "is not a git repository" "backend not git"
out="$(run 1 frontend-not-git --backend "$tmp/be" --frontend "$tmp/plain" --contract "$tmp/api/openapi.yaml" --dry-run)"
contains "$out" "frontend $tmp/plain is not a git repository" "frontend not git"
out="$(run 1 same-repo --backend "$tmp/be" --frontend "$tmp/be" --contract "$tmp/api/openapi.yaml" --dry-run)"
contains "$out" "the same folder" "same folder"
out="$(run 1 missing-contract --backend "$tmp/be" --contract "$tmp/api/none.yaml" --dry-run)"
contains "$out" "does not exist" "missing contract"
out="$(run 1 wrong-extension --backend "$tmp/be" --contract "$tmp/api/spec.txt" --dry-run)"
contains "$out" ".yaml, .yml or .json" "extension"
out="$(run 1 not-openapi --backend "$tmp/be" --contract "$tmp/api/old.yaml" --dry-run)"
contains "$out" "no top-level openapi key" "swagger 2"

out="$(run 0 dry-run --backend "$tmp/be" --frontend "$tmp/fe" --contract "$tmp/api/openapi.yaml" --dry-run)"
contains "$out" "Dry run: nothing changed" "dry run"
contains "$out" "backend    $tmp/be" "dry run backend"
contains "$out" "frontend   $tmp/fe" "dry run frontend"
contains "$out" "backlog    off" "backlog default off"
contains "$out" "branch chore/archon-kit" "default branch"
contains "$out" "in $HOME/archon," "default archon dir"

# Relative paths and ~ resolve; a JSON contract and the flags show in the plan.
# shellcheck disable=SC2088  # a literal ~ on purpose: the script expands it itself
out="$(cd "$tmp" && run 0 dry-run-flags --backend be --contract api/openapi.json --archon-dir '~/a' \
  --backlog --no-web --no-commit --no-smoke --branch kit/x --dry-run)"
contains "$out" "backend    $tmp/be " "relative backend"
contains "$out" "contract   $tmp/api/openapi.json" "json contract"
contains "$out" "in $HOME/a," "tilde archon dir"
contains "$out" "frontend   (none)" "no frontend"
contains "$out" "backlog    on" "backlog"
contains "$out" "web views  off" "no web"
contains "$out" "commit     off" "no commit"
contains "$out" "smoke run  skipped" "no smoke"

[ ! -e "$HOME/.archon" ] || fail "a dry run wrote $HOME/.archon"
[ -z "$(git -C "$tmp/be" status --porcelain)" ] || fail "a dry run changed the backend"

echo "test-install-copilot-kit: $(wc -l < "$count" | tr -d " ") passed"
