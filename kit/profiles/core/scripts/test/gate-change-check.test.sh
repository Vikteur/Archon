#!/usr/bin/env bash
# Tests .claude/scripts/gate-change-check.sh (CI plan C11): a change to a gate (the job set or steps of ci.yml,
# ci-inputs.yml, ci-plan.sh, the accept rules of local-ci-status.sh and the grammar's reader, the gates map of the kit
# config) fails unless the same
# change adds a dated decision entry to docs/memory.md that names the gate; comment-only changes are not gate changes.
# Each case works in a throwaway repo whose commit "base" holds a small copy of every gate file.
# Usage: bash scripts/test/gate-change-check.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.claude/scripts/gate-change-check.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
out=""; rc=0

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0
export GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false
export GIT_CONFIG_KEY_2=receive.autoGc GIT_CONFIG_VALUE_2=false
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset GATE_BASE

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"
  else fail=$((fail+1)); echo "FAIL - $1"; printf '%s\n' "$out" | sed 's/^/       | /'; fi
}
said() { grep -qF -- "$1" <<< "$out"; }

# The base: every gate file, small.
tpl="$tmp/tpl"
mkdir -p "$tpl/.github/workflows" "$tpl/.claude/scripts" "$tpl/.archon/scripts" "$tpl/docs"
cat > "$tpl/.github/workflows/ci.yml" <<'EOF'
# the jobs
on: [push]
jobs:
  test:
    timeout-minutes: 30
    steps:
      - run: ./gradlew test
  lint:
    steps:
      - run: lint check
EOF
cat > "$tpl/.github/ci-inputs.yml" <<'EOF'
# the manifest
version: 1
always:
  - .github/ci-inputs.yml
EOF
printf '#!/usr/bin/env bash\n# the planner\nplan() {\n  echo run\n}\nplan\n' > "$tpl/.claude/scripts/ci-plan.sh"
cat > "$tpl/.archon/scripts/local-ci-status.sh" <<'EOF'
#!/usr/bin/env bash
statuses() {
  echo none
}
parse() {
  echo ran
}
verify() {
  return 1
}
# accept: may this success count?
accept() {
  case "$1" in ran) return 0 ;; *) return 1 ;; esac
}
echo done
EOF
printf 'ci_status_ran() {\n  printf ran\n}\nci_status_parse() {\n  echo kind=ran\n}\n' > "$tpl/.claude/scripts/ci-status-grammar.sh"
printf '# Memory\n\n## 2026-10-01 — first\n- a decision\n' > "$tpl/docs/memory.md"
printf 'base_branch: main\ngates: # ci-gate.sh\n  format: report\n  secrets: report\n' > "$tpl/.archon/kit.yaml"
echo readme > "$tpl/README.md"
git -C "$tpl" init -q -b main && git -C "$tpl" add -A && git -C "$tpl" commit -qm base

new_repo() { r="$tmp/r$((++n))"; cp -r "$tpl" "$r"; cd "$r" || exit 1; git checkout -q -b feat; }
n=0
commit() { git add -A && git commit -qm change; }
run() { out="$(bash "$script" "$@" 2>&1)"; rc=$?; }
entry() { printf '\n## 2026-10-20 — a gate change\n- %s\n' "$1" >> docs/memory.md; }

# 1. No gate changed.
new_repo; echo more >> README.md; commit; run main
check "1 a change to no gate passes" "$([ "$rc" -eq 0 ] && said 'gate-change-check: no gate changed'; echo $?)"

# 2. ci.yml.
new_repo; sed -i 's/# the jobs/# the CI jobs/' .github/workflows/ci.yml; commit; run main
check "2 a comment in ci.yml is no gate change" "$([ "$rc" -eq 0 ]; echo $?)"
new_repo; sed -i 's/timeout-minutes: 30/timeout-minutes: 40/' .github/workflows/ci.yml; commit; run main
check "2 a key outside the job set and steps is no gate change" "$([ "$rc" -eq 0 ]; echo $?)"
new_repo; printf '  extra:\n    steps:\n      - run: echo extra\n' >> .github/workflows/ci.yml; commit; run main
check "2 a new job without an entry fails" "$([ "$rc" -eq 1 ] && said 'gate changed: ci.yml (.github/workflows/ci.yml: the job set)' \
  && said 'FAIL: ci.yml changed, but the change adds no decision entry'; echo $?)"
entry "ci.yml gets the extra job"; commit; run main
check "2 ... and passes with a dated entry that names ci.yml" "$([ "$rc" -eq 0 ] && said 'gate-change-check: ok'; echo $?)"
new_repo; sed -i 's/lint check/lint check --strict/' .github/workflows/ci.yml; entry "the lint step is stricter"; commit; run main
check "2 a changed step with an entry that does not name ci.yml fails" "$([ "$rc" -eq 1 ] \
  && said 'gate changed: ci.yml (.github/workflows/ci.yml: the steps of a job)' && said 'does not name it (ci.yml)'; echo $?)"
new_repo; sed -i 's/lint check/lint check --strict/' .github/workflows/ci.yml
printf -- '- ci.yml: the lint step is stricter\n' >> docs/memory.md; commit; run main
check "2 a bullet without a dated heading is no entry" "$([ "$rc" -eq 1 ] && said 'adds no decision entry'; echo $?)"
new_repo; sed -i 's/lint check/lint check --strict/' .github/workflows/ci.yml
printf '\n## Decisions\n\n### 2026-10-21 — the lint step is stricter\n- ci.yml: the lint step\n' >> docs/memory.md; commit; run main
check "2 a ### entry under a ## Decisions section counts" "$([ "$rc" -eq 0 ] && said 'gate-change-check: ok'; echo $?)"
new_repo; sed -i 's/lint check/lint check --strict/' .github/workflows/ci.yml
printf '\n#### 2026-10-21 — too deep\n- ci.yml: the lint step\n' >> docs/memory.md; commit; run main
check "2 a #### heading is no entry" "$([ "$rc" -eq 1 ] && said 'adds no decision entry'; echo $?)"

# 3. ci-inputs.yml.
new_repo; sed -i 's/# the manifest/# the input manifest/' .github/ci-inputs.yml; commit; run main
check "3 a comment in ci-inputs.yml is no gate change" "$([ "$rc" -eq 0 ]; echo $?)"
new_repo; printf '  - .gitattributes\n' >> .github/ci-inputs.yml; commit; run main
check "3 a changed manifest without an entry fails" "$([ "$rc" -eq 1 ] && said 'gate changed: ci-inputs.yml'; echo $?)"

# 4. ci-plan.sh.
new_repo; sed -i 's/# the planner/# the run-or-reuse planner/' .claude/scripts/ci-plan.sh; printf '\n# more\n' >> .claude/scripts/ci-plan.sh; commit; run main
check "4 comments and blank lines in ci-plan.sh are no gate change" "$([ "$rc" -eq 0 ]; echo $?)"
new_repo; sed -i 's/echo run$/echo reuse/' .claude/scripts/ci-plan.sh; commit; run main
check "4 changed planner code without an entry fails" "$([ "$rc" -eq 1 ] && said 'gate changed: ci-plan'; echo $?)"
entry "ci-plan.sh reuses"; commit; run main
check "4 ... and passes with an entry that names ci-plan" "$([ "$rc" -eq 0 ]; echo $?)"

# 5. The accept rules.
new_repo; sed -i 's/echo none/echo pending/; s/^echo done/echo finished/' .archon/scripts/local-ci-status.sh; commit; run main
check "5 local-ci-status.sh outside parse, verify and accept is no gate change" "$([ "$rc" -eq 0 ]; echo $?)"
new_repo; sed -i 's/# accept: may this success count?/# accept: does it count?/' .archon/scripts/local-ci-status.sh; commit; run main
check "5 a comment above accept is no gate change" "$([ "$rc" -eq 0 ]; echo $?)"
new_repo; sed -i 's/ran) return 0/ran|reuse) return 0/' .archon/scripts/local-ci-status.sh; commit; run main
check "5 a changed accept without an entry fails" "$([ "$rc" -eq 1 ] \
  && said 'gate changed: local-ci-status (.archon/scripts/local-ci-status.sh: parse, verify or accept)'; echo $?)"
new_repo; sed -i 's/return 1$/return 0/' .archon/scripts/local-ci-status.sh; commit; run main
check "5 a changed verify fails too" "$([ "$rc" -eq 1 ] && said 'gate changed: local-ci-status'; echo $?)"
new_repo; sed -i 's/kind=ran/kind=reuse/' .claude/scripts/ci-status-grammar.sh; commit; run main
check "5 a changed ci_status_parse counts as the accept rules" "$([ "$rc" -eq 1 ] \
  && said 'gate changed: local-ci-status (.claude/scripts/ci-status-grammar.sh: ci_status_parse)'; echo $?)"
entry "ci-status-grammar reads reuse"; commit; run main
check "5 ... and an entry naming ci-status-grammar passes" "$([ "$rc" -eq 0 ]; echo $?)"
new_repo; sed -i 's/printf ran/printf "ran "/' .claude/scripts/ci-status-grammar.sh; commit; run main
check "5 a grammar writer change is no accept-rule change" "$([ "$rc" -eq 0 ]; echo $?)"

# 6. Two gates, one named.
new_repo; sed -i 's/echo run$/echo reuse/' .claude/scripts/ci-plan.sh; printf '  - x\n' >> .github/ci-inputs.yml
entry "ci-plan.sh reuses"; commit; run main
check "6 every changed gate must be named" "$([ "$rc" -eq 1 ] && said 'FAIL: ci-inputs.yml changed, but the decision entry' \
  && ! said 'FAIL: ci-plan'; echo $?)"

# 7. The work tree by default; a named head compares commits only.
new_repo; sed -i 's/echo run$/echo reuse/' .claude/scripts/ci-plan.sh; run main
check "7 an uncommitted gate change is seen by default" "$([ "$rc" -eq 1 ] && said 'gate changed: ci-plan'; echo $?)"
run main HEAD
check "7 with <head> only commits count" "$([ "$rc" -eq 0 ] && said 'no gate changed'; echo $?)"
commit; git checkout -q main; echo more >> README.md; commit; run main feat
check "7 the base side is the merge-base, not the base's tip" "$([ "$rc" -eq 1 ] && said 'gate changed: ci-plan'; echo $?)"
out="$(GATE_BASE=main bash "$script" 2>&1)"; rc=$?
check "7 GATE_BASE names the default base" "$([ "$rc" -eq 0 ] && said 'no gate changed'; echo $?)"

# 9. The report-only gates of ci-gate.sh: kit key gates in .archon/kit.yaml or .archon/kit.defaults.yaml.
new_repo; sed -i 's/base_branch: main/base_branch: trunk/; s/# ci-gate.sh/# the CI gates/' .archon/kit.yaml; commit; run main
check "9 another kit key or a comment in kit.yaml is no gate change" "$([ "$rc" -eq 0 ] && said 'no gate changed'; echo $?)"
new_repo; sed -i 's/format: report/format: block/' .archon/kit.yaml; commit; run main
check "9 a gate switched to block without an entry fails" "$([ "$rc" -eq 1 ] \
  && said 'gate changed: kit-gates (.archon/kit.yaml: gates)' && said 'FAIL: kit-gates changed'; echo $?)"
entry "kit-gates: format blocks"; commit; run main
check "9 ... and passes with an entry that names kit-gates" "$([ "$rc" -eq 0 ] && said 'gate-change-check: ok'; echo $?)"
new_repo; sed -i '/secrets: report/d' .archon/kit.yaml; commit; run main
check "9 a gate taken out of the map is a gate change" "$([ "$rc" -eq 1 ] && said 'gate changed: kit-gates'; echo $?)"
new_repo; printf 'gates:\n  coverage: block\n' > .archon/kit.defaults.yaml; commit; run main
check "9 a new kit.defaults.yaml with gates is a gate change" "$([ "$rc" -eq 1 ] \
  && said 'gate changed: kit-gates (.archon/kit.defaults.yaml: gates)'; echo $?)"

# 8. Usage and fail closed.
new_repo; run --bogus
check "8 an option is refused" "$([ "$rc" -eq 2 ]; echo $?)"
run a b c
check "8 three arguments are refused" "$([ "$rc" -eq 2 ]; echo $?)"
run no-such-ref
check "8 no merge-base fails closed" "$([ "$rc" -eq 3 ] && said 'could not run: no merge-base'; echo $?)"
cd "$tmp" && out="$(bash "$script" main 2>&1)"; rc=$?
check "8 outside a repo fails closed" "$([ "$rc" -eq 3 ]; echo $?)"
new_repo; printf '  image:\n    steps: []\n' >> .github/workflows/ci.yml; commit
bin="$tmp/bin"; mkdir -p "$bin"
for c in bash git awk grep sed tr cat dirname env; do ln -sf "$(command -v "$c")" "$bin/$c"; done
out="$(PATH="$bin" bash "$script" main 2>&1)"; rc=$?
check "8 yq missing while ci.yml changed fails closed" "$([ "$rc" -eq 3 ] && said 'yq (mikefarah v4) is required'; echo $?)"

cd "$tmp" || exit 1
echo "gate-change-check tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
