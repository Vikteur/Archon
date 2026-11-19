#!/usr/bin/env bash
# Tests scripts/install-local.sh argument parsing and its --dry-run plan.
# Never builds or installs anything.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/install-local.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "$3: output lacks '$2'. Got: $1" ;;
  esac
}

lacks() {
  case "$1" in
    *"$2"*) fail "$3: output has '$2'. Got: $1" ;;
  esac
}

version=$(grep '"version"' "$repo_root/package.json" | head -1 | cut -d'"' -f4)

output=$(bash "$script" --dry-run --prefix /p/bin --archon-home /p/home --target bun-linux-arm64) \
  || fail "dry-run failed"
contains "$output" "target bun-linux-arm64" "target"
contains "$output" "/p/bin/archon" "prefix"
contains "$output" "/p/home/server/$version/archon-server-linux-arm64" "server path"
contains "$output" "/p/home/plugins/archon-provider-claude" "provider path"
contains "$output" "/p/home/web-dist/$version/" "web path"
contains "$output" "archon kit tools" "kit step"
# The tests run without a terminal: no hand-off to kit setup.
contains "$output" "kit setup    skipped (no terminal)" "no setup without a terminal"

output=$(bash "$script" --dry-run --prefix=/q/bin --archon-home=/q/home --target=bun-darwin-x64 --skip-web --skip-tools) \
  || fail "dry-run with = forms failed"
contains "$output" "/q/bin/archon" "--prefix= form"
contains "$output" "skipped (--skip-web)" "--skip-web"
contains "$output" "skipped (--skip-tools)" "--skip-tools"
lacks "$output" "web-dist" "--skip-web hides the web path"

output=$(bash "$script" --dry-run --target bun-linux-x64 --no-setup) || fail "dry-run with --no-setup failed"
contains "$output" "kit setup    skipped (--no-setup)" "--no-setup"
contains "$output" "archon kit tools" "--no-setup keeps the kit tools step"

output=$(bash "$script" --dry-run --target bun-linux-x64 --no-setup --no-backlog) || fail "dry-run with --no-backlog failed"
contains "$output" "backlog      left out of kit tools (--no-backlog)" "--no-backlog plan line"
output=$(bash "$script" --dry-run --target bun-linux-x64 --no-setup) || fail "dry-run without --no-backlog failed"
lacks "$output" "left out of kit tools" "no --no-backlog keeps Backlog.md"

output=$(ARCHON_HOME=/env/home bash "$script" --dry-run --target bun-linux-x64) || fail "env home dry-run failed"
contains "$output" "/env/home/server/" "ARCHON_HOME default"

status=0
output=$(bash "$script" --dry-run --target bun-windows-x64 2>&1) || status=$?
[ "$status" -ne 0 ] || fail "accepted an unsupported target"
contains "$output" "Unsupported target" "bad target"

status=0
output=$(bash "$script" --bogus 2>&1) || status=$?
[ "$status" -ne 0 ] || fail "accepted an unknown option"
contains "$output" "Unknown option: --bogus" "unknown option"

status=0
output=$(bash "$script" --prefix 2>&1) || status=$?
[ "$status" -ne 0 ] || fail "accepted --prefix without a value"
contains "$output" "--prefix needs a value" "missing value"

# A relative --prefix/--archon-home is read against the caller's folder, not the checkout.
output=$(cd /tmp && bash "$script" --dry-run --prefix rel/bin --archon-home=./rel/home --target bun-linux-x64) \
  || fail "relative dry-run failed"
contains "$output" "/tmp/rel/bin/archon" "relative --prefix"
contains "$output" "/tmp/rel/home/server/" "relative --archon-home"
contains "$output" "empty temp folder" "kit tools runs outside the checkout"

# The helpers, sourced: backups of a failed run come back, a finished run keeps the newest 3.
work="$(mktemp -d "${TMPDIR:-/tmp}/install-local-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
(
  # shellcheck source=/dev/null
  source "$script"
  set +e
  [ "$(cd "$work" && abs_path x/y)" = "$work/x/y" ] || fail "abs_path relative"
  [ "$(abs_path /a/b)" = "/a/b" ] || fail "abs_path absolute"

  STAMP=20260101-000000
  echo old-bin > "$work/archon"
  mkdir -p "$work/receipts" && echo old-receipt > "$work/receipts/r.json"
  echo new-bin > "$work/new"
  install_file "$work/new" "$work/archon" >/dev/null
  backup_copy "$work/receipts" >/dev/null
  echo new-receipt > "$work/receipts/r.json"
  backup_existing "$work/fresh"
  mkdir -p "$work/fresh"
  [ "$(cat "$work/archon")" = new-bin ] || fail "install_file did not install"
  restore_backups >/dev/null 2>&1
  [ "$(cat "$work/archon")" = old-bin ] || fail "restore did not bring the old binary back"
  [ "$(cat "$work/receipts/r.json")" = old-receipt ] || fail "restore did not bring the receipts back"
  [ ! -e "$work/fresh" ] || fail "restore left a target that was new"
  [ ! -e "$work/archon.prev-$STAMP" ] || fail "restore left the backup behind"

  for stamp in 20250101-000001 20250101-000002 20250101-000003 20250101-000004 20250101-000005; do
    echo "$stamp" > "$work/archon.prev-$stamp"
  done
  mkdir "$work/archon.prev-20250101-000006"
  prune_backups "$work/archon"
  left="$(cd "$work" && printf "%s " archon.prev-*)"
  [ "$left" = "archon.prev-20250101-000004 archon.prev-20250101-000005 archon.prev-20250101-000006 " ] \
    || fail "prune kept: $left"
) || exit 1

# The hand-off to kit setup, sourced, with a stub CLI that records its calls.
# shellcheck disable=SC2034,SC2317 # NO_SETUP and SKIP_TOOLS are the sourced script's; is_interactive is its seam
(
  # shellcheck source=/dev/null
  source "$script"
  set +e
  calls="$work/calls"
  bin="$work/archon-stub"
  cat > "$bin" <<STUB
#!/usr/bin/env bash
if [ "\$1 \$2" = "kit --help" ]; then cat "$work/kit-help"; exit 0; fi
echo "\$*" >> "$calls"
STUB
  chmod +x "$bin"
  echo "  kit setup [--backend <path> --contract <file>]" > "$work/kit-help"

  is_interactive() { return 1; }
  : > "$calls"
  run_kit_setup "$bin" >/dev/null 2>&1 && fail "setup started without a terminal"
  [ ! -s "$calls" ] || fail "no terminal, yet the CLI ran: $(cat "$calls")"

  is_interactive() { return 0; }
  NO_SETUP=true
  run_kit_setup "$bin" >/dev/null 2>&1 && fail "setup started with --no-setup"
  [ ! -s "$calls" ] || fail "--no-setup, yet the CLI ran: $(cat "$calls")"

  NO_SETUP=false
  SKIP_TOOLS=false
  run_kit_setup "$bin" >/dev/null 2>&1 || fail "setup did not start in a terminal"
  [ "$(cat "$calls")" = "kit setup" ] || fail "setup call: $(cat "$calls")"
  plan="$(VERSION=0 OS_ARCH=x TARGET=t print_plan)"
  contains "$plan" "kit setup    archon kit setup in this terminal" "plan names the setup"
  contains "$plan" "kit tools    run by archon kit setup" "plan leaves the tools to setup"

  : > "$calls"
  SKIP_TOOLS=true
  run_kit_setup "$bin" >/dev/null 2>&1 || fail "setup did not start with --skip-tools"
  [ "$(cat "$calls")" = "kit setup --no-tools" ] || fail "--skip-tools setup call: $(cat "$calls")"

  : > "$calls"
  echo "  kit add [path]" > "$work/kit-help"
  run_kit_setup "$bin" >/dev/null 2>&1 && fail "setup started on a CLI without it"
  [ ! -s "$calls" ] || fail "a CLI without setup ran: $(cat "$calls")"
) || exit 1

# The kit tools step, sourced: --no-backlog reaches the CLI as a flag (when its help has it)
# and as INSTALL_TOOLS_BACKLOG=0; without it, neither.
# shellcheck disable=SC2034 # NO_BACKLOG is the sourced script's
(
  # shellcheck source=/dev/null
  source "$script"
  set +e
  calls="$work/tool-calls"
  bin="$work/archon-tools-stub"
  cat > "$bin" <<STUB
#!/usr/bin/env bash
if [ "\$1 \$2" = "kit --help" ]; then cat "$work/kit-help"; exit 0; fi
echo "\$1 \$2 \${3:+<dir>} \$4 backlog=\${INSTALL_TOOLS_BACKLOG:-unset}" >> "$calls"
STUB
  chmod +x "$bin"
  echo "  kit tools [path] [--check] [--no-backlog]" > "$work/kit-help"

  : > "$calls"
  NO_BACKLOG=false
  run_kit_tools "$bin" >/dev/null 2>&1
  [ "$(cat "$calls")" = "kit tools <dir>  backlog=unset" ] || fail "default tools call: $(cat "$calls")"

  : > "$calls"
  NO_BACKLOG=true
  run_kit_tools "$bin" >/dev/null 2>&1
  [ "$(cat "$calls")" = "kit tools <dir> --no-backlog backlog=0" ] || fail "--no-backlog tools call: $(cat "$calls")"

  : > "$calls"
  echo "  kit tools [path] [--check]" > "$work/kit-help"
  run_kit_tools "$bin" >/dev/null 2>&1
  [ "$(cat "$calls")" = "kit tools <dir>  backlog=0" ] || fail "older CLI --no-backlog call: $(cat "$calls")"
) || exit 1

echo "install-local tests passed"
