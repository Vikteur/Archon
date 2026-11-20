#!/usr/bin/env bash
# Tests that each .archon workflow can run its own control flow:
#  - every node whose field another node reads (`$<id>.output.<field>`) declares output_format: without it Archon
#    keeps the node's stdout as raw text, and the read fails the reading node at run time (build-feature, #126:
#    build-step's `when:` read `$tests-skills.output.ok` and every run failed at the first step);
#  - no bash or until_bash field puts a node output (`$<id>.output.<field>`) inside double quotes: Archon substitutes
#    the output already single-quoted, so the quotes stay in the argument (TASK-65: the ci node passed `'…/pull/147'`
#    to local-ci-run.sh, which read the pull request as 147'). Assign it unquoted first (`pr=$<id>.output.pr`);
#  - a run never merges: no gh pr merge and no merge API call; a team member merges;
#  - W1, every repo script a workflow names (.archon/scripts/…, .claude/scripts/…, .claude/hooks/scripts/…,
#    .github/skills/<skill>/scripts/…, scripts/…) exists, so a renamed or unmerged script fails here, not in a run;
#  - W4, open-pr keeps its lease: build-feature-copilot's open-pr node runs open-pr.sh, and every push in open-pr.sh carries
#    --force-with-lease=<branch>:<head last seen> (TASK-70: a plain push of a rebased branch was rejected);
#  - W5, every build-feature-copilot node has a time bucket in .archon/scripts/run-buckets.json, so a renamed node cannot drop
#    out of the run telemetry silently (ROADMAP R18). Without that file this part is reported as SKIPPED.
#  - every node whose prompt tells it to `git commit` denies Bash(*--no-verify*) and Bash(*commit -n *), and
#    .archon/config.yaml points core.hooksPath at .archon/githooks, whose hooks are executable: the commit-shape hook
#    runs in every run worktree and an agent cannot skip it (owner decision D12, 2026-10-20);
#  - build-feature-copilot's ci-fix loop starts with red-head (a head red on the same job as main stops as RED_FROM_MAIN), a fix
#    without a commit fails as CI_FIX_NO_COMMIT, one without a commit after a `CAUSE: main` diagnosis ends at a cancel
#    node as BLOCKED_NEEDS_PERSON, and diagnose and fix may not push to main or commit tickets (D13, D14).
#  - every skill a node names (its `skills:` allow-list, loop nodes too) is shipped under .github/skills/<skill>/SKILL.md,
#    and build-feature-copilot's write-tests and build-step name exactly their full lists cut to the installed profiles'
#    skills (`kit add` drops a line marked for a profile not installed; Copilot warns copilot.skills_missing otherwise);
#  - build-feature-copilot's committing agent nodes (write-tests, build-step, review, fix) are retry-safe: each prompt says
#    the node may run again, and has it read `git status` and its own commits since its base sha first (step-base.sha,
#    review-base.sha, ci-fix-before.sha), so a transient retry never commits the same work twice;
#  W1, W4 and W5 are ROADMAP R17 (T12); each check also runs on a fixture of the old code, where it must fail.
#  - a dry run with default stubs of each workflow ends `Simulation outcome: completed`; a build workflow's plan
#    approval is answered by a stub, and a rejected plan ends `Simulation outcome: cancelled`. It needs the archon CLI;
#    without it this part is reported as SKIPPED, never as passed.
# Usage: bash .archon/scripts/test/workflow-contracts.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$here/../.." && pwd)"
workflows="${WORKFLOWS_DIR:-$repo/.archon/workflows}"
pass=0; fail=0; skipped=0

check() { # check <name> <condition exit code> [<detail>]
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; [ -n "${3:-}" ] && sed 's/^/    /' <<< "$3"; fi
}

# The nodes read through `$<id>.output.<field>` that declare no output_format, one `<node> (read as <ref>)` per line
undeclared() { # undeclared <workflow yaml>
  yq -o=json '.' "$1" | node -e '
    const wf = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const nodes = [];
    const walk = ns => { for (const n of ns || []) { nodes.push(n); walk(n.loop_group && n.loop_group.nodes); } };
    walk(wf.nodes);
    // A wait node answers with its own fixed contract (decision, text), an include node with the typed returns
    // of its block: neither needs output_format
    const declared = new Map(nodes.map(n => [n.id, !!(n.output_format || n.wait || n.approval || n.include)]));
    const text = JSON.stringify(wf.nodes);
    const seen = new Set();
    for (const m of text.matchAll(/\$([A-Za-z][\w-]*)\.output\.(\w+)/g)) {
      if (!declared.has(m[1]) || declared.get(m[1]) || seen.has(m[0])) continue;
      seen.add(m[0]);
      console.log(`${m[1]} (read as ${m[0]})`);
    }'
}

# The node outputs a bash or until_bash field puts inside double quotes, one `<node>: <line>` per line
quoted_outputs() { # quoted_outputs <workflow yaml>
  yq -o=json '.' "$1" | node -e '
    const wf = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const walk = ns => { for (const n of ns || []) {
      for (const f of ["bash", "until_bash"]) for (const line of String(n[f] || "").split("\n"))
        // a double-quoted string that holds a node output, outside single quotes
        if (/"[^"]*\$[A-Za-z][\w-]*\.output\.\w+[^"]*"/.test(line.replace(/\x27[^\x27]*\x27/g, "")))
          console.log(`${n.id}: ${line.trim()}`);
      walk(n.loop_group && n.loop_group.nodes); walk(n.loop && n.loop.nodes); walk(n.nodes);
    } };
    walk(wf.nodes);'
}

# The lines that merge a pull request, one `<line>:<text>` per line, comments left out. A run never merges its own pull
# request: a team member does.
merges() { # merges <workflow yaml>
  grep -nE 'gh pr merge|gh api [^#]*/pulls/[^ ]*/merge' "$1" | grep -vE '^[0-9]+:\s*#'
}

# The repo scripts a workflow names that do not exist under <root>, one `<line>: <path>` per line (W1)
missing_scripts() { # missing_scripts <workflow yaml> <root>
  grep -noP '(?<![\w./$}-])(?:\.archon/scripts|\.claude/scripts|\.claude/hooks/scripts|\.github/skills/[\w-]+/scripts|scripts)/[\w./-]*\.(?:sh|js|mjs|cjs|py|json)(?![\w-])' "$1" \
    | while IFS=: read -r n p; do [ -e "$2/$p" ] || echo "$n: $p"; done | sort -u
}

# What breaks open-pr's lease, one line each; nothing when the open-pr node runs open-pr.sh and every push in it
# carries --force-with-lease=<branch>:<head last seen> (W4)
open_pr_unleased() { # open_pr_unleased <workflow yaml> <open-pr.sh>
  local bash_field pushes
  bash_field=$(yq -r '.nodes[] | select(.id == "open-pr") | .bash // ""' "$1")
  grep -qE '(^|[;&|(]|\$\()\s*bash \.archon/scripts/open-pr\.sh' <<< "$bash_field" \
    || echo "the open-pr node does not run bash .archon/scripts/open-pr.sh"
  pushes=$(grep -nE '(^|[^[:alnum:]_-])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$)' "$2" | grep -vE '^[0-9]+:\s*#')
  [ -n "$pushes" ] || echo "open-pr.sh has no git push"
  grep -vE -- '--force-with-lease="?\$?[^[:space:]:]+:[^[:space:]]*' <<< "$pushes" | sed '/^$/d; s/^/no lease against the head last seen: /'
}

# The build workflow's node ids that run-buckets.json does not name, one per line (W5). The map may be keyed by node id
# or by bucket; a node counts as bucketed when its id is a key or a value anywhere in it.
unbucketed() { # unbucketed <workflow yaml> <run-buckets.json>
  yq -o=json '.' "$1" | BUCKETS="$2" node -e '
    const fs = require("fs");
    const wf = JSON.parse(fs.readFileSync(0, "utf8"));
    const named = new Set();
    const collect = v => { if (typeof v === "string") named.add(v);
      else if (Array.isArray(v)) v.forEach(collect);
      else if (v && typeof v === "object") for (const [k, x] of Object.entries(v)) { named.add(k); collect(x); } };
    collect(JSON.parse(fs.readFileSync(process.env.BUCKETS, "utf8")));
    const walk = ns => { for (const n of ns || []) {
      if (n.id && !named.has(n.id)) console.log(n.id);
      walk(n.loop_group && n.loop_group.nodes); walk(n.loop && n.loop.nodes); walk(n.nodes);
    } };
    walk(wf.nodes);'
}

# The nodes whose prompt says `git commit` but that do not deny both hook skips, one `<node>: missing <rule>` per line
unguarded_commits() { # unguarded_commits <workflow yaml>
  yq -o=json '.' "$1" | node -e '
    const wf = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const need = ["Bash(*--no-verify*)", "Bash(*commit -n *)"];
    const walk = ns => { for (const n of ns || []) {
      const said = Object.entries(n).some(([k, v]) => k !== "bash" && typeof v === "string" && /git commit/.test(v));
      if (said) for (const r of need) if (!(n.denied_tools || []).includes(r)) console.log(`${n.id}: missing ${r}`);
      walk(n.loop_group && n.loop_group.nodes); walk(n.loop && n.loop.nodes); walk(n.nodes);
    } };
    walk(wf.nodes);'
}

# The skills a node names that <root> does not ship, one `<node>: <skill>` per line
unshipped_skills() { # unshipped_skills <workflow yaml> <root>
  yq -o=json '.' "$1" | ROOT="$2" node -e '
    const fs = require("fs"), path = require("path");
    const wf = JSON.parse(fs.readFileSync(0, "utf8"));
    const walk = ns => { for (const n of ns || []) {
      for (const s of n.skills || []) if (!fs.existsSync(path.join(process.env.ROOT, ".github/skills", s, "SKILL.md")))
        console.log(`${n.id}: ${s}`);
      walk(n.loop_group && n.loop_group.nodes); walk(n.loop && n.loop.nodes); walk(n.nodes);
    } };
    walk(wf.nodes);'
}

# A node's skills, comma-joined, found anywhere in the workflow (loop nodes too)
node_skills() { # node_skills <workflow yaml> <node id>
  yq -o=json '.' "$1" | ID="$2" node -e '
    const wf = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const find = ns => { for (const n of ns || []) {
      if (n.id === process.env.ID) return n;
      const f = find(n.loop_group && n.loop_group.nodes) || find(n.loop && n.loop.nodes) || find(n.nodes);
      if (f) return f;
    } };
    const n = find(wf.nodes);
    console.log(n ? (n.skills || []).join(",") : "");'
}

# Each <node>:<base file> whose prompt does not say it may run again, read `git status` and git log from that base sha
retry_unsafe() { # retry_unsafe <workflow yaml> <node>:<base file>...
  local wf=$1; shift
  yq -o=json '.' "$wf" | node -e '
    const wf = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const find = (ns, id) => { for (const n of ns || []) {
      if (n.id === id) return n;
      const f = find(n.loop_group && n.loop_group.nodes, id) || find(n.loop && n.loop.nodes, id) || find(n.nodes, id);
      if (f) return f;
    } };
    for (const pair of process.argv.slice(1)) {
      const [id, base] = pair.split(":");
      const n = find(wf.nodes, id), p = (n && n.prompt) || "";
      const miss = [];
      if (!n) miss.push("no such node");
      else {
        if (!/may run again/.test(p)) miss.push("does not say it may run again");
        if (!/`git status`/.test(p)) miss.push("reads no `git status`");
        if (!new RegExp("git log [^`]*" + base.replace(/[.]/g, "[.]") + "[^`]*[.][.]HEAD").test(p)) miss.push("reads no git log since " + base);
      }
      if (miss.length) console.log(id + ": " + miss.join(", "));
    }' "$@"
}

# <list> cut to the skills <root> ships, order kept, comma-joined
shipped_of() { # shipped_of <root> <skill>...
  local root=$1 s out=(); shift
  for s in "$@"; do [ -f "$root/.github/skills/$s/SKILL.md" ] && out+=("$s"); done
  local IFS=,; echo "${out[*]}"
}

# What the run-worktree hook setup lacks under <root>, one line each (D12)
hook_gaps() { # hook_gaps <root>
  local cfg="$1/.archon/config.yaml" h
  [ "$(yq -r '.env.GIT_CONFIG_KEY_0 // ""' "$cfg")" = core.hooksPath ] || echo "config.yaml env sets no GIT_CONFIG_KEY_0=core.hooksPath"
  [ "$(yq -r '.env.GIT_CONFIG_VALUE_0 // ""' "$cfg")" = .archon/githooks ] || echo "config.yaml env sets no GIT_CONFIG_VALUE_0=.archon/githooks"
  [ "$(yq -r '.env.GIT_CONFIG_COUNT // ""' "$cfg")" = 1 ] || echo "config.yaml env sets no GIT_CONFIG_COUNT=1"
  [ -f "$1/.archon/githooks/commit-msg" ] || echo "no .archon/githooks/commit-msg"
  for h in "$1"/.archon/githooks/*; do [ ! -f "$h" ] || [ -x "$h" ] || echo "not executable: ${h#"$1"/}"; done
}

# What the build workflow's ci-fix loop lacks, one line each (failure recovery, D13, D14)
ci_fix_gaps() { # ci_fix_gaps <workflow yaml>
  local first r n
  first=$(yq -r '.nodes[] | select(.id == "ci-fix") | .loop_group.nodes[0].id' "$1")
  [ "$first" = red-head ] || echo "ci-fix's first node is ${first:-none}, not red-head"
  for n in diagnose fix; do
    for r in 'Bash(*git push*main*)' 'Bash(*commit-tickets*)'; do
      R="$r" yq -e ".nodes[] | select(.id == \"ci-fix\") | .loop_group.nodes[] | select(.id == \"$n\") | .denied_tools[] | select(. == strenv(R))" "$1" >/dev/null 2>&1 \
        || echo "ci-fix.$n does not deny $r"
    done
  done
  for r in RED_FROM_MAIN CI_FIX_NO_COMMIT BLOCKED_NEEDS_PERSON; do grep -q "$r" "$1" || echo "no $r token"; done
  yq -e '.nodes[] | select(.id == "ci-fix") | .loop_group.nodes[] | select(has("cancel") and (.depends_on // [] | contains(["fix-made"])))' "$1" >/dev/null 2>&1 \
    || echo "ci-fix has no cancel node after fix-made for the blocked outcome"
}

for wf in "$workflows"/*.yaml; do
  name=$(basename "$wf" .yaml)
  out=$(unguarded_commits "$wf")
  check "$name: every node told to git commit denies --no-verify and commit -n" $([ -z "$out" ]; echo $?) "$out"
  out=$(quoted_outputs "$wf")
  check "$name: no node output inside double quotes in bash" $([ -z "$out" ]; echo $?) "$out"
  out=$(undeclared "$wf")
  check "$name: every node read through \$<id>.output.<field> declares output_format" $([ -z "$out" ]; echo $?) "$out"
  # A run never merges its own pull request: a team member does
  out=$(merges "$wf")
  check "$name: never merges (no gh pr merge, no merge API call)" $([ -z "$out" ]; echo $?) "$out"
  out=$(missing_scripts "$wf" "$repo")
  check "$name: W1 every repo script it names exists" $([ -z "$out" ]; echo $?) "$out"
  out=$(unshipped_skills "$wf" "$repo")
  check "$name: every skill a node names is shipped (.github/skills/<skill>/SKILL.md)" $([ -z "$out" ]; echo $?) "$out"
  # Seconds after a push GitHub still reports the old head, so local CI on a pull request names the commit it expects
  # (TASK-59). --logs only reads a folder, and a merge commit is a sha, not a pull request.
  out=$(grep -nE 'local-ci-run\.sh' "$wf" | grep -vE '^[0-9]+:\s*#' | grep -vE -- '--logs|--head|local-ci-run\.sh "\$merge"')
  check "$name: local-ci-run.sh on a pull request passes --head" $([ -z "$out" ]; echo $?) "$out"
done

out=$(hook_gaps "$repo")
check "run worktrees: core.hooksPath points at .archon/githooks, every hook executable" $([ -z "$out" ]; echo $?) "$out"
if [ -f "$workflows/build-feature-copilot.yaml" ]; then
  out=$(ci_fix_gaps "$workflows/build-feature-copilot.yaml")
  check "build-feature-copilot: ci-fix starts with red-head, names its three outcome tokens, ends blocked at a cancel node, may not push main or commit tickets" \
    $([ -z "$out" ]; echo $?) "$out"
  # The test and build agents' skills follow the installed profiles: the full lists (core, java, java-spring) cut to
  # what this install ships, in order; a profile's skill is never dropped while that profile ships it.
  got=$(node_skills "$workflows/build-feature-copilot.yaml" write-tests)
  want=$(shipped_of "$repo" tdd-loop jvm-testing object-mother-builders usecase-bdd-spec testcontainers archunit-fitness \
    domain-to-dto-mapper-tests code-generation)
  check "build-feature-copilot: write-tests names its skills of the installed profiles ($got)" $([ -n "$got" ] && [ "$got" = "$want" ]; echo $?) "want $want"
  got=$(node_skills "$workflows/build-feature-copilot.yaml" build-step)
  want=$(shipped_of "$repo" clean-code java domain-modeling validation-notification-result domain-events \
    usecase-orchestration api-first-controller domain-dto-mapper persistence-repository jpa-entity-mapping \
    flyway-migrations resilience4j bean-config-di exception-to-http conventional-commits code-generation)
  check "build-feature-copilot: build-step names its skills of the installed profiles ($got)" $([ -n "$got" ] && [ "$got" = "$want" ]; echo $?) "want $want"
  out=$(retry_unsafe "$workflows/build-feature-copilot.yaml" write-tests:step-base.sha build-step:step-base.sha \
    review:review-base.sha fix:ci-fix-before.sha)
  check "build-feature-copilot: write-tests, build-step, review and fix check their own earlier commits before a retry" \
    $([ -z "$out" ]; echo $?) "$out"
  out=$(open_pr_unleased "$workflows/build-feature-copilot.yaml" "$here/open-pr.sh")
  check "build-feature-copilot: W4 open-pr pushes only with a lease against the head last seen" $([ -z "$out" ]; echo $?) "$out"
  if [ -f "$here/run-buckets.json" ]; then
    out=$(unbucketed "$workflows/build-feature-copilot.yaml" "$here/run-buckets.json")
    check "build-feature-copilot: W5 every node has a time bucket in run-buckets.json" $([ -z "$out" ]; echo $?) "$out"
  else
    skipped=$((skipped+1)); echo "SKIPPED: build-feature-copilot: W5 time buckets (.archon/scripts/run-buckets.json does not exist yet)"
  fi
fi

# The check itself: a node read by field without output_format is found, one that declares it is not
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/w.yaml" <<'EOF'
nodes:
  - id: probe
    bash: echo '{"ok":true}'
  - id: loop
    loop_group:
      nodes:
        - id: inner
          bash: echo '{"n":1}'
        - id: use
          when: "$inner.output.n == '1' && $probe.output.ok == 'true'"
          bash: echo "$probe.output $gate.output.decision"
        - id: gate
          wait: { form: select, options: [{ id: approve, label: go }] }
EOF
out=$(undeclared "$tmp/w.yaml")
check "contracts: a field read of an undeclared node, in or out of a loop, is found" \
  $(grep -qx 'probe (read as $probe.output.ok)' <<< "$out" && grep -qx 'inner (read as $inner.output.n)' <<< "$out"; echo $?) "$out"
check "contracts: a wait node's answer needs no output_format" $(! grep -q '^gate' <<< "$out"; echo $?) "$out"
printf '%s\n' 'nodes:' '  - id: block' '    include: archon-plan-block' '  - id: after' '    bash: echo $block.output.ready' > "$tmp/inc.yaml"
inc=$(undeclared "$tmp/inc.yaml")
check "contracts: an include node's typed returns need no output_format" $([ -z "$inc" ]; echo $?) "$inc"
sed -i 's/^    bash: echo .{"ok":true}.$/&\n    output_format: { type: object, properties: { ok: { type: boolean } }, required: [ok] }/' "$tmp/w.yaml"
out=$(undeclared "$tmp/w.yaml")
check "contracts: a node that declares output_format is not reported" $(! grep -q '^probe' <<< "$out"; echo $?) "$out"

# never merges: each way a run could merge is found; another script and a comment are not
cat > "$tmp/m.yaml" <<'EOF'
nodes:
  # a run never calls gh pr merge
  - id: gate
    bash: bash .archon/scripts/ci-by-sha.sh --check
  - id: merge
    bash: |
      gh pr merge "$pr" --squash
      gh api -X PUT repos/o/r/pulls/7/merge
EOF
out=$(merges "$tmp/m.yaml")
check "contracts: gh pr merge and the merge API are found" \
  $([ "$(grep -c . <<< "$out")" -eq 2 ] && grep -q 'gh pr merge' <<< "$out"; echo $?) "$out"
check "contracts: another script and a comment are not reported" \
  $(! grep -qE '^(2|4):' <<< "$out"; echo $?) "$out"

# W1: a named script that does not exist is found; one that exists, a glob and a variable path are not
mkdir -p "$tmp/root/.archon/scripts" "$tmp/root/scripts"
touch "$tmp/root/.archon/scripts/there.sh" "$tmp/root/scripts/scaffold.sh"
cat > "$tmp/s.yaml" <<'EOF'
nodes:
  - id: a
    bash: bash .archon/scripts/there.sh && bash .archon/scripts/gone.sh
    prompt: Render it with `scripts/scaffold.sh x` and run (scripts/test/*.test.sh); "$umbrella/scripts/other.sh" is not ours.
  - id: b
    bash: node .github/skills/gh-git-ops/scripts/missing.js
EOF
out=$(missing_scripts "$tmp/s.yaml" "$tmp/root")
check "contracts: W1 a named script that does not exist is found" \
  $(grep -qx '3: .archon/scripts/gone.sh' <<< "$out" && grep -qx '6: .github/skills/gh-git-ops/scripts/missing.js' <<< "$out"; echo $?) "$out"
check "contracts: W1 an existing script, a glob and a path under a variable are not reported" \
  $([ "$(grep -c . <<< "$out")" -eq 2 ]; echo $?) "$out"

# W4: open-pr.sh before TASK-70 pushed plainly; the open-pr node must run the script
cat > "$tmp/o.yaml" <<'EOF'
nodes:
  - id: open-pr
    bash: |
      pr=$(bash .archon/scripts/open-pr.sh "$BASE_BRANCH" "$title" body.md)
EOF
printf '#!/usr/bin/env bash
git push -u origin "$branch" >&2
' > "$tmp/open-pr.sh"
out=$(open_pr_unleased "$tmp/o.yaml" "$tmp/open-pr.sh")
check "contracts: W4 open-pr.sh before TASK-70 (a plain push) is found" $(grep -q 'no lease' <<< "$out"; echo $?) "$out"
printf '#!/usr/bin/env bash
git push -u --force-with-lease origin "$branch"
' > "$tmp/open-pr.sh"
out=$(open_pr_unleased "$tmp/o.yaml" "$tmp/open-pr.sh")
check "contracts: W4 a lease without the head last seen is found" $(grep -q 'no lease' <<< "$out"; echo $?) "$out"
printf '#!/usr/bin/env bash
# git push plain is wrong
git push -u --force-with-lease="$branch:$seen" origin "HEAD:refs/heads/$branch" >&2
' > "$tmp/open-pr.sh"
out=$(open_pr_unleased "$tmp/o.yaml" "$tmp/open-pr.sh")
check "contracts: W4 the TASK-70 push is not reported" $([ -z "$out" ]; echo $?) "$out"
sed -i 's#bash .archon/scripts/open-pr.sh#git push -u origin x#' "$tmp/o.yaml"
out=$(open_pr_unleased "$tmp/o.yaml" "$tmp/open-pr.sh")
check "contracts: W4 an open-pr node that does not run open-pr.sh is found" $(grep -q 'does not run' <<< "$out"; echo $?) "$out"

# W5: a node the bucket map does not name is found, in or out of a loop, whichever way the map is keyed
echo '{"build": ["probe"], "ci": ["inner"]}' > "$tmp/b1.json"
echo '{"probe": "build", "inner": "ci", "use": "ci", "gate": "gate", "loop": "build"}' > "$tmp/b2.json"
out=$(unbucketed "$tmp/w.yaml" "$tmp/b1.json")
check "contracts: W5 a node without a bucket is found, in or out of a loop" \
  $([ "$(sort <<< "$out" | tr '\n' ' ')" = "gate loop use " ]; echo $?) "$out"
out=$(unbucketed "$tmp/w.yaml" "$tmp/b2.json")
check "contracts: W5 a map keyed by node id that names every node reports nothing" $([ -z "$out" ]; echo $?) "$out"

# Hook skips: a node told to commit without both denials is found (the nodes before D12); one with both is not
cat > "$tmp/c.yaml" <<'EOF'
nodes:
  - id: old
    prompt: Commit with `git commit -m "x"`.
  - id: half
    prompt: Then git commit the docs.
    denied_tools: ["Bash(*--no-verify*)"]
  - id: guarded
    prompt: git commit once.
    denied_tools: ["Bash(*--no-verify*)", "Bash(*commit -n *)"]
  - id: script
    bash: git commit -m "a script commit is not an agent's"
EOF
out=$(unguarded_commits "$tmp/c.yaml")
check "contracts: a node told to git commit without both hook-skip denials is found" \
  $([ "$(tr '\n' ' ' <<< "$out")" = "old: missing Bash(*--no-verify*) old: missing Bash(*commit -n *) half: missing Bash(*commit -n *) " ]; echo $?) "$out"

# Hook setup: the config before D12 (no env) and a hook without the execute bit are found
mkdir -p "$tmp/h/.archon/githooks"
printf 'worktree:\n  baseBranch: main\n' > "$tmp/h/.archon/config.yaml"
printf '#!/usr/bin/env bash\n' > "$tmp/h/.archon/githooks/commit-msg"; chmod 644 "$tmp/h/.archon/githooks/commit-msg"
out=$(hook_gaps "$tmp/h")
check "contracts: a config without core.hooksPath and a hook without the execute bit are found" \
  $(grep -q 'GIT_CONFIG_KEY_0' <<< "$out" && grep -q 'not executable: .archon/githooks/commit-msg' <<< "$out"; echo $?) "$out"
printf 'env:\n  GIT_CONFIG_COUNT: "1"\n  GIT_CONFIG_KEY_0: core.hooksPath\n  GIT_CONFIG_VALUE_0: .archon/githooks\n' > "$tmp/h/.archon/config.yaml"
chmod 755 "$tmp/h/.archon/githooks/commit-msg"
out=$(hook_gaps "$tmp/h")
check "contracts: the D12 config with an executable hook is not reported" $([ -z "$out" ]; echo $?) "$out"

# ci-fix: the loop before failure recovery (diagnose first, no denials, no tokens) is found; the C4 shape is not
cat > "$tmp/f.yaml" <<'EOF'
nodes:
  - id: ci-fix
    loop_group:
      nodes:
        - id: diagnose
          prompt: Find why CI is red.
        - id: fix
          prompt: Fix it.
          denied_tools: ["Bash(*--no-verify*)", "Bash(*commit -n *)"]
EOF
out=$(ci_fix_gaps "$tmp/f.yaml")
check "contracts: a ci-fix loop without red-head, denials and tokens is found" \
  $([ "$(grep -c . <<< "$out")" -eq 9 ]; echo $?) "$out"
cat > "$tmp/f.yaml" <<'EOF'
nodes:
  - id: ci-fix
    loop_group:
      nodes:
        - id: red-head
          bash: echo "RED_FROM_MAIN" >&2
        - id: diagnose
          denied_tools: ["Bash(*git push*main*)", "Bash(*commit-tickets*)"]
        - id: fix
          prompt: Without a commit print CI_FIX_NO_COMMIT.
          denied_tools: ["Bash(*commit-tickets*)", "Bash(*git push*main*)"]
        - id: fix-made
          depends_on: [fix]
          bash: echo BLOCKED_NEEDS_PERSON
        - id: blocked
          depends_on: [fix-made]
          cancel: blocked
EOF
out=$(ci_fix_gaps "$tmp/f.yaml")
check "contracts: the failure-recovery ci-fix loop is not reported" $([ -z "$out" ]; echo $?) "$out"

# Skills: a node that names a skill the root does not ship is found, in or out of a loop (the lists before the profile
# markers named the java skills on a core-only install); shipped ones are not
mkdir -p "$tmp/sk/.github/skills/tdd-loop" "$tmp/sk/.github/skills/clean-code"
: > "$tmp/sk/.github/skills/tdd-loop/SKILL.md"; : > "$tmp/sk/.github/skills/clean-code/SKILL.md"
mkdir -p "$tmp/sk/.github/skills/java"   # a folder without SKILL.md is not a shipped skill
cat > "$tmp/f.yaml" <<'EOF'
nodes:
  - id: plan
    skills: [clean-code]
  - id: implement
    loop_group:
      nodes:
        - id: write-tests
          skills: [tdd-loop, jvm-testing]
        - id: build-step
          skills: [clean-code, java]
EOF
out=$(unshipped_skills "$tmp/f.yaml" "$tmp/sk")
check "contracts: a skill a node names but the install lacks is found, loop nodes too" \
  $([ "$out" = "$(printf 'write-tests: jvm-testing\nbuild-step: java')" ]; echo $?) "$out"
check "contracts: a loop node's skills are read" $([ "$(node_skills "$tmp/f.yaml" build-step)" = clean-code,java ]; echo $?)
check "contracts: a full list is cut to the shipped skills, order kept" \
  $([ "$(shipped_of "$tmp/sk" java tdd-loop jvm-testing clean-code)" = tdd-loop,clean-code ]; echo $?)
sed -i 's/, jvm-testing//; s/clean-code, java/clean-code/' "$tmp/f.yaml"
out=$(unshipped_skills "$tmp/f.yaml" "$tmp/sk")
check "contracts: only shipped skills: nothing reported" $([ -z "$out" ]; echo $?) "$out"

cat > "$tmp/r.yaml" <<'EOF'
nodes:
  - id: review
    prompt: |
      This node may run again. First run `git status` and `git log --oneline "$(cat "$ARTIFACTS_DIR/review-base.sha")"..HEAD`.
  - id: implement
    loop_group:
      nodes:
        - id: build-step
          prompt: |
            Build the step and commit.
EOF
out=$(retry_unsafe "$tmp/r.yaml" review:review-base.sha build-step:step-base.sha fix:ci-fix-before.sha)
check "contracts: a committing node without the retry check is found, loop nodes too, and a missing node is named" \
  $([ "$out" = "$(printf 'build-step: does not say it may run again, reads no `git status`, reads no git log since step-base.sha\nfix: no such node')" ]; echo $?) "$out"
out=$(retry_unsafe "$tmp/r.yaml" review:step-base.sha)
check "contracts: a retry check against another base sha is found" $([ "$out" = "review: reads no git log since step-base.sha" ]; echo $?) "$out"
out=$(retry_unsafe "$tmp/r.yaml" review:review-base.sha)
check "contracts: a retry-safe node: nothing reported" $([ -z "$out" ]; echo $?) "$out"

# A dry run with default stubs walks each workflow's control flow without a provider
if command -v archon >/dev/null 2>&1; then
  for wf in "$workflows"/*.yaml; do
    name=$(basename "$wf" .yaml)
    stubs=()
    if [ "$(yq '[.nodes[] | select(.id == "plan-approval")] | length' "$wf")" -gt 0 ]; then
      # The plan approval pauses a dry run: a reject stub ends it cancelled, an approve stub walks on to ready.
      printf '{"plan-approval": {"decision": "reject", "text": "dry run"}}\n' > "$tmp/reject.json"
      out=$(cd "$repo" && archon workflow run "$name" "dry run" --dry-run --default-stubs --stubs "$tmp/reject.json" 2>&1)
      check "$name: a rejected plan ends the dry run cancelled" $(grep -q '^Simulation outcome: cancelled' <<< "$out"; echo $?) \
        "$(grep -E '^(FAILED|Simulation outcome|Error)' <<< "$out")"
      printf '{"plan-approval": {"decision": "approve", "text": "dry run"}}\n' > "$tmp/approve.json"
      stubs=(--stubs "$tmp/approve.json")
    fi
    out=$(cd "$repo" && archon workflow run "$name" "dry run" --dry-run --default-stubs "${stubs[@]}" 2>&1)
    check "$name: a dry run with default stubs completes" $(grep -q '^Simulation outcome: completed' <<< "$out"; echo $?) \
      "$(grep -E '^(FAILED|Simulation outcome|Error)' <<< "$out")"
  done
else
  for wf in "$workflows"/*.yaml; do
    skipped=$((skipped+1))
    echo "SKIPPED: $(basename "$wf" .yaml): dry run with default stubs (the archon CLI is not installed)"
  done
fi

echo "workflow-contracts: $pass passed, $fail failed, $skipped skipped"
[ "$fail" -eq 0 ]
