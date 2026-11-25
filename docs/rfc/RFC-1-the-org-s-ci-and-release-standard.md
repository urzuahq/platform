---
Stable-Id: 01M864XDQ0WW6FX6T2BRJ9Q1BW
Status: Accepted
Date: 2026-11-24
Author: beauwilliams
---
# 1 — The org's CI and release standard

## Summary

One standard for how every urzuahq repository is checked, released and protected, written here and
shared from here. Each rule says what a project must do, the evidence for it in the org's repositories,
and whether this repository ships it as a reusable workflow or composite action (**shared**) or only
states it (**stated**), because GitHub gives a reusable workflow no say over the caller's triggers,
concurrency or job names. Projects call shared units at a full commit SHA. This record also lists what
to build, in order, with the project that adopts each unit first, and the questions only the maintainer
can settle.

## Motivation

**The same CI is maintained twice and has already drifted.** garita's `.github/scripts` started as a
copy of urzua's. Of the eleven scripts both carry, ten now differ (`ci-tests.sh` by 61 lines,
`release-invariants.sh` by 48, `release-invariants.test.sh` by 32); only `ci-gate.test.sh` is
identical. Both `install-knope` and `install-nextest` actions differ, and the two `scripts/install.sh`
differ by 135 lines out of about 260.

**A fix lands once per repository, or not at all.** urzua BUG-222 (a second event on the same commit
cancels a correct run, leaving a failed required `ci`) and BUG-223 (a manual run posts a green `ci`
beside a failed changeset gate) were fixed in garita PR #18 and separately in urzua PR #651. The
other two repositories still carry the defects: decision-agent-kit's `ci.yml` has `workflow_dispatch`
and `cancel-in-progress: true`, and agent-cli-kit's cancels on every non-push event.

**The contract check exists in one tool only.** garita runs `scripts/contract-check.sh --release`
(vendored schemas match `SHA256SUMS`, and `SHA256SUMS` matches the kit commit named in `VERSION`) and
`scripts/conform.sh` (the kit's `conform.py --require-run` against the built binary). urzua checks its
vendored schemas against their own checksums in `agent_cli_contract_integration.rs` and never against
the release `VERSION` names. agent-cli-kit's README asks every tool to do both.

**Protection and pins are uneven.** urzua and garita protect the default branch with a ruleset that
requires a pull request and the `ci` check, blocks force pushes and deletion, and has no bypass actor.
agent-cli-kit, decision-agent-kit and this repository have no ruleset. The records gate is pinned at
three versions: `v0.4.7` (urzua's own pinned-release job), `v0.4.13` (agent-cli-kit,
decision-agent-kit) and `v0.4.14` (garita), with no stated way to move them.

**This repository becomes the release path.** Once projects call its release workflows, a change here
runs with their release secrets. It needs protection at least as strict as theirs, and callers must pin
what they run.

## Proposal

### 1. What the standard covers

The required check, workflow triggers and concurrency, least privilege, pinning, the changeset gate,
the two-step release, what a release publishes, branch protection, the records gate, the agent CLI
contract check, local hooks, and a profile per language (Rust, TypeScript). It does not cover what a
project tests: each project's own checks stay its own, called from the shared shape.

A rule applies to every repository unless marked **release** (applies once a repository publishes an
artifact) or **contract** (applies to a tool that implements the agent CLI contract).

### 2. The rules

Evidence cites urzua records as `urzua ADR-n` / `urzua BUG-n` and garita's as `garita RFC-4 §n`.

**R1. One required check, named `ci`, that fails closed.** The last job of `ci.yml` is `ci`. It needs
every other job and fails unless each succeeded: a failure, a cancellation, a skip and a missing result
are all red, except a job declared skippable off pull requests (`changeset`). Branch protection requires
`ci` and nothing else. *Evidence:* urzua ADR-98, urzua ADR-95 §4, garita RFC-4 §1, `ci-gate.sh` in
both. *How:* **shared** action `ci-gate`. The job itself stays in the caller: a job that calls a
reusable workflow reports as `<caller job> / <called job>`, so a reusable `ci` would rename the
required check.

**R2. Triggers and concurrency.** `ci.yml` runs on `pull_request` with types
`[opened, synchronize, reopened, labeled, unlabeled]`, `merge_group`, and `push` with
`branches: [main]`. No `workflow_dispatch`, no `edited`, and no `branches:` or `paths:` filter on
`pull_request` or `merge_group`. Concurrency group
`ci-${{ github.workflow }}-${{ github.ref }}` with
`cancel-in-progress: ${{ github.event_name == 'pull_request' && github.event.action == 'synchronize' }}`.
*Evidence:* urzua BUG-222, BUG-223, BUG-15 (label events), garita RFC-4 §1; urzua `ci.yml` header on
why a filtered required check deadlocks a merge. *How:* **stated** (triggers and concurrency belong to
the calling workflow), and checked by the **shared** `workflow-lint` job.

**R3. One definition of the checks, run by CI and by the release.** A project's checks live in a
`workflow_call` workflow (`checks.yml`) that `ci.yml` calls and the publish workflow calls again on the
commit it tags. *Evidence:* urzua ADR-47, garita RFC-4 §1 and §4. *How:* **stated**; the shared
language workflows (R14) are what `checks.yml` calls.

**R4. Least privilege and hygiene.** Workflow-level `permissions: contents: read`, wider grants per
job. `actions/checkout` with `persist-credentials: false` unless the job pushes. `timeout-minutes` on
every job. Event data (`github.event.*`, `github.base_ref`, matrix values) reaches a `run:` script
through `env:`, never as `${{ }}` inside the script. Secrets pass to a reusable workflow by name,
never `secrets: inherit`. *Evidence:* urzua and garita follow the first two; decision-agent-kit has
neither timeouts nor `persist-credentials: false`; garita moved event data into `env:` in its release
and changeset jobs where urzua still inlines `base.ref` and `matrix.target`. *How:* **stated**,
checked by `workflow-lint`.

**R5. Pins.** Every third-party action is pinned by full commit SHA with the version in a comment.
Every tool CI downloads is pinned by version and checksum in one place, and a test fails when a
workflow carries its own copy. *Evidence:* garita RFC-4 §6, urzua ADR-98 (nextest), urzua
`knope-pin.test.sh`; all four repositories already SHA-pin actions. *How:* **shared** actions
`install-knope`, `install-nextest`, `install-cargo-tools` (cargo-deny, cargo-machete), each with its
pin test.

**R6. Changesets are the only release trigger** (**release**). A pull request touching a path listed
in `.github/release-paths` adds a `.changeset/*.md` fragment or carries the `no-changeset` label, read
live from the API. Commit messages never decide a version (`ignore_conventional_commits = true`).
*Evidence:* urzua ADR-48, ADR-49, BUG-34, garita RFC-4 §3. *How:* **shared** reusable workflow
`changeset.yml`; `release-paths` stays in each project.

**R7. A release is a pull request, and merging it publishes** (**release**). On each push to `main`,
`prepare-release` opens or updates one PR from `release`, using a GitHub App installation token
narrowed to `contents: write` and `pull-requests: write`, with no fallback to `GITHUB_TOKEN`. Merging
it runs `publish-release`, which runs `checks.yml` on `merge_commit_sha`, then tags with
`GITHUB_TOKEN`, creates the release and builds and attaches the artifacts in the same workflow.
knope's `releases::no_release` is the only tolerated failure. *Evidence:* urzua ADR-45, ADR-47,
ADR-95, BUG-28, BUG-27, BUG-33, garita RFC-4 §4. *How:* **shared** reusable workflows
`prepare-release.yml` and `publish-release.yml`, the App secrets passed by name.

**R8. What a release publishes** (**release**). Artifacts are built in CI from the tag with
`--locked` and the pinned toolchain, carry a build provenance attestation (blocking), and the run
checks that each binary reports the tagged version and that the release carries exactly the expected
assets. Every platform released is also tested. *Evidence:* urzua ADR-13 and its 2026-11-23
amendment (attestation is blocking); garita RFC-4 §2 and §5, and garita's `publish-release.yml`
(version check, exact asset set). *How:* **shared** inside `publish-release.yml`.

**R9. Branch protection.** A ruleset on the default branch: pull request required (0 approvals for a
sole maintainer), `ci` required (GitHub Actions source), force pushes and deletion blocked, no bypass
actor. No rule on the `release` branch. A tag ruleset on `v*` may block update and deletion but
never creation, which `publish-release` needs to push its tag. *Evidence:* urzua
ADR-95 §4; the live rulesets on urzua (`release`) and garita (`main`) match this. *How:* **stated**; a
repository setting the maintainer applies (§5).

**R10. The records gate.** A repository with records runs `urzua-gate` from urzua, pinned by SHA,
with `fetch-depth: 0`. *Evidence:* urzua ADR-71, MILE-180; used by all four repositories. *How:*
**stated**. The action stays in urzua, where it is the product's adopter-facing unit; this repository
states the rule and the pin policy (§3).

**R11. The agent CLI contract check** (**contract**). A tool vendors the kit's schemas at a release
tag, checks them against `SHA256SUMS` and checks `SHA256SUMS` against the kit commit in `VERSION`, and
runs the kit's `conform.py --require-run` against its built binary at that commit. *Evidence:*
agent-cli-kit README ("In CI, it must also match the release it claims to be") and RFC-1; garita
`contract` and `conform` jobs. *How:* **shared** reusable workflow `agent-cli-contract.yml`; the tool
supplies its binary build and the fixture setup the runner needs.

**R12. Local checks mirror CI; CI is the guarantee.** `make ci` runs every check that can run without
the GitHub API. Hooks are versioned and wired by a make target; a hook that cannot run says so and
never reads as a pass. *Evidence:* urzua ADR-71 and `.git-hooks/`, garita `Makefile` (`ci` is the
default target), decision-agent-kit RFC-2 ("Every task runs through `make`"). *How:* **stated**.

**R13. Tests are split by wall-clock, not by habit.** One test job until it is the slowest part of
`ci` by a clear margin; then shard it and aggregate under R1. *Evidence:* urzua ADR-98 (sharded after
a 15-minute job kept timing out), garita RFC-4 §2 (one job while the suite runs in seconds). *How:*
**shared** as a `shards` input on the Rust workflow.

**R14. Language profiles.** The standard assumes `make`, not a language.

- **Rust.** `rust-toolchain.toml` pins `1.87.0` with rustfmt and clippy; `rust-version = "1.87"`;
  `publish = false` on every crate; `[workspace.lints]` with `unsafe_code = "forbid"`,
  `clippy::all = deny`, `too_many_lines = deny` and `too-many-lines-threshold = 100`; edition 2024.
  CI runs `fmt --check`, `clippy --all-targets --locked -D warnings`, `cargo machete`,
  `cargo deny check`, `build --locked`, nextest and doctests under the leak guard, with
  `rust-cache` written only on `main`. *Evidence:* garita `rust/Cargo.toml` and `clippy.toml`; urzua
  and garita `checks.yml`. *How:* **shared** reusable workflow `rust.yml`.
- **TypeScript.** Node from `.nvmrc`, pnpm from `packageManager`, and `make install fmt-check lint
  check test`. *Evidence:* decision-agent-kit `ci.yml`, `package.json`, RFC-2. *How:* **shared**
  reusable workflow `node.yml`.

### 3. How this repository is versioned and pinned

- A version is an annotated tag `vMAJOR.MINOR.PATCH` on `main`. A breaking change to a unit's inputs,
  outputs, required permissions or required secrets is a major.
- Tags never move: a tag ruleset on `refs/tags/v*` blocks update and deletion, with no bypass actor.
  No moving `v1` tag.
- A caller pins the full commit SHA of a tag, with the tag in a comment:
  `uses: urzuahq/platform/.github/workflows/changeset.yml@<40-hex-sha> # v1.2.0`. Never a branch, never
  a bare tag. `workflow-lint` fails on any other form.
- A shared workflow cannot use `./` to reach this repository's actions or scripts: in a called
  workflow `./` is the caller's checkout. Each shared workflow therefore references this repository's
  actions by full path and SHA, and the release PR updates those internal pins, guarded by a test that
  every internal reference names the same SHA.
- Bumps arrive as pull requests from a dependency bot that understands SHA pins with version
  comments, so a project moves when its own `ci` passes on the new pin. The records gate pin follows
  the same policy.

### 4. How a project adopts it

1. Apply the ruleset (R9) if missing. It requires `ci`, so it goes on once `ci.yml` reports `ci`.
2. Replace the project's copies with calls, one unit per pull request in the build order below, each
   pinned per §3. A unit replaces a local copy only when the project's `ci` passes on the call.
3. Delete the replaced scripts, actions and their pin tests in the same pull request.
4. For a released artifact, keep the release App and secrets (`RELEASE_APP_CLIENT_ID`,
   `RELEASE_APP_PRIVATE_KEY`) as they are; the shared workflow receives them by name.
5. urzua's workflow and hook files are blocked for agents, so urzua adopts each unit as a patch this
   repository's thread prepares and the maintainer applies by hand.

### 5. Settings the maintainer applies

Not in this pull request: the `ci` check does not exist here until build step 1 lands, and a ruleset
requiring it would block every merge. After step 1:

```sh
gh api -X POST repos/urzuahq/platform/rulesets --input - <<'EOF'
{"name":"main","target":"branch","enforcement":"active","bypass_actors":[],
 "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},
 "rules":[{"type":"deletion"},{"type":"non_fast_forward"},
  {"type":"pull_request","parameters":{"required_approving_review_count":0,
   "dismiss_stale_reviews_on_push":false,"require_code_owner_review":false,
   "require_last_push_approval":false,"required_review_thread_resolution":false}},
  {"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,
   "required_status_checks":[{"context":"ci","integration_id":15368}]}}]}
EOF
gh api -X POST repos/urzuahq/platform/rulesets --input - <<'EOF'
{"name":"version tags","target":"tag","enforcement":"active","bypass_actors":[],
 "conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},
 "rules":[{"type":"deletion"},{"type":"update"}]}
EOF
```

`integration_id` 15368 is GitHub Actions, as in urzua's and garita's rulesets.

### 6. Where urzua and garita differ

| | urzua | garita | Recommendation |
|---|---|---|---|
| Release App secrets unset | `prepare-release` fails red on every push (urzua ADR-95 §2) | both unset: a notice and no-op; one set: error | urzua's: the release path is not silent (ADR-71). A new adopter sets the secrets before calling the workflow. |
| Platforms tested | Linux only; releases macOS arm64 too | Linux and macOS; a platform is released only with a test job (RFC-4 §2) | garita's (R8). |
| Release asserts | archive count `>= 2` | binary reports the tag version; asset set equals the expected list | garita's (R8). |
| Event data in scripts | inlined `${{ }}` in some `run:` | through `env:` | garita's (R4). |
| Job timeouts on release build and upload | none | 30 and 10 minutes | garita's (R4). |
| Contract check | vendored checksums only, at `v1.0.0` | checksums, release `VERSION`, conformance runner | garita's (R11). |
| knope config check | `knope-closes-compat.test.sh` | `knope --validate` | both: they catch different faults. |
| Test sharding | 3 nextest + 4 acceptance shards (ADR-98) | one job | R13: both are right for their suite size. |
| Rust edition | 2021 | 2024 | 2024 (R14); urzua migrates in its own pull request. |
| Lints | `#![forbid(unsafe_code)]` per crate, `-D warnings` in CI | `[workspace.lints]`, `too_many_lines` at 100 | garita's (R14). |

## Repository layout

```
.github/workflows/      reusable workflows (GitHub only runs them from here) and this repo's ci.yml
ci/actions/<name>/      composite actions
ci/scripts/             scripts the actions run, each with a planted-violation test
ci/templates/           a caller ci.yml per language, kept passing by this repo's own ci
docs/rfc/               the platform record
.urzua/config.yaml      the records gate config
```

## Build order

Each unit lands with its tests and is adopted by one project before the next starts.

| # | Unit | Kind | First adopter | Risk |
|---|---|---|---|---|
| 1 | This repo's `ci.yml`: records gate, `ci-gate`, script tests; then the rulesets (§5) and tag `v0.1.0` | workflow, action | platform | low |
| 2 | `workflow-lint`: R2, R4, R5 and §3 over a caller's workflow files | reusable workflow | decision-agent-kit (fixes its BUG-222/223 class) | low |
| 3 | `ci-gate` for callers | action | agent-cli-kit (has no aggregate gate) | low |
| 4 | `install-knope`, `install-nextest`, `install-cargo-tools` with pin tests | actions | garita | medium |
| 5 | `agent-cli-contract.yml` | reusable workflow | garita, then urzua (its open contract fix) | medium |
| 6 | `changeset.yml` | reusable workflow | garita | medium |
| 7 | `rust.yml` (lint, build, test matrix, shards) | reusable workflow | garita, then urzua around its own acceptance and gate jobs | medium |
| 8 | `node.yml` | reusable workflow | decision-agent-kit | low |
| 9 | `prepare-release.yml` | reusable workflow, App secrets | garita | high: line-by-line review |
| 10 | `publish-release.yml` (verify, tag, build, attest, upload, assert) | reusable workflow, write tokens | garita, then urzua by hand patch | high: line-by-line review |
| 11 | a shared `install.sh` for released binaries | script | garita | medium |

## Open questions

1. **The differences in §6.** Recommendation: as the table says. Accepting the record accepts them
   unless the maintainer marks one.
2. **How this repository cuts its own versions.** Recommendation: tags by hand until unit 10 exists,
   then changesets and its own `prepare-release` and `publish-release`, so the release path is used
   here first.
3. **Which bot proposes pin bumps.** decision-agent-kit has a Renovate config; nothing else does.
   Recommendation: Renovate org-wide, with digest pinning for actions and reusable workflows.
4. **Release Apps: one per repository or one for the org.** urzua ADR-95 installs its App on urzua
   only. Recommendation: one per repository, so one key opens release PRs in one repository.
5. **Release rules for agent-cli-kit.** Its RFC-1 defines a release as a tag on `main`, cut by hand.
   Recommendation: it keeps hand-cut tags and adopts every rule except R6–R8, plus the tag ruleset of
   §5, since tools vendor its schemas by tag and commit.
6. **When urzua moves to edition 2024.** Recommendation: after its contract `v1.1.0` work, in its own
   pull request; not a precondition for adopting anything here.

## Non-goals

- Moving `urzua-gate` out of urzua.
- Deciding package registries (crates.io, npm); garita RFC-4 §5 defers that to an org decision.
- A release cadence.

> **Revision log**
>
> | Date | Change | Class |
> |---|---|---|
> | 2026-11-25 | R2 states that `push` carries `branches: [main]` and the banned filters are those on `pull_request` and `merge_group`; R9 states that a tag ruleset blocks update and deletion but never creation, as §3 and §5 already do. **Why:** review found each rule could be read against another part of this record; neither changes what a project must do. | **structural** |
| 2026-11-25 | `Status` set to `Accepted`. **Why:** the maintainer accepted the record. Their words, relayed from the URZUAHQ thread: "in terms of the platform PR 1, that is acceptable. Let's go merge that in and get started with the next steps." No row of §6 was marked, so its recommendations stand. Open questions 2 to 6 are accepted as recommended: hand-cut tags until `publish-release.yml` exists; Renovate org-wide; one release App per repository; agent-cli-kit keeps hand-cut tags and skips R6–R8; urzua moves to edition 2024 after its `v1.1.0` work, in its own pull request. | **substantive** |
