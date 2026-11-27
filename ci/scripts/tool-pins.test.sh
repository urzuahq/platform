#!/usr/bin/env bash
# Each pinned tool is downloaded in one place, its install action, which also
# runs the one checksum check per download. This fails when a workflow carries
# a download of its own, an action downloads twice or skips the checksum, or an
# action is missing.
#
# It checks the repository it sits in, then the same check over scratch copies
# with a planted violation, so a check that always passes fails here.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# tool|action|download URL prefix|checksum checks the action must run
tools=(
  "knope|ci/actions/install-knope/action.yml|knope-dev/knope/releases/download|1"
  "nextest|ci/actions/install-nextest/action.yml|nextest-rs/nextest/releases/download|1"
  "cargo-deny|ci/actions/install-cargo-tools/action.yml|EmbarkStudios/cargo-deny/releases/download|2"
  "cargo-machete|ci/actions/install-cargo-tools/action.yml|bnjbvr/cargo-machete/releases/download|2"
)
actions=(ci/actions/install-knope ci/actions/install-nextest ci/actions/install-cargo-tools)

# The lines of a file that are not comments, so a commented-out command never counts.
live() { grep -v '^[[:space:]]*#' "$1"; }

# Prints one line per problem found under $1 and returns 1 when there is one.
verify() {
  local dir="$1" bad=0 entry tool action url checks f
  for entry in "${tools[@]}"; do
    IFS='|' read -r tool action url checks <<< "$entry"
    if [ ! -f "$dir/$action" ]; then
      echo "missing $action"; bad=1; continue
    fi
    [ "$(live "$dir/$action" | grep -o "$url" | wc -l)" -eq 1 ] \
      || { echo "$action must name the $tool download exactly once"; bad=1; }
    while IFS= read -r f; do
      [ "$f" = "$dir/$action" ] || [ "$f" = "$dir/ci/scripts/tool-pins.test.sh" ] && continue
      echo "${f#"$dir"/} carries its own $tool download; use the $action action"
      bad=1
    done < <(git -C "$dir" ls-files -z 2>/dev/null | xargs -0 -I{} grep -l "$url" "$dir/{}" 2>/dev/null)
  done
  for f in "${actions[@]}"; do
    [ -f "$dir/$f/action.yml" ] || continue
    checks=1; [ "$f" = ci/actions/install-cargo-tools ] && checks=2
    [ "$(live "$dir/$f/action.yml" | grep -o 'shasum -a 256 -c' | wc -l)" -eq "$checks" ] \
      || { echo "$f/action.yml must run exactly $checks sha256 check(s)"; bad=1; }
  done
  return "$bad"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

expect() {
  local want="$1" desc="$2" dir="$3" out got
  out=$(verify "$dir"); got=$?
  if [ "$got" -ne "$want" ]; then
    echo "  FAIL  $desc (want exit $want, got $got)"
    [ -n "$out" ] && printf '          %s\n' "$out"
    fail=1
  else
    echo "  ok    $desc"
  fi
}

plant() { # a scratch git repository holding the files the check reads
  local dir="$1" a
  mkdir -p "$dir/.github/workflows"
  cp "$root"/.github/workflows/*.yml "$dir/.github/workflows/"
  for a in "${actions[@]}"; do
    mkdir -p "$dir/$a"
    cp "$root/$a/action.yml" "$dir/$a/action.yml"
  done
  git -C "$dir" init -q && git -C "$dir" add -A
}

expect 0 "the repository's own files" "$root"

copy=$tmp/copy; plant "$copy"
expect 0 "an unmodified copy" "$copy"

for pair in \
  "knope|https://github.com/knope-dev/knope/releases/download/knope/v0.0.1/knope.tgz" \
  "nextest|https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-0.0.1/n.tgz" \
  "cargo-deny|https://github.com/EmbarkStudios/cargo-deny/releases/download/0.0.1/d.tgz" \
  "cargo-machete|https://github.com/bnjbvr/cargo-machete/releases/download/v0.0.1/m.tgz"; do
  name=${pair%%|*}; url=${pair#*|}
  d=$tmp/wf-$name; plant "$d"
  printf '      - run: curl -o x.tgz %s\n' "$url" >> "$d/.github/workflows/ci.yml"
  git -C "$d" add -A
  expect 1 "a workflow carrying its own $name download" "$d"
done

for a in "${actions[@]}"; do
  name=${a##*/}
  twice=$tmp/twice-$name; plant "$twice"
  url=$(grep -o 'github.com/[A-Za-z0-9_./-]*/releases/download' "$root/$a/action.yml" | head -n 1)
  printf '        curl -fsSL -o other.tgz "https://%s/v0.0.1/other.tgz"\n' "$url" >> "$twice/$a/action.yml"
  expect 1 "$name with a second download" "$twice"

  nosum=$tmp/nosum-$name; plant "$nosum"
  sed 's|shasum -a 256 -c|true|' "$nosum/$a/action.yml" > "$tmp/edit" && mv "$tmp/edit" "$nosum/$a/action.yml"
  expect 1 "$name missing its checksum check" "$nosum"

  oneline=$tmp/oneline-$name; plant "$oneline"
  sed "0,/curl -fsSL --retry/s||curl -fsSL -o same.tgz https://$url/v0.0.1/same.tgz; curl -fsSL --retry|" "$oneline/$a/action.yml" > "$tmp/edit" && mv "$tmp/edit" "$oneline/$a/action.yml"
  expect 1 "$name with two downloads on one line" "$oneline"

  commented=$tmp/commented-$name; plant "$commented"
  sed 's|^\([[:space:]]*\)echo \(.*shasum -a 256 -c\)|\1# echo \2|' "$commented/$a/action.yml" > "$tmp/edit" && mv "$tmp/edit" "$commented/$a/action.yml"
  expect 1 "$name with its checksum check commented out" "$commented"

  gone=$tmp/gone-$name; plant "$gone"; rm "$gone/$a/action.yml"
  expect 1 "$name action file deleted" "$gone"
done

onesum=$tmp/onesum; plant "$onesum"
sed '0,/shasum -a 256 -c/s|shasum -a 256 -c|true|' "$onesum/ci/actions/install-cargo-tools/action.yml" > "$tmp/edit" && mv "$tmp/edit" "$onesum/ci/actions/install-cargo-tools/action.yml"
expect 1 "install-cargo-tools checking only one of its two downloads" "$onesum"

if [ "$fail" -eq 0 ]; then
  echo "tool-pins: all cases passed"
else
  echo "tool-pins: FAILURES"
fi
exit "$fail"
