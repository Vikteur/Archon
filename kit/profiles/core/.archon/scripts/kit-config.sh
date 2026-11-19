#!/usr/bin/env bash
# kit-config.sh — SOURCED helper: read one key of .archon/kit.yaml (the project config the Copilot kit writes) with an
# environment override and a default, so a checkout without the file behaves as it always did.
#   . "$(dirname "$0")/kit-config.sh"
#   kit_get contract.spec_path contract/dist/openapi.yaml        # env KIT_CONTRACT_SPEC_PATH, else kit.yaml, else the default
#   kit_get build_workflow build-feature BUILD_WORKFLOW          # an explicit env name as the third argument
# The file is $KIT_CONFIG, else <repo root>/.archon/kit.yaml (the repo root is git's top level, else $PWD). Reading needs
# yq (mikefarah v4); with no yq, no file or no such key the default is printed. A null or empty value is "no key".
# A key the project's kit.yaml leaves out is read from kit.defaults.yaml beside it, the kit's own defaults that
# `archon kit add` ships (agent_cli: copilot), so a Copilot project's runtime agrees with what kit add rendered; a checkout
# without that file (wedding-portal) keeps the script's default.
kit_get() { # kit_get <dotted.key> <default> [ENV_NAME]
  local key="$1" def="${2-}" env="${3:-}" v="" f root
  [ -n "$env" ] || env="KIT_$(printf '%s' "$key" | tr 'a-z.' 'A-Z_')"
  v="${!env:-}"
  if [ -z "$v" ]; then
    f="${KIT_CONFIG:-}"
    if [ -z "$f" ]; then root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; f="$root/.archon/kit.yaml"; fi
    if command -v yq >/dev/null 2>&1; then
      for f in "$f" "${f%/*}/kit.defaults.yaml"; do
        [ -f "$f" ] || continue
        v="$(yq -r ".$key // \"\"" "$f" 2>/dev/null)" || v=""
        [ "$v" != null ] || v=""
        [ -z "$v" ] || break
      done
    fi
  fi
  printf '%s' "${v:-$def}"
}

# kit_list <dotted.key>: the items of a YAML list key, one per line (nothing for a missing or empty key, or with no yq).
# The project's kit.yaml first, else kit.defaults.yaml beside it, as kit_get does; no environment override.
#   kit_list codegraph.extra_projects        # absolute paths of the other repos CodeGraph indexes
kit_list() {
  local key="$1" f root v=""
  f="${KIT_CONFIG:-}"
  if [ -z "$f" ]; then root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; f="$root/.archon/kit.yaml"; fi
  command -v yq >/dev/null 2>&1 || return 0
  for f in "$f" "${f%/*}/kit.defaults.yaml"; do
    [ -f "$f" ] || continue
    v="$(yq -r ".$key[]" "$f" 2>/dev/null)" || v=""
    if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
  done
}
