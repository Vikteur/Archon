#!/usr/bin/env bash
# Tests scripts/scaffold.sh rendering: the output is source code, so a variable is written as given ("/", quotes, "&",
# "<", ">"), never HTML-escaped as the mustache CLI does; sections, lists and the package check still apply, and a
# template under docs/scaffold-templates/project/ resolves by its name like a kit template.
# Each case renders in a throwaway repo that links the real scripts/.
# Usage: bash scripts/test/scaffold.test.sh   (exit 0 = all pass)
set -uo pipefail

top="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0; out=""; rc=0

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"
  else fail=$((fail+1)); echo "FAIL - $1"; printf '%s\n' "$out" | sed 's/^/       | /'; fi
}

[ -d "$top/scripts/scaffold/node_modules/mustache" ] || npm ci --prefix "$top/scripts/scaffold" --silent --no-audit --no-fund >&2
w="$tmp/w"
mkdir -p "$w/scripts" "$w/docs/scaffold-templates/project/x"
cp "$top/scripts/scaffold.sh" "$w/scripts/scaffold.sh"
ln -s "$top/scripts/scaffold" "$w/scripts/scaffold"
git init -q "$w"
export SCAFFOLD_LOG="$tmp/scaffold.jsonl"
cat > "$w/docs/scaffold-templates/project/x/thing.mustache" <<'TPL'
{{! a project template }}
package {{package}};

class {{Name}} {
    String path = "{{path}}";
    String note = "{{{note}}}";
{{#fields}}
    {{type}} {{name}};
{{/fields}}
}
TPL
vars='{"package":"a.b","Name":"Thing","path":"/api/things?a=1&b=2","note":"say \"hi\"","fields":[{"type":"List<String>","name":"tags"},{"type":"Map<String, Integer>","name":"counts"}]}'
target="m/src/main/java/a/b/Thing.java"

out="$(cd "$w" && bash scripts/scaffold.sh project/x/thing "$vars" "$target" 2>&1)"; rc=$?
file="$w/$target"
check "1 a project template renders by its name" "$([ "$rc" -eq 0 ] && [ -f "$file" ]; echo $?)"
out="$(cat "$file" 2>/dev/null)"
check "2 '/', '?' and '&' are written as given" "$(grep -qF 'String path = "/api/things?a=1&b=2";' <<< "$out"; echo $?)"
check "2 quotes are written as given" "$(grep -qF 'String note = "say "hi"";' <<< "$out"; echo $?)"
check "2 generics in a list item are written as given" "$(grep -qF 'List<String> tags;' <<< "$out" && grep -qF 'Map<String, Integer> counts;' <<< "$out"; echo $?)"
check "2 no HTML entity anywhere" "$(! grep -qE '&(#x?[0-9A-Fa-f]+|quot|amp|lt|gt);' <<< "$out"; echo $?)"

out="$(cd "$w" && bash scripts/scaffold.sh project/x/thing "$vars" "m/src/main/java/a/c/Thing.java" 2>&1)"; rc=$?
check "3 the package check still refuses a wrong directory" "$([ "$rc" -eq 1 ] && grep -qF 'package mismatch, nothing written' <<< "$out" \
  && [ ! -e "$w/m/src/main/java/a/c/Thing.java" ]; echo $?)"
out="$(cd "$w" && bash scripts/scaffold.sh project/x/thing "$vars" "$target" 2>&1)"; rc=$?
check "3 an existing target is never overwritten" "$([ "$rc" -eq 1 ] && grep -qF 'refusing to overwrite' <<< "$out"; echo $?)"

echo "scaffold tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
