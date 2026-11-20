#!/usr/bin/env bash
# Generated code is never tracked (TASK-2.3, BR-OPS-30, AC #3): the server interfaces that `openApiGenerate` writes under
# shared-adapter/build/generated/openapi stay out of git. Refuses a tracked file under any build folder, generated
# sources that git does not ignore, a committed Java file holding the generator's marker, and a build that produced no
# generated sources (the check would then prove nothing). Run it after a clean build.
# The stack (kit key `stack`, env KIT_STACK, default spring) names the generator and its source folder: quarkus is
# JavaJAXRSSpecServerCodegen under src/gen/java, spring is SpringCodegen under src/main/java. Every check runs on both.
# Usage: bash .claude/scripts/generated-untracked-check.sh [<repo-root>]   (default: this repository)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../.archon/scripts/kit-config.sh
. "$here/../../.archon/scripts/kit-config.sh" 2>/dev/null || kit_get() { local e="${3:-}"; printf '%s' "${!e:-$2}"; }
repo="${1:-$(cd "$here/../.." && pwd)}"
cd "$repo" || { echo "FAIL: $repo is not a directory"; exit 1; }
gen=shared-adapter/build/generated/openapi
# The generator stamps every file it writes with this annotation; a bare mention (a test that reads one) is no marker.
case "$(kit_get stack spring KIT_STACK)" in
  spring) marker='^@.*Generated\(.*SpringCodegen'; src=src/main/java ;;
  *) marker='^@.*Generated\(.*JavaJAXRSSpecServerCodegen'; src=src/gen/java ;;
esac
failed=0
fail() { echo "FAIL: $1"; failed=1; }

while IFS= read -r file; do
  fail "tracked under a build folder: $file"
done < <(git ls-files | grep -E '(^|/)build/')

git check-ignore -q "$gen" || fail "generated sources are not ignored by git: $gen"

while IFS= read -r file; do
  fail "generated Java is committed: $file"
done < <(git grep -lE "$marker" -- '*.java')

[[ -d "$gen/$src" ]] || fail "no generated sources under $gen: run the build first"

[[ $failed -eq 0 ]] || exit 1
echo "generated-untracked: ok"
