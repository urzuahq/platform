#!/usr/bin/env bash
# usage: contract-pin.sh SCHEMAS_DIR VERSION_FILE KIT_DIR
# Checks a vendored copy of the agent CLI kit's schemas (RFC-1 R11): it matches
# its own SHA256SUMS, VERSION names a kit tag and commit that agree, and
# SHA256SUMS equals the kit's at that commit, fetched into KIT_DIR.
# Env: KIT_REPO (the kit's git URL), ALLOW_PRERELEASE=true (accept -rc tags).
# Exit: 0 ok, 1 a check failed, 2 bad invocation or input.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: contract-pin.sh SCHEMAS_DIR VERSION_FILE KIT_DIR" >&2
  exit 2
fi
schemas="$1" version_file="$2" kit_dir="$3"
kit_repo="${KIT_REPO:-https://github.com/urzuahq/agent-cli-kit.git}"

[ -d "$schemas" ] || { echo "contract-pin: no schemas directory at $schemas" >&2; exit 2; }
[ -f "$version_file" ] || { echo "contract-pin: no VERSION file at $version_file" >&2; exit 2; }

if [ "$(wc -l < "$version_file")" -ne 1 ] || ! grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)? [0-9a-f]{40}$' "$version_file"; then
  echo "contract-pin: $version_file must be one line, '<tag> <40-hex commit>', tag as v<major>.<minor>.<patch>[-pre-release]" >&2
  exit 2
fi
read -r tag commit < "$version_file"

failed=0
fail() { echo "FAIL  $*" >&2; failed=1; }

case "$tag" in
  *-*)
    if [ "${ALLOW_PRERELEASE:-false}" != "true" ]; then
      fail "$tag is a pre-release; set allow-prerelease to accept it"
    fi ;;
esac

refs="$(git ls-remote "$kit_repo" "refs/tags/$tag" "refs/tags/$tag^{}" 2>/dev/null || true)"
tag_commit="$(printf '%s\n' "$refs" | awk -v t="refs/tags/$tag" '$2 == t "^{}" { print $1; exit }')"
[ -n "$tag_commit" ] || tag_commit="$(printf '%s\n' "$refs" | awk -v t="refs/tags/$tag" '$2 == t { print $1; exit }')"
if [ -z "$tag_commit" ]; then
  fail "tag $tag does not exist in $kit_repo"
elif [ "$tag_commit" != "$commit" ]; then
  fail "tag $tag is commit $tag_commit, but VERSION says $commit"
fi

sums="$schemas/SHA256SUMS"
if [ ! -f "$sums" ]; then
  fail "$sums is missing"
else
  listed=""
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    want="${line%% *}"
    name="${line#"$want"}"
    name="${name# }"
    name="${name#[ *]}"
    listed="$listed$name"$'\n'
    if [ ! -f "$schemas/$name" ]; then
      fail "SHA256SUMS lists $name, which is not in $schemas"
    elif [ "$(shasum -a 256 "$schemas/$name" | cut -d' ' -f1)" != "$want" ]; then
      fail "$name does not match its hash in SHA256SUMS"
    fi
  done < "$sums"
  for f in "$schemas"/*.schema.json; do
    [ -e "$f" ] || continue
    name="$(basename "$f")"
    printf '%s' "$listed" | grep -Fxq -- "$name" || fail "$name is not listed in SHA256SUMS"
  done
fi

mkdir -p "$kit_dir"
if git init -q "$kit_dir" \
  && git -C "$kit_dir" fetch -q --depth 1 "$kit_repo" "$commit" 2>/dev/null \
  && git -C "$kit_dir" checkout -q FETCH_HEAD 2>/dev/null; then
  head="$(git -C "$kit_dir" rev-parse HEAD)"
  if [ "$head" != "$commit" ]; then
    fail "fetched kit is at $head, not $commit"
  elif [ ! -f "$sums" ]; then
    :
  elif ! cmp -s "$sums" "$kit_dir/schemas/SHA256SUMS"; then
    fail "SHA256SUMS differs from the kit's at $commit"
  fi
else
  fail "could not fetch commit $commit from $kit_repo"
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "contract-pin: $tag ($commit) ok"
