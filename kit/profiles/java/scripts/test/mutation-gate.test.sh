#!/usr/bin/env bash
# Tests .claude/scripts/mutation-gate.sh (decision 2026-10-18): it targets only the main classes the branch changes in
# the domain, usecase and gateway modules (gateways: owner decision 2026-10-18), runs one Gradle pitest for their modules, fails on a surviving or uncovered mutant,
# passes when config/mutation-accepted.txt accepts it with a reason, and runs no Gradle when there is no target. Each
# case builds a throwaway clone of a throwaway origin with a stub gradlew that logs its arguments and writes a PIT
# report from scripts/test/fixtures/mutation-gate, so no real PIT runs.
# Usage: bash scripts/test/mutation-gate.test.sh
set -uo pipefail
# No automatic gc or maintenance in the throwaway repos: a background gc racing the next git call was the suspected
# cause of the temp-repo flakes (docs/memory.md 2026-10-20).
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0
export GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false
export GIT_CONFIG_KEY_2=receive.autoGc GIT_CONFIG_VALUE_2=false

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/.claude/scripts/mutation-gate.sh"
fixtures="$repo_root/scripts/test/fixtures/mutation-gate"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
passed=0
failed=0

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

out=""
rc=0
log="$tmp/log"

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    passed=$((passed + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name"
    printf '%s\n' "$out" | sed 's/^/       | /'
  fi
}

# The stub gradlew logs its arguments; for each :<module>:pitest it copies $tmp/report-<module>.xml, when there is
# one, to that module's PIT report; it exits with the code in $tmp/rc-gradlew, else 0.
write_gradlew() {
  cat > gradlew <<EOF
#!/usr/bin/env bash
echo "gradlew \$*" >> "$log"
for a in "\$@"; do
  case "\$a" in
    :*:pitest) m="\${a#:}"; m="\${m%:pitest}"
      if [ -f "$tmp/report-\$m.xml" ]; then mkdir -p "\$m/build/reports/pitest"; cp "$tmp/report-\$m.xml" "\$m/build/reports/pitest/mutations.xml"; fi ;;
  esac
done
[ -f "$tmp/rc-gradlew" ] && exit "\$(cat "$tmp/rc-gradlew")"
exit 0
EOF
  chmod +x gradlew
}

# new_repo <dir>: a clone of a fresh origin whose main holds x-domain, x-usecase, x-gateway and x-adapter, each with
# one main class, a test, docs and the accept file; the clone is on branch feat.
new_repo() {
  local d="$1" m
  rm -rf "$d" "$d.git" "$tmp/rc-gradlew" "$tmp/report-"*
  git init -q --bare -b main "$d.git"
  git init -q -b main "$d"
  cd "$d" || exit 1
  for m in x-domain x-usecase x-gateway x-adapter; do
    mkdir -p "$m/src/main/java/app/x" "$m/src/test/java/app/x"
    echo 'class A {}' > "$m/src/main/java/app/x/A.java"
    echo 'class ATest {}' > "$m/src/test/java/app/x/ATest.java"
  done
  echo 'package app.x;' > x-domain/src/main/java/app/x/package-info.java
  mkdir -p docs config && echo a > docs/readme.md
  echo '# header' > config/mutation-accepted.txt
  printf 'build/\n' > .gitignore
  write_gradlew
  git add -A && git commit -qm base
  git remote add origin "$d.git" && git push -q origin main
  git checkout -qb feat
}

run() {
  : > "$log"
  out="$(bash "$script" "$@" 2>&1)"
  rc=$?
}

ran_gradle() { [ -s "$log" ]; }
no_gradle() { [ ! -s "$log" ]; }
logged() { grep -xF "$1" "$log" >/dev/null; }
said() { printf '%s\n' "$out" | grep -F -- "$1" >/dev/null; }
r="$tmp/repo"

# No change in a gated module: no Gradle, a pass.
new_repo "$r"
echo b > docs/readme.md && echo 'class B {}' > x-adapter/src/main/java/app/x/A.java && git commit -qam other
run
check "no target: exit 0" test "$rc" -eq 0
check "no target: no Gradle" no_gradle
check "no target: says so" said "nothing to mutate"

# A test file, a package-info and a deleted class are no target.
new_repo "$r"
echo '// b' >> x-domain/src/test/java/app/x/ATest.java
echo '// b' >> x-domain/src/main/java/app/x/package-info.java
git rm -q x-usecase/src/main/java/app/x/A.java && git commit -qam t
run
check "tests, package-info, deleted: no Gradle" no_gradle
check "tests, package-info, deleted: exit 0" test "$rc" -eq 0

# Changed classes in two modules, one untracked: one Gradle run, both modules, every class.
new_repo "$r"
echo '// b' >> x-domain/src/main/java/app/x/A.java && git commit -qam t
mkdir -p x-usecase/src/main/java/app/x/sub && echo 'class C {}' > x-usecase/src/main/java/app/x/sub/C.java
cp "$fixtures/killed.xml" "$tmp/report-x-domain.xml"
run
check "targets: one pitest run with each class" \
  logged "gradlew :x-domain:pitest :x-usecase:pitest -PpitTargets=app.x.A,app.x.sub.C --console=plain"
check "all detected: exit 0" test "$rc" -eq 0
check "all detected: counts" said "mutation-gate: 2 mutants, 2 detected, 0 not killed, 0 accepted"
check "all detected: ends ok" said "mutation-gate: ok"

# A gateway module is gated by its name (owner decision 2026-10-18): a changed main class is a target, its tests are not.
new_repo "$r"
mkdir -p x-gateway/src/main/java/app/x/gw && echo 'class G {}' > x-gateway/src/main/java/app/x/gw/G.java
echo '// b' >> x-gateway/src/test/java/app/x/ATest.java && git add -A && git commit -qm t
cp "$fixtures/survived.xml" "$tmp/report-x-gateway.xml"
run
check "gateway: its main class is the target" logged "gradlew :x-gateway:pitest -PpitTargets=app.x.gw.G --console=plain"
check "gateway: a survivor fails it" test "$rc" -eq 1
check "gateway: survivor printed" said "SURVIVED: app.x.domain.Parse:23:ConditionalsBoundaryMutator"

# A gateway test class alone, or a module whose name only contains "gateway", is no target.
new_repo "$r"
echo '// b' >> x-gateway/src/test/java/app/x/ATest.java
mkdir -p x-gateway-adapter/src/main/java/app/x && echo 'class H {}' > x-gateway-adapter/src/main/java/app/x/H.java
git add -A && git commit -qm t
run
check "gateway test, *-gateway-adapter: no Gradle" no_gradle

# A surviving and an uncovered mutant fail the gate, each printed with class, line, mutator and description.
new_repo "$r"
echo '// b' >> x-domain/src/main/java/app/x/A.java && git commit -qam t
cp "$fixtures/survived.xml" "$tmp/report-x-domain.xml"
run
check "survivor: exit 1" test "$rc" -eq 1
check "survivor: printed" said "SURVIVED: app.x.domain.Parse:23:ConditionalsBoundaryMutator (parse) changed conditional boundary"
check "uncovered: printed, nested class, entities decoded" \
  said 'NO_COVERAGE: app.x.domain.Parse$Part:40:EmptyObjectReturnValsMutator (of) replaced return value with "" for'
check "survivor: counts" said "mutation-gate: 3 mutants, 1 detected, 2 not killed, 0 accepted"
check "survivor: no ok" test -z "$(printf '%s\n' "$out" | grep -xF 'mutation-gate: ok')"

# Both accepted with a reason: the gate passes and says what it accepted.
new_repo "$r"
echo '// b' >> x-domain/src/main/java/app/x/A.java && git commit -qam t
cp "$fixtures/survived.xml" "$tmp/report-x-domain.xml"
printf '%s\n' 'app.x.domain.Parse:23:ConditionalsBoundaryMutator # equivalent: the boundary value cannot occur' \
  'app.x.domain.Parse$Part:40:EmptyObjectReturnValsMutator   #  equivalent: never called with an empty part' \
  >> config/mutation-accepted.txt
run
check "accepted: exit 0" test "$rc" -eq 0
check "accepted: printed" said "accepted:  app.x.domain.Parse:23:ConditionalsBoundaryMutator"
check "accepted: counts" said "mutation-gate: 3 mutants, 1 detected, 0 not killed, 2 accepted"

# One accepted, one not: still a failure.
new_repo "$r"
echo '// b' >> x-domain/src/main/java/app/x/A.java && git commit -qam t
cp "$fixtures/survived.xml" "$tmp/report-x-domain.xml"
echo 'app.x.domain.Parse:23:ConditionalsBoundaryMutator # equivalent' >> config/mutation-accepted.txt
run
check "partly accepted: exit 1" test "$rc" -eq 1
check "partly accepted: the other printed" said "NO_COVERAGE: app.x.domain.Parse\$Part:40"

# An accept line on another line number does not match.
new_repo "$r"
echo '// b' >> x-domain/src/main/java/app/x/A.java && git commit -qam t
cp "$fixtures/survived.xml" "$tmp/report-x-domain.xml"
printf '%s\n' 'app.x.domain.Parse:24:ConditionalsBoundaryMutator # moved' \
  'app.x.domain.Parse$Part:40:EmptyObjectReturnValsMutator # equivalent' >> config/mutation-accepted.txt
run
check "other line: exit 1" test "$rc" -eq 1

# An accept line without a reason fails the gate even when it matches.
new_repo "$r"
echo '// b' >> x-domain/src/main/java/app/x/A.java && git commit -qam t
cp "$fixtures/survived.xml" "$tmp/report-x-domain.xml"
printf '%s\n' 'app.x.domain.Parse:23:ConditionalsBoundaryMutator' \
  'app.x.domain.Parse$Part:40:EmptyObjectReturnValsMutator #' >> config/mutation-accepted.txt
run
check "no reason: exit 1" test "$rc" -eq 1
check "no reason: named" said "gives no reason"

# A report left by an earlier run does not answer for this one.
new_repo "$r"
echo '// b' >> x-domain/src/main/java/app/x/A.java && git commit -qam t
mkdir -p x-domain/build/reports/pitest && cp "$fixtures/survived.xml" x-domain/build/reports/pitest/mutations.xml
run
check "stale report: removed, exit 0" test "$rc" -eq 0
check "stale report: no mutants" said "mutation-gate: 0 mutants"

# A failed Gradle run fails the gate with its exit code.
new_repo "$r"
echo '// b' >> x-domain/src/main/java/app/x/A.java && git commit -qam t
echo 3 > "$tmp/rc-gradlew"
run
check "gradle fails: its exit code" test "$rc" -eq 3
check "gradle fails: named" said "FAIL: ./gradlew :x-domain:pitest"

# The merge-base, not origin/main's tip: a later commit on main is not this branch's change.
new_repo "$r"
echo b > docs/readme.md && git commit -qam docs
git checkout -q main && echo '// b' >> x-domain/src/main/java/app/x/A.java && git commit -qam main-moves && git push -q origin main
git checkout -q feat
run
check "merge-base: main's later commit is no target" no_gradle

# --base: on main itself there is no diff, so no Gradle.
new_repo "$r"
git checkout -q main
run --base origin/main
check "on main: no Gradle" no_gradle
check "on main: exit 0" test "$rc" -eq 0

# --dry-run prints the command and runs nothing.
new_repo "$r"
echo '// b' >> x-domain/src/main/java/app/x/A.java && git commit -qam t
run --dry-run
check "dry run: prints the command" said "run: ./gradlew :x-domain:pitest -PpitTargets=app.x.A"
check "dry run: runs nothing" no_gradle

# --list-targets: the target rule as a filter over paths (ci-plan.sh's one source for it); no repo, no Gradle.
cd "$tmp" || exit 1
out=$(printf '%s\n' x-domain/src/main/java/app/A.java shared-usecase/src/main/java/app/B.java \
  pay-gateway/src/main/java/app/C.java x-domain/src/main/java/app/package-info.java x-domain/src/main/java/module-info.java \
  x-web/src/main/java/app/D.java x-domain/src/test/java/app/ATest.java x-domain/src/main/java/app/E.kt docs/x.md \
  'y-domain/src/main/java/app/F.java'$'\r' | bash "$script" --list-targets 2>&1); rc=$?
check "list-targets: exit 0" test "$rc" -eq 0
check "list-targets: domain, usecase and gateway main classes, as given" test "$out" = "x-domain/src/main/java/app/A.java
shared-usecase/src/main/java/app/B.java
pay-gateway/src/main/java/app/C.java
y-domain/src/main/java/app/F.java"
out=$(printf '%s\n' docs/x.md | bash "$script" --list-targets 2>&1); rc=$?
check "list-targets: no target is exit 0 and no output" test "$rc" -eq 0 -a -z "$out"
out=$(: | bash "$script" --list-targets --base x 2>&1); rc=$?
check "list-targets: another argument is a usage error" test "$rc" -eq 2

cd "$repo_root" || exit 1
echo "mutation-gate tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
