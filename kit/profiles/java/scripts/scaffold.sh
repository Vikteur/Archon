#!/usr/bin/env bash
# Render a scaffold template into a new source file (base case only; edge cases are hand-written after).
# Usage: scripts/scaffold.sh [--test] <layer/name | path.mustache> <'{json}' | vars.json> <target file>
#        scripts/scaffold.sh [--test] --for <new file>  (which template renders it, and the command; writes nothing)
#   e.g. scripts/scaffold.sh --test domain/mother '{"package": "...", "Name": "Guest", "fixture": "standardGuest",
#        "fields": [...]}' guest-domain/src/test/java/.../GuestMother.java
#   --test: the target must sit in a test source tree, src/testFixtures included (the test-writer's fence). Pass JSON inline on one line:
#   the scope guard splits multi-line commands (no heredocs).
# "package" is the base package: a Java template appends its layer's suffix to it (.domain, .usecase, .config,
# .repository, .adapter.controller, .adapter.repository; its header says which). A .java target under src/<set>/java/
# must sit in the directory of the package the file declares: on a mismatch nothing is written, and the error names
# both packages and the "package" value that fits the target.
# Every file written appends one line {"type":"SCAFFOLD","template","target","loggedAt"} (target relative to the repo
# root, no variables) to $SCAFFOLD_LOG, by default .apm-audit/scaffold.jsonl in the repo, for the run's scaffold report.
# --for prints, for each template whose `## Scaffold` Target in docs/code-maps/ matches the path (scaffold/targets.js,
# the scaffold-check gate's own matcher), its Vars, what it leaves out and the render command with the variables the
# path gives already filled in, the most specific Target first; with no match, the plan's Hand-written line
# (scaffold/for.js). The plan line names the file from the repo root, the command as given (run it where you are).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
SCAFFOLD_DIR="$root/docs/scaffold-templates"
# mustache@4.2.0, pinned with its integrity hash in scripts/scaffold/package-lock.json; npm ci installs it on first use.
# Rendered without HTML escaping: the output is source code, so `{{x}}` writes "/", quotes and "&" as given (the
# mustache CLI would write &#x2F;, &quot; and &amp;).
TOOL_DIR="$root/scripts/scaffold"

test_only=0
if [[ "${1:-}" == "--test" ]]; then test_only=1; shift; fi
usage() { sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
if [[ "${1:-}" == "--for" ]]; then
  [[ $# -eq 2 ]] || usage
  [[ -d "$TOOL_DIR/node_modules/mustache" ]] || npm ci --prefix "$TOOL_DIR" --silent --no-audit --no-fund >&2
  exec node "$TOOL_DIR/for.js" "$root" "$(git rev-parse --show-prefix 2>/dev/null || true)${2//\\//}" "${2//\\//}"
fi
[[ $# -eq 3 ]] || usage

template="$1" vars="$2" target="$3"
template_name="${template%.mustache}"
template_name="${template_name#"$SCAFFOLD_DIR"/}"
[[ "$template" == *.mustache ]] || template="$SCAFFOLD_DIR/$template.mustache"
[[ -f "$template" ]] || { echo "[scaffold] template not found: $template" >&2; exit 1; }

# Only relative targets inside the working tree.
t="${target//\\//}"
case "$t" in
  /*|[A-Za-z]:/*) echo "[scaffold] target must be a relative path: $target" >&2; exit 1 ;;
  ..|../*|*/..|*/../*) echo "[scaffold] target may not contain '..': $target" >&2; exit 1 ;;
esac
if [[ $test_only -eq 1 ]]; then
  case "$t" in
    src/test/*|*/src/test/*|src/testFixtures/*|*/src/testFixtures/*|test/*|*/test/*) ;;
    *) echo "[scaffold] --test: target must be in a test source tree (src/test/, src/testFixtures/ or test/): $target" >&2; exit 1 ;;
  esac
fi
# Never clobber code: a template only produces the first version of a file.
[[ ! -e "$target" ]] || { echo "[scaffold] target exists, refusing to overwrite: $target" >&2; exit 1; }

renderer="$TOOL_DIR/node_modules/mustache/bin/mustache"
[[ -f "$renderer" ]] || npm ci --prefix "$TOOL_DIR" --silent --no-audit --no-fund >&2

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if [[ "$vars" == "{"* ]]; then
  printf '%s' "$vars" > "$tmp"
  vars="$tmp"
fi
[[ -f "$vars" ]] || { echo "[scaffold] vars file not found: $vars" >&2; exit 1; }

out="$(node -e 'const m = require(process.argv[1]); const fs = require("fs"); m.escape = String;
  process.stdout.write(m.render(fs.readFileSync(process.argv[3], "utf8"), JSON.parse(fs.readFileSync(process.argv[2], "utf8"))));' \
  "$TOOL_DIR/node_modules/mustache" "$vars" "$template")"

# The declared package must match the target's directory under src/<set>/java/.
if [[ "$t" =~ (^|/)src/([^/]+)/java/(.+/)?[^/]+\.java$ ]]; then
  set_name="${BASH_REMATCH[2]}"
  dir="${BASH_REMATCH[3]%/}"
  expected="${dir//\//.}"
  declared="$(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*package[[:space:]]+([A-Za-z0-9_.]+)[[:space:]]*;.*/\1/p' | head -n 1)"
  if [[ "$declared" != "$expected" ]]; then
    suffix="$(sed -nE 's/^[[:space:]]*package[[:space:]]+\{\{package\}\}([A-Za-z0-9_.]*)[[:space:]]*;.*/\1/p' "$template" | head -n 1)"
    hint=""
    if [[ -n "$expected" && ( -z "$suffix" || "$expected" == *"$suffix" ) ]]; then
      hint=" Pass \"package\" as \"${expected%"$suffix"}\""
      [[ -n "$suffix" ]] && hint="$hint: this template appends \"$suffix\" itself"
      hint="$hint."
    fi
    echo "[scaffold] package mismatch, nothing written: the file would declare package \"$declared\", but its target" \
      "$target sits in src/$set_name/java/${dir:-} (package \"$expected\").$hint" >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$target")"
printf '%s\n' "$out" > "$target"
echo "[scaffold] $target"

# The scaffold record: what was rendered where, never the variables.
prefix="$(git rev-parse --show-prefix 2>/dev/null || true)"
repo_top="$(git rev-parse --show-toplevel 2>/dev/null || echo "$root")"
log="${SCAFFOLD_LOG:-$repo_top/.apm-audit/scaffold.jsonl}"
jstr() { local s="${1//\\/\\\\}"; printf '"%s"' "${s//\"/\\\"}"; }
if mkdir -p "$(dirname "$log")" 2>/dev/null; then
  printf '{"type":"SCAFFOLD","template":%s,"target":%s,"loggedAt":"%s"}\n' "$(jstr "$template_name")" \
    "$(jstr "$prefix$t")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$log" 2>/dev/null || true
fi
