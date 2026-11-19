#!/usr/bin/env bash
# Fails unless every compiled main and test class is Java 26 bytecode (class-file major version 70).
# Run after ./gradlew build, from the repo root.
set -euo pipefail
want=70
count=0; bad=0
while IFS= read -r -d '' f; do
  count=$((count+1))
  major=$(od -An -t u1 -j 6 -N 2 "$f" | awk '{print $1*256+$2}')
  if [ "$major" -ne "$want" ]; then echo "FAIL: $f is major $major, want $want"; bad=$((bad+1)); fi
done < <(find . -path '*/build/classes/java/*' \( -path '*/java/main/*' -o -path '*/java/test/*' \) -name '*.class' -print0)
[ "$count" -gt 0 ] || { echo "FAIL: no compiled classes found, run ./gradlew build first"; exit 1; }
echo "class-version: $count classes checked, $bad wrong"
[ "$bad" -eq 0 ]
