#!/usr/bin/env bash
# Planted-violation cases for workflow-lint.py: every rule must fire on a
# fixture that breaks only that rule, and the exemptions must not fire.
# PYTHON must be an interpreter with PyYAML installed.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
lint="$here/workflow-lint.py"
fx="$here/fixtures/workflow-lint"
py="${PYTHON:-python3}"
fail=0

run() { "$py" -I "$lint" "$@" 2>&1; }

expect() { # want-exit description [lint args...]
  local want="$1" desc="$2" got
  shift 2
  run "$@" >/dev/null
  got=$?
  if [ "$got" -ne "$want" ]; then
    echo "  FAIL  $desc (want exit $want, got $got)"
    fail=1
  else
    echo "  ok    $desc"
  fi
}

violates() { # rule-id fixture [lint args...]: exit 1, and only that rule fires
  local rule="$1" file="$2" out got ids
  shift 2
  out="$(run --ci-workflow "$fx/$file" "$fx/$file" "$@")"
  got=$?
  ids="$(printf '%s\n' "$out" | grep -v '^::' | sed -n 's/^[^:]*:[0-9]*: \([A-Z][0-9]*\.[a-z-]*\): .*/\1/p' | sort -u | tr '\n' ' ')"
  if [ "$got" -ne 1 ] || [ "$ids" != "$rule " ]; then
    echo "  FAIL  $rule on $file (want exit 1 and only $rule, got exit $got: ${ids:-no rule})"
    fail=1
  elif ! printf '%s\n' "$out" | grep -q "^::error file=.*$file,line=[0-9]*::$rule: "; then
    echo "  FAIL  $rule on $file (no annotation with file and line)"
    fail=1
  else
    echo "  ok    $rule on $file"
  fi
}

expect 0 "a clean ci workflow" --ci-workflow "$fx/clean.yml" "$fx/clean.yml"
expect 0 "exemptions: reusable-workflow job, checkout with token or contents: write, allowlisted expressions, local action" \
  --ci-workflow "$fx/exempt.yml" "$fx/exempt.yml"

violates R2.pull-request-types r2-pull-request-types.yml
violates R2.merge-group r2-merge-group.yml
violates R2.push-branches r2-push-branches.yml
violates R2.push-branches clean.yml --default-branch develop
violates R2.no-dispatch r2-no-dispatch.yml
violates R2.no-filter r2-no-filter-pull-request.yml
violates R2.no-filter r2-no-filter-push.yml
violates R2.concurrency r2-concurrency-group.yml
violates R2.concurrency r2-concurrency-cancel.yml
violates R1.gate-job r1-gate-missing.yml
violates R1.gate-job r1-gate-if.yml
violates R1.gate-job r1-gate-needs.yml
violates R4.permissions r4-permissions-missing.yml
violates R4.permissions r4-permissions-write.yml
violates R4.timeout r4-timeout.yml
violates R4.persist-credentials r4-persist-credentials.yml
violates R4.expression-in-run r4-expression-in-run.yml
violates R4.secrets-inherit r4-secrets-inherit.yml
violates R5.pin r5-pin-tag.yml
violates R5.pin r5-pin-comment.yml
violates R5.pin r5-pin-docker.yml

tpl="$here/../templates/default/.github/workflows/ci.yml"
expect 0 "the default caller template is clean" --ci-workflow "$tpl" "$tpl"

expect 2 "invalid YAML" --ci-workflow "$fx/invalid-yaml.yml" "$fx/invalid-yaml.yml"
expect 2 "a top level that is not a mapping" --ci-workflow "$fx/not-a-mapping.yml" "$fx/not-a-mapping.yml"
expect 2 "a missing ci workflow" --ci-workflow "$fx/absent.yml" "$fx/clean.yml"
expect 2 "an unknown argument" --bogus
expect 2 "invalid YAML beside a finding" --ci-workflow "$fx/r2-merge-group.yml" "$fx/invalid-yaml.yml"

multi="$(run --ci-workflow "$fx/r2-merge-group.yml" "$fx/r2-merge-group.yml" "$fx/r4-timeout.yml" | grep -c '^::error')"
if [ "$multi" -ne 2 ]; then echo "  FAIL  every finding in one run (want 2 annotations, got $multi)"; fail=1; else echo "  ok    every finding in one run"; fi

if [ "$fail" -eq 0 ]; then echo "workflow-lint: all cases passed"; else echo "workflow-lint: FAILURES"; fi
exit "$fail"
