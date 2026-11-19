#!/usr/bin/env bash
# Smoke test of the repo's own scaffold templates (docs/scaffold-templates/project/): in a throwaway copy of the repo
# (HEAD plus the working tree's changed and new files), scaffold the smoke context with scripts/scaffold/new-context.sh,
# render every template with its <name>.example.json to the example's "_target" (<name>.<variant>.example.json is a
# second set of variables for the same template), then run the Gradle tasks that compile and test what was rendered.
# Green means every template renders code that compiles and passes its tests; nothing in this checkout is touched.
# Usage: scripts/scaffold/smoke.sh [--keep] [--render-only]
#   --keep: keep the throwaway copy (its path is printed) even when green; it is always kept when red.
#   --render-only: render and stop before Gradle (fast check of the templates and the example vars).
# The "smoke" object of docs/scaffold-templates/project/scaffold.json, the repo's own, says what else runs:
#   "context": [...]  the arguments of scripts/scaffold/new-context.sh for the smoke context (none: no context first)
#   "gradle": [...]   the ./gradlew tasks and options after the render (none: the run stops after the render)
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
config=docs/scaffold-templates/project/scaffold.json
keep=0 render_only=0
for a in "$@"; do
  case "$a" in
    --keep) keep=1 ;;
    --render-only) render_only=1 ;;
    *) sed -n '7,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
  esac
done
cd "$root"
[[ -d docs/scaffold-templates/project ]] || { echo "[smoke] no docs/scaffold-templates/project/: nothing to smoke" >&2; exit 1; }
# list <key>: the smoke.<key> list of the config, one item per line (none when the config or the key is absent)
list() {
  [[ -f "$config" ]] || return 0
  node -e 'const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const v = (c.smoke || {})[process.argv[2]];
    if (v === undefined) process.exit(0);
    if (!Array.isArray(v) || v.some(x => typeof x !== "string" || x.includes("\n"))) { console.error(`[smoke] ${process.argv[1]}: smoke.${process.argv[2]} must be a list of strings`); process.exit(1); }
    v.forEach(x => console.log(x));' "$config" "$1"
}
list context > /dev/null && list gradle > /dev/null
context_args=() gradle_args=()
while IFS= read -r l; do context_args+=("$l"); done < <(list context)
while IFS= read -r l; do gradle_args+=("$l"); done < <(list gradle)

work="$(mktemp -d "${TMPDIR:-/tmp}/scaffold-smoke.XXXXXX")"
echo "[smoke] copy: $work"
git archive HEAD | tar -x -C "$work"
# overlay the working tree's changed and new files, so uncommitted templates are what gets tested
git ls-files -z -m -o --exclude-standard | while IFS= read -r -d '' f; do
  if [[ -f "$f" ]]; then mkdir -p "$work/$(dirname "$f")" && cp -p "$f" "$work/$f"; fi
done
# reuse the installed mustache renderer instead of a fresh npm ci
[[ -d scripts/scaffold/node_modules ]] && ln -s "$root/scripts/scaffold/node_modules" "$work/scripts/scaffold/node_modules"

cd "$work"
export SCAFFOLD_LOG="$work/.scaffold-smoke.jsonl"
if [[ ${#context_args[@]} -gt 0 ]]; then
  bash scripts/scaffold/new-context.sh "${context_args[@]}" || { echo "[smoke] RED: new-context.sh failed, copy kept: $work" >&2; exit 1; }
fi

for t in $(find docs/scaffold-templates/project -name '*.mustache' | sort); do
  [[ -f "${t%.mustache}.example.json" ]] || { echo "[smoke] RED: template without example: $t, copy kept: $work" >&2; exit 1; }
done
rendered=0
while IFS= read -r example; do
  template="${example#docs/scaffold-templates/}"
  template="${template%.example.json}"
  [[ -f "docs/scaffold-templates/$template.mustache" ]] || template="${template%.*}"
  [[ -f "docs/scaffold-templates/$template.mustache" ]] || { echo "[smoke] RED: no template for $example, copy kept: $work" >&2; exit 1; }
  target="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))._target || ""))' "$example")"
  [[ -n "$target" ]] || { echo "[smoke] RED: $example has no _target, copy kept: $work" >&2; exit 1; }
  if [[ -e "$target" ]]; then continue; fi   # already rendered by new-context.sh
  flag=()
  case "$target" in src/test/*|*/src/test/*|src/testFixtures/*|*/src/testFixtures/*|test/*|*/test/*) flag=(--test) ;; esac
  bash scripts/scaffold.sh "${flag[@]}" "$template" "$example" "$target" > /dev/null \
    || { echo "[smoke] RED: $example did not render, copy kept: $work" >&2; exit 1; }
  rendered=$((rendered + 1))
done < <(find docs/scaffold-templates/project -name '*.example.json' | sort)
echo "[smoke] rendered $rendered templates${context_args:+ (plus the module set of the context)}"

if [[ $render_only -eq 1 || ${#gradle_args[@]} -eq 0 ]]; then
  [[ $render_only -eq 1 ]] || echo "[smoke] no smoke.gradle tasks in $config: stopped after the render"
  echo "[smoke] render-only: $work"
  exit 0
fi

if ./gradlew --console=plain -q "${gradle_args[@]}"; then
  echo "[smoke] GREEN"
  if [[ $keep -eq 0 ]]; then cd / && rm -rf "$work"; else echo "[smoke] kept: $work"; fi
else
  echo "[smoke] RED, copy kept for inspection: $work" >&2
  exit 1
fi
