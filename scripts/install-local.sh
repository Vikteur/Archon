#!/usr/bin/env bash
# scripts/install-local.sh
# Build Archon from this checkout and install it as a set: CLI, server binary,
# claude provider plugin and web UI. The CLI embeds the server's SHA-256, so the
# three binaries must come from the same build.
#
# Usage:
#   bash scripts/install-local.sh [options]
#
# Options:
#   --prefix DIR        CLI goes to DIR/archon            (default: ~/.local/bin)
#   --archon-home DIR   Archon home (ARCHON_HOME)         (default: $ARCHON_HOME or ~/.archon)
#   --target T          bun-linux-x64 | bun-linux-arm64 | bun-darwin-x64 | bun-darwin-arm64
#                       (default: this machine)
#   --skip-web          do not build or install the web UI
#   --skip-tools        do not run the kit tools step afterwards
#   --dry-run           print the plan, change nothing
#   -h, --help          this text
#
# Layout written (matches packages/paths/src/home-paths.ts and
# packages/plugin-manifest/src/store.ts):
#   <prefix>/archon
#   <archon-home>/server/<version>/archon-server-<os>-<arch>
#   <archon-home>/plugins/archon-provider-claude        (+ installed/.../receipt.json)
#   <archon-home>/web-dist/<version>/
# An existing target is moved to <name>.prev-<timestamp> first; a failed run puts
# this run's backups back, and a finished one keeps the newest 3 per name.

set -euo pipefail

BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

PREFIX="${HOME}/.local/bin"
ARCHON_HOME_DIR="${ARCHON_HOME:-${HOME}/.archon}"
TARGET=""
SKIP_WEB=false
SKIP_TOOLS=false
DRY_RUN=false

SUPPORTED_TARGETS="bun-linux-x64 bun-linux-arm64 bun-darwin-x64 bun-darwin-arm64"

host_target() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$os" in
    linux | darwin) ;;
    *) error "Unsupported OS: $os (use WSL2 on Windows)"; return 1 ;;
  esac
  case "$arch" in
    x86_64 | amd64) arch=x64 ;;
    arm64 | aarch64) arch=arm64 ;;
    *) error "Unsupported architecture: $arch"; return 1 ;;
  esac
  echo "bun-${os}-${arch}"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prefix | --archon-home | --target)
        [ "$#" -ge 2 ] || { error "$1 needs a value"; return 1; }
        case "$1" in
          --prefix) PREFIX="$2" ;;
          --archon-home) ARCHON_HOME_DIR="$2" ;;
          --target) TARGET="$2" ;;
        esac
        shift 2
        ;;
      --prefix=*) PREFIX="${1#--prefix=}"; shift ;;
      --archon-home=*) ARCHON_HOME_DIR="${1#--archon-home=}"; shift ;;
      --target=*) TARGET="${1#--target=}"; shift ;;
      --skip-web) SKIP_WEB=true; shift ;;
      --skip-tools) SKIP_TOOLS=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *) error "Unknown option: $1"; return 1 ;;
    esac
  done
  if [ -z "$TARGET" ]; then
    TARGET="$(host_target)" || return 1
  fi
  case " $SUPPORTED_TARGETS " in
    *" $TARGET "*) ;;
    *) error "Unsupported target '$TARGET'. Choose from: $SUPPORTED_TARGETS"; return 1 ;;
  esac
  # main cds to the checkout, so a relative path is read against the caller's folder now.
  PREFIX="$(abs_path "$PREFIX")"
  ARCHON_HOME_DIR="$(abs_path "$ARCHON_HOME_DIR")"
}

# An absolute path for $1, read against the current folder; the folder need not exist.
abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "${PWD%/}/${1#./}" ;;
  esac
}

timestamp() { date +%Y%m%d-%H%M%S; }

# What this run replaced, in order: "<target>|<backup>" (backup empty when the target was new).
TOUCHED=()
KEEP_BACKUPS=3

# Move an existing path aside; print what happened. Records the target for restore_backups.
backup_existing() {
  local path="$1" backup=""
  if [ -e "$path" ] || [ -L "$path" ]; then
    backup="${path}.prev-${STAMP}"
    mv "$path" "$backup"
    info "Backed up $path -> $backup"
  fi
  TOUCHED+=("${path}|${backup}")
}

# Copy an existing folder aside (it is updated in place, not replaced). Records it like backup_existing.
backup_copy() {
  local path="$1" backup=""
  if [ -e "$path" ]; then
    backup="${path}.prev-${STAMP}"
    cp -R "$path" "$backup"
    info "Backed up $path -> $backup"
  fi
  TOUCHED+=("${path}|${backup}")
}

# Undo this run: newest first, drop what it put at each target and move the backup back.
restore_backups() {
  local i entry path backup
  for ((i = ${#TOUCHED[@]} - 1; i >= 0; i--)); do
    entry="${TOUCHED[$i]}"
    path="${entry%%|*}"
    backup="${entry#*|}"
    rm -rf "$path"
    if [ -n "$backup" ] && { [ -e "$backup" ] || [ -L "$backup" ]; }; then
      mv "$backup" "$path"
      warn "Restored $path from $backup"
    fi
  done
  TOUCHED=()
}

# Keep the newest $KEEP_BACKUPS <path>.prev-* (the stamp sorts by time), remove the rest.
prune_backups() {
  local path="$1" old
  local -a backups=()
  for old in "${path}".prev-*; do
    { [ -e "$old" ] || [ -L "$old" ]; } && backups+=("$old")
  done
  [ "${#backups[@]}" -gt "$KEEP_BACKUPS" ] || return 0
  while IFS= read -r old; do
    rm -rf "$old"
  done < <(printf '%s\n' "${backups[@]}" | sort -r | tail -n +"$((KEEP_BACKUPS + 1))")
}

# EXIT trap while installing: a failed step puts every backup of this run back.
on_install_exit() {
  local status="$1"
  if [ "$status" -ne 0 ] && [ "${#TOUCHED[@]}" -gt 0 ]; then
    error "Install failed (exit $status); restoring the previous install"
    restore_backups
  fi
}

# Replace $2 with the file $1 (staged beside it so the final rename is atomic).
install_file() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  backup_existing "$dest"
  cp "$src" "${dest}.new.$$"
  chmod 755 "${dest}.new.$$"
  mv "${dest}.new.$$" "$dest"
}

check_bun() {
  command -v bun >/dev/null 2>&1 && return 0
  error "bun is required to build Archon but was not found on PATH."
  echo "Install it with:  curl -fsSL https://bun.sh/install | bash" >&2
  echo "Then restart the shell (or: export PATH=\"\$HOME/.bun/bin:\$PATH\") and re-run." >&2
  return 1
}

# Feature-detect what the installed CLI offers: `archon kit tools`, else
# `archon kit doctor`, else nothing. It runs in an empty temp folder, never in this
# checkout: a folder without scripts/install-tools.sh makes `kit tools` run the kit's
# bundled installer. A failing tools step is a warning only.
run_kit_tools() {
  local bin="$1" help_out dir
  if ! help_out="$("$bin" kit --help 2>&1)"; then
    info "This Archon has no 'kit' command; skipping the kit tools step."
    return 0
  fi
  dir="$(mktemp -d "${TMPDIR:-/tmp}/archon-kit-tools.XXXXXX")"
  if printf '%s\n' "$help_out" | grep -Eqw 'tools'; then
    info "Installing kit tools: archon kit tools (the kit's bundled installer)"
    (cd "$dir" && "$bin" kit tools "$dir") || warn "'archon kit tools' failed; re-run it by hand."
  elif printf '%s\n' "$help_out" | grep -Eqw 'doctor'; then
    info "No 'archon kit tools'; running: archon kit doctor"
    (cd "$dir" && "$bin" kit doctor "$dir") || warn "'archon kit doctor' reported problems."
  else
    info "'archon kit' has neither 'tools' nor 'doctor'; skipping the kit tools step."
  fi
  rm -rf "$dir"
}

running_servers() {
  command -v pgrep >/dev/null 2>&1 || return 0
  pgrep -af 'archon-server|archon serve' 2>/dev/null | grep -v "install-local" || true
}

print_plan() {
  echo "Install plan (version $VERSION, target $TARGET):"
  echo "  build        TARGET=$TARGET OUTFILE=dist/binaries/archon-${OS_ARCH} via scripts/build-binaries.sh"
  echo "  cli          dist/binaries/archon-${OS_ARCH} -> $PREFIX/archon"
  echo "  server       dist/binaries/archon-server-${OS_ARCH} -> $ARCHON_HOME_DIR/server/$VERSION/archon-server-${OS_ARCH}"
  echo "  provider     dist/binaries/archon-provider-claude-${OS_ARCH} -> $ARCHON_HOME_DIR/plugins/archon-provider-claude (+ receipt)"
  if [ "$SKIP_WEB" = true ]; then
    echo "  web          skipped (--skip-web)"
  else
    echo "  web          packages/web/dist -> $ARCHON_HOME_DIR/web-dist/$VERSION/"
  fi
  echo "  backups      existing targets move to <name>.prev-<timestamp>; restored if a step fails; newest $KEEP_BACKUPS kept"
  if [ "$SKIP_TOOLS" = true ]; then
    echo "  kit tools    skipped (--skip-tools)"
  else
    echo "  kit tools    archon kit tools in an empty temp folder (the kit's bundled installer), or archon kit doctor, if the CLI has a kit command"
  fi
}

main() {
  parse_args "$@" || exit 1

  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cd "$repo_root"

  VERSION="$(grep '"version"' package.json | head -1 | cut -d'"' -f4)"
  OS_ARCH="${TARGET#bun-}"
  STAMP="$(timestamp)"

  if [ "$DRY_RUN" = true ]; then
    print_plan
    command -v bun >/dev/null 2>&1 || warn "bun not found; a real run needs it (curl -fsSL https://bun.sh/install | bash)"
    exit 0
  fi

  check_bun || exit 1
  print_plan
  echo ""

  info "Installing dependencies..."
  bun install --frozen-lockfile

  info "Building binaries for $TARGET (this takes a few minutes)..."
  ARCHON_LOCAL_BUILD=1 TARGET="$TARGET" OUTFILE="dist/binaries/archon-${OS_ARCH}" bash scripts/build-binaries.sh

  local cli="dist/binaries/archon-${OS_ARCH}"
  local server="dist/binaries/archon-server-${OS_ARCH}"
  local provider="dist/binaries/archon-provider-claude-${OS_ARCH}"
  for f in "$cli" "$server" "$provider"; do
    [ -f "$f" ] || { error "Expected build output missing: $f"; exit 1; }
  done

  if [ "$SKIP_WEB" = false ]; then
    info "Building the web UI..."
    (cd packages/web && bunx vite build)
    [ -f packages/web/dist/index.html ] || { error "Web build produced no packages/web/dist/index.html"; exit 1; }
  fi

  local servers
  servers="$(running_servers)"

  # The set goes in together: server first, CLI last, so a half-finished install
  # never leaves a CLI whose embedded server hash matches nothing.
  info "Installing to $ARCHON_HOME_DIR and $PREFIX"
  trap 'on_install_exit $?' EXIT
  install_file "$server" "$ARCHON_HOME_DIR/server/$VERSION/archon-server-${OS_ARCH}"

  # Provider plugin: binary plus receipt, written by the repo's own installer code.
  # Move an existing binary aside so the receipt writer can claim the name; the
  # receipts are rewritten in place, so they are copied aside.
  backup_copy "$ARCHON_HOME_DIR/plugins/installed"
  backup_existing "$ARCHON_HOME_DIR/plugins/archon-provider-claude"
  ARCHON_HOME="$ARCHON_HOME_DIR" bun scripts/install-local-provider.ts claude "$provider"

  if [ "$SKIP_WEB" = false ]; then
    local web_dest="$ARCHON_HOME_DIR/web-dist/$VERSION"
    backup_existing "$web_dest"
    mkdir -p "$web_dest"
    cp -R packages/web/dist/. "$web_dest/"
    info "Installed web UI to $web_dest"
  fi

  install_file "$cli" "$PREFIX/archon"
  trap - EXIT
  local entry
  for entry in "${TOUCHED[@]}"; do
    prune_backups "${entry%%|*}"
  done
  TOUCHED=()
  success "Installed $PREFIX/archon (v$VERSION)"

  if [ -n "$servers" ]; then
    echo ""
    warn "An Archon server is running and still uses the old build:"
    printf '  %s\n' "${servers//$'\n'/$'\n'  }"
    echo "Restart it yourself when convenient (nothing was stopped):"
    echo "  stop it (Ctrl+C in its terminal, or: kill <pid>), then run: archon serve"
  fi

  case ":$PATH:" in
    *":$PREFIX:"*) ;;
    *) warn "$PREFIX is not on PATH. Add it: export PATH=\"$PREFIX:\$PATH\"" ;;
  esac

  if [ "$SKIP_TOOLS" = false ]; then
    ARCHON_HOME="$ARCHON_HOME_DIR" run_kit_tools "$PREFIX/archon"
  fi

  echo ""
  echo "Next, in a project:"
  echo "  archon kit add <project> --trust"
  echo "  archon kit doctor <project>"
  echo ""
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
