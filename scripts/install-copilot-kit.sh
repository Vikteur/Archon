#!/usr/bin/env bash
# install-copilot-kit.sh: install Archon and its Copilot kit on this machine, in one go.
# Run it with --help for the steps and the options.

set -euo pipefail

FORK_URL="https://github.com/Vikteur/Archon.git"
FORK_BRANCH="local/console"

BACKEND="" FRONTEND="" CONTRACT="" BACKLOG=0
ARCHON_DIR="$HOME/archon" BRANCH="chore/archon-kit"
COMMIT=1 WEB=1 SMOKE=1 DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage:
  bash install-copilot-kit.sh --backend <repo> --contract <openapi file> [options]
  bash <(curl -fsSL https://raw.githubusercontent.com/Vikteur/Archon/local/console/scripts/install-copilot-kit.sh) \
    --backend <repo> --contract <openapi file> [options]

Required:
  --backend <path>      backend git repository (gets the whole kit)
  --contract <file>     the OpenAPI contract file (.yaml, .yml or .json)

Options:
  --frontend <path>     frontend git repository (gets the codegraph MCP server and rtk)
  --backlog             use Backlog.md for tickets (default: off)
  --archon-dir <path>   where the Archon clone lives (default: ~/archon)
  --branch <name>       branch for the kit commit (default: chore/archon-kit)
  --no-commit           leave the kit files uncommitted
  --no-web              do not start the MCP Inspectors at the end
  --no-smoke            skip the dry run of build-feature-copilot
  --dry-run             check the machine and the paths, print the plan, change nothing
  -h, --help            this text

What it does, in order (a rerun is safe; it updates what is there):
  1. checks the machine and the paths you gave
  2. installs Bun if it is missing
  3. clones or updates the Archon fork (Vikteur/Archon, branch local/console), builds and installs it
  4. pulls the contract's repository when it is a clean git checkout
  5. runs `archon kit setup`: tools (jq, yq, gh, node, codegraph, copilot, rtk, the MCP Inspector),
     the kit, the contract MCP server, both CodeGraph indexes, the rtk hooks, the web views
  6. logs gh in when it is not (in a terminal only)
  7. runs `archon kit doctor` on the backend
  8. commits the kit on a new branch in each repo whose tree was clean before (it never pushes)
  9. runs a dry run of build-feature-copilot
It assumes Copilot CLI is up to date and logged in. It never writes a token anywhere.
Log: ~/.archon/logs/install-copilot-kit-<timestamp>.log
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --backend)    BACKEND="${2:?--backend needs a path}"; shift 2 ;;
    --frontend)   FRONTEND="${2:?--frontend needs a path}"; shift 2 ;;
    --contract)   CONTRACT="${2:?--contract needs a file}"; shift 2 ;;
    --backlog)    BACKLOG=1; shift ;;
    --archon-dir) ARCHON_DIR="${2:?--archon-dir needs a path}"; shift 2 ;;
    --branch)     BRANCH="${2:?--branch needs a name}"; shift 2 ;;
    --no-commit)  COMMIT=0; shift ;;
    --no-web)     WEB=0; shift ;;
    --no-smoke)   SMOKE=0; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

BLUE='\033[0;34m' YELLOW='\033[0;33m' RED='\033[0;31m' GREEN='\033[0;32m' NC='\033[0m'
step()  { echo -e "\n${BLUE}==> $*${NC}"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; WARNINGS+=("$*"); }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
WARNINGS=()

abspath() {  # expand ~ and make a path absolute, without needing it to exist
  local p="${1/#\~/$HOME}"
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  local d; d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || { echo "$p"; return; }
  echo "${d%/}/$(basename "$p")"
}
is_git_repo() { git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1; }
tree_clean()  { [ -z "$(git -C "$1" status --porcelain 2>/dev/null)" ]; }
TTY=0; [ -t 0 ] && [ -t 1 ] && TTY=1  # read before the log pipe below takes stdout
interactive() { [ "$TTY" = 1 ]; }

[ -n "$BACKEND" ]  || { usage >&2; die "--backend is required"; }
[ -n "$CONTRACT" ] || { usage >&2; die "--contract is required"; }
BACKEND="$(abspath "$BACKEND")"
CONTRACT="$(abspath "$CONTRACT")"
[ -z "$FRONTEND" ] || FRONTEND="$(abspath "$FRONTEND")"
ARCHON_DIR="$(abspath "$ARCHON_DIR")"

if [ "$DRY_RUN" = 0 ]; then
  mkdir -p "$HOME/.archon/logs"
  LOG="$HOME/.archon/logs/install-copilot-kit-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG") 2>&1
  echo "log: $LOG"
fi

# ---------------------------------------------------------------- 1. checks
step "1/9 Checking the machine and the paths"
case "$(uname -s)" in
  Linux)  grep -qi microsoft /proc/version 2>/dev/null && ok "WSL" || ok "Linux" ;;
  Darwin) ok "macOS" ;;
  *) die "unsupported OS $(uname -s); on Windows run this inside WSL2 (Ubuntu)" ;;
esac
for cmd in git curl; do command -v "$cmd" >/dev/null || die "$cmd is missing; install it first"; done

is_git_repo "$BACKEND" || die "backend $BACKEND is not a git repository"
ok "backend  $BACKEND"
if [ -n "$FRONTEND" ]; then
  is_git_repo "$FRONTEND" || die "frontend $FRONTEND is not a git repository"
  [ "$FRONTEND" != "$BACKEND" ] || die "frontend and backend are the same folder"
  ok "frontend $FRONTEND"
fi
[ -f "$CONTRACT" ] || die "contract $CONTRACT does not exist"
case "$CONTRACT" in *.yaml|*.yml|*.json) ;; *) die "contract must be a .yaml, .yml or .json file" ;; esac
grep -Eq '^[[:space:]{]*"?openapi"?[[:space:]]*:' "$CONTRACT" || die "contract $CONTRACT has no top-level openapi key"
ok "contract $CONTRACT"

if [ "$DRY_RUN" = 1 ]; then
  onoff() { if [ "$1" = 1 ]; then echo "$2"; else echo "$3"; fi; }
  echo
  echo "Dry run: nothing changed. The plan:"
  echo "  archon     clone or update $FORK_URL ($FORK_BRANCH) in $ARCHON_DIR, build and install it"
  echo "  contract   $CONTRACT"
  echo "  backend    $BACKEND (kit, contract MCP, codegraph, rtk)"
  echo "  frontend   ${FRONTEND:-(none)}"
  echo "  backlog    $(onoff "$BACKLOG" on off)"
  echo "  web views  $(onoff "$WEB" on off)"
  echo "  commit     $(onoff "$COMMIT" "on, branch $BRANCH, only in repos clean before the run" off)"
  echo "  smoke run  $(onoff "$SMOKE" "build-feature-copilot --dry-run" skipped)"
  exit 0
fi

# The paths are right; now the parts that need sudo.
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null; then
  echo "The tool installer needs sudo for a few packages; asking once now."
  sudo -v || die "sudo is needed for the tool installer"
fi
if [ "$(uname -s)" = Linux ] && ! command -v unzip >/dev/null; then
  command -v apt-get >/dev/null || die "unzip is missing (Bun needs it); install it first"
  sudo apt-get update -qq && sudo apt-get install -y -qq unzip
fi

# Which repos may be committed afterwards: only those clean before we start.
BACKEND_CLEAN=0 FRONTEND_CLEAN=0
tree_clean "$BACKEND" && BACKEND_CLEAN=1
[ -z "$FRONTEND" ] || { tree_clean "$FRONTEND" && FRONTEND_CLEAN=1; } || true
command -v copilot >/dev/null && ok "copilot $(copilot --version 2>/dev/null | head -1)" \
  || warn "copilot is not on PATH yet; kit setup installs it, then log in with: copilot, /login"

# ---------------------------------------------------------------- 2. bun
step "2/9 Bun"
export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export PATH="$BUN_INSTALL/bin:$HOME/.local/bin:$PATH"
if command -v bun >/dev/null; then
  ok "bun $(bun --version)"
else
  curl -fsSL https://bun.sh/install | bash
  command -v bun >/dev/null || die "Bun did not install"
  ok "bun $(bun --version) installed"
fi

# ---------------------------------------------------------------- 3. archon
step "3/9 Archon (fork $FORK_BRANCH) in $ARCHON_DIR"
if [ -d "$ARCHON_DIR/.git" ]; then
  url="$(git -C "$ARCHON_DIR" remote get-url origin 2>/dev/null || true)"
  case "$url" in *Vikteur/Archon*) ;; *) die "$ARCHON_DIR is a clone of '$url', not the fork; pass --archon-dir <other folder>" ;; esac
  tree_clean "$ARCHON_DIR" || die "$ARCHON_DIR has local changes; commit or move them first"
  git -C "$ARCHON_DIR" fetch -q origin "$FORK_BRANCH"
  git -C "$ARCHON_DIR" checkout -q "$FORK_BRANCH" 2>/dev/null \
    || git -C "$ARCHON_DIR" checkout -q -b "$FORK_BRANCH" "origin/$FORK_BRANCH"
  git -C "$ARCHON_DIR" merge -q --ff-only "origin/$FORK_BRANCH"
  ok "updated to $(git -C "$ARCHON_DIR" log --oneline -1)"
elif [ -e "$ARCHON_DIR" ]; then
  die "$ARCHON_DIR exists and is not a git clone; pass --archon-dir <other folder>"
else
  git clone -q -b "$FORK_BRANCH" "$FORK_URL" "$ARCHON_DIR"
  ok "cloned $(git -C "$ARCHON_DIR" log --oneline -1)"
fi
(cd "$ARCHON_DIR" && bun install)
# --skip-tools: kit setup (step 5) installs the tools itself; --no-setup: this script runs setup.
(cd "$ARCHON_DIR" && bash scripts/install-local.sh --no-setup --skip-tools)
command -v archon >/dev/null || die "archon is not on PATH after the install (expected in ~/.local/bin)"
ok "$(archon --version 2>/dev/null | head -1)"

for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -f "$rc" ] || continue
  grep -q 'install-copilot-kit: PATH' "$rc" && continue
  printf '\n# install-copilot-kit: PATH\nexport PATH="$HOME/.bun/bin:$HOME/.local/bin:$PATH"\n' >> "$rc"
  ok "added ~/.bun/bin and ~/.local/bin to PATH in $rc"
done
if [ -f "$ARCHON_DIR/scripts/update-copilot-kit.sh" ]; then
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$ARCHON_DIR/scripts/update-copilot-kit.sh" "$HOME/.local/bin/archon-kit-update"
  ok "archon-kit-update updates this machine later (Archon, the kit, the tools)"
fi

# ---------------------------------------------------------------- 4. contract
step "4/9 Contract repository"
CONTRACT_REPO="$(git -C "$(dirname "$CONTRACT")" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$CONTRACT_REPO" ]; then
  ok "the contract is not in a git checkout; used as it is"
elif ! tree_clean "$CONTRACT_REPO"; then
  warn "$CONTRACT_REPO has local changes; not pulled"
elif git -C "$CONTRACT_REPO" pull -q --ff-only 2>/dev/null; then
  ok "pulled $CONTRACT_REPO ($(git -C "$CONTRACT_REPO" log --oneline -1))"
else
  warn "could not pull $CONTRACT_REPO (no upstream, or it has diverged); used as it is"
fi

# ---------------------------------------------------------------- 5. kit setup
step "5/9 archon kit setup"
setup_args=(--backend "$BACKEND" --contract "$CONTRACT" --yes)
[ -z "$FRONTEND" ] || setup_args+=(--frontend "$FRONTEND")
[ "$BACKLOG" = 1 ] && setup_args+=(--backlog)
[ "$WEB" = 1 ] || setup_args+=(--no-web)
SETUP_OK=1
archon kit setup "${setup_args[@]}" || { SETUP_OK=0; warn "kit setup reported a failed step; its log is in ~/.archon/logs/kit-setup-*.log"; }
hash -r

# ---------------------------------------------------------------- 6. gh login
step "6/9 GitHub CLI login"
if ! command -v gh >/dev/null; then
  warn "gh is not installed; kit setup's tool step should have done that"
elif gh auth status >/dev/null 2>&1; then
  ok "gh is logged in"
elif interactive; then
  gh auth login || warn "gh auth login did not finish; run it yourself later"
else
  warn "gh is not logged in; run: gh auth login"
fi

# ---------------------------------------------------------------- 7. doctor
step "7/9 archon kit doctor"
DOCTOR_OK=1
(cd "$BACKEND" && archon kit doctor .) || { DOCTOR_OK=0; warn "kit doctor is not all green; see above"; }

# ---------------------------------------------------------------- 8. commit
step "8/9 Commit the kit (local only, never pushed)"
commit_repo() {  # <repo> <was clean> <message>
  local repo="$1" clean="$2" msg="$3"
  if [ "$COMMIT" = 0 ]; then warn "$repo: --no-commit, left uncommitted"; return; fi
  if [ "$clean" != 1 ]; then warn "$repo had changes before the install; left uncommitted so yours stay apart"; return; fi
  if [ "$SETUP_OK" != 1 ]; then warn "$repo: kit setup failed a step; left uncommitted"; return; fi
  if tree_clean "$repo"; then ok "$repo: nothing changed"; return; fi
  if [ -z "$(git -C "$repo" config user.email || true)" ]; then
    warn "$repo: no git user.email set; left uncommitted"; return
  fi
  if git -C "$repo" show-ref -q --verify "refs/heads/$BRANCH"; then
    git -C "$repo" switch -q "$BRANCH"
  else
    git -C "$repo" switch -q -c "$BRANCH"
  fi
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$msg"
  ok "$repo: committed on $BRANCH ($(git -C "$repo" log --oneline -1))"
}
commit_repo "$BACKEND" "$BACKEND_CLEAN" "chore: add the Archon Copilot kit"
[ -z "$FRONTEND" ] || commit_repo "$FRONTEND" "$FRONTEND_CLEAN" "chore: add codegraph MCP and rtk for Copilot"

# ---------------------------------------------------------------- 9. smoke
step "9/9 Dry run of build-feature-copilot"
if [ "$SMOKE" = 0 ]; then
  ok "skipped (--no-smoke)"
elif (cd "$BACKEND" && archon workflow run build-feature-copilot --dry-run --default-stubs); then
  ok "the dry run completed"
else
  warn "the dry run failed; see above"
fi

# ---------------------------------------------------------------- summary
echo
if [ ${#WARNINGS[@]} -eq 0 ]; then
  echo -e "${GREEN}All done.${NC}"
else
  echo -e "${YELLOW}Done, with ${#WARNINGS[@]} warning(s):${NC}"
  for w in "${WARNINGS[@]}"; do echo "  - $w"; done
fi
cat <<EOF

Next:
  - Push the branch '$BRANCH' in each committed repo and open a PR, as you usually do.
  - Work in Copilot:  cd $BACKEND && copilot     then /agent to pick an agent, /mcp for the servers
  - Build something:  cd $BACKEND && archon workflow run build-feature-copilot "what to build"
  - Stop the MCP Inspectors: cd $BACKEND && bash scripts/web-uis.sh stop
  - Update this machine later (Archon, the kit, the tools): archon-kit-update
  - If /mcp says the servers are "blocked by policy", that is your organization's registry;
    the agents fall back to the codegraph and contract CLIs by themselves.
Log: $LOG
EOF
[ "$SETUP_OK" = 1 ] && [ "$DOCTOR_OK" = 1 ]
