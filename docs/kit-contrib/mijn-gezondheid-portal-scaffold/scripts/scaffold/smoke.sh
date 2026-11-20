#!/usr/bin/env bash
# Smoke test of the project scaffold templates (docs/scaffold-templates/project/): in a throwaway copy of the repo
# (HEAD plus the working tree's changes), scaffold the "zzsmoke" context with scripts/scaffold/new-context.sh, render
# every template with its <name>.example.json to the example's "_target", then compile and run the generated tests
# and the architecture tests (TransactionalConventionTest, ...). Green means every template renders code that
# compiles, passes its own tests and keeps the ArchUnit rules; nothing in this checkout is touched.
# Usage: scripts/scaffold/smoke.sh [--keep] [--render-only]
#   --keep: keep the throwaway copy (its path is printed) even when green; it is always kept when red.
#   --render-only: render and stop before Gradle (fast check of the templates and the example vars).
# Needs Docker for the repository slice test (Testcontainers Postgres) and network access for the OpenAPI spec.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
keep=0 render_only=0
for a in "$@"; do
  case "$a" in
    --keep) keep=1 ;;
    --render-only) render_only=1 ;;
    *) sed -n '7,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
  esac
done

work="$(mktemp -d "${TMPDIR:-/tmp}/scaffold-smoke.XXXXXX")"
echo "[smoke] copy: $work"
cd "$root"
git archive HEAD | tar -x -C "$work"
# overlay the working tree's changed and new files, so uncommitted templates are what gets tested
git ls-files -z -m -o --exclude-standard | while IFS= read -r -d '' f; do
  [[ -f "$f" ]] && mkdir -p "$work/$(dirname "$f")" && cp "$f" "$work/$f"
done
# reuse the installed mustache renderer instead of a fresh npm ci
[[ -d scripts/scaffold/node_modules ]] && ln -s "$root/scripts/scaffold/node_modules" "$work/scripts/scaffold/node_modules"

cd "$work"
export SCAFFOLD_LOG="$work/.scaffold-smoke.jsonl"
bash scripts/scaffold/new-context.sh --gateway zzsmoke Zzsmoke be.mijngezondheid.zzsmoke "Vaccination,OauthAdmin" \
  "vaccinations,vaccination,vaccinationCode,contextEnum,blockedAudience,notification"

rendered=0
while IFS= read -r example; do
  template="${example#docs/scaffold-templates/}"
  template="${template%.example.json}"
  # <name>.<variant>.example.json: a second set of variables for the same template
  [[ -f "docs/scaffold-templates/$template.mustache" ]] || template="${template%.*}"
  target="$(jq -r '._target // empty' "$example")"
  [[ -n "$target" ]] || { echo "[smoke] $example has no _target" >&2; exit 1; }
  [[ -f "docs/scaffold-templates/$template.mustache" ]] || { echo "[smoke] no template for $example" >&2; exit 1; }
  if [[ -e "$target" ]]; then continue; fi   # already rendered by new-context.sh
  flag=()
  [[ "$target" == */src/test/* ]] && flag=(--test)
  bash scripts/scaffold.sh "${flag[@]}" "$template" "$example" "$target" >/dev/null
  rendered=$((rendered + 1))
done < <(find docs/scaffold-templates/project -name '*.example.json' | sort)
for t in $(find docs/scaffold-templates/project -name '*.mustache' | sort); do
  [[ -f "${t%.mustache}.example.json" ]] || { echo "[smoke] template without example: $t" >&2; exit 1; }
done
echo "[smoke] rendered $rendered templates (plus the module set)"

if [[ $render_only -eq 1 ]]; then
  echo "[smoke] render-only: $work"
  exit 0
fi

if ./gradlew --console=plain -q \
    :zzsmoke-domain:test :zzsmoke-usecase:test :zzsmoke-gateway:test :zzsmoke-adapter:test \
    :application:test --tests 'be.mijngezondheid.architecture.*'; then
  echo "[smoke] GREEN"
  if [[ $keep -eq 0 ]]; then cd / && rm -rf "$work"; else echo "[smoke] kept: $work"; fi
else
  echo "[smoke] RED, copy kept for inspection: $work" >&2
  exit 1
fi
