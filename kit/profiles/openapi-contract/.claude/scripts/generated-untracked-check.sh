#!/usr/bin/env bash
# Generated code is never tracked (TASK-2.3, BR-OPS-30, AC #3): the server interfaces that `openApiGenerate` writes under
# shared-adapter/build/generated/openapi stay out of git. Refuses a tracked file under any build folder, generated
# sources that git does not ignore, a committed Java file holding the generator's marker, and a build that produced no
# generated sources (the check would then prove nothing). Run it after a clean build.
# Usage: bash .claude/scripts/generated-untracked-check.sh [<repo-root>]   (default: this repository)
set -uo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$repo" || { echo "FAIL: $repo is not a directory"; exit 1; }
gen=shared-adapter/build/generated/openapi
# The generator stamps every file it writes with this annotation; a bare mention (a test that reads one) is no marker.
marker='^@.*Generated\(.*JavaJAXRSSpecServerCodegen'
failed=0
fail() { echo "FAIL: $1"; failed=1; }

while IFS= read -r file; do
  fail "tracked under a build folder: $file"
done < <(git ls-files | grep -E '(^|/)build/')

git check-ignore -q "$gen" || fail "generated sources are not ignored by git: $gen"

while IFS= read -r file; do
  fail "generated Java is committed: $file"
done < <(git grep -lE "$marker" -- '*.java')

[[ -d "$gen/src/gen/java" ]] || fail "no generated sources under $gen: run the build first"

[[ $failed -eq 0 ]] || exit 1
echo "generated-untracked: ok"
