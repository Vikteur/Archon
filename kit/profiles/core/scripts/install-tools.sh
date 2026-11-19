#!/usr/bin/env bash
# One-step tool install (TASK-37): installs every tool listed in scripts/tools.conf on Windows (winget, from Git Bash),
# on macOS (Homebrew) and on Linux (no sudo: jq, yq and gh as release downloads into ~/.local, npm -g for the npm tools,
# the installer scripts; git, node, java and docker need sudo there, so they are only checked: a missing one is warned
# about and counts as failed, exit 1). The npm tools are installed at their pinned version; the others come through winget,
# Homebrew or their own installer, and are only checked against the version in tools.conf. A tool that is already
# installed at a fitting version is skipped, so a second run installs nothing. Ends with a summary and the steps that
# stay manual.
#   bash scripts/install-tools.sh            install what is missing
#   bash scripts/install-tools.sh --check    only report what is missing or at the wrong version; installs nothing and
#                                            skips the git hooks; exit 1 when any tool is missing
# Environment (for tests; the defaults are right on a real machine):
#   TOOLS_CONF                tool list (default: tools.conf beside this script)
#   INSTALL_TOOLS_OS          windows | macos | linux (default: from uname)
#   LOCAL_PREFIX              Linux install prefix (default: ~/.local; binaries go to its bin/)
#   JQ_VERSION, YQ_VERSION, GH_VERSION   Linux download versions (1.7.1, v4.54.1, 2.63.2)
#   PROJECT_DIR               the checkout whose scripts/install-hooks.sh switches the git hooks on (default: this repo)
#   INSTALL_TOOLS_PATH_DIRS   directories put on PATH after a Windows install, colon-separated (default: the usual ones)
#   AGENT_CLI                 claude | copilot: the agent CLI this project runs (default: agent_cli in .archon/kit.yaml,
#                             else in .archon/kit.defaults.yaml, else claude). Of the two agent CLIs in tools.conf only
#                             that one is installed or checked; INSTALL_TOOLS_ALL=1 takes both.
#   INSTALL_TOOLS_BACKLOG     0 | 1: Backlog.md (the backlog tool) off or on (default: backlog: false|true in
#                             .archon/kit.yaml, else in .archon/kit.defaults.yaml, else on)
# Plain bash 3.2 on purpose: a fresh Mac has no newer one. Exit 1 when an install failed (including one that left the
# tool at a version that does not fit), when a package manager is missing, or when the OS is not supported.
set -o pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
conf=${TOOLS_CONF:-$here/tools.conf}
project=${PROJECT_DIR:-$(cd "$here/.." && pwd)}

os=${INSTALL_TOOLS_OS:-}
if [ -z "$os" ]; then
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) os=windows ;;
    Darwin) os=macos ;;
    Linux) os=linux ;;
    *) os=other ;;
  esac
fi
case "$os" in
  windows | macos | linux) ;;
  *) echo "install-tools.sh: $os ($(uname -s)) is not supported yet (Windows with Git Bash, macOS and Linux only)." >&2; exit 1 ;;
esac
check_only=0
case "${1:-}" in
  --check) check_only=1 ;;
  '') ;;
  *) echo "usage: install-tools.sh [--check]" >&2; exit 2 ;;
esac
[ -f "$conf" ] || { echo "install-tools.sh: tool list not found: $conf" >&2; exit 1; }

trim() { local v=$1; v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}; printf '%s' "$v"; }
unix_path() { if command -v cygpath > /dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi; }

# A winget install does not update the running shell's PATH: put the usual install directories on it, so later steps
# (npm after node) and the re-check find what was just installed. Called again after every install.
path_dirs=()
prefix=${LOCAL_PREFIX:-$HOME/.local}
if [ "$os" = linux ] || [ "$os" = macos ]; then
  path_dirs=("$prefix/bin")
elif [ "$os" = windows ]; then
  if [ -n "${INSTALL_TOOLS_PATH_DIRS+x}" ]; then
    IFS=: read -r -a path_dirs <<< "$INSTALL_TOOLS_PATH_DIRS"
  else
    path_dirs=("/c/Program Files/nodejs")
    [ -z "${APPDATA:-}" ] || path_dirs+=("$(unix_path "$APPDATA")/npm")
    [ -z "${LOCALAPPDATA:-}" ] || path_dirs+=("$(unix_path "$LOCALAPPDATA")/Microsoft/WinGet/Links")
    path_dirs+=("$HOME/.archon/bin" "$HOME/.local/bin")
  fi
fi
refresh_path() {
  local d
  for d in ${path_dirs[@]+"${path_dirs[@]}"}; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
  done
  export PATH
}

# version_fits <spec> <version>: "-" is any version, ">=X.Y" a numeric minimum, anything else a prefix (1.53.0, 25).
version_fits() {
  local spec=$1 ver=$2 min a b i
  case "$spec" in
    -) return 0 ;;
    '>='*)
      [ -n "$ver" ] || return 1
      min=${spec#>=}
      IFS=. read -r -a a <<< "$ver"; IFS=. read -r -a b <<< "$min"
      for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
        if ((10#${a[i]:-0} > 10#${b[i]:-0})); then return 0; fi
        if ((10#${a[i]:-0} < 10#${b[i]:-0})); then return 1; fi
      done
      return 0 ;;
    *)
      spec=${spec%.}
      [ -n "$ver" ] && { [ "$ver" = "$spec" ] || [[ "$ver" == "$spec".* ]]; } ;;
  esac
}

# check_tool <spec> <check command>: sets found_version; succeeds when the tool runs and its version fits the spec.
found_version=""
check_tool() {
  local spec=$1 check=$2 out
  found_version=""
  command -v "${check%% *}" > /dev/null 2>&1 || return 1
  out=$(eval "$check" 2>&1 < /dev/null) || return 1
  found_version=$(printf '%s\n' "$out" | grep -oE '[0-9]+(\.[0-9]+)*' | head -1)
  version_fits "$spec" "$found_version"
}

names=(); specs=(); kinds=(); wins=(); macs=(); checks=()
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}; line=${line%%#*}
  [ -n "$(trim "$line")" ] || continue
  IFS='|' read -r name spec kind win mac check <<< "$line"
  names+=("$(trim "$name")"); specs+=("$(trim "$spec")"); kinds+=("$(trim "$kind")")
  wins+=("$(trim "$win")"); macs+=("$(trim "$mac")"); checks+=("$(trim "$check")")
done < "$conf"

# The agent CLI (claude or copilot): read with sed, not yq, since yq may be one of the tools still to install.
agent_cli=${AGENT_CLI:-}
for f in "$project/.archon/kit.yaml" "$project/.archon/kit.defaults.yaml"; do
  [ -z "$agent_cli" ] || break
  [ -f "$f" ] && agent_cli=$(sed -n 's/^agent_cli:[[:space:]]*["'"'"']\{0,1\}\([a-z]*\).*/\1/p' "$f" | head -n 1)
done
agent_cli=${agent_cli:-claude}
# Backlog.md (the task board) is optional: INSTALL_TOOLS_BACKLOG=0|1, else `backlog: false|true` in kit.yaml, then in
# kit.defaults.yaml, else on.
use_backlog=${INSTALL_TOOLS_BACKLOG:-}
for f in "$project/.archon/kit.yaml" "$project/.archon/kit.defaults.yaml"; do
  [ -z "$use_backlog" ] || break
  [ -f "$f" ] && use_backlog=$(sed -n 's/^backlog:[[:space:]]*["'"'"']\{0,1\}\([a-z01]*\).*/\1/p' "$f" | head -n 1)
done
case "$use_backlog" in false | 0 | no | off) use_backlog=0 ;; *) use_backlog=1 ;; esac
keep=(); agent_dropped=0
for i in "${!names[@]}"; do
  case "${names[i]}" in
    claude | copilot)
      if [ "${INSTALL_TOOLS_ALL:-0}" != 1 ] && [ "${names[i]}" != "$agent_cli" ]; then agent_dropped=1; continue; fi ;;
    backlog) [ "$use_backlog" = 1 ] || continue ;;
  esac
  keep+=("$i")
done
[ "$agent_dropped" = 0 ] || echo "Agent CLI: $agent_cli (the other one is left out; INSTALL_TOOLS_ALL=1 takes both)"
[ "$use_backlog" = 1 ] || echo "Backlog.md: off (backlog: false in .archon/kit.yaml, or INSTALL_TOOLS_BACKLOG=0), not installed"
if [ "${#keep[@]}" -ne "${#names[@]}" ]; then
  n2=(); s2=(); k2=(); w2=(); m2=(); c2=()
  for i in "${keep[@]}"; do
    n2+=("${names[i]}"); s2+=("${specs[i]}"); k2+=("${kinds[i]}"); w2+=("${wins[i]}"); m2+=("${macs[i]}"); c2+=("${checks[i]}")
  done
  names=("${n2[@]}"); specs=("${s2[@]}"); kinds=("${k2[@]}"); wins=("${w2[@]}"); macs=("${m2[@]}"); checks=("${c2[@]}")
fi

installed=(); skipped=(); failed=(); notes=()
todo=()
refresh_path
echo "Checking ${#names[@]} tools ($os)"
for i in "${!names[@]}"; do
  if check_tool "${specs[i]}" "${checks[i]}"; then
    echo "  ok       ${names[i]} ${found_version}"
    skipped+=("${names[i]}")
  else
    echo "  missing  ${names[i]} (wants ${specs[i]}${found_version:+, has $found_version})"
    todo+=("$i")
  fi
done

if [ "$check_only" -eq 1 ]; then
  echo
  if [ "${#todo[@]}" -eq 0 ]; then echo "Check: every tool is in place."; exit 0; fi
  missing=()
  for i in "${todo[@]}"; do missing+=("${names[i]}"); done
  echo "Check: missing or wrong version: ${missing[*]}"
  exit 1
fi

# winget and brew are needed before the first install, not halfway through.
for i in ${todo[@]+"${todo[@]}"}; do
  [ "${kinds[i]}" = pkg ] || { [ "${kinds[i]}" = script ] && [ "$os" = windows ] && [[ "${wins[i]}" == winget:* ]]; } || continue
  [ "$os" != linux ] || continue
  if [ "$os" = windows ] && ! command -v winget > /dev/null 2>&1; then
    echo "install-tools.sh: winget is missing. Install 'App Installer' from the Microsoft Store (or update Windows), then run this again." >&2
    exit 1
  fi
  if [ "$os" = macos ] && ! command -v brew > /dev/null 2>&1; then
    echo "install-tools.sh: Homebrew is missing. Install it first:" >&2
    echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' >&2
    exit 1
  fi
  break
done

# Linux, no sudo. fetch <url> <dest>; sum_of <file> <name> [<column>]: the sha256 listed for <name>; fetch_checked <url>
# <dest> <sums url> <name> [<column>] downloads, and verifies against the release's checksum file when there is one (a
# file that cannot be fetched is a warning; a mismatch fails).
fetch() { curl -fsSL -o "$2" "$1"; }
fetch_checked() {
  local url=$1 dest=$2 sums_url=$3 name=$4 col=${5:-1} sums want got
  fetch "$url" "$dest" || return 1
  sums=$(mktemp)
  if fetch "$sums_url" "$sums" 2> /dev/null; then
    want=$(awk -v n="$name" -v c="$col" '$1 == n || $2 == n || $2 == "*" n {print $c; exit}' "$sums")
    got=$(sha256sum "$dest" | cut -d' ' -f1)
    rm -f "$sums"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then echo "checksum mismatch for $name" >&2; rm -f "$dest"; return 1; fi
    [ -n "$want" ] || echo "  no checksum listed for $name" >&2
  else
    rm -f "$sums"; echo "  no checksum file for $name, skipping the check" >&2
  fi
}
linux_arch() { case "$(uname -m)" in x86_64 | amd64) echo amd64 ;; aarch64 | arm64) echo arm64 ;; *) echo "$(uname -m)" ;; esac; }
linux_install() { # linux_install <name>
  local n=$1 arch ver tmp
  arch=$(linux_arch); mkdir -p "$prefix/bin" || return 1
  case "$n" in
    jq)
      ver=${JQ_VERSION:-1.7.1}; tmp=$(mktemp)
      fetch_checked "https://github.com/jqlang/jq/releases/download/jq-$ver/jq-linux-$arch" "$tmp" \
        "https://github.com/jqlang/jq/releases/download/jq-$ver/sha256sum.txt" "jq-linux-$arch" 1 || return 1
      install -m 0755 "$tmp" "$prefix/bin/jq"; rm -f "$tmp" ;;
    yq)
      ver=${YQ_VERSION:-v4.54.1}; tmp=$(mktemp)
      # mikefarah's `checksums` file lists several hashes per file; checksums_hashes_order names the columns
      local order col
      order=$(curl -fsSL "https://github.com/mikefarah/yq/releases/download/$ver/checksums_hashes_order" 2> /dev/null | grep -n -x 'SHA-256' | cut -d: -f1)
      col=$(( ${order:-0} + 1 ))
      [ "$col" -gt 1 ] || col=0
      if [ "$col" -gt 1 ]; then
        fetch_checked "https://github.com/mikefarah/yq/releases/download/$ver/yq_linux_$arch" "$tmp" \
          "https://github.com/mikefarah/yq/releases/download/$ver/checksums" "yq_linux_$arch" "$col" || return 1
      else
        echo "  no checksum list for yq, skipping the check" >&2
        fetch "https://github.com/mikefarah/yq/releases/download/$ver/yq_linux_$arch" "$tmp" || return 1
      fi
      install -m 0755 "$tmp" "$prefix/bin/yq"; rm -f "$tmp" ;;
    gh)
      ver=${GH_VERSION:-2.63.2}; tmp=$(mktemp)
      fetch_checked "https://github.com/cli/cli/releases/download/v$ver/gh_${ver}_linux_$arch.tar.gz" "$tmp" \
        "https://github.com/cli/cli/releases/download/v$ver/gh_${ver}_checksums.txt" "gh_${ver}_linux_$arch.tar.gz" 1 || return 1
      tar -xzf "$tmp" -C "$prefix" --strip-components=1 "gh_${ver}_linux_$arch/bin/gh" "gh_${ver}_linux_$arch/share" 2> /dev/null \
        || tar -xzf "$tmp" -C "$prefix" --strip-components=1 || { rm -f "$tmp"; return 1; }
      rm -f "$tmp" ;;
    java | docker)
      echo "$n cannot be installed without sudo: install it with your package manager (see tools.conf for the version)" >&2
      return 2 ;;
    *)
      echo "$n cannot be installed here: install it with your package manager" >&2
      return 1 ;;
  esac
}

# install_tool <index>: runs the one install command for the tool on this OS.
install_tool() {
  local i=$1 kind=${kinds[$1]} target
  if [ "$os" = windows ]; then target=${wins[i]}; else target=${macs[i]}; fi
  case "$kind:$os" in
    pkg:windows) winget install --id "$target" -e --silent --accept-source-agreements --accept-package-agreements ;;
    pkg:macos)
      case "$target" in
        cask:*) brew install --cask "${target#cask:}" ;;
        *) brew install "$target" ;;
      esac ;;
    pkg:linux) linux_install "${names[i]}" ;;
    npm:*)
      if [[ "${specs[i]}" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then npm install -g "$target@${specs[i]}"; else npm install -g "$target"; fi ;;
    script:windows)
      # a Windows column "winget:<id>" says the tool comes from winget there (rtk has no PowerShell installer)
      case "$target" in
        winget:*) winget install --id "${target#winget:}" -e --silent --accept-source-agreements --accept-package-agreements ;;
        *) powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm $target | iex" ;;
      esac ;;
    script:macos | script:linux)
      # rtk: its install script is pinned in the URL; the OSS edition (Apache-2.0) at the pinned version, into the prefix,
      # with the script's own checksum check on (RTK_SKIP_CHECKSUM is never set). Never `cargo install rtk`: other crate.
      case "${names[i]}" in
        rtk) curl -fsSL "$target" | env RTK_VERSION="v${specs[i]}" RTK_INSTALL_DIR="$prefix/bin" RTK_EDITION=oss sh ;;
        *) curl -fsSL "$target" | bash ;;
      esac ;;
    *) echo "unknown kind '$kind' for ${names[i]}" >&2; return 1 ;;
  esac
}

echo
if [ "${#todo[@]}" -eq 0 ]; then
  echo "Nothing to install: every tool is already in place."
else
  for i in "${todo[@]}"; do
    echo "Installing ${names[i]}"
    if result=$(install_tool "$i" 2>&1 < /dev/null); then
      refresh_path
      if check_tool "${specs[i]}" "${checks[i]}"; then
        installed+=("${names[i]}")
      elif [ -n "$found_version" ]; then
        # Found, but at a version that does not fit (an older copy earlier on PATH, say): the install did not help.
        echo "  failed: ${names[i]} installed, but $(command -v "${checks[i]%% *}") still runs $found_version (wants ${specs[i]})"
        failed+=("${names[i]}")
      else
        installed+=("${names[i]}")
        notes+=("${names[i]} is installed but not found on this PATH yet: open a new terminal.")
      fi
    else
      rc=$?
      printf '%s\n' "$result" | tail -n 15 | sed 's/^/    /'
      if [ "$os" = linux ] && [ "$rc" -eq 2 ]; then
        echo "  warning: ${names[i]} is missing and is not installed by this script"
        notes+=("${names[i]} is missing: install it by hand.")
        failed+=("${names[i]}")
      else
        echo "  failed: ${names[i]}"
        failed+=("${names[i]}")
      fi
    fi
  done
fi

# The repo's git hooks (.githooks/: commit-msg, the pre-push map check) are switched on by its own script.
echo
if [ -f "$project/scripts/install-hooks.sh" ]; then
  echo "Switching on the project's git hooks (scripts/install-hooks.sh)"
  if ! (cd "$project" && bash scripts/install-hooks.sh); then
    echo "  failed: the project hooks"
    failed+=("project-hooks")
  fi
else
  echo "Skipped the project hooks: $project/scripts/install-hooks.sh not found."
fi

list() { if [ "$#" -eq 0 ]; then echo none; else echo "$*"; fi; }
echo
echo "Summary"
echo "  Installed: $(list ${installed[@]+"${installed[@]}"})"
echo "  Skipped: $(list ${skipped[@]+"${skipped[@]}"})"
echo "  Failed: $(list ${failed[@]+"${failed[@]}"})"
if [ "${#notes[@]}" -gt 0 ]; then
  printf '  Note: %s\n' "${notes[@]}"
fi

cat <<'STEPS'

Still to do by hand (they need you):
  1. gh auth login          sign in to GitHub
  2. claude                 start Claude Code once and log in, then exit
  3. Docker Desktop         start it once so the daemon runs
STEPS

[ "${#failed[@]}" -eq 0 ]
