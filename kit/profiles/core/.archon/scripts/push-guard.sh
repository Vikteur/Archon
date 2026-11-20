#!/usr/bin/env bash
# Pre-push guard (P2: a script, not a model; owner decision 2026-10-20, D14 and its "kleine uitzondering"): a push to
# main is refused, day or night, unless either
#   - every commit it adds is an exempt one: a script that commits to main by design made it and it changes only that
#     script's own paths (EXEMPT below: a ticket commit backlog/, retro-commit.sh docs/retro/, the
#     token reports' scripts/tokenomics/commit-reports.sh docs/tokenomics/). The guard does not take the caller's word
#     for which script it is: it reads the changed paths of every commit in the push range itself, and each commit must
#     stay inside ONE entry's paths; a merge commit, a commit touching any other path, a forced (non-fast-forward)
#     push, or a range it cannot read is not exempt; or
#   - the owner allowed that exact commit (sudo allow, below).
# Work reaches main through a pull request and its merge, not a push.
#   push-guard.sh check <remote> <url>    the pre-push hook: git passes one line per pushed ref on stdin,
#                                         "<local ref> <local sha> <remote ref> <remote sha>". Exit 0 when no ref is
#                                         refs/heads/main or each such push is exempt or allowed; exit 1 (the push
#                                         stops) otherwise.
#   sudo bash push-guard.sh allow <sha> [<minutes>]
#                                         the owner allows ONE push of that commit (40 hex, e.g. "$(git rev-parse HEAD)")
#                                         to main, for <minutes> (30, at most 240). It must run as root: the entry is a
#                                         root-owned file in /etc/push-guard/allow, which an agent cannot write without
#                                         the owner's sudo password.
#   push-guard.sh paths                   print the exempt path prefixes, one per line (one list, no drift).
#   push-guard.sh install                 switch the hook on for this clone and its worktrees: writes
#                                         <git common dir>/hooks/pre-push, which runs this script from the main checkout.
#                                         It does not set core.hooksPath (that would also switch on every hook of .githooks/).
# An allow entry counts only when the file is owned by root, names the pushed sha and has not expired; once a push of it
# passed the guard it is recorded in ~/.local/state/push-guard/used and does not count again (one push per entry). A
# delete of main is never allowed here. There are no environment overrides on purpose: an override would be a way
# around the guard; widening EXEMPT is a change to D14, made by the owner. Exit 2: usage.
set -uo pipefail

ALLOW_DIR=/etc/push-guard/allow
OWNER_UID=0
USED=${HOME:-/nonexistent}/.local/state/push-guard/used
BRANCH=refs/heads/main
# The scripts that may push to main without an allow, and the only paths their commits may change (owner decision
# 2026-10-20). "<who>|<path prefix>"; a commit is exempt when all its paths share one entry's prefix.
EXEMPT=(
  "ticket commits|backlog/"
  "retro-commit.sh|docs/retro/"
  "scripts/tokenomics/commit-reports.sh|docs/tokenomics/"
)

usage() { echo "push-guard: $*" >&2; echo "usage: push-guard.sh check <remote> <url> | allow <sha> [<minutes>] | paths | install" >&2; exit 2; }
zero='^0+$' sha_re='^[0-9a-f]{40}$'

allowed() { # allowed <sha>: a root-owned, unexpired entry for it that was not used yet
  local f="$ALLOW_DIR/$1" expires
  [ -f "$f" ] && [ "$(stat -c %u "$f" 2>/dev/null)" = "$OWNER_UID" ] || return 1
  expires=$(sed -n 's/^expires: //p' "$f")
  [[ "$expires" =~ ^[0-9]+$ ]] && [ "$expires" -gt "$(date +%s)" ] || return 1
  ! grep -qxF "$1" "$USED" 2>/dev/null
}

why=""
exempt() { # exempt <remote sha> <local sha>: every commit in the range stays inside one EXEMPT entry; else $why says why
  local c p paths entry prefix who fits outside n=0
  [[ "$2" =~ $zero ]] && { why="a delete"; return 1; }
  [[ "$1" =~ $zero ]] && { why="main does not exist on the remote yet"; return 1; }
  git cat-file -e "$1^{commit}" 2>/dev/null || { why="the remote main ${1:0:7} is not here: fetch, then push again"; return 1; }
  git merge-base --is-ancestor "$1" "$2" 2>/dev/null || { why="not a fast-forward of main (a forced push)"; return 1; }
  for c in $(git rev-list "$1..$2") ; do
    n=$((n+1))
    [ "$(git rev-list --no-walk --parents "$c" | wc -w)" -eq 2 ] || { why="${c:0:7} is a merge commit"; return 1; }
    paths=$(git -c core.quotePath=false diff-tree --no-commit-id -r --name-only --no-renames "$c") || { why="cannot read ${c:0:7}"; return 1; }
    [ -n "$paths" ] || { why="${c:0:7} changes no file"; return 1; }
    fits=""
    for entry in "${EXEMPT[@]}"; do
      who=${entry%%|*} prefix=${entry#*|}
      outside=$(while IFS= read -r p; do [[ "$p" == "$prefix"* ]] || echo "$p"; done <<< "$paths")
      [ -z "$outside" ] && { fits=$who; break; }
    done
    [ -n "$fits" ] || { why="${c:0:7} changes $(printf '%s\n' "$paths" | head -n 3 | paste -sd ' ' -), outside every exempt script's paths"; return 1; }
  done
  [ "$n" -gt 0 ] || { why="no commit to push"; return 1; }
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
  check)
    refused=() passed=()
    while read -r _ local_sha remote_ref remote_sha; do
      [ "$remote_ref" = "$BRANCH" ] || continue
      if [[ "$local_sha" =~ $zero ]]; then refused+=("a delete of main (never allowed through the guard)")
      elif allowed "$local_sha"; then passed+=("$local_sha")
      elif exempt "$remote_sha" "$local_sha"; then
        echo "push-guard: ${local_sha:0:7} to main is exempt: every commit stays inside one exempt script's paths" >&2
      else refused+=("$local_sha to main: not exempt ($why), and no unused owner allow entry for it"); fi
    done
    if [ ${#refused[@]} -gt 0 ]; then
      {
        echo "push-guard: push refused (owner decision 2026-10-20, D14: a push to main needs the owner's allow):"
        printf '  %s\n' "${refused[@]}"
        echo "Agents: do not push to main; open a pull request. Never use --no-verify to get around this."
        echo "Owner, to allow one push of a commit: sudo bash .archon/scripts/push-guard.sh allow <sha>"
      } >&2
      exit 1
    fi
    if [ ${#passed[@]} -gt 0 ]; then
      mkdir -p "$(dirname "$USED")" && printf '%s\n' "${passed[@]}" >> "$USED" \
        || { echo "push-guard: cannot record the allow entry as used ($USED): push refused" >&2; exit 1; }
      echo "push-guard: push of ${passed[*]} to main allowed by the owner (one push; the entry is now used)" >&2
    fi
    exit 0 ;;
  allow)
    sha=${1:-}; minutes=${2:-30}
    [[ "$sha" =~ $sha_re ]] || usage "allow needs the full 40-hex sha, e.g. \"\$(git rev-parse HEAD)\""
    [[ "$minutes" =~ ^[0-9]+$ ]] && [ "$minutes" -ge 1 ] && [ "$minutes" -le 240 ] || usage "minutes: 1 to 240"
    [ "$(id -u)" = "$OWNER_UID" ] || { echo "push-guard: allow runs as root only: sudo bash $0 allow $sha" >&2; exit 1; }
    mkdir -p "$ALLOW_DIR" && chmod 755 "$(dirname "$ALLOW_DIR")" "$ALLOW_DIR" || exit 1
    expires=$(( $(date +%s) + minutes * 60 ))
    printf 'sha: %s\nexpires: %s\nby: %s\ncreated: %s\n' "$sha" "$expires" "${SUDO_USER:-root}" "$(date -u +%FT%TZ)" \
      > "$ALLOW_DIR/$sha" && chmod 644 "$ALLOW_DIR/$sha" || exit 1
    echo "push-guard: one push of $sha to main allowed until $(date -d "@$expires" +%T)" >&2 ;;
  paths) for entry in "${EXEMPT[@]}"; do echo "${entry#*|}"; done ;;
  install)
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || usage "not in a git checkout"
    main=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
    [ -z "$(git config --get core.hooksPath)" ] \
      || echo "push-guard: core.hooksPath is set, so git ignores $common/hooks: call this script from that folder's pre-push too" >&2
    mkdir -p "$common/hooks"
    cat > "$common/hooks/pre-push" <<EOF
#!/usr/bin/env bash
# Written by push-guard.sh install (owner decision 2026-10-20, D14). A missing guard refuses every push.
guard="$main/.archon/scripts/push-guard.sh"
[ -f "\$guard" ] || { echo "pre-push: \$guard is missing: push refused" >&2; exit 1; }
exec bash "\$guard" check "\$@"
EOF
    chmod +x "$common/hooks/pre-push"
    echo "push-guard: installed $common/hooks/pre-push" >&2 ;;
  *) usage "unknown command '$cmd'" ;;
esac
