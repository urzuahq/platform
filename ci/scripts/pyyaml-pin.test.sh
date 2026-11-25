#!/usr/bin/env bash
# The PyYAML version and hashes live in workflow-lint-requirements.txt only:
# fail when any other tracked file carries a copy.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
req="ci/scripts/workflow-lint-requirements.txt"
cd "$root" || exit 2

fail=0
hashes="$(grep -o '[0-9a-f]\{64\}' "$req")"
[ -n "$hashes" ] || { echo "  FAIL  $req carries no hashes"; exit 1; }

while IFS= read -r file; do
  [ "$file" = "$req" ] && continue
  [ "$file" = "ci/scripts/pyyaml-pin.test.sh" ] && continue
  if grep -Eiq 'pyyaml[[:space:]]*(==|~=|>=|<=|<|>)' "$file" || grep -Fq "$hashes" "$file"; then
    echo "  FAIL  $file carries its own PyYAML pin"
    fail=1
  fi
done < <(git ls-files)

if [ "$fail" -eq 0 ]; then echo "  ok    PyYAML is pinned in $req only"; fi
exit "$fail"
