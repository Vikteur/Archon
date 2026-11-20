#!/usr/bin/env bash
# Contract tests for the way the repo's scripts and workflows call other scripts and push (ROADMAP R17, T12). Each check
# pins a defect class that cost a live run, or that the build-feature standing exception depends on:
#  - W2, no direct call of a script without the execute bit: git checks a 100644 script out without it, so a call that
#    does not go through bash, sh, source or `.` fails with Permission denied (TASK-74: a post-merge script and
#    retro-commit.sh ran scripts/tokenomics/commit-reports.sh directly and the token reports went uncommitted). A call
#    is direct when the script's path stands where a command stands: at the start of a line, after ; & | ( $( or `,
#    after then/do/else/if/while/until/exec/!, or after VAR=value assignments. The scan reads the repo's scripts, the
#    bash fields of every workflow, and the backtick spans of every other workflow field (the commands a prompt tells
#    an agent to run). Do not chmod every script instead: changing 57 modes is churn with no defect behind it
#    (ROADMAP section 10);
#  - W3, every force push has a lease: no `git push --force`, `-f` or `+<refspec>` without --force-with-lease. The
#    build-feature exception lets a run force-push its own branch only with a lease (.claude/CLAUDE.md, owner decision
#    2026-10-17, docs/memory.md).
# Tests (*/test/*) are left out: their fixtures are not the runtime path. A known false positive goes in the ignore
# lists below, one `<file>:<text>` entry each, with the reason.
# Each check also runs on a fixture of the old code, where it must fail.
# Usage: bash .archon/scripts/test/script-calls.test.sh   (exit 0 = all pass)
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
pass=0; fail=0

check() { # check <name> <condition exit code> [<detail>]
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; [ -n "${3:-}" ] && sed 's/^/    /' <<< "$3"; fi
}

# A direct call that is not one, `<file>:<text on the line>` per entry, with the reason.
CALL_IGNORE=(
  # a case pattern of gate files (paths after |), no call
  '.claude/scripts/affected-check.sh:.github/workflows/ci.yml|.github/ci-inputs.yml|.claude/scripts/ci-plan.sh|'
)
# A force push that has its lease elsewhere, or is not one, `<file>:<text on the line>` per entry, with the reason.
FORCE_IGNORE=(
)

# The files a scan reads under <root>, relative to it, one per line: scripts, git hooks and workflows, no tests.
scanned() { # scanned <root>
  (cd "$1" && find .archon/scripts .archon/workflows .archon/githooks .claude/scripts .claude/hooks/scripts scripts \
      .github/skills/*/scripts -type f \( -name '*.sh' -o -name '*.yaml' -o -name '*.yml' -o -path '*/githooks/*' \) \
      -not -path '*/test/*' -not -path '*/node_modules/*' 2>/dev/null | sed 's#^\./##' | sort)
}

# One `<file>:<line>: <text>` per direct call of a repo *.sh that has no execute bit
direct_calls() { # direct_calls <root>
  local root=$1 f
  {
    while IFS= read -r f; do
      case "$f" in
        *.yaml|*.yml) printf '%s\0%s\0' "$f" "$(yq -o=json '.' "$root/$f")" ;;
        *) printf '%s\0%s\0' "$f" "$(cat "$root/$f")" ;;
      esac
    done < <(scanned "$root")
  } | ROOT="$root" IGNORE="$(printf '%s\n' "${CALL_IGNORE[@]+"${CALL_IGNORE[@]}"}")" node -e '
    const fs = require("fs"), path = require("path");
    const root = process.env.ROOT;
    const ignore = process.env.IGNORE.split("\n").filter(Boolean);
    const parts = fs.readFileSync(0, "utf8").split("\0");
    // Every *.sh under the scanned folders, tests included, as a call may name one
    const all = [];
    const walk = d => { let es; try { es = fs.readdirSync(path.join(root, d), { withFileTypes: true }); } catch { return; }
      for (const e of es) { const p = d ? `${d}/${e.name}` : e.name;
        if (e.isDirectory()) { if (![".git", "node_modules", "build", ".gradle"].includes(e.name)) walk(p); }
        else if (e.name.endsWith(".sh")) all.push(p); } };
    for (const d of [".archon", ".claude", "scripts"]) walk(d);
    const exec = p => (fs.statSync(path.join(root, p)).mode & 0o111) !== 0;
    // The text before a word that puts the word where a command stands
    const cmdPos = /(^|[;&|(`]|\$\(|\b(?:then|do|else|elif|if|while|until|exec|time|nohup|command)\s|!\s)\s*(?:[A-Za-z_]\w*=[^\s$("\x27`]*\s+)*$/;
    const word = /(["\x27]?)([^\s"\x27();|&<>`]*\.sh)\1(?=[\s;|&)`]|$)/g;
    // The repo script a word names, or null for one outside the repo (on PATH, in another repo)
    const resolve = (w, caller) => {
      const plain = !/\$/.test(w);
      let tail = w.replace(/^.*(\$\{[^}]*\}|\$\([^)]*\)|\$\w+)/, "").replace(/^\.\//, "");
      if (plain) return all.includes(tail) ? tail : null;
      if (!tail.startsWith("/")) return null;
      const hits = all.filter(p => ("/" + p).endsWith(tail));
      if (!hits.length) return null;
      const near = hits.filter(p => path.dirname(p) === path.dirname(caller));
      if (near.length === 1) return near[0];
      return hits.every(p => !exec(p)) ? hits[0] : null;
    };
    const out = [];
    const scanLine = (file, n, line) => {
      if (/^\s*#/.test(line)) return;
      const code = line.replace(/\x27[^\x27]*\x27/g, "\x27\x27");
      for (const m of code.matchAll(word)) {
        const pre = code.slice(0, m.index);
        if (!cmdPos.test(pre)) continue;
        // `pattern)` with no open parenthesis before it is a case label, not a call
        if (code[m.index + m[0].length] === ")" && (pre.match(/\(/g) || []).length <= (pre.match(/\)/g) || []).length) continue;
        const p = resolve(m[2], file);
        if (!p || exec(p)) continue;
        if (ignore.some(i => i === `${file}:${line.trim()}` || (i.startsWith(file + ":") && line.includes(i.slice(file.length + 1))))) continue;
        out.push(`${file}:${n}: ${line.trim()}`);
      }
    };
    const scanShell = (file, text) => {
      let doc = null;
      text.split("\n").forEach((line, i) => {
        if (doc) { if (line.trim() === doc) doc = null; return; }
        scanLine(file, i + 1, line);
        const h = /<<-?\s*["\x27]?(\w+)["\x27]?/.exec(line);
        if (h) doc = h[1];
      });
    };
    // A prompt: each backtick span is a command an agent may run as it stands
    const scanSpans = (file, where, text) => {
      for (const m of text.matchAll(/`([^`]+)`/g)) scanLine(file, where, m[1].replace(/\s+/g, " ").trim());
    };
    const walkNodes = (file, ns) => { for (const n of ns || []) {
      for (const [k, v] of Object.entries(n)) {
        if (typeof v !== "string") continue;
        if (k === "bash" || k === "until_bash") scanShell(file, v);
        else scanSpans(file, `${n.id}.${k}`, v);
      }
      if (n.loop && typeof n.loop.until_bash === "string") scanShell(file, n.loop.until_bash);
      if (n.loop && typeof n.loop.prompt === "string") scanSpans(file, `${n.id}.loop.prompt`, n.loop.prompt);
      walkNodes(file, n.loop_group && n.loop_group.nodes); walkNodes(file, n.loop && n.loop.nodes); walkNodes(file, n.nodes);
    } };
    for (let i = 0; i + 1 < parts.length; i += 2) {
      const [file, text] = [parts[i], parts[i + 1]];
      if (/\.ya?ml$/.test(file)) { let wf; try { wf = JSON.parse(text); } catch { continue; } walkNodes(file, wf && wf.nodes); }
      else scanShell(file, text);
    }
    console.log(out.join("\n"));'
}

# One `<file>:<line>: <text>` per git push that forces without --force-with-lease
unleased_pushes() { # unleased_pushes <root>
  local root=$1 f n line i skip
  while IFS= read -r f; do
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n+1))
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      grep -qE '(^|[^[:alnum:]_-])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$)' <<< "$line" || continue
      grep -qE -- '--force-with-lease' <<< "$line" && continue
      grep -qE -- '[[:space:]](--force|--force-if-includes|-[A-Za-z]*f[A-Za-z]*|["'\'']?\+[^[:space:]]+)([[:space:]]|$|["'\''])' \
        <<< "${line#*push}" || continue
      skip=""
      for i in "${FORCE_IGNORE[@]+"${FORCE_IGNORE[@]}"}"; do
        [ "${i%%:*}" = "$f" ] && [[ "$line" == *"${i#*:}"* ]] && skip=1
      done
      [ -n "$skip" ] || echo "$f:$n: $(sed 's/^[[:space:]]*//' <<< "$line")"
    done < "$root/$f"
  done < <(scanned "$root")
}

# Today's tree
out=$(direct_calls "$repo")
check "W2: no script or workflow calls a repo script without the execute bit directly" $([ -z "$out" ]; echo $?) "$out"
out=$(unleased_pushes "$repo")
check "W3: every force push in a script or workflow has a lease" $([ -z "$out" ]; echo $?) "$out"

# The checks themselves, on a fixture tree of the old code and its fix
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.archon/scripts" "$tmp/.archon/workflows" "$tmp/scripts/tokenomics" "$tmp/.claude/scripts"
printf '#!/usr/bin/env bash\necho reports\n' > "$tmp/scripts/tokenomics/commit-reports.sh"
printf '#!/usr/bin/env bash\necho ok\n' > "$tmp/.claude/scripts/runs.sh"
chmod 644 "$tmp/scripts/tokenomics/commit-reports.sh"; chmod 755 "$tmp/.claude/scripts/runs.sh"
# post-merge.sh, a script before TASK-74: the 100644 commit-reports.sh run directly through a variable
cat > "$tmp/.archon/scripts/post-merge.sh" <<'EOF'
#!/usr/bin/env bash
if find_umbrella 2> /dev/null && [ -f "$umbrella/scripts/tokenomics/commit-reports.sh" ]; then
  "$umbrella/scripts/tokenomics/commit-reports.sh" "$umbrella" >&2 || echo "warning: the token reports were not committed." >&2
fi
EOF
out=$(direct_calls "$tmp")
check "W2 self-test: TASK-74's direct call of a 100644 script through a variable is found" \
  $(grep -q '^\.archon/scripts/post-merge\.sh:3: ' <<< "$out"; echo $?) "$out"
check "W2 self-test: a test of the file (-f) is not a call" $(! grep -q 'post-merge\.sh:2:' <<< "$out"; echo $?) "$out"
sed -i 's#^  "\$umbrella/scripts#  bash "$umbrella/scripts#' "$tmp/.archon/scripts/post-merge.sh"
out=$(direct_calls "$tmp")
check "W2 self-test: the same call through bash is not reported" $([ -z "$out" ]; echo $?) "$out"
cat > "$tmp/.archon/workflows/w.yaml" <<'EOF'
nodes:
  - id: ok
    bash: |
      .claude/scripts/runs.sh --all
      bash scripts/tokenomics/commit-reports.sh
      cat <<'TXT'
      scripts/tokenomics/commit-reports.sh
      TXT
  - id: direct
    bash: out=$(scripts/tokenomics/commit-reports.sh x) && echo "$out"
  - id: told
    prompt: |
      Run `scripts/tokenomics/commit-reports.sh .` once; read scripts/tokenomics/commit-reports.sh first.
      Then run `bash scripts/tokenomics/commit-reports.sh`.
EOF
out=$(direct_calls "$tmp")
check "W2 self-test: a workflow bash field that runs a 100644 script after \$( is found" \
  $(grep -q '^\.archon/workflows/w\.yaml:1: out=' <<< "$out"; echo $?) "$out"
check "W2 self-test: a prompt that tells an agent to run a 100644 script directly is found" \
  $(grep -q '^\.archon/workflows/w\.yaml:told\.prompt: scripts/tokenomics' <<< "$out"; echo $?) "$out"
check "W2 self-test: an executable script, a call through bash, a heredoc and prose are not reported" \
  $([ "$(grep -c . <<< "$out")" -eq 2 ]; echo $?) "$out"

# open-pr.sh before TASK-70 pushed plainly; a plain force push is the class the lease exists for
cat > "$tmp/.archon/scripts/push.sh" <<'EOF'
#!/usr/bin/env bash
# git push --force is never used here
git push -u origin "$branch" >&2
git push --force origin "HEAD:$branch"
git -C "$dir" push -qf origin "$branch"
git push origin "+HEAD:refs/heads/$branch"
git push -q --force-with-lease="$branch:$seen" origin "HEAD:$branch"
git push --force --force-with-lease origin x
git push origin --delete "$branch"
EOF
out=$(unleased_pushes "$tmp")
check "W3 self-test: --force, -f in a flag group and a +refspec without a lease are found" \
  $(grep -q 'push\.sh:4:' <<< "$out" && grep -q 'push\.sh:5:' <<< "$out" && grep -q 'push\.sh:6:' <<< "$out"; echo $?) "$out"
check "W3 self-test: a plain push, a leased push, a delete and a comment are not reported" \
  $([ "$(grep -c . <<< "$out")" -eq 3 ]; echo $?) "$out"

echo "script-calls: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
