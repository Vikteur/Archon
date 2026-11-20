#!/usr/bin/env bash
# Scaffold a new bounded context: the <capability>-<module> set the repo's own templates describe, rendered through
# scripts/scaffold.sh (so every file is in the scaffold record) and registered in the Gradle build.
# Usage: scripts/scaffold/new-context.sh [--<flag>]... <capability> <Ctx> <basePackage> [<arg>]...
#   The modules, flags, extra arguments, files and registration come from the "context" object of
#   docs/scaffold-templates/project/scaffold.json, the repo's own (scripts/scaffold/new-context.js says its form);
#   run it without arguments for this repo's usage. Refuses, writing nothing, when a module or a target exists.
# The aggregate's own files come after, one scripts/scaffold.sh call each.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
exec node "$root/scripts/scaffold/new-context.js" "$root" "$@"
