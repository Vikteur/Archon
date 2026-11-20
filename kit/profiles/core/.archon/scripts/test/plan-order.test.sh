#!/usr/bin/env bash
# Tests for .archon/scripts/plan-order.js: a plan step that adds a port must deliver its adapter in the same step
# (TASK-7.4, TASK-48.8: the port's use case was a bean, so every test that booted the DI container failed until a later
# step's adapter; Quarkus and Spring alike, so the rule does not read the kit's stack), and
# a plan has at most one (pin only) step, with a `Pin:` line per pinned behaviour.
# Usage: bash .archon/scripts/test/plan-order.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/plan-order.js"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git -C "$root" init -q -b main
mkdir -p "$root/x-usecase/src/main/java/a/repository" "$root/x-adapter/src/main/java/a/adapter/repository"
echo 'interface OldRepository {}' > "$root/x-usecase/src/main/java/a/repository/OldRepository.java"
echo 'class DefaultLateRepository {}' > "$root/x-adapter/src/main/java/a/adapter/repository/DefaultLateRepository.java"
git -C "$root" add -A
plan="$root/plan.md"

expect() { # expect <ok|fail> <name> [<text the output must hold>]
  local got out
  out=$(cd "$root" && node "$script" "$plan" 2>&1) && got=ok || got=fail
  if [ "$got" = "$1" ] && { [ -z "${3:-}" ] || grep -qF -- "$3" <<< "$out"; }; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: $2 (wanted $1, got $got)"; echo "$out" | sed 's/^/    /'; fi
}
write() { printf '%s\n' "$@" > "$plan"; }

write '## Steps' \
  '- [ ] **1. Use case and port: `SignInUseCase`, `SignInAccountRepository`**' \
  '  Test skills: jvm-testing' \
  '- [ ] **2. Adapter: `DefaultSignInAccountRepository`**' \
  '  Build skills: persistence-repository'
expect fail "a port whose adapter comes in a later step fails" \
  'step 1 adds the port SignInAccountRepository, but its adapter DefaultSignInAccountRepository comes only in step 2'

write '## Steps' \
  '- [ ] **1. Use case, port and adapter: `SignInAccountRepository`, `DefaultSignInAccountRepository`**' \
  '- [ ] **2. Web adapter**'
expect ok "port and adapter in one step pass"

write '## Steps' \
  '- [ ] **1. Use case and port: `SignInAccountRepository`**' \
  '- [x] (folded into step 1) **2. Adapter: `DefaultSignInAccountRepository`**'
expect ok "an adapter step folded into the port's step passes"

write '## Steps' \
  '- [ ] **1. Port: `OldRepository`, now with `find`**' \
  '- [ ] **2. Adapter: `DefaultOldRepository`**'
expect ok "a port that exists already is no new port"

write '## Steps' \
  '- [ ] **1. Port: `LateRepository`**' \
  '- [ ] **2. Adapter: `DefaultLateRepository` gets a method**'
expect ok "an adapter that exists already is wired from the start"

write '## Steps' \
  '- [ ] **1. Use case: `SignInUseCase`**' \
  '  - Hand-written: x-usecase/src/main/java/a/repository/PasswordVerifier.java — no template' \
  '- [ ] **2. Crypto adapter**' \
  '  - x-adapter/src/main/java/a/adapter/crypto/DefaultPasswordVerifier.java'
expect fail "a port named only by its usecase repository path counts" \
  'step 1 adds the port PasswordVerifier, but its adapter DefaultPasswordVerifier comes only in step 2'

write '## Steps' \
  '- [ ] **1. Gateway port: `PaymentGateway`**' \
  '- [ ] **2. Something else**' \
  '- [ ] **3. `DefaultPaymentGateway`**'
expect fail "a gateway port counts too" 'comes only in step 3'

write 'Tests: `DefaultSignInAccountRepositoryTest` before the steps' '## Steps' \
  '- [ ] **1. Port: `SignInAccountRepository` and `DefaultSignInAccountRepositoryTest`**' \
  '- [ ] **2. Adapter: `DefaultSignInAccountRepository`**'
expect fail "a test class name is not the adapter, and text before the steps is not a step"

write '## Steps' '- [ ] **1. Port: `SignInAccountRepository`, no adapter in this plan**'
expect ok "a port with no adapter in the plan is not this check's"

# Pin steps (owner decision 2026-10-23): a plan has at most one (pin only) step, and it names each pinned behaviour on
# a `Pin:` line, one mutation each.
write '## Steps' \
  '- [ ] (pin only) **1. Pin the existing guest rules**' \
  '  - Pin: `Guest`: a blank name is refused' \
  '  - Pin: `GuestList`: a duplicate is refused' \
  '- [ ] **2. Use case: `InviteGuestUseCase`**'
expect ok "one pin step with Pin: lines passes"

write '## Steps' \
  '- [ ] (pin only) **1. Pin `Guest`**' '  - Pin: `Guest`: a blank name is refused' \
  '- [ ] **2. Use case**' \
  '- [ ] (pin only) **3. Pin `GuestList`**' '  - Pin: `GuestList`: a duplicate is refused'
expect fail "two pin steps fail" 'steps 1 and 3 are both (pin only): put every pin in one (pin only) step'

write '## Steps' '- [ ] (pin only) **1. Pin `Guest`**' '- [ ] **2. Use case**'
expect fail "a pin step without a Pin: line fails" 'step 1 is (pin only) but names no `Pin:` line'

write '## Steps' '- [x] (pin only) **1. Pin `Guest`**' '  - Pin: `Guest`: blank' '- [x] (pin only) (folded into step 1) **2. Pin `GuestList`**'
expect ok "a pin step folded into the pin step is one step"

rm -f "$plan"
expect fail "no plan fails" 'no plan'

# build-feature runs it in plan-check, before any agent writes code, and the planner is told the rule.
wf="$here/../workflows/build-feature-copilot.yaml"
yq '.nodes[] | select(.id == "plan-check") | .script' "$wf" | grep -q 'plan-order\.js'
r=$?; if [ "$r" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: plan-check runs plan-order.js"; fi

# plan-check's skill-line count runs on the node's own script: a skill line is a plain line or a list item under its
# step (run efc54c08, 2026-10-24: "4 steps but 0 'Test skills:' lines" on `  - Test skills: ...`), as skill-check.js
# reads it; a step without its two lines still fails.
pc_script="$(mktemp -d)/plan-check.js"
yq '.nodes[] | select(.id == "plan-check") | .script' "$wf" > "$pc_script"
plan_check() { # plan_check <want ok|fail> <label> <plan lines...>
  local want=$1 label=$2 art; shift 2; art=$(mktemp -d)
  printf '%s\n' "$@" > "$art/plan.md"
  (cd "$here/../.." && ARTIFACTS_DIR="$art" node "$pc_script") > /dev/null 2>&1
  local r=$? ok=fail; [ "$r" -eq 0 ] && ok=ok
  if [ "$ok" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: plan-check: $label (exit $r)"; fi
}
plan_check ok "plain skill lines" '- [ ] **1. Add `Guest`**' '  Test skills: tdd-loop' '  Build skills: java'
plan_check ok "skill lines as list items" '- [ ] **1. Add `Guest`**' '  - Test skills: tdd-loop' '  - Build skills: java'
plan_check ok "skill lines as starred items" '- [ ] **1. Add `Guest`**' '  * Test skills: tdd-loop' '  * Build skills: java'
plan_check fail "a step without its Build skills line" '- [ ] **1. Add `Guest`**' '  - Test skills: tdd-loop'
# A skills line inside a code fence is a sample, which skill-check.js does not read (TASK-77): it is not counted either.
plan_check fail "a Build skills line only inside a backtick fence" \
  '- [ ] **1. Add `Guest`**' '  Test skills: tdd-loop' '  ```' '  Build skills: java' '  ```'
plan_check fail "a Test skills line only inside a tilde fence" \
  '- [ ] **1. Add `Guest`**' '  ~~~' '  Test skills: tdd-loop' '  ~~~' '  Build skills: java'
plan_check fail "a tilde line does not close a backtick fence" \
  '- [ ] **1. Add `Guest`**' '  Test skills: tdd-loop' '  ```' '  ~~~' '  Build skills: java' '  ```'
plan_check ok "a fenced sample beside the step's own skill lines" \
  '- [ ] **1. Add `Guest`**' '  Test skills: tdd-loop' '  ```' '  Build skills: java' '  ```' '  Build skills: java'
yq '.nodes[] | select(.id == "plan") | .prompt' "$wf" | grep -q 'adapter (or a stub) in the same step'
r=$?; if [ "$r" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: the plan prompt names the port rule"; fi

yq '.nodes[] | select(.id == "plan") | .prompt' "$wf" | grep -q 'at most one `(pin only)` step'
r=$?; if [ "$r" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: the plan prompt names the one-pin-step rule"; fi
yq '.nodes[] | select(.id == "implement") | .loop_group.nodes[] | select(.id == "write-tests") | .prompt' "$wf" \
  | tr '\n' ' ' | grep -q 'for each `Pin:` line'
r=$?; if [ "$r" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: write-tests mutates once for each Pin: line"; fi

# The rule is the same on the spring stack (a missing bean fails the Spring context too): KIT_STACK changes nothing.
write '## Steps' \
  '- [ ] **1. Use case and port: `SignInUseCase`, `SignInAccountRepository`**' \
  '- [ ] **2. Adapter: `DefaultSignInAccountRepository`**'
out=$(cd "$root" && KIT_STACK=spring node "$script" "$plan" 2>&1); r=$?
if [ "$r" -ne 0 ] && grep -qF 'but its adapter DefaultSignInAccountRepository comes only in step 2' <<< "$out"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: spring stack: a port whose adapter comes later still fails"; echo "$out" | sed 's/^/    /'; fi

echo "plan-order: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
