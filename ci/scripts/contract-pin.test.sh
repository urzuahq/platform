#!/usr/bin/env bash
# Planted-violation cases for contract-pin.sh, against a local kit fixture:
# every way a vendored copy can disagree with its checksums, its VERSION or the
# kit must fail with a message naming it, and a clean copy must pass.
# shellcheck disable=SC2329  # the edit functions run through a variable
set -uo pipefail

pin="$(cd "$(dirname "$0")" && pwd)/contract-pin.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

git_q() { git -C "$tmp/kit" -c user.name=t -c user.email=t@example.com "$@"; }

git init -q "$tmp/kit"
mkdir "$tmp/kit/schemas"
printf '{"a":1}\n' > "$tmp/kit/schemas/a.schema.json"
printf '{"b":1}\n' > "$tmp/kit/schemas/b.schema.json"
(cd "$tmp/kit/schemas" && shasum -a 256 -- *.schema.json > SHA256SUMS)
git_q add -A
git_q commit -q -m release
git_q tag -a v1.1.0 -m v1.1.0
c1=$(git_q rev-parse HEAD)
printf '{"c":1}\n' > "$tmp/kit/schemas/c.schema.json"
(cd "$tmp/kit/schemas" && shasum -a 256 -- *.schema.json > SHA256SUMS)
git_q add -A
git_q commit -q -m candidate
git_q tag -a v1.2.0-rc.1 -m rc
c2=$(git_q rev-parse HEAD)

export KIT_REPO="$tmp/kit"
n=0

# Runs a case: a fresh vendored copy of the v1.1.0 schemas, edited by $edit.
expect() { # want-exit description fail-text version edit-function [ALLOW_PRERELEASE]
  local want="$1" desc="$2" text="$3" version="$4" edit="$5" allow="${6:-}" dir out got
  n=$((n + 1))
  dir="$tmp/case$n"
  mkdir -p "$dir/schemas"
  git -C "$tmp/kit" archive "$c1" schemas | tar -x -C "$dir"
  printf '%s\n' "$version" > "$dir/VERSION"
  (cd "$dir" && $edit)
  out=$(ALLOW_PRERELEASE="$allow" "$pin" "$dir/schemas" "$dir/VERSION" "$dir/kit" 2>&1)
  got=$?
  if [ "$got" -ne "$want" ]; then
    echo "  FAIL  $desc (want exit $want, got $got)"; indent <<< "$out"
    fail=1
  elif [ -n "$text" ] && ! grep -Fq -- "$text" <<< "$out"; then
    echo "  FAIL  $desc (output lacks '$text')"; indent <<< "$out"
    fail=1
  else
    echo "  ok    $desc"
  fi
}

indent() { sed "s/^/        /"; }

none() { :; }
edit_schema() { printf '{"a":2}\n' > schemas/a.schema.json; }
unlist_schema() { grep -v ' b.schema.json' schemas/SHA256SUMS > sums && mv sums schemas/SHA256SUMS; }
remove_schema() { rm schemas/b.schema.json; }
own_sums() { printf '{"a":2}\n' > schemas/a.schema.json; (cd schemas && shasum -a 256 -- *.schema.json > SHA256SUMS); }
rc_files() { git -C "$tmp/kit" archive "$c2" schemas | tar -x -C .; }

v1="v1.1.0 $c1"
expect 0 "a clean copy" "ok" "$v1" none
expect 0 "a pre-release when allowed" "ok" "v1.2.0-rc.1 $c2" rc_files true
expect 1 "an edited schema" "a.schema.json does not match" "$v1" edit_schema
expect 1 "a schema missing from SHA256SUMS" "b.schema.json is not listed" "$v1" unlist_schema
expect 1 "a listed schema that is absent" "lists b.schema.json" "$v1" remove_schema
expect 1 "SHA256SUMS that differs from the kit's" "differs from the kit's" "$v1" own_sums
expect 1 "a commit that is not the tag's" "tag v1.1.0 is commit $c1" "v1.1.0 $c2" none
expect 1 "a tag that does not exist" "tag v9.9.9 does not exist" "v9.9.9 $c1" none
expect 1 "a pre-release without the flag" "pre-release" "v1.2.0-rc.1 $c2" rc_files
expect 2 "a malformed VERSION" "must be one line" "v1.1.0" none
expect 2 "an uppercase commit" "must be one line" "v1.1.0 ${c1^^}" none
expect 2 "a tag without v" "must be one line" "1.1.0 $c1" none

out=$("$pin" "$tmp/nope" "$tmp/case1/VERSION" "$tmp/k" 2>&1); got=$?
if [ "$got" -eq 2 ] && grep -Fq "no schemas directory" <<< "$out"; then echo "  ok    a missing schemas dir"; else echo "  FAIL  a missing schemas dir (got $got)"; fail=1; fi
out=$("$pin" "$tmp/case1/schemas" 2>&1); got=$?
if [ "$got" -eq 2 ] && grep -Fq "usage" <<< "$out"; then echo "  ok    wrong argument count"; else echo "  FAIL  wrong argument count (got $got)"; fail=1; fi

if [ "$fail" -eq 0 ]; then echo "contract-pin: all cases passed"; else echo "contract-pin: FAILURES"; fi
exit "$fail"
