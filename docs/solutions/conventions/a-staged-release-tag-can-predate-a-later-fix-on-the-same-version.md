---
title: "A staged release tag can predate a later fix on the same version"
module: "pro-gate"
date: "2026-09-04"
category: "conventions"
problem_type: "workflow_issue"
component: "development_workflow"
severity: "high"
applies_when:
  - "a CI workflow auto-tags or auto-releases the first push whose version file has no matching tag"
  - "the tagging/release trigger is deliberately idempotent or tag-absent guarded (does not re-fire on later pushes at the same version)"
  - "a draft or staged release is built once and held for a manual publish/repin step"
  - "a live pre-release or human review step can surface fixes after the version has already been tagged"
tags:
  - "pro-gate"
  - "release-pipeline"
  - "auto-release"
  - "staged-draft-release"
  - "tag-immutability"
  - "version-bump"
  - "ci-blind-spot"

---

# A staged release tag can predate a later fix on the same version

## Context

`.github/workflows/auto-release.yml` tags any push to `main` whose `VERSION` (and
`.claude-plugin/plugin.json`, which must match it) has no corresponding `vX.Y.Z` tag yet. The tag
push triggers `.github/workflows/release.yml`, which reruns the full test battery on the tagged
commit, packages the runtime, checksums it, and (per `scripts/publish-runtime-release.sh`'s
draft-first design) stages a **draft** GitHub release rather than publishing immediately — publish
is a separate, later step gated on the marketplace card naming the release.

The tag-absent check is deliberate and documented in the workflow's own header: "the tag-absent
guard makes the workflow idempotent and self-healing: a merge that failed to release is retried by
the next push" (`.github/workflows/auto-release.yml:13`). That design is correct for its stated
purpose — a release that failed partway through (packaging, publish, marketplace train) gets retried
without operator intervention. It has an unstated consequence: once a version has *any* tag, the
workflow treats that version as spoken for and will never tag it again, no matter what lands on
`main` afterward at the same `VERSION`.

PR #137 merged `feat: --brief, a custom task body for the Pro slot` with `VERSION=0.39.0`. Eight
seconds later `auto-release.yml` tagged that commit and `release.yml` staged a `v0.39.0` draft
release, built and checksummed from that exact tree. A live pre-release run (spending a real
Pro-model review slot, not the stub oracle the PR had been verified against) then returned
`FIX-FIRST` with three design defects in `--brief`, tracked as #138 and fixed in PR #139 (`fix:
harden --brief after a live pre-release run returned FIX-FIRST`). Because `auto-release.yml` is
tag-absent guarded, merging #139 did not re-tag: `VERSION` was still `0.39.0`, and `v0.39.0` already
existed. The staged `v0.39.0` draft kept holding the **pre-fix** build while
the then-current `v0.39.0` release-notes file in the repo already described the fixed behavior (it was renamed to `docs/release-notes/v0.39.1.md` when 0.39.1 was cut). Every individual
PR was green; nothing in CI asks whether a staged artifact still matches the version's current state
on `main`. It was caught only at release preflight, by dereferencing the tag and grepping its blob
for the expected fix — not by any automated gate.

## Guidance

### A tag is a snapshot, not a live pointer to "the current state of this version"

Treat `vX.Y.Z` as frozen the instant it's created, even under an idempotent/self-healing auto-tag
workflow. "Self-healing" here means *retries an incomplete release*, not *tracks later commits at
the same version*. Any fix that lands after the tag exists is invisible to everything the tag
already produced (built artifacts, checksums, draft release) until a human or process re-points or
re-cuts.

### At release preflight, verify what the tag actually built, not that it exists

Before running a publish step against a staged draft, dereference the tag and check its content for
the change you expect (`git show <tag>:path | grep ...`), rather than trusting that the tag tracks
`main` or that a passing CI run at merge time is still representative. This is the one check that
caught the gap in this incident, and no workflow file performs it automatically.

### Prefer cutting a new version over moving an existing tag

Once `release.yml` has built and checksummed assets against a tagged commit, moving that tag to a
newer commit creates exactly the kind of sha/tag/asset identity mismatch this repo's own release
guards (the tag/manifest/`VERSION` triple-check in `scripts/package-runtime.sh:12`) exist to reject.
A new patch version is cheaper than re-establishing that identity. PR #140 cut `0.39.1` rather than
moving the `v0.39.0` tag: `VERSION` and `.claude-plugin/plugin.json` both bumped (packaging hard-fails
on a mismatch between them — see below), the `v0.39.0` release-notes file was renamed to
`docs/release-notes/v0.39.1.md` unchanged (it already described the fixed behavior, which is what
would actually ship),
and the stale `v0.39.0` draft was deleted **without** `--cleanup-tag`, so the tag survives as an
accurate historical marker of where `VERSION` was `0.39.0` — just not something a publish step should
ever act on again.

### Every version-bump PR must move VERSION and the plugin manifest together

`VERSION` and `.claude-plugin/plugin.json`'s `version` field must agree, or `scripts/package-runtime.sh`
exits nonzero with `release version mismatch: tag=... VERSION=... manifest=...`
(`scripts/package-runtime.sh:12-14`). `tests/distribution.test.sh` invokes packaging unconditionally
near the top of the file and never checks its exit status — the suite runs under `set -uo pipefail`
with no `-e` (`tests/distribution.test.sh:2`), and the packaging call at
`tests/distribution.test.sh:15` isn't itself an assertion. So a bump that touches only `VERSION`
doesn't fail with one clear "you forgot the manifest" message: packaging silently produces no
archive, and every later check in the file that depends on that archive or the runtime installed
from it cascades to `FAIL`, one at a time, none of them mentioning the manifest. One session's
bump-only-`VERSION` run reportedly turned up dozens of failures across the file's 106 checks this
way, all looking unrelated to the actual single-line cause. When this suite fails broadly and
immediately, check `VERSION` against `.claude-plugin/plugin.json` before reading past the first
handful of failures — the real defect is upstream of nearly all of them.

## Applicability

- Any CI pipeline that auto-tags or auto-releases on a version-file bump, especially one designed to
  be idempotent/self-healing against partial-release failures — that design guarantees it will *not*
  retag when a later commit at the same version fixes something the first tag already shipped.
  Direct analogue: `.github/workflows/auto-release.yml` + `.github/workflows/release.yml`.
- Any draft-first / staged-release pattern where assets are built once and held pending a manual or
  gated publish step (`scripts/publish-runtime-release.sh`'s draft-first design,
  `.github/workflows/publish-staged-release.yml`) — the staleness window is exactly the time between
  staging and publish, and nothing shortens it automatically.
- Any packaging or build step whose precondition check (a version-triple match, a required file, a
  schema) is invoked without checking its exit code inside a test harness — the resulting failure
  mode is a wall of downstream FAILs that obscure the one upstream cause
  (`tests/distribution.test.sh`'s unguarded `package-runtime.sh` call is the concrete example here).

