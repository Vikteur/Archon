#!/usr/bin/env bash
# Tests scripts/scaffold.sh rendering: the output is source code, so a variable is written as given ("/", quotes, "&",
# "<", ">"), never HTML-escaped as the mustache CLI does; sections, lists and the package check still apply, and a
# template under docs/scaffold-templates/project/ resolves by its name like a kit template. `--for` (targets.js, which
# the scaffold step and the scaffold-check gate share) offers the repo's own templates: one beside a kit template takes
# over that template's code-map rows, and a new one is offered from the rows of docs/scaffold-templates/project/README.md.
# Each case renders in a throwaway repo with fixture code-maps and templates that links the real scripts/.
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

# 4. --for offers the repo's own templates, without an edit to a kit-owned code-map leaf.
mkdir -p "$w/docs/code-maps" "$w/docs/scaffold-templates/domain" "$w/docs/scaffold-templates/project/domain"
cat > "$w/docs/code-maps/leaf.md" <<'MD'
## Scaffold

| Template | Target | Variables | Left to you |
|---|---|---|---|
| [domain/id](../scaffold-templates/domain/id.mustache) | `<capability>-domain/src/main/java/<pkg>/domain/<Name>Id.java` | `package`, `Name` | nothing |
| [domain/record](../scaffold-templates/domain/record.mustache) | `.../domain/<Name>.java` | `package`, `Name` | the fields |
MD
printf '{{! kit id\n  Vars: package, Name }}\npackage {{package}}.domain;\nrecord {{Name}}Id(String kit) {}\n' > "$w/docs/scaffold-templates/domain/id.mustache"
printf '{{! kit record\n  Vars: package, Name }}\npackage {{package}}.domain;\nrecord {{Name}}() {}\n' > "$w/docs/scaffold-templates/domain/record.mustache"
id_target="x-domain/src/main/java/a/b/domain/GuestId.java"
out="$(cd "$w" && bash scripts/scaffold.sh --for "$id_target" 2>&1)"; rc=$?
check "4 without a repo template, --for offers the kit's" "$([ "$rc" -eq 0 ] && grep -qF 'domain/id (skill leaf)' <<< "$out" \
  && ! grep -qF 'project/' <<< "$out"; echo $?)"
printf '{{! the repo'"'"'s id\n  Vars: package, Name }}\npackage {{package}}.domain;\nrecord {{Name}}Id(java.util.UUID value) {}\n' \
  > "$w/docs/scaffold-templates/project/domain/id.mustache"
out="$(cd "$w" && bash scripts/scaffold.sh --for "$id_target" 2>&1)"; rc=$?
check "4 a repo template beside a kit one takes over its row" "$([ "$rc" -eq 0 ] && grep -qF 'project/domain/id (skill leaf)' <<< "$out" \
  && grep -qF 'Render: scripts/scaffold.sh project/domain/id' <<< "$out" && ! grep -qE '^domain/id ' <<< "$out"; echo $?)"
cmd="$(grep -oE "Render: scripts/scaffold.sh project/domain/id '[^']*' $id_target" <<< "$out" | sed 's/^Render: //')"
out="$(cd "$w" && eval "bash $cmd" 2>&1)"; rc=$?
check "4 its render command writes the repo's template" "$([ "$rc" -eq 0 ] && grep -qF 'record GuestId(java.util.UUID value) {}' "$w/$id_target"; echo $?)"
out="$(cd "$w" && bash scripts/scaffold.sh --for x-domain/src/main/java/a/b/domain/Guest.java 2>&1)"
check "4 the kit's other rows stay" "$(grep -qF 'domain/record (skill leaf)' <<< "$out"; echo $?)"
printf '{{! a new shape\n  Vars: package, Name }}\npackage {{package}}.domain;\nenum {{Name}}Status { NEW }\n' \
  > "$w/docs/scaffold-templates/project/domain/status.mustache"
cat > "$w/docs/scaffold-templates/project/README.md" <<'MD'
# The repo's own templates

## Scaffold

| Template | Target | Variables | Left to you |
|---|---|---|---|
| [project/domain/status](domain/status.mustache) | `<capability>-domain/src/main/java/<pkg>/domain/<Name>Status.java` | `package`, `Name` | the values |
| [escape](../domain/id.mustache) | `**/Nope.java` | none | nothing |
MD
out="$(cd "$w" && bash scripts/scaffold.sh --for x-domain/src/main/java/a/b/domain/GuestStatus.java 2>&1)"; rc=$?
check "5 a new repo template is offered from project/README.md" "$([ "$rc" -eq 0 ] \
  && grep -qF 'project/domain/status (skill project)' <<< "$out" && grep -qF 'Render: scripts/scaffold.sh project/domain/status' <<< "$out"; echo $?)"
out="$(cd "$w" && bash scripts/scaffold.sh --for x/src/main/java/a/Nope.java 2>&1)"
check "5 a README row links only into project/" "$(grep -qF 'no template targets' <<< "$out"; echo $?)"

echo "scaffold tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
