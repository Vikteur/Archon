#!/usr/bin/env bash
# Tests for scripts/install-tools.sh with stubbed package managers and fake tools (TASK-37).
# Fake tools (tool-a, ...) have check commands that are stub scripts, so the real tools on this machine never
# interfere. An "install" makes a fake tool's check pass by writing a state file. The managers (winget, brew, npm,
# powershell.exe, curl) are logging stubs on a stub PATH.
# Usage: bash scripts/test/install-tools.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../install-tools.sh"
real_conf="$here/../tools.conf"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

mkdir -p "$root/bin" "$root/mgr" "$root/late" "$root/project-with/scripts" "$root/project-without"

# The shared part of every installer stub: name = the tool an install makes available (the package, formula or
# script name); FAIL_IDS makes an install exit 1; ghost-* installs "succeed" without the tool ever appearing; late-*
# appear only in $LATE_DIR, a directory the script has to put on PATH.
cat > "$root/lib.sh" <<'LIB'
do_install() { # do_install <name> [version]
  local f
  for f in ${FAIL_IDS:-}; do
    if [ "$f" = "$1" ]; then echo "install of $1 failed" >&2; exit 1; fi
  done
  case "$1" in
    ghost-*) return 0 ;;
    late-*)
      printf '#!/usr/bin/env bash\necho "%s version $(cat "$STATE/%s") (2025-01-01)"\n' "$1" "$1" > "$LATE_DIR/$1"
      chmod +x "$LATE_DIR/$1" ;;
  esac
  echo "${2:-22.1.0}" > "$STATE/$1"
}
LIB

mgr() { # mgr <name> <body>: a manager stub that logs its call first
  { printf '#!/usr/bin/env bash\n. "$STUB_LIB"\necho "%s $*" >> "$LOG"\n' "$1"; printf '%s\n' "$2"; } > "$root/mgr/$1"
  chmod +x "$root/mgr/$1"
}
# shellcheck disable=SC2016
{
  mgr winget 'if [ "$1" = install ]; then
  while [ $# -gt 0 ]; do [ "$1" = --id ] && { shift; do_install "$1"; break; }; shift; done
fi'
  mgr brew 'if [ "$1" = install ]; then shift; [ "$1" = --cask ] && shift; do_install "$1"; fi'
  mgr npm 'if [ "$1 $2" = "install -g" ]; then
  case "$3" in *@*) do_install "${3%@*}" "${3##*@}" ;; *) do_install "$3" ;; esac
fi'
  mgr powershell.exe 'url="${*: -1}"; url="${url#irm }"; url="${url% | iex}"; n="${url##*/}"; do_install "${n%.*}"'
  mgr curl 'url="${*: -1}"; n="${url##*/}"; printf ". \"\$STUB_LIB\"; do_install %s\n" "${n%.*}"'
}
# The curl stub logs its own call; what it prints is the "install script" that bash runs.

# check stub for a fake tool: version from the state file, exit 127 when not installed; <style> picks the format.
tool() { # tool <name> <dir> [stderr]
  local out='echo "$1 version $v (2025-01-01)"'
  [ "${3:-}" = stderr ] && out='echo "openjdk version \"$v\"" >&2'
  printf '#!/usr/bin/env bash\nn=%s\nv=$(cat "$STATE/%s" 2>/dev/null) || exit 127\n%s\n' "$1" "$1" "${out//\$1/$1}" > "$2/$1"
  chmod +x "$2/$1"
}
for t in tool-a tool-b tool-c; do tool $t "$root/bin"; done
tool tool-d "$root/bin" stderr

cat > "$root/tools.conf" <<'CONF'
# name   | version  | kind   | windows                     | macos                      | check command
tool-a   | -        | pkg    | tool-a                      | tool-a                     | tool-a --version

tool-b   | >=20.19  | pkg    | tool-b                      | cask:tool-b                | tool-b --version
tool-c   | 1.53.0   | npm    | tool-c                      | tool-c                     | tool-c --version
tool-d   | -        | script | https://x.test/tool-d.ps1   | https://x.test/tool-d.sh   | tool-d --version
CONF

cat > "$root/project-with/scripts/install-hooks.sh" <<'HOOKS'
#!/usr/bin/env bash
echo "install-hooks.sh ran in $(basename "$PWD")" >> "$LOG"
HOOKS

# fresh [name]: a new state and log directory (an untouched machine); sets state, log.
fresh() {
  state="$root/state-$1"; log="$root/log-$1"; mkdir -p "$state"; : > "$log"
}
setver() { echo "$2" > "$state/$1"; } # setver <tool> <version>: the tool is installed at that version
run() { # run [env...]: the script on the stub PATH; sets out (stdout+stderr), rc
  out=$(env PATH="$root/mgr:$root/bin:$PATH" STUB_LIB="$root/lib.sh" STATE="$state" LOG="$log" LATE_DIR="$root/late" \
    TOOLS_CONF="$root/tools.conf" INSTALL_TOOLS_OS=windows PROJECT_DIR="$root/project-without" \
    INSTALL_TOOLS_PATH_DIRS="$root/late" "$@" bash "$script" ${script_args:-} 2>&1); rc=$?
}
check() { # check <name> <condition...>
  local name=$1; shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name"; echo "  out: $out"; echo "  log: $(cat "$log")"; fi
}
logged() { grep -qxF -- "$1" "$log"; }   # an exact line of the manager log
said() { grep -qF -- "$1" <<< "$out"; }  # text anywhere in the output
nosaid() { ! said "$1"; }
calls() { grep -c . "$log"; }

winget_flags='-e --silent --accept-source-agreements --accept-package-agreements'


# I1: a fresh Windows machine gets each tool from the right manager, at the pinned version.
fresh i1
run
check "I1 exit 0" [ "$rc" = 0 ]
check "I1 winget for a pkg" logged "winget install --id tool-a $winget_flags"
check "I1 winget for the next pkg" logged "winget install --id tool-b $winget_flags"
check "I1 npm at the pinned version" logged "npm install -g tool-c@1.53.0"
check "I1 powershell for a script" logged "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command irm https://x.test/tool-d.ps1 | iex"
check "I1 four installs, nothing else" [ "$(calls)" = 4 ]
check "I1 summary lists the installed" said "Installed: tool-a tool-b tool-c tool-d"
check "I1 summary: none skipped" said "Skipped: none"
check "I1 summary: none failed" said "Failed: none"

# I2: the second run installs nothing and says so (AC 13).
before=$(calls)
run
check "I2 exit 0" [ "$rc" = 0 ]
check "I2 no manager called" [ "$(calls)" = "$before" ]
check "I2 says nothing to install" said "Nothing to install: every tool is already in place."
check "I2 all skipped" said "Skipped: tool-a tool-b tool-c tool-d"

# I3: a fresh macOS machine: brew, brew --cask, npm, curl | bash.
fresh i3
run INSTALL_TOOLS_OS=macos
check "I3 exit 0" [ "$rc" = 0 ]
check "I3 brew formula" logged "brew install tool-a"
check "I3 brew cask" logged "brew install --cask tool-b"
check "I3 npm at the pinned version" logged "npm install -g tool-c@1.53.0"
check "I3 curl piped to bash" logged "curl -fsSL https://x.test/tool-d.sh"
check "I3 the piped script ran" [ -s "$state/tool-d" ]
check "I3 no winget, no powershell" [ -z "$(grep -E '^(winget|powershell)' "$log")" ]
check "I3 four installs" [ "$(calls)" = 4 ]

# I4: everything installed at a fitting version: no manager is called.
fresh i4
setver tool-a 2.88.1; setver tool-b 22.0.0; setver tool-c 1.53.0; setver tool-d 25.0.4
run
check "I4 exit 0" [ "$rc" = 0 ]
check "I4 no manager called" [ "$(calls)" = 0 ]
check "I4 says nothing to install" said "Nothing to install: every tool is already in place."
check "I4 all skipped" said "Skipped: tool-a tool-b tool-c tool-d"
check "I4 java-style stderr version read" nosaid "Failed: tool-d"

# I5: a wrong version installs; only that tool.
fresh i5
setver tool-a 2.88.1; setver tool-b 22.0.0; setver tool-c 1.52.0; setver tool-d 25.0.4
run
check "I5 exit 0" [ "$rc" = 0 ]
check "I5 the wrong version is reinstalled" logged "npm install -g tool-c@1.53.0"
check "I5 only that one" [ "$(calls)" = 1 ]
check "I5 summary" said "Installed: tool-c"
check "I5 not 'nothing to install'" nosaid "Nothing to install"

# I6: a pin is a prefix match on the version: 1.53.0 does not accept 1.53.9, a major spec accepts any minor.
fresh i6
setver tool-a 1; setver tool-b 22.0.0; setver tool-c 1.53.9; setver tool-d 25.0.4
run
check "I6 1.53.9 is not 1.53.0" logged "npm install -g tool-c@1.53.0"
printf '%s\n' '# major pin' 'tool-d | 25 | script | https://x.test/tool-d.ps1 | https://x.test/tool-d.sh | tool-d --version' > "$root/major.conf"
setver tool-d 250.1.0
run TOOLS_CONF="$root/major.conf"
check "I6 major 25 does not accept 250" logged "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command irm https://x.test/tool-d.ps1 | iex"
fresh i6b
setver tool-d 25.0.4
run TOOLS_CONF="$root/major.conf"
check "I6 major 25 accepts 25.0.4" [ "$(calls)" = 0 ]

# I7: a >= spec is a numeric minimum, per component (20.2 is below 20.19, 9.99 is below 20.19).
for case_ in "20.18.9 install" "20.2.0 install" "9.99.0 install" "20.19.0 skip" "20.19 skip" "20.20.1 skip" "21.0.0 skip" "100.0.0 skip"; do
  set -- $case_
  fresh i7
  setver tool-a 1; setver tool-b "$1"; setver tool-c 1.53.0; setver tool-d 25.0.4
  run
  if [ "$2" = install ]; then
    check "I7 >=20.19 installs over $1" logged "winget install --id tool-b $winget_flags"
  else
    check "I7 >=20.19 keeps $1" [ "$(calls)" = 0 ]
  fi
done

# I8: one failing install does not stop the others; it is listed as failed and the exit is 1.
fresh i8
run FAIL_IDS="tool-b"
check "I8 exit 1" [ "$rc" = 1 ]
check "I8 the later tools still ran" logged "npm install -g tool-c@1.53.0"
check "I8 the later script tool still ran" [ -s "$state/tool-d" ]
check "I8 listed as failed" said "Failed: tool-b"
check "I8 the rest listed as installed" said "Installed: tool-a tool-c tool-d"

# I9: a tool that is not found after a successful install command is "installed, open a new terminal", not failed;
# one that appears in a directory the script puts on PATH is simply installed.
cat > "$root/late.conf" <<'CONF'
late-x   | -  | pkg | late-x   | late-x   | late-x --version
ghost-y  | -  | pkg | ghost-y  | ghost-y  | ghost-y --version
CONF
fresh i9
run TOOLS_CONF="$root/late.conf"
check "I9 exit 0" [ "$rc" = 0 ]
check "I9 both installed, none failed" said "Failed: none"
check "I9 the ghost is installed" said "Installed: late-x ghost-y"
check "I9 asks for a new terminal" said "open a new terminal"

# I9b: a successful install command after which the tool still runs at a version that does not fit (a shadowing node
# on PATH, say) is failed, and the message names the version found and the version wanted. Not the "new terminal" note.
tool ghost-z "$root/bin"
printf '%s
' 'ghost-z | 2 | pkg | ghost-z | ghost-z | ghost-z --version' > "$root/stale.conf"
fresh i9b
setver ghost-z 1.0.0
run TOOLS_CONF="$root/stale.conf"
check "I9b exit 1" [ "$rc" = 1 ]
check "I9b listed as failed" said "Failed: ghost-z"
check "I9b not listed as installed" said "Installed: none"
check "I9b names the version found and wanted" said "still runs 1.0.0 (wants 2)"
check "I9b no new-terminal note" nosaid "open a new terminal"

# I10: the repo's install-hooks.sh runs (in its own directory); without one the step is skipped.
fresh i10
run PROJECT_DIR="$root/project-with"
check "I10 install-hooks.sh ran" logged "install-hooks.sh ran in project-with"
fresh i10b
run PROJECT_DIR="$root/project-without"
check "I10 not run without it" [ -z "$(grep install-hooks "$log")" ]
check "I10 a skip line says so" said "install-hooks.sh not found"

# I11: the manual steps are printed at the end.
check "I11 gh auth login" said "  1. gh auth login          sign in to GitHub"
check "I11 launch claude once" said "  2. claude                 start Claude Code once and log in, then exit"
check "I11 start Docker Desktop" said "  3. Docker Desktop         start it once so the daemon runs"
check "I11 the steps come after the summary" [ "$(grep -n 'gh auth login' <<< "$out" | head -1 | cut -d: -f1)" -gt "$(grep -n 'Installed:' <<< "$out" | head -1 | cut -d: -f1)" ]

# I16: a trailing-dot spec (tools.conf's "1." for jq, "4." for yq) is a major prefix: 1.7.1 fits, 17.0.0 does not.
printf '%s
' 'tool-a | 1. | pkg | tool-a | tool-a | tool-a --version' > "$root/dot.conf"
fresh i16
setver tool-a 1.7.1
run TOOLS_CONF="$root/dot.conf"
check "I16 1. accepts 1.7.1" [ "$(calls)" = 0 ]
fresh i16b
setver tool-a 17.0.0
run TOOLS_CONF="$root/dot.conf"
check "I16 1. does not accept 17.0.0" logged "winget install --id tool-a $winget_flags"

# I17: a failing install-hooks.sh is listed as failed and the exit is 1, even with every tool in place.
mkdir -p "$root/project-broken/scripts"
printf '#!/usr/bin/env bash
exit 3
' > "$root/project-broken/scripts/install-hooks.sh"
fresh i17
setver tool-a 2.88.1; setver tool-b 22.0.0; setver tool-c 1.53.0; setver tool-d 25.0.4
run PROJECT_DIR="$root/project-broken"
check "I17 exit 1" [ "$rc" = 1 ]
check "I17 listed as failed" said "Failed: project-hooks"

# I12: an unsupported OS exits 1.
fresh i12
run INSTALL_TOOLS_OS=plan9
check "I12 exit 1" [ "$rc" = 1 ]
check "I12 not supported yet" said "not supported yet"
check "I12 nothing installed" [ "$(calls)" = 0 ]

# I13: a missing manager is an error with a hint, and nothing is installed. The PATH has no stub managers.
fresh i13
run PATH="$root/bin:/usr/bin:/bin"
check "I13 winget missing: exit 1" [ "$rc" = 1 ]
check "I13 winget missing: says so" said "winget"
check "I13 nothing installed" [ "$(calls)" = 0 ]
run PATH="$root/bin:/usr/bin:/bin" INSTALL_TOOLS_OS=macos
check "I13 brew missing: exit 1" [ "$rc" = 1 ]
check "I13 brew missing: install hint" said "Homebrew/install"
check "I13 nothing installed" [ "$(calls)" = 0 ]

# I14: with everything installed, a missing manager does not matter. git stays on PATH: the hooks step needs it.
fresh i14
setver tool-a 2.88.1; setver tool-b 22.0.0; setver tool-c 1.53.0; setver tool-d 25.0.4
run PATH="$root/bin:$(dirname "$(command -v git)"):/usr/bin:/bin"
check "I14 exit 0 without a manager" [ "$rc" = 0 ]

# I15: the real scripts/tools.conf: 13 tools, known kinds, every column filled, groma pinned like example-app CI.
conf=$(sed -e 's/#.*//' "$real_conf" | grep -v '^[[:space:]]*$')
out="$conf"
check "I15 13 tools" [ "$(grep -c . <<< "$conf")" = 13 ]
check "I15 order" [ "$(cut -d'|' -f1 <<< "$conf" | tr -d ' ' | tr '\n' ' ')" = \
  "git gh node jq yq java docker claude copilot archon backlog groma codegraph " ]
check "I15 six columns, none empty" [ -z "$(awk -F'|' 'NF != 6 { print; next } { for (i = 1; i <= 6; i++) { v = $i; gsub(/[[:space:]]/, "", v); if (v == "") print } }' <<< "$conf")" ]
check "I15 known kinds" [ -z "$(cut -d'|' -f3 <<< "$conf" | tr -d ' ' | grep -vxE 'pkg|npm|script')" ]
pin() { awk -F'|' -v n="$1" '{ gsub(/ /, "", $1); gsub(/ /, "", $2) } $1 == n { print $2 }' <<< "$conf"; }
check "I15 groma is pinned to 0.6.6" [ "$(pin groma)" = 0.6.6 ]
project_ci="$here/../../.github/workflows/ci.yml"
if [ ! -f "$project_ci" ]; then
  echo "SKIP: I15 groma pin vs example-app CI ($project_ci not found)"
elif ! grep -qF "npm install -g groma.md@" "$project_ci"; then
  # example-app CI installs no groma until its fresh map exists (TASK-1.1 skeleton); nothing to match then.
  echo "SKIP: I15 groma pin vs example-app CI (it installs no groma)"
else
  check "I15 groma pin matches example-app CI" grep -qF "npm install -g groma.md@$(pin groma)" "$project_ci"
fi
project_agents="$here/../../AGENTS.md"
if [ ! -f "$project_agents" ]; then
  echo "SKIP: I15 backlog pin vs example-app AGENTS.md ($project_agents not found)"
else
  check "I15 backlog pin matches the instructions version in example-app AGENTS.md" grep -qF "backlog.md-instructions-version: $(pin backlog)" "$project_agents"
fi
check "I15 every npm tool is pinned" [ -z "$(awk -F'|' '{ gsub(/ /, "", $2); gsub(/ /, "", $3) } $3 == "npm" && $2 !~ /^[0-9]+(\.[0-9]+)+$/ { print $1 }' <<< "$conf")" ]

# L1: --check only reports: exit 1 with a tool missing, no manager called, no hooks step; exit 0 when all fit.
fresh l1
script_args=--check; run PROJECT_DIR="$root/project-with"
check "L1 missing: exit 1" [ "$rc" = 1 ]
check "L1 missing: names them" said "Check: missing or wrong version: tool-a tool-b tool-c tool-d"
check "L1 nothing installed" [ "$(calls)" = 0 ]
check "L1 no hooks step" nosaid "install-hooks"
setver tool-a 2.88.1; setver tool-b 22.0.0; setver tool-c 1.53.0; setver tool-d 25.0.4
run
check "L1 all fit: exit 0" [ "$rc" = 0 ]
check "L1 all fit: says so" said "Check: every tool is in place."
setver tool-c 1.52.0; run
check "L1 a wrong version: exit 1" [ "$rc" = 1 ]
check "L1 a wrong version: named" said "wrong version: tool-c"
script_args=bogus; run
check "L1 an unknown argument: exit 2" [ "$rc" = 2 ]
script_args=

# L2: Linux: pkg tools are not installed by a manager (warned about), npm and script tools are.
fresh l2
run INSTALL_TOOLS_OS=linux
check "L2 exit 1: pkg tools are missing" [ "$rc" = 1 ]
check "L2 npm tool installed" logged "npm install -g tool-c@1.53.0"
check "L2 script tool installed with the macOS URL" logged "curl -fsSL https://x.test/tool-d.sh"
check "L2 no winget, no brew" [ -z "$(grep -E '^(winget|brew)' "$log")" ]
check "L2 reports tool-a as failed, with a hint" said "tool-a cannot be installed here"
check "L2 summary" said "Installed: tool-c tool-d"

# L3: Linux jq: a release download into the prefix (stub curl writes the binary; the checksum file is not found).
fresh l3
mkdir -p "$root/lp/bin" "$root/curlbin"
printf '#!/usr/bin/env bash\necho "$*" >> "$LOG"\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && o=$2; shift; done\ncase "$o" in *tmp*|/tmp/*) ;; esac\ncase "${*: -1}" in *sha256sum.txt) exit 22 ;; esac\nprintf "#!/usr/bin/env bash\\necho jq-1.7.1\\n" > "$o"\n' > "$root/curlbin/curl"
chmod +x "$root/curlbin/curl"
cat > "$root/linux.conf" <<CONF
jq | 1.7 | pkg | jqlang.jq | jq | $root/lp/bin/jq --version
CONF
run INSTALL_TOOLS_OS=linux TOOLS_CONF="$root/linux.conf" LOCAL_PREFIX="$root/lp" PATH="$root/curlbin:$PATH"
check "L3 exit 0" [ "$rc" = 0 ]
check "L3 downloaded the release binary" grep -q 'jqlang/jq/releases/download/jq-1.7.1/jq-linux-' "$log"
check "L3 installed into the prefix" [ -x "$root/lp/bin/jq" ]
check "L3 summary" said "Installed: jq"
run INSTALL_TOOLS_OS=linux TOOLS_CONF="$root/linux.conf" LOCAL_PREFIX="$root/lp" PATH="$root/curlbin:$PATH"
check "L3 idempotent: second run installs nothing" said "Nothing to install"

echo "install-tools tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
