#!/usr/bin/env bash
# Tests the scripts for a repo's own scaffold templates, which read docs/scaffold-templates/project/scaffold.json:
# scripts/scaffold/new-context.sh (renders and registers the context the config describes, checks everything before it
# writes), scripts/scaffold/smoke.sh (renders every example in a throwaway copy, then runs the configured Gradle
# tasks) and scripts/test/scaffold-wiring.test.sh (the repo's templates are linked and reachable). Each case works in a
# throwaway repo with fixture templates, a fixture config and a ./gradlew that records its arguments; nothing reads
# this checkout's templates.
# Usage: bash scripts/test/scaffold-project.test.sh   (exit 0 = all pass; needs git and node)
set -uo pipefail

top="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"
pass=0; fail=0; out=""; rc=0

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"
  else fail=$((fail+1)); echo "FAIL - $1"; printf '%s\n' "$out" | sed 's/^/       | /'; fi
}
has() { grep -qF -- "$1" <<< "$out"; }

# kit add keeps a repo's own new-context.sh or smoke.sh; those are the repo's to test, not this suite's
for own in new-context.sh:new-context.js smoke.sh:scaffold.json; do
  if ! grep -qF "${own#*:}" "$top/scripts/scaffold/${own%%:*}" 2> /dev/null; then
    echo "scaffold-project tests: scripts/scaffold/${own%%:*} is the repo's own, not the kit's: nothing of the kit's to test"
    exit 0
  fi
done
[ -d "$top/scripts/scaffold/node_modules/mustache" ] || npm ci --prefix "$top/scripts/scaffold" --silent --no-audit --no-fund >&2
# scaffold-step.js: in an install beside scripts/; in the kit's source, in the core profile beside this one
step="$top/.archon/scripts/scaffold-step.js"
[ -f "$step" ] || step="$top/../core/.archon/scripts/scaffold-step.js"
[ -f "$step" ] || { echo "scaffold-project tests: no .archon/scripts/scaffold-step.js"; exit 1; }

w="$tmp/w"
# fixture: a repo with the scaffold scripts, three templates of its own and a config
fixture() {
  rm -rf "${w:?}"
  mkdir -p "$w/scripts/scaffold" "$w/scripts/test" "$w/.archon/scripts" "$w/app" "$w/old-lib"
  cp "$top/scripts/scaffold.sh" "$w/scripts/"
  cp "$top"/scripts/scaffold/*.js "$top"/scripts/scaffold/*.sh "$top"/scripts/scaffold/package*.json "$w/scripts/scaffold/"
  ln -s "$top/scripts/scaffold/node_modules" "$w/scripts/scaffold/node_modules"
  cp "$top/scripts/test/scaffold-wiring.test.sh" "$w/scripts/test/"
  cp "$step" "$w/.archon/scripts/"
  local d="$w/docs/scaffold-templates/project"
  mkdir -p "$d/module" "$d/domain" "$w/docs/scaffold-templates/domain"
  printf '// {{capability}} extra={{#extra}}yes{{/extra}}{{^extra}}no{{/extra}} apis={{apis}}\n' > "$d/module/lib-build.mustache"
  echo '{"_target": "zz-lib/build.gradle.kts", "capability": "zz", "extra": true, "apis": "Api1"}' > "$d/module/lib-build.example.json"
  printf '// {{capability}} extra module\n' > "$d/module/extra-build.mustache"
  echo '{"_target": "zz-extra/build.gradle.kts", "capability": "zz"}' > "$d/module/extra-build.example.json"
  printf 'package {{package}};\n\nclass {{Name}} {\n    String note = "{{note}}";\n}\n' > "$d/domain/thing.mustache"
  echo '{"_target": "zz-lib/src/main/java/a/b/zz/Thing.java", "package": "a.b.zz", "Name": "Thing", "note": "x&y/z"}' > "$d/domain/thing.example.json"
  printf 'package {{package}};\n\nclass {{Name}}Test {\n}\n' > "$d/domain/thing-test.mustache"
  echo '{"_target": "zz-lib/src/test/java/a/b/zz/ThingTest.java", "package": "a.b.zz", "Name": "Thing"}' > "$d/domain/thing-test.example.json"
  printf 'package {{package}};\n' > "$w/docs/scaffold-templates/domain/kitthing.mustache"
  cat > "$d/README.md" << 'EOF'
# The repo's own templates

## Scaffold

| Template | Target | Variables | Left to you |
|---|---|---|---|
| [project/module/lib-build](module/lib-build.mustache) | `<capability>-lib/build.gradle.kts` | capability, extra, apis | - |
| [project/module/extra-build](module/extra-build.mustache) | `<capability>-extra/build.gradle.kts` | capability | - |
| [project/domain/thing](domain/thing.mustache) | `<capability>-lib/src/main/java/<pkg>/<Name>.java` | package, Name, note | - |
| [project/domain/thing-test](domain/thing-test.mustache) | `<capability>-lib/src/test/java/<pkg>/<Name>Test.java` | package, Name | - |
EOF
  cat > "$d/scaffold.json" << 'EOF'
{
  "projectOnly": true,
  "context": {
    "modules": ["lib"],
    "flags": {"extra": ["extra"]},
    "args": ["apis"],
    "help": ["e.g. scripts/scaffold/new-context.sh ab-cd AbCd a.b.abcd Api1"],
    "files": [
      {"template": "project/module/lib-build", "target": "{{capability}}-lib/build.gradle.kts",
       "vars": {"capability": "{{capability}}", "extra": "{{extra}}", "apis": "{{apis}}"}},
      {"template": "project/domain/thing", "target": "{{capability}}-lib/src/main/java/{{path}}/{{Ctx}}.java",
       "vars": {"package": "{{basePackage}}", "Name": "{{Ctx}}", "note": "{{ctx}} of {{capability}}"}},
      {"template": "project/domain/thing-test", "target": "{{capability}}-lib/src/test/java/{{path}}/{{Ctx}}Test.java",
       "vars": {"package": "{{basePackage}}", "Name": "{{Ctx}}"}},
      {"when": "!extra", "copy": "seed.sql", "target": "{{capability}}-lib/src/test/resources/seed.sql"},
      {"when": "extra", "template": "project/module/extra-build", "target": "{{capability}}-extra/build.gradle.kts",
       "vars": {"capability": "{{capability}}"}}
    ],
    "register": {"settings": "settings.gradle.kts", "dependents": {"app/build.gradle.kts": ["lib"]}}
  },
  "smoke": {
    "context": ["--extra", "zz", "Zz", "a.b.zz", "Api1"],
    "gradle": ["checkScaffold", "--tests", "x.*"]
  }
}
EOF
  printf 'rootProject.name = "w"\n\ninclude(\n    "app",\n    "old-lib"\n)\n' > "$w/settings.gradle.kts"
  printf 'dependencies {\n    implementation(project(":old-lib"))\n    testImplementation("t")\n}\n' > "$w/app/build.gradle.kts"
  echo 'CREATE ROLE seed;' > "$w/seed.sql"
  echo keep > "$w/old-lib/README.md"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$GRADLE_RECORD"\nexit "${GRADLE_RC:-0}"\n' > "$w/gradlew"
  chmod +x "$w/gradlew"
  printf 'node_modules\n' > "$w/.gitignore"
  git init -q -b main "$w"; git -C "$w" config user.name t; git -C "$w" config user.email t@t
  git -C "$w" add -A; git -C "$w" commit -qm fixture
}
nc() { out="$(cd "$w" && SCAFFOLD_LOG="$tmp/nc.jsonl" bash scripts/scaffold/new-context.sh "$@" 2>&1)"; rc=$?; }
smoke() { out="$(cd "$w" && GRADLE_RECORD="$tmp/gradle.txt" bash scripts/scaffold/smoke.sh "$@" 2>&1)"; rc=$?; }
wiring() { out="$(cd "$w" && bash scripts/test/scaffold-wiring.test.sh 2>&1)"; rc=$?; }
copy() { sed -n 's/^\[smoke\] copy: //p' <<< "$out"; }
clean() { [ -z "$(git -C "$w" status --porcelain)" ]; }

# 1. new-context.sh: usage and bad arguments, nothing written.
fixture
nc
check "1 without arguments: the usage from the config, exit 2" \
  "$([ "$rc" -eq 2 ] && has 'Usage: scripts/scaffold/new-context.sh [--extra] <capability> <Ctx> <basePackage> <apis>' \
     && has 'e.g. scripts/scaffold/new-context.sh ab-cd AbCd a.b.abcd Api1'; echo $?)"
nc --nope ab AbCd a.b Api1
check "1 an unknown flag prints the usage, exit 2" "$([ "$rc" -eq 2 ] && has 'Usage:'; echo $?)"
nc Bad AbCd a.b Api1
check "1 a capability that is not kebab-case is refused" "$([ "$rc" -eq 1 ] && has 'capability must be kebab-case: Bad'; echo $?)"
nc ab-cd abCd a.b Api1
check "1 a Ctx that is not PascalCase is refused" "$([ "$rc" -eq 1 ] && has 'Ctx must be PascalCase: abCd'; echo $?)"
nc ab-cd AbCd A.b Api1
check "1 an invalid base package is refused" "$([ "$rc" -eq 1 ] && has 'invalid base package: A.b'; echo $?)"
check "1 ... and none of them wrote anything" "$(clean; echo $?)"

# 2. new-context.sh renders, copies and registers the context.
nc ab-cd AbCd a.b.abcd Api1
check "2 the context is scaffolded" "$([ "$rc" -eq 0 ]; echo $?)"
out="$(cat "$w/ab-cd-lib/build.gradle.kts" 2>&1)"
check "2 a flag left off is false for a section, an arg is its value" "$(has '// ab-cd extra=no apis=Api1'; echo $?)"
out="$(cat "$w/ab-cd-lib/src/main/java/a/b/abcd/AbCd.java" 2>&1)"
check "2 path, Ctx, ctx and basePackage fill targets and vars" "$(has 'package a.b.abcd;' && has 'class AbCd {' && has 'String note = "abCd of ab-cd";'; echo $?)"
check "2 a test-tree target is rendered (scaffold.sh --test)" "$([ -f "$w/ab-cd-lib/src/test/java/a/b/abcd/AbCdTest.java" ]; echo $?)"
check "2 a copy without its flag is made, a file for the flag is not" \
  "$(cmp -s "$w/seed.sql" "$w/ab-cd-lib/src/test/resources/seed.sql" && [ ! -e "$w/ab-cd-extra" ]; echo $?)"
out="$(cat "$w/settings.gradle.kts" "$w/app/build.gradle.kts")"
check "2 the module joins the settings' include block and the dependent's implementation lines" \
  "$(has $'    "old-lib",\n    "ab-cd-lib"\n)' && has $'    implementation(project(":old-lib"))\n    implementation(project(":ab-cd-lib"))\n    testImplementation'; echo $?)"
out="$(cat "$tmp/nc.jsonl")"
check "2 each rendered file leaves its SCAFFOLD record" "$([ "$(grep -c '"type":"SCAFFOLD"' <<< "$out")" -eq 3 ]; echo $?)"
nc --extra ef Ef a.b.ef Api2
out="$out
$(cat "$w/ef-lib/build.gradle.kts" "$w/settings.gradle.kts" 2>&1)"
check "2 a flag is true for a section and adds its modules and files" \
  "$([ "$rc" -eq 0 ] && has '// ef extra=yes apis=Api2' && [ -f "$w/ef-extra/build.gradle.kts" ] && has '"ef-extra"' \
     && [ ! -e "$w/ef-lib/src/test/resources/seed.sql" ]; echo $?)"

# 3. new-context.sh refuses, writing nothing.
git -C "$w" add -A; git -C "$w" commit -qm contexts
nc ab-cd AbCd a.b.abcd Api1
check "3 an existing module is refused" "$([ "$rc" -eq 1 ] && has 'module exists, refusing: ab-cd-lib' && clean; echo $?)"
mkdir -p "$w/gh-lib-x"; sed -i 's/"settings": "settings.gradle.kts"/"settings": "app\/build.gradle.kts"/' "$w/docs/scaffold-templates/project/scaffold.json"
git -C "$w" add -A; git -C "$w" commit -qm 'no include block'
nc gh Gh a.b.gh Api1
check "3 a settings file without an include block is refused before any file is written" \
  "$([ "$rc" -eq 1 ] && has 'no include( ... ) block in app/build.gradle.kts' && [ ! -e "$w/gh-lib" ] && clean; echo $?)"
git -C "$w" checkout -q HEAD~1 -- docs/scaffold-templates/project/scaffold.json
sed -i 's/"{{ctx}} of {{capability}}"/"{{nope}}"/' "$w/docs/scaffold-templates/project/scaffold.json"
nc gh Gh a.b.gh Api1
check "3 a variable the config names but nobody sets is refused before any file is written" \
  "$([ "$rc" -eq 1 ] && has 'names {{nope}}, which is no variable' && [ ! -e "$w/gh-lib" ]; echo $?)"
rm "$w/docs/scaffold-templates/project/scaffold.json"
nc gh Gh a.b.gh Api1
check "3 without scaffold.json it says what is missing" "$([ "$rc" -eq 1 ] && has 'no docs/scaffold-templates/project/scaffold.json'; echo $?)"

# 4. smoke.sh renders every example in a copy and runs the configured tasks.
fixture
smoke --render-only
c="$(copy)"
check "4 --render-only renders the examples the context did not" \
  "$([ "$rc" -eq 0 ] && has '[smoke] rendered 2 templates (plus the module set of the context)' && [ -f "$c/zz-extra/build.gradle.kts" ]; echo $?)"
out="$(cat "$c/zz-lib/src/main/java/a/b/zz/Thing.java" 2>&1)"
check "4 ... with the example's values, unescaped" "$(has 'String note = "x&y/z";'; echo $?)"
check "4 ... in the copy only: the checkout is untouched" "$(clean && [ ! -e "$w/zz-lib" ]; echo $?)"
check "4 --render-only never runs Gradle" "$([ ! -e "$tmp/gradle.txt" ]; echo $?)"
smoke
check "4 a full run runs ./gradlew with the configured tasks, green removes the copy" \
  "$([ "$rc" -eq 0 ] && has '[smoke] GREEN' && [ "$(cat "$tmp/gradle.txt")" = '--console=plain -q checkScaffold --tests x.*' ] \
     && [ ! -e "$(copy)" ]; echo $?)"
out="$(cd "$w" && GRADLE_RC=1 GRADLE_RECORD="$tmp/gradle.txt" bash scripts/scaffold/smoke.sh 2>&1)"; rc=$?
check "4 a red Gradle run fails and keeps the copy" "$([ "$rc" -eq 1 ] && has 'RED, copy kept' && [ -d "$(copy)" ]; echo $?)"
printf '// changed, not committed\n' >> "$w/docs/scaffold-templates/project/domain/thing.mustache"
smoke --render-only
check "4 the working tree's uncommitted template is the one rendered" \
  "$(grep -qF '// changed, not committed' "$(copy)/zz-lib/src/main/java/a/b/zz/Thing.java"; echo $?)"
git -C "$w" checkout -q -- .
printf 'x\n' > "$w/docs/scaffold-templates/project/domain/orphan.mustache"
smoke --render-only
check "4 a template without an example is red" "$([ "$rc" -eq 1 ] && has 'template without example: docs/scaffold-templates/project/domain/orphan.mustache'; echo $?)"
rm "$w/docs/scaffold-templates/project/domain/orphan.mustache"
echo '{"package": "a.b"}' > "$w/docs/scaffold-templates/project/domain/thing.other.example.json"
smoke --render-only
check "4 an example without a _target is red" "$([ "$rc" -eq 1 ] && has 'thing.other.example.json has no _target'; echo $?)"
rm "$w/docs/scaffold-templates/project/domain/thing.other.example.json"
node -e 'const f = process.argv[1], c = JSON.parse(require("fs").readFileSync(f, "utf8")); delete c.smoke.gradle; require("fs").writeFileSync(f, JSON.stringify(c))' \
  "$w/docs/scaffold-templates/project/scaffold.json"
rm -f "$tmp/gradle.txt"
smoke
check "4 no gradle tasks in the config: it stops after the render" \
  "$([ "$rc" -eq 0 ] && has 'no smoke.gradle tasks' && [ ! -e "$tmp/gradle.txt" ]; echo $?)"
smoke --fast
check "4 an unknown option prints the usage, exit 2" "$([ "$rc" -eq 2 ] && has 'Usage:'; echo $?)"

# 5. The wiring test.
fixture
wiring
check "5 the wiring test passes on wired templates" "$([ "$rc" -eq 0 ] && has 'scaffold-wiring tests: ' && has ', 0 failed' \
  && has 'ok   - 3 scaffold-step renders' && has 'ok   - 4 new-context refuses an existing module (old-lib)'; echo $?)"
printf 'x\n' > "$w/docs/scaffold-templates/project/domain/orphan.mustache"
echo '{"_target": "zz-lib/src/main/java/a/b/zz/Orphan.java"}' > "$w/docs/scaffold-templates/project/domain/orphan.example.json"
wiring
check "5 an unlinked template fails it, and --for misses it" \
  "$([ "$rc" -eq 1 ] && has 'unlinked: project/domain/orphan' && has 'project/domain/orphan at zz-lib/src/main/java/a/b/zz/Orphan.java'; echo $?)"
rm "$w"/docs/scaffold-templates/project/domain/orphan.*
mkdir -p "$w/docs/code-maps"
printf '## Scaffold\n\n| Template | Target | Variables | Left to you |\n|---|---|---|---|\n| [domain/kitthing](../scaffold-templates/domain/kitthing.mustache) | `<capability>-lib/src/main/java/<pkg>/<Name>.java` | package | - |\n' \
  > "$w/docs/code-maps/kit-leaf.md"
wiring
check "5 projectOnly: a row that links a kit template fails, and --for offering it" \
  "$([ "$rc" -eq 1 ] && has 'kit template linked: domain/kitthing (kit-leaf)' && has 'FAIL - 2 --for never offers a kit template'; echo $?)"
sed -i 's/"projectOnly": true/"projectOnly": false/' "$w/docs/scaffold-templates/project/scaffold.json"
wiring
check "5 ... and passes without projectOnly" "$([ "$rc" -eq 0 ]; echo $?)"
rm -r "$w/docs/scaffold-templates/project"
wiring
check "5 a repo without templates of its own passes with nothing to check" "$([ "$rc" -eq 0 ] && has 'nothing to check'; echo $?)"

# 6. A repo that keeps its own scripts: this suite leaves them to the repo's own tests.
for own in new-context.sh smoke.sh; do
  o="$tmp/own-$own"; mkdir -p "$o/scripts/test" "$o/scripts/scaffold"
  cp "$top/scripts/test/scaffold-project.test.sh" "$o/scripts/test/"
  cp "$top/scripts/scaffold/new-context.sh" "$top/scripts/scaffold/smoke.sh" "$o/scripts/scaffold/"
  printf '#!/usr/bin/env bash\necho "the repo'"'"'s own"\n' > "$o/scripts/scaffold/$own"
  out="$(bash "$o/scripts/test/scaffold-project.test.sh" 2>&1)"; rc=$?
  check "6 a repo's own $own: the suite passes without testing it" "$([ "$rc" -eq 0 ] && has "scripts/scaffold/$own is the repo's own"; echo $?)"
done

echo "scaffold-project tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
