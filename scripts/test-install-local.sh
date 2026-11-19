#!/usr/bin/env bash
# Tests scripts/install-local.sh argument parsing and its --dry-run plan.
# Never builds or installs anything.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/install-local.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "$3: output lacks '$2'. Got: $1" ;;
  esac
}

lacks() {
  case "$1" in
    *"$2"*) fail "$3: output has '$2'. Got: $1" ;;
  esac
}

version=$(grep '"version"' "$repo_root/package.json" | head -1 | cut -d'"' -f4)

output=$(bash "$script" --dry-run --prefix /p/bin --archon-home /p/home --target bun-linux-arm64) \
  || fail "dry-run failed"
contains "$output" "target bun-linux-arm64" "target"
contains "$output" "/p/bin/archon" "prefix"
contains "$output" "/p/home/server/$version/archon-server-linux-arm64" "server path"
contains "$output" "/p/home/plugins/archon-provider-claude" "provider path"
contains "$output" "/p/home/web-dist/$version/" "web path"
contains "$output" "archon kit tools" "kit step"

output=$(bash "$script" --dry-run --prefix=/q/bin --archon-home=/q/home --target=bun-darwin-x64 --skip-web --skip-tools) \
  || fail "dry-run with = forms failed"
contains "$output" "/q/bin/archon" "--prefix= form"
contains "$output" "skipped (--skip-web)" "--skip-web"
contains "$output" "skipped (--skip-tools)" "--skip-tools"
lacks "$output" "web-dist" "--skip-web hides the web path"

output=$(ARCHON_HOME=/env/home bash "$script" --dry-run --target bun-linux-x64) || fail "env home dry-run failed"
contains "$output" "/env/home/server/" "ARCHON_HOME default"

status=0
output=$(bash "$script" --dry-run --target bun-windows-x64 2>&1) || status=$?
[ "$status" -ne 0 ] || fail "accepted an unsupported target"
contains "$output" "Unsupported target" "bad target"

status=0
output=$(bash "$script" --bogus 2>&1) || status=$?
[ "$status" -ne 0 ] || fail "accepted an unknown option"
contains "$output" "Unknown option: --bogus" "unknown option"

status=0
output=$(bash "$script" --prefix 2>&1) || status=$?
[ "$status" -ne 0 ] || fail "accepted --prefix without a value"
contains "$output" "--prefix needs a value" "missing value"

echo "install-local tests passed"
