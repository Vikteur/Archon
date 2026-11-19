#!/usr/bin/env bash
# Tests for .archon/scripts/kit-config.sh and kit-config.js: env override, kit.yaml value, default (no file, no key, empty
# value), nested keys, quotes and comments. Usage: bash .archon/scripts/test/kit-config.test.sh   (exit 0 = all pass)
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
eq() { if [ "$3" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 -- got [$3], want [$2]"; fi; }
cat > "$tmp/kit.yaml" <<'Y'
agent_cli: copilot            # a comment
build_workflow: "build-feature-copilot"
empty_one:
contract:
  repo: acme/acme-contract
  tag_key: 'acmeTag'
other:
  repo: not-this
Y
sh_get() { ( . "$root/.archon/scripts/kit-config.sh"; kit_get "$@" ); }
js_get() { node -e 'console.log(require(process.argv[1]).kitGet(process.argv[2], process.argv[3], process.argv[4] || undefined))' "$root/.archon/scripts/kit-config.js" "$@"; }

for impl in sh js; do
  g() { "${impl}_get" "$@"; }
  export KIT_CONFIG="$tmp/kit.yaml"
  eq "$impl: top-level value, comment stripped" copilot "$(g agent_cli claude)"
  eq "$impl: quoted value" build-feature-copilot "$(g build_workflow build-feature)"
  eq "$impl: nested value" acme/acme-contract "$(g contract.repo x)"
  eq "$impl: nested quoted value" acmeTag "$(g contract.tag_key x)"
  eq "$impl: a key in another section is not matched" x "$(g contract.spec_path x)"
  eq "$impl: an empty value is the default" dflt "$(g empty_one dflt)"
  eq "$impl: a missing key is the default" dflt "$(g nope dflt)"
  eq "$impl: env override wins" fromenv "$(AGENT_CLI=fromenv g agent_cli claude AGENT_CLI)"
  eq "$impl: KIT_ env name by default" fromkit "$(KIT_CONTRACT_REPO=fromkit g contract.repo x)"
  export KIT_CONFIG="$tmp/missing.yaml"
  eq "$impl: no file is the default" claude "$(g agent_cli claude)"
  unset KIT_CONFIG
done
# without yq the shell helper still answers the default
eq "sh: no yq is the default" claude "$(KIT_CONFIG="$tmp/kit.yaml" PATH="$(dirname "$(command -v bash)")" bash -c '. "'"$root"'/.archon/scripts/kit-config.sh"; kit_get agent_cli claude')"
echo "kit-config: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
