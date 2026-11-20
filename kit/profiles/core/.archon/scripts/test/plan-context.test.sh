#!/usr/bin/env bash
# Tests for .archon/scripts/plan-context.sh against a throwaway repo and a stubbed backlog CLI.
# Usage: bash .archon/scripts/test/plan-context.test.sh   (exit 0 = all pass)
set -uo pipefail
# No automatic gc or maintenance in the throwaway repos: a background gc racing the next git call was the suspected
# cause of the temp-repo flakes (docs/memory.md 2026-10-20).
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0
export GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false
export GIT_CONFIG_KEY_2=receive.autoGc GIT_CONFIG_VALUE_2=false

# The build workflow is read from .archon/kit.yaml only, never from the caller's environment.
unset BUILD_WORKFLOW KIT_CONFIG
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plan-context.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$root/out.md" 2>/dev/null; fi
}
has() { grep -qF -- "$1" "$root/out.md"; }

# The backlog stub knows TASK-1 (with a final summary) and TASK-2 (without one); any other id exits 1, like the CLI.
mkdir -p "$root/bin"
cat > "$root/bin/backlog" <<'STUB'
#!/usr/bin/env bash
echo "backlog $*" >> "$BACKLOG_LOG"
case "$3" in
  TASK-1) echo '{"task":{"id":"TASK-1","title":"First","status":"Done","finalSummary":"Built   the\nthing."}}' ;;
  TASK-2) echo '{"task":{"id":"TASK-2","title":"Second","status":"To Do"}}' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$root/bin/backlog"
export PATH="$root/bin:$PATH" BACKLOG_LOG="$root/backlog.log" BACKLOG_CWD="$root/backlog-home"

repo="$root/repo"
mkdir -p "$repo/a-domain" "$repo/a-usecase" "$repo/.archon/workflows" "$repo/.archon/scripts/test" "$repo/scripts/test" \
  "$repo/docs/code-maps"
cd "$repo" || exit 1
git init -q && git config user.email t@t && git config user.name t
cat > settings.gradle.kts <<'EOF'
rootProject.name = "x"
include(
    "a-domain",
    "a-usecase",
    "no-build-file",
)
EOF
echo 'dependencies { testFixturesApi(testFixtures(project(":a-domain"))) }' > a-domain/build.gradle.kts
printf 'dependencies {\n  implementation(project(":a-domain"))\n  testImplementation(testFixtures(project(":a-domain")))\n}\n' > a-usecase/build.gradle.kts
cat > .archon/workflows/build-feature-copilot.yaml <<'EOF'
nodes:
  - id: ticket
    bash: x
  - id: plan
    depends_on: [ticket]
  - id: implement
    depends_on: [plan]
    loop_group:
      nodes:
        - id: write-tests
        - id: build-step
          depends_on: [write-tests]
EOF
printf '# Memory\n\n## 2026-10-01 — first decision\n\ntext\n\n### 2026-10-02 — sub\n' > docs/memory.md
touch docs/code-maps/java.md docs/code-maps/README.md
printf '#!/usr/bin/env bash\n# Does the gate thing for a run. It also\n# does more.\n# Usage: gate.sh <run>\nset -e\n' > .archon/scripts/gate.sh
touch .archon/scripts/test/gate.test.sh
printf '// Traces one run (P2: a script, not a model): which\n// skills it used.\nconst x = 1;\n' > .archon/scripts/trace.js
printf '#!/usr/bin/env bash\n# A repo script whose header runs past the cap %s\n' "$(printf 'word %.0s' $(seq 1 80))" > scripts/long.sh
touch scripts/test/long.test.sh
# A stand-in for scripts/contract-mcp/plan-ops.mjs (its own test is scripts/test/contract-mcp.test.sh): it names an
# operation when the ticket does, and prints nothing otherwise.
mkdir -p contract/dist scripts/contract-mcp/node_modules
echo 'openapi: 3.0.3' > contract/dist/openapi.yaml
cat > scripts/contract-mcp/plan-ops.mjs <<'EOF'
import { readFileSync } from 'node:fs';
if (/\bsignIn\b/.test(readFileSync(process.argv[2], 'utf8'))) console.log('## Contract operations this ticket names\n\n- **signIn** stub');
EOF
git add -A && git commit -qm "feat: the fixture"

printf 'Task TASK-9 - x\n\nDepends on: TASK-1, TASK-2, TASK-404\n\nDescription:\n' > "$root/ticket.md"
bash "$script" "$root/ticket.md" > "$root/out.md"; check "exits 0" $?

has "- **TASK-1** (Done) First"; check "dependency title and status" $?
has "  Built the thing."; check "final summary on one line" $?
has "- **TASK-2** (To Do) Second"; check "dependency without a summary" $?
has "- **TASK-404**: not in the Backlog"; check "unknown dependency is named, not fatal" $?
has "- a-domain"$'\n' || grep -qx -- "- a-domain" "$root/out.md"; check "module whose only reference is itself has no arrow" $?
grep -qx -- "- a-usecase → :a-domain" "$root/out.md"; check "module dependency, repeat left out" $?
grep -qx -- "- no-build-file" "$root/out.md"; check "module without a build file is listed" $?
grep -qx -- "- plan ← ticket" "$root/out.md"; check "node with its dependency" $?
grep -qx -- "  - build-step ← write-tests" "$root/out.md"; check "nested node is indented" $?
grep -qx -- "- 3: 2026-10-01 — first decision" "$root/out.md" && grep -qx -- "- 7: 2026-10-02 — sub" "$root/out.md"
check "memory sections with line numbers" $?
grep -qx -- "java" "$root/out.md"; check "code-maps leaves, README left out" $?
has '- `.archon/scripts/gate.sh`: Does the gate thing for a run.'; check "header cut at its first sentence" $?
has '  usage: `gate.sh <run>`'; check "usage line" $?
has '  test: `.archon/scripts/test/gate.test.sh`'; check "the script's own test" $?
has '- `.archon/scripts/trace.js`: Traces one run (P2: a script, not a model): which skills it used.'
check "js header without a shebang, joined across lines" $?
has '  test: `scripts/test/long.test.sh`' && grep -q 'long.sh`: A repo script.*…$' "$root/out.md"; check "long header capped" $?
has "feat: the fixture"; check "recent commits" $?
! has "## Contract operations"; check "a ticket that names no operation has no operations section" $?

printf 'Task TASK-9 - x\n\nDescription:\nServe signIn.\n' > "$root/ticket.md"
bash "$script" "$root/ticket.md" > "$root/out.md"; check "a ticket that names an operation exits 0" $?
has "## Contract operations this ticket names" && has "- **signIn** stub"; check "the operations section from plan-ops.mjs" $?
mv scripts/contract-mcp/node_modules "$root/nm.off"
bash "$script" "$root/ticket.md" > "$root/out.md"; check "no node_modules exits 0" $?
! has "## Contract operations"; check "no node_modules, no operations section" $?
mv "$root/nm.off" scripts/contract-mcp/node_modules

# No dependencies, or no Backlog: the section is left out and the backlog CLI is never called.
: > "$BACKLOG_LOG"
printf 'Task TASK-9 - x\n\nDepends on: none\n' > "$root/ticket.md"
bash "$script" "$root/ticket.md" > "$root/out.md"; check "no dependencies exits 0" $?
! has "## Dependencies" && [ ! -s "$BACKLOG_LOG" ]; check "no dependencies, no section and no backlog call" $?
bash "$script" "$root/missing.md" > "$root/out.md"; check "no ticket.md exits 0" $?
has "## build-feature-copilot nodes"; check "no ticket.md still writes the pack" $?

# Read-only: the pack changes nothing in the checkout.
[ -z "$(git status --porcelain)" ]; check "checkout untouched" $?

# The nodes are those of the workflow build_workflow in .archon/kit.yaml names, not of the kit's default.
printf 'build_workflow: my-build\n' > .archon/kit.yaml
printf 'nodes:\n  - id: only-mine\n' > .archon/workflows/my-build.yaml
bash "$script" "$root/missing.md" > "$root/out.md"; check "kit.yaml build_workflow exits 0" $?
has "## my-build nodes" && grep -qx -- "- only-mine" "$root/out.md" && ! has "## build-feature-copilot nodes"
check "the nodes of the workflow build_workflow names" $?

echo "plan-context: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
