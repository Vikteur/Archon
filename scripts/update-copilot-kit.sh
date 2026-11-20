#!/usr/bin/env bash
# update-copilot-kit.sh: bring a machine that ran install-copilot-kit.sh up to date, in one go.
# Run it with --help for the steps and the options.

set -euo pipefail

FORK_BRANCH="local/console"
SELF_NAME="update-copilot-kit.sh"
LINK_NAME="archon-kit-update"

usage() {
  cat <<'USAGE'
Usage:
  archon-kit-update [options]
  bash ~/archon/scripts/update-copilot-kit.sh [options]
  bash <(curl -fsSL https://raw.githubusercontent.com/Vikteur/Archon/local/console/scripts/update-copilot-kit.sh) [options]

It reads the repositories, the contract, the profiles and the Backlog.md answer from the last
`archon kit setup` (~/.archon/kit-setup.json), so on a machine that was installed it needs no options.

Options:
  --backend <path>      backend repository (default: the last setup's)
  --frontend <path>     frontend repository (default: the last setup's; "" for none)
  --contract <file>     the OpenAPI contract file (default: the last setup's)
  --archon-dir <path>   the Archon clone (default: the clone this script is in, else ~/archon)
  --branch <name>       branch for the update commit (default: chore/archon-kit-<archon commit>)
  --add-profile <a,b>   also install these kit profiles, beside the saved ones (kept for the next update),
                        e.g. --add-profile mijn-gezondheid for that repo's own scaffold templates
  --no-pull             do not pull the backend, frontend and contract repositories first
  --no-tools            do not update the tools (jq, yq, gh, node, codegraph, copilot, rtk, ...)
  --no-commit           leave the updated kit files uncommitted
  --no-restart          leave a running `archon serve` on the old build
  --no-web              do not start and open the web views at the end
  --rebuild             rebuild and reinstall Archon even when the clone is already up to date
  --force               update even while a build run is running on this machine
  --dry-run             fetch and print what would be updated, change nothing
  -h, --help            this text

What it does, in order (a rerun is safe):
  1. checks the machine, the saved answers and that no build run is running
  2. updates the Archon clone (fast-forward only), builds and installs it, when there is something new
  3. pulls the contract, backend and frontend repositories when their tree is clean (fast-forward only)
  4. runs `archon kit setup` again with the saved answers: the kit files, the tools, the contract MCP
     server, both CodeGraph indexes, the Groma map (groma init and a first scan, when the backend has
     no groma/ yet), the rtk hooks. A kit file you edited is kept; one the kit no longer ships is
     removed when you never edited it
  5. runs `archon kit doctor` on the backend
  6. commits the update on a new branch in each repo whose tree was clean before (it never pushes)
  7. restarts `archon serve` when it was running, so it runs the new build
  8. starts the web views and opens each in the browser once it answers (`archon kit web`): the MCP
     Inspectors (codegraph of each repo, the contract server on your contract), the Groma map, the
     Backlog.md board when it is on, and the Archon web UI (`archon serve`, started when it is not running)
It never writes a token anywhere. Log: ~/.archon/logs/update-copilot-kit-<timestamp>.log
USAGE
}

# Everything runs from main(): bash has read the whole function before it starts, so the
# fast-forward of the clone this script lives in cannot change the code under it.
main() {
  local orig_args=()
  [ $# -eq 0 ] || orig_args=("$@")
  local BACKEND="" FRONTEND="" CONTRACT="" ARCHON_DIR="" BRANCH=""
  local HAVE_BACKEND=0 HAVE_FRONTEND=0 HAVE_CONTRACT=0
  local PULL=1 TOOLS=1 COMMIT=1 RESTART=1 WEB=1 REBUILD=0 FORCE=0 DRY_RUN=0
  local ARCHON_DONE=0 LOG="" ADD_PROFILES=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --backend)    BACKEND="${2:?--backend needs a path}"; HAVE_BACKEND=1; shift 2 ;;
      --frontend)   [ $# -ge 2 ] || { echo "--frontend needs a path" >&2; exit 2; }
                    FRONTEND="$2"; HAVE_FRONTEND=1; shift 2 ;;
      --contract)   CONTRACT="${2:?--contract needs a file}"; HAVE_CONTRACT=1; shift 2 ;;
      --archon-dir) ARCHON_DIR="${2:?--archon-dir needs a path}"; shift 2 ;;
      --branch)     BRANCH="${2:?--branch needs a name}"; shift 2 ;;
      --add-profile) ADD_PROFILES="${ADD_PROFILES:+$ADD_PROFILES,}${2:?--add-profile needs a profile name}"; shift 2 ;;
      --no-pull)    PULL=0; shift ;;
      --no-tools)   TOOLS=0; shift ;;
      --no-commit)  COMMIT=0; shift ;;
      --no-restart) RESTART=0; shift ;;
      --web)        WEB=1; shift ;;   # the default since the web views open at the end; kept for old scripts
      --no-web)     WEB=0; shift ;;
      --rebuild)    REBUILD=1; shift ;;
      --force)      FORCE=1; shift ;;
      --dry-run)    DRY_RUN=1; shift ;;
      --archon-done) ARCHON_DONE=1; shift ;;            # internal: the re-run after step 2
      --log)        LOG="${2:?--log needs a file}"; shift 2 ;;  # internal: keep writing to this log
      -h|--help)    usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
  done

  BLUE='\033[0;34m' YELLOW='\033[0;33m' RED='\033[0;31m' GREEN='\033[0;32m' NC='\033[0m'
  WARNINGS=()

  export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
  export PATH="$BUN_INSTALL/bin:$HOME/.local/bin:$PATH"

  # ---------------------------------------------------------------- the saved answers
  local saved="$HOME/.archon/kit-setup.json" PROFILES="" BACKLOG=0
  if [ -f "$saved" ]; then
    command -v bun >/dev/null || die "bun is not on PATH; run install-copilot-kit.sh first"
    local answers
    answers="$(bun -e '
      const a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf-8"));
      const s = v => (typeof v === "string" ? v : "");
      console.log([s(a.backend), s(a.frontend), s(a.contract),
        Array.isArray(a.profiles) ? a.profiles.join(",") : "", a.backlog === true ? "1" : "0"].join("\x1f"));
    ' "$saved")" || die "$saved does not parse"
    local s_backend s_frontend s_contract
    IFS=$'\x1f' read -r s_backend s_frontend s_contract PROFILES BACKLOG <<<"$answers"
    [ "$HAVE_BACKEND" = 1 ] || BACKEND="$s_backend"
    [ "$HAVE_FRONTEND" = 1 ] || FRONTEND="$s_frontend"
    [ "$HAVE_CONTRACT" = 1 ] || CONTRACT="$s_contract"
  fi
  [ -n "$BACKEND" ] || die "no saved setup in $saved: pass --backend and --contract, or run install-copilot-kit.sh first"
  [ -n "$CONTRACT" ] || die "no contract in $saved: pass --contract"
  if [ -n "$ADD_PROFILES" ]; then
    [ -n "$PROFILES" ] || die "no saved profiles in $saved to add $ADD_PROFILES to: run archon kit setup --profile <a,b,c> once"
    local p
    for p in ${ADD_PROFILES//,/ }; do
      case ",$PROFILES," in *",$p,"*) ;; *) PROFILES="$PROFILES,$p" ;; esac
    done
  fi
  BACKEND="$(abspath "$BACKEND")"
  CONTRACT="$(abspath "$CONTRACT")"
  [ -z "$FRONTEND" ] || FRONTEND="$(abspath "$FRONTEND")"
  [ -n "$ARCHON_DIR" ] || ARCHON_DIR="$(own_clone || echo "$HOME/archon")"
  ARCHON_DIR="$(abspath "$ARCHON_DIR")"

  if [ "$DRY_RUN" = 0 ] && [ -z "$LOG" ]; then
    mkdir -p "$HOME/.archon/logs"
    LOG="$HOME/.archon/logs/update-copilot-kit-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$LOG") 2>&1
    echo "log: $LOG"
  fi  # with --log (the re-run), stdout still goes through the first run's tee

  # ---------------------------------------------------------------- 1. checks
  if [ "$ARCHON_DONE" = 0 ]; then
    step "1/8 Checking the machine and the saved answers"
    for cmd in git curl; do command -v "$cmd" >/dev/null || die "$cmd is missing"; done
    command -v archon >/dev/null || die "archon is not on PATH; run install-copilot-kit.sh first"
  fi
  is_git_repo "$BACKEND" || die "backend $BACKEND is not a git repository (pass --backend)"
  if [ -n "$FRONTEND" ]; then
    is_git_repo "$FRONTEND" || die "frontend $FRONTEND is not a git repository (pass --frontend, or --frontend '' for none)"
  fi
  [ -f "$CONTRACT" ] || die "contract $CONTRACT does not exist (pass --contract)"
  [ -d "$ARCHON_DIR/.git" ] || die "$ARCHON_DIR is not the Archon clone (pass --archon-dir)"
  local url
  url="$(git -C "$ARCHON_DIR" remote get-url origin 2>/dev/null || true)"
  case "$url" in *Vikteur/Archon*) ;; *) die "$ARCHON_DIR is a clone of '$url', not the fork" ;; esac
  if [ "$ARCHON_DONE" = 0 ]; then
    ok "backend  $BACKEND"
    ok "frontend ${FRONTEND:-(none)}"
    ok "contract $CONTRACT"
    ok "archon   $ARCHON_DIR"
    local running
    running="$(running_build_runs)"
    if [ "$running" != 0 ]; then
      if [ "$FORCE" = 1 ]; then warn "$running build run(s) running; updating anyway (--force)"
      else die "$running build run(s) running on this machine; wait for them (archon workflow status --all), or pass --force"
      fi
    else
      ok "no build run is running"
    fi
  fi

  # ---------------------------------------------------------------- 2. archon
  local before after
  before="$(git -C "$ARCHON_DIR" rev-parse HEAD)"
  if [ "$ARCHON_DONE" = 0 ]; then
    step "2/8 Archon (fork $FORK_BRANCH) in $ARCHON_DIR"
    git -C "$ARCHON_DIR" fetch -q origin "$FORK_BRANCH"
    local pending
    pending="$(git -C "$ARCHON_DIR" log --oneline "HEAD..origin/$FORK_BRANCH" | wc -l | tr -d ' ')"
    if [ "$DRY_RUN" = 1 ]; then
      print_plan "$pending"
      exit 0
    fi
    tree_clean "$ARCHON_DIR" || die "$ARCHON_DIR has local changes; commit or move them first"
    git -C "$ARCHON_DIR" checkout -q "$FORK_BRANCH" 2>/dev/null \
      || git -C "$ARCHON_DIR" checkout -q -b "$FORK_BRANCH" "origin/$FORK_BRANCH"
    git -C "$ARCHON_DIR" merge -q --ff-only "origin/$FORK_BRANCH" \
      || die "$ARCHON_DIR has commits that are not on origin/$FORK_BRANCH; it cannot fast-forward"
    after="$(git -C "$ARCHON_DIR" rev-parse HEAD)"
    if [ "$before" = "$after" ] && [ "$REBUILD" = 0 ]; then
      ok "already at $(git -C "$ARCHON_DIR" log --oneline -1); no rebuild (--rebuild forces one)"
    else
      [ "$before" = "$after" ] || ok "updated $(short "$before") -> $(git -C "$ARCHON_DIR" log --oneline -1) ($pending commit(s))"
      (cd "$ARCHON_DIR" && bun install)
      (cd "$ARCHON_DIR" && bash scripts/install-local.sh --no-setup --skip-tools)
      hash -r
      ok "$(archon --version 2>/dev/null | head -1)"
    fi
    link_command
    # The rest runs from the clone's newest copy of this script: an update may have changed it.
    local fresh="$ARCHON_DIR/scripts/$SELF_NAME"
    if [ -f "$fresh" ] && { [ "$(self_path)" != "$(real "$fresh")" ] || [ "$before" != "$after" ]; }; then
      local next=(--archon-done --log "$LOG" --archon-dir "$ARCHON_DIR")
      exec env UPDATE_KIT_BEFORE="$before" bash "$fresh" ${orig_args[@]+"${orig_args[@]}"} "${next[@]}"
    fi
  fi
  before="${UPDATE_KIT_BEFORE:-$before}"
  after="$(git -C "$ARCHON_DIR" rev-parse HEAD)"
  [ -n "$BRANCH" ] || BRANCH="chore/archon-kit-$(short "$after")"

  # ---------------------------------------------------------------- 3. pull
  step "3/8 Pull the repositories"
  local BACKEND_CLEAN=0 FRONTEND_CLEAN=0
  tree_clean "$BACKEND" && BACKEND_CLEAN=1
  [ -z "$FRONTEND" ] || { tree_clean "$FRONTEND" && FRONTEND_CLEAN=1; } || true
  local contract_repo
  contract_repo="$(git -C "$(dirname "$CONTRACT")" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ "$PULL" = 0 ]; then
    ok "skipped (--no-pull)"
  else
    pull_repo "$BACKEND"
    [ -z "$FRONTEND" ] || pull_repo "$FRONTEND"
    if [ -n "$contract_repo" ] && [ "$contract_repo" != "$BACKEND" ] && [ "$contract_repo" != "$FRONTEND" ]; then
      pull_repo "$contract_repo"
    fi
  fi

  # ---------------------------------------------------------------- 4. kit setup
  step "4/8 archon kit setup (the saved answers)"
  local setup_args=(--backend "$BACKEND" --contract "$CONTRACT" --yes)
  [ -z "$FRONTEND" ] || setup_args+=(--frontend "$FRONTEND")
  [ -z "$PROFILES" ] || setup_args+=(--profile "$PROFILES")
  [ "$BACKLOG" = 1 ] && setup_args+=(--backlog)
  [ "$TOOLS" = 1 ] || setup_args+=(--no-tools)
  setup_args+=(--no-web)   # step 8 opens them, after the server restart
  local SETUP_OK=1 setup_out
  setup_out="$(mktemp)"
  archon kit setup "${setup_args[@]}" | tee "$setup_out" || { SETUP_OK=0; warn "kit setup reported a failed step; its log is in ~/.archon/logs/kit-setup-*.log"; }
  hash -r
  kit_file_report "$(sed -n 's/^Log: //p' "$setup_out" | head -1)"
  rm -f "$setup_out"

  # ---------------------------------------------------------------- 5. doctor
  step "5/8 archon kit doctor"
  local DOCTOR_OK=1
  (cd "$BACKEND" && archon kit doctor .) || { DOCTOR_OK=0; warn "kit doctor is not all green; see above"; }

  # ---------------------------------------------------------------- 6. commit
  step "6/8 Commit the update (local only, never pushed)"
  local kit_commit
  kit_commit="$(kit_source "$BACKEND")"
  commit_repo "$BACKEND" "$BACKEND_CLEAN" "chore: update the Archon Copilot kit${kit_commit:+ to $kit_commit}" "$SETUP_OK"
  [ -z "$FRONTEND" ] || commit_repo "$FRONTEND" "$FRONTEND_CLEAN" "chore: update codegraph MCP and rtk for Copilot" "$SETUP_OK"

  # ---------------------------------------------------------------- 7. server
  step "7/8 archon serve"
  restart_server

  # ---------------------------------------------------------------- 8. web views
  step "8/8 Web views"
  if [ "$WEB" = 1 ]; then
    archon kit web "$BACKEND" || warn "not every web view answered; see the lines above (archon kit web $BACKEND retries)"
  else
    ok "skipped (--no-web); open them later with: archon kit web $BACKEND"
  fi

  # ---------------------------------------------------------------- summary
  echo
  if [ ${#WARNINGS[@]} -eq 0 ]; then
    echo -e "${GREEN}Up to date.${NC}"
  else
    echo -e "${YELLOW}Done, with ${#WARNINGS[@]} warning(s):${NC}"
    for w in "${WARNINGS[@]}"; do echo "  - $w"; done
  fi
  cat <<EOF

  archon   $(short "$before") -> $(short "$after")
  kit      ${kit_commit:-(unknown)}
Next:
  - Push the branch '$BRANCH' in each committed repo and open a PR, as you usually do.
  - Files listed "kept (differs)" or "kept (no longer in the kit)" in step 4 are ones you edited:
    compare them with the kit and keep or remove them; archon kit add $BACKEND --force takes the kit's version.
  - Next time, just run: $LINK_NAME
Log: $LOG
EOF
  [ "$SETUP_OK" = 1 ] && [ "$DOCTOR_OK" = 1 ]
}

step() { echo -e "\n${BLUE}==> $*${NC}"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; WARNINGS+=("$*"); }
die()  { echo -e "${RED:-}[ERROR]${NC:-} $*" >&2; exit 1; }

abspath() {  # expand ~ and make a path absolute, without needing it to exist
  local p="${1/#\~/$HOME}"
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  local d; d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || { echo "$p"; return; }
  echo "${d%/}/$(basename "$p")"
}
real() { readlink -f "$1" 2>/dev/null || echo "$1"; }
self_path() { real "${BASH_SOURCE[0]}"; }
short() { git -C "$ARCHON_DIR" rev-parse --short "$1" 2>/dev/null || echo "${1:0:9}"; }
is_git_repo() { git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1; }
tree_clean()  { [ -z "$(git -C "$1" status --porcelain 2>/dev/null)" ]; }

own_clone() {  # the clone this script sits in, when it runs from <clone>/scripts/
  local self dir
  self="$(self_path)"
  [ -f "$self" ] || return 1
  dir="$(dirname "$(dirname "$self")")"
  [ -d "$dir/.git" ] && [ "$(basename "$(dirname "$self")")" = scripts ] || return 1
  echo "$dir"
}

running_build_runs() {  # how many runs are running (a paused one, waiting for its plan approval, is fine)
  archon workflow status --all --json 2>/dev/null | bun -e '
    let t = ""; process.stdin.on("data", d => (t += d)).on("end", () => {
      try { console.log((JSON.parse(t).runs ?? []).filter(r => r.status === "running").length); }
      catch { console.log(0); }
    });' 2>/dev/null || echo 0
}

print_plan() {
  local pending="$1"
  onoff() { if [ "$1" = 1 ]; then echo "$2"; else echo "$3"; fi; }
  echo
  echo "Dry run: nothing changed. The plan:"
  if [ "$pending" = 0 ]; then
    echo "  archon     up to date at $(git -C "$ARCHON_DIR" log --oneline -1)$( [ "$REBUILD" = 1 ] && echo ', rebuilt (--rebuild)')"
  else
    echo "  archon     $pending new commit(s) on $FORK_BRANCH, then build and install:"
    git -C "$ARCHON_DIR" log --oneline "HEAD..origin/$FORK_BRANCH" | head -10 | sed 's/^/               /'
  fi
  echo "  pull       $(onoff "$PULL" "backend, frontend and contract repos when clean" off)"
  echo "  kit setup  backend $BACKEND, frontend ${FRONTEND:-(none)}, profiles ${PROFILES:-(from kit.yaml)}, backlog $(onoff "$BACKLOG" on off), tools $(onoff "$TOOLS" on off)"
  echo "  commit     $(onoff "$COMMIT" "on, branch ${BRANCH:-chore/archon-kit-<archon commit>}, only in repos clean before the run" off)"
  echo "  server     $(onoff "$RESTART" "restart archon serve when it runs" "left as it is")"
  echo "  web views  $(onoff "$WEB" "start and open them once they answer (archon kit web)" off)"
}

pull_repo() {
  local repo="$1"
  if ! tree_clean "$repo"; then warn "$repo has local changes; not pulled"; return; fi
  if ! git -C "$repo" rev-parse -q --verify '@{upstream}' >/dev/null 2>&1; then
    ok "$repo: no upstream branch; not pulled"; return
  fi
  if git -C "$repo" pull -q --ff-only 2>/dev/null; then
    ok "pulled $repo ($(git -C "$repo" log --oneline -1))"
  else
    warn "could not pull $repo (it has diverged from its upstream); updated as it is"
  fi
}

kit_source() {  # the kit's source commit, from the lock kit add wrote
  [ -f "$1/.archon/kit.lock.json" ] || return 0
  bun -e '
    const l = JSON.parse(require("fs").readFileSync(process.argv[1], "utf-8"));
    if (l.kit?.name && l.kit?.commit) console.log(`${l.kit.name}@${String(l.kit.commit).slice(0, 7)}`);
  ' "$1/.archon/kit.lock.json" 2>/dev/null || true
}

kit_file_report() {  # kit add's lines from kit setup's log: what it removed, and what it kept because you edited it
  local log="$1" lines
  [ -n "$log" ] && [ -f "$log" ] || return 0
  lines="$(grep -E '^  (removed|kept \(differs\)|kept \(no longer in the kit\)|skipped \()' "$log" || true)"
  [ -n "$lines" ] || { ok "kit files: every one updated or unchanged"; return 0; }
  echo "Kit files kit add did not simply update:"
  echo "$lines"
  grep -E '^Files: ' "$log" | head -1 || true
  if grep -q '^  kept (no longer in the kit)' <<<"$lines"; then
    warn "a kit file the kit no longer ships was kept because you edited it; remove it once you no longer need it"
  fi
}

commit_repo() {  # <repo> <was clean> <message> <setup ok>
  local repo="$1" clean="$2" msg="$3" setup_ok="$4"
  if [ "$COMMIT" = 0 ]; then warn "$repo: --no-commit, left uncommitted"; return; fi
  if tree_clean "$repo"; then ok "$repo: nothing changed"; return; fi
  if [ "$clean" != 1 ]; then warn "$repo had changes before the update; left uncommitted so yours stay apart"; return; fi
  if [ "$setup_ok" != 1 ]; then warn "$repo: kit setup failed a step; left uncommitted"; return; fi
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
  ok "$repo: committed on $BRANCH ($(git -C "$repo" log --oneline -1)): $(git -C "$repo" show --shortstat --format= HEAD | sed 's/^ *//')"
}

link_command() {  # archon-kit-update on the PATH, pointing at the clone's copy of this script
  local target="$ARCHON_DIR/scripts/$SELF_NAME" link="$HOME/.local/bin/$LINK_NAME"
  [ -f "$target" ] || return 0
  mkdir -p "$HOME/.local/bin"
  if [ "$(real "$link")" != "$(real "$target")" ]; then
    ln -sfn "$target" "$link"
    ok "$LINK_NAME -> $target"
  fi
}

restart_server() {
  local line pid args=()
  line="$(pgrep -af '(^|/)archon serve( |$)' 2>/dev/null | grep -v "$SELF_NAME" | head -1 || true)"
  if [ -z "$line" ]; then ok "not running"; return; fi
  if [ "$RESTART" = 0 ]; then warn "archon serve still runs the old build (--no-restart); restart it yourself"; return; fi
  pid="${line%% *}"
  read -r -a args <<<"${line#*archon serve}"
  kill -TERM "$pid" 2>/dev/null || { warn "could not stop archon serve ($pid); restart it yourself"; return; }

  for _ in $(seq 1 30); do
    pgrep -f 'archon-server|(^|/)archon serve( |$)' >/dev/null 2>&1 || break
    sleep 0.5
  done
  if pgrep -f 'archon-server|(^|/)archon serve( |$)' >/dev/null 2>&1; then
    warn "archon serve did not stop within 15 s; restart it yourself"; return
  fi
  local serve_log
  serve_log="$HOME/.archon/logs/serve-$(date +%Y%m%d-%H%M%S).log"
  if command -v setsid >/dev/null; then
    (cd "$HOME" && setsid nohup archon serve ${args[@]+"${args[@]}"} >"$serve_log" 2>&1 </dev/null &)
  else
    (cd "$HOME" && nohup archon serve ${args[@]+"${args[@]}"} >"$serve_log" 2>&1 </dev/null &)
  fi
  sleep 2
  if pgrep -f '(^|/)archon serve( |$)' >/dev/null 2>&1; then
    ok "restarted on the new build (log $serve_log)"
  else
    warn "archon serve did not come back; see $serve_log"
  fi
}

main "$@"
