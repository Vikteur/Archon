#!/usr/bin/env bash
# Check an OpenAPI contract for what an agent must know before it calls an operation: wrap, describe or redesign.
# Usage: scripts/contract-agent-readiness.sh --spec <openapi.yaml> [--map <map.json>] [--out <dir>] [--strict]
#          [--first-paragraph]
#   --map:    the look-alike operations, the ones a person confirms, the thresholds, the `read` budget and the accepted
#             findings.
#   Writes <out>/readiness-report.json and readiness-report.md (default out: build/contract-agent-readiness).
#   --strict: exit 1 when the report holds an error-severity finding, a `read` answer over the budget that
#             readBudget.allowOver does not list, or a median `read` answer over the budget's median.
#   --first-paragraph: also check every description cut to its first paragraph, and report what the cut adds.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# yaml@2.9.1, pinned with its integrity hash in scripts/contract-agent-readiness/package-lock.json; npm ci installs it
# on first use.
TOOL_DIR="$root/scripts/contract-agent-readiness"

usage() { sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

spec="" map="" out="$root/build/contract-agent-readiness" strict=0 cut=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec) spec="${2:-}"; shift 2 ;;
    --map) map="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --strict) strict=1; shift ;;
    --first-paragraph) cut="--first-paragraph"; shift ;;
    *) usage ;;
  esac
done
[[ -n "$spec" ]] || usage
[[ -f "$spec" ]] || { echo "[readiness] spec not found: $spec" >&2; exit 1; }
[[ -z "$map" || -f "$map" ]] || { echo "[readiness] map not found: $map" >&2; exit 1; }

mkdir -p "$out"
[[ -d "$TOOL_DIR/node_modules/yaml" ]] || npm ci --prefix "$TOOL_DIR" --silent --no-audit --no-fund >&2

node "$TOOL_DIR/check.mjs" "$spec" ${map:+"$map"} ${cut:+"$cut"} > "$out/readiness-report.json"
node "$TOOL_DIR/render.mjs" "$out/readiness-report.json" > "$out/readiness-report.md"
echo "[readiness] $out/readiness-report.json"
echo "[readiness] $out/readiness-report.md"
node -e '
  const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const s = r.summary, b = r.readBudget;
  console.log(`[readiness] ${s.errors} errors, ${s.warnings} warnings, ${s.info} info (${s.accepted} accepted); `
    + `${s.operations} operations: ${s.wrap} wrap, ${s.describe} describe, ${s.redesign} redesign; `
    + `one tool per operation ≈ ${r.toolBudget.tokens} tokens`);
  console.log(`[readiness] read budget: median ≈ ${b.median} tokens (budget ${b.medianTokens}), max ≈ ${b.max} `
    + `(budget ${b.maxTokens}), ${b.over.length} over, ${b.unallowed} not allowed`
    + (r.cut ? `; first paragraph only: ${r.cut.errors} errors, ${r.cut.warnings} warnings, ${r.cut.adds.length} new` : ""));
  if (process.argv[2] === "1" && (s.errors > 0 || b.unallowed > 0 || b.medianOver)) process.exit(1);' "$out/readiness-report.json" "$strict"
