# Shared helpers for gh-git-ops scripts. Sourced, not executed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_SWITCH="$SCRIPT_DIR/../../gh-switch-account/scripts/gh-switch.sh"

die() { echo "error: $*" >&2; exit 1; }

require_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
}

current_branch() {
  local b
  b=$(git symbolic-ref --quiet --short HEAD) || die "detached HEAD; check out a branch first"
  echo "$b"
}

default_branch() {
  local b
  b=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [[ -z "$b" ]]; then
    b=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || true)
  fi
  echo "${b#origin/}"
}

is_protected() {
  local b="$1" def
  def=$(default_branch)
  [[ "$b" == "main" || "$b" == "master" || "$b" == "develop" || ( -n "$def" && "$b" == "$def" ) ]]
}

has_upstream() {
  git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1
}

# --as <account>: switch gh account for this run, restore the previous one on exit.
use_account() {
  local target="$1" prev
  [[ -f "$GH_SWITCH" ]] || die "gh-switch-account skill not found at $GH_SWITCH"
  prev=$(gh api user --jq .login 2>/dev/null || true)
  bash "$GH_SWITCH" "$target" >&2
  if [[ -n "$prev" && "${prev,,}" != "${target,,}" ]]; then
    RESTORE_ACCOUNT="$prev"
    trap 'bash "$GH_SWITCH" "$RESTORE_ACCOUNT" >&2' EXIT
  fi
}
