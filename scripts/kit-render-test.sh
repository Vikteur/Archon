#!/usr/bin/env bash
# kit-render-test.sh: renders the kit's three installs from this checkout and runs every shipped suite in each, so
# nobody rebuilds that by hand. Not shipped in the kit (it lives beside kit-sync.ts, in scripts/).
#
#   scripts/kit-render-test.sh [--only on|off|spring] [--keep] [--jobs N] [--serial]
#
# The three renders (a fresh git repo, `archon kit add` from this checkout's own CLI source):
#   on      default profiles, local_ci true
#   off     default profiles, local_ci false
#   spring  core,java,java-spring (local_ci default)
# Each render has its own HOME, COPILOT_HOME and ARCHON_HOME under one temp folder, so the real ones are never read or
# written, and an `archon` shim on PATH that runs this checkout's source. Its suites run through the kit's own
# .claude/scripts/run-suites.sh with SUITE_JOBS=N (default 8). A suite that is red there is run again alone and counts
# as red only when it is red alone. The summary table gives, per render, the suites, the red, the wall time and the three
# slowest suites. Exit 0 only when every render ran is green.
#   --only X   render just that install
#   --keep     keep the temp folder (its path is printed); otherwise it is removed at the end
#   --jobs N   SUITE_JOBS per render (default 8)
#   --serial   the renders one after another (default: all at the same time)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
only="" keep=0 jobs=8 serial=0
while [ $# -gt 0 ]; do
  case "$1" in
    --only) only=${2:-}; shift 2 ;;
    --keep) keep=1; shift ;;
    --jobs) jobs=${2:-}; shift 2 ;;
    --serial) serial=1; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) echo "kit-render-test: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
case "$only" in ""|on|off|spring) ;; *) echo "kit-render-test: --only takes on, off or spring, not $only" >&2; exit 2 ;; esac
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { echo "kit-render-test: --jobs takes a whole number of 1 or more, not $jobs" >&2; exit 2; }
[ -f "$root/packages/cli/src/cli.ts" ] || { echo "kit-render-test: no CLI source at $root/packages/cli/src/cli.ts" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/kit-render-test.XXXXXX")
cleanup() { [ "$keep" = 1 ] && echo "kept: $work" || rm -rf "$work"; }
trap cleanup EXIT

now() { date +%s.%N; }
secs() { printf '%.1f' "$(echo "$(now) - $1" | bc)"; }

render() { # render <name> <local_ci> [profiles]: one install and its suites; writes $work/<name>/result
  local name=$1 lc=$2 prof=${3:-} R="$work/$1" t0 rc
  mkdir -p "$R/repo" "$R/home" "$R/copilot" "$R/archon" "$R/bin" "$R/logs"
  printf '#!/usr/bin/env bash\nexec bun %s/packages/cli/src/cli.ts "$@"\n' "$root" > "$R/bin/archon"; chmod +x "$R/bin/archon"
  export HOME="$R/home" COPILOT_HOME="$R/copilot" ARCHON_HOME="$R/archon" PATH="$R/bin:$PATH"
  cd "$R/repo" || return 2
  git init -q -b main && git config user.name t && git config user.email t@t
  printf 'plugins { java }\njava {\n  toolchain { languageVersion.set(JavaLanguageVersion.of(21)) }\n}\n' > build.gradle.kts
  git add -A && git commit -qm init
  local pa=(); [ -n "$prof" ] && pa=(--profile "$prof")
  t0=$(now)
  timeout 600 archon kit add . "${pa[@]}" --no-tools --no-post-install --set local_ci="$lc" > "$R/add.log" 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'kit add failed (rc=%s), see %s/add.log\n' "$rc" "$R" > "$R/result"; tail -n 5 "$R/add.log" >> "$R/result"
    echo "FAILED-ADD" > "$R/status"; return 1
  fi
  bash .archon/scripts/kit-gitignore.sh > /dev/null 2>&1; git add -A > /dev/null; git commit -qm kit > /dev/null 2>&1
  local suites
  mapfile -t suites < <(find . -path ./node_modules -prune -o -name '*.test.sh' -print | grep -v node_modules | sort)
  t0=$(now)
  SUITE_JOBS=$jobs bash .claude/scripts/run-suites.sh "${suites[@]}" > "$R/logs/parallel.log" 2>&1
  local wall; wall=$(secs "$t0")
  local red=() t n still=()
  mapfile -t red < <(sed -n 's/^::error::\(.*\) failed$/\1/p' "$R/logs/parallel.log")
  for t in "${red[@]}"; do
    [ -n "$t" ] || continue
    n=$(echo "$t" | tr '/' '_')
    timeout 900 bash "$t" > "$R/logs/rerun-$n.log" 2>&1 < /dev/null || still+=("$t")
  done
  {
    echo "suites ${#suites[@]}"
    echo "red ${#still[@]}"
    echo "red-in-parallel ${#red[@]}"
    echo "wall $wall"
    echo "slowest $(sed -n 's/^::group::\(.*\) (\([0-9]*\)s)$/\2s \1/p' "$R/logs/parallel.log" | sort -rn | head -3 | sed 's#\./##' | tr '\n' ';' | sed 's/;$//')"
    for t in "${still[@]}"; do echo "REDSUITE $t"; done
  } > "$R/result"
  [ "${#still[@]}" -eq 0 ] && echo green > "$R/status" || echo red > "$R/status"
}

names=(on off spring)
[ -n "$only" ] && names=("$only")
run_one() {
  case "$1" in
    on) render on true ;;
    off) render off false ;;
    spring) render spring true core,java,java-spring ;;
  esac
}

t_all=$(now)
if [ "$serial" = 1 ]; then
  for n in "${names[@]}"; do ( run_one "$n" ) > "$work/$n.out" 2>&1; done
else
  pids=()
  for n in "${names[@]}"; do ( run_one "$n" ) > "$work/$n.out" 2>&1 & pids+=($!); done
  wait "${pids[@]}"
fi
total=$(secs "$t_all")

echo
printf '%-8s %-7s %-4s %-9s %s\n' render suites red wall 'three slowest'
rc=0
for n in "${names[@]}"; do
  f="$work/$n/result"
  if [ ! -s "$f" ]; then printf '%-8s no result (see %s)\n' "$n" "$work/$n.out"; rc=1; continue; fi
  if [ "$(cat "$work/$n/status" 2>/dev/null)" = FAILED-ADD ]; then printf '%-8s %s\n' "$n" "$(head -n 1 "$f")"; rc=1; continue; fi
  s=$(sed -n 's/^suites //p' "$f"); r=$(sed -n 's/^red //p' "$f"); w=$(sed -n 's/^wall //p' "$f"); sl=$(sed -n 's/^slowest //p' "$f")
  printf '%-8s %-7s %-4s %-9s %s\n' "$n" "$s" "$r" "${w}s" "$sl"
  grep '^REDSUITE ' "$f" | sed 's/^REDSUITE /    red alone: /'
  [ "$r" = 0 ] || rc=1
done
echo "total wall ${total}s ($([ "$serial" = 1 ] && echo one after another || echo at the same time)), SUITE_JOBS=$jobs"
[ "$rc" -eq 0 ] && echo "all green" || echo "NOT green"
exit "$rc"
