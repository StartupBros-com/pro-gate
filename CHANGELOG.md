# Changelog

Orientation layer for pro-gate's full history: what changed, when, why, and where to look
first. Scope window: 2026-06-29 → 2026-08-03 (complete history). Reconstructed 2026-08-03
from the full git log (66 non-merge commits), all 11 tags and GitHub Releases, the
VERSION-bump record, and the issue tracker. Release notes on individual GitHub Releases remain per-release; this file is the
durable cross-version record.

Conventions in this file:

- **Release** means a published GitHub Release (tag + assets + marketplace promotion).
- **Untagged** versions are real version numbers that shipped without a tag; the early ones
  lived on the operator's machine before the repo became the source of truth, and v0.22.0
  was bumped in-repo before the release chain existed.
- Every version from v0.23.0 onward was produced by the automated release chain and exists
  as a Release.

## Version Timeline

| Version | Date | Artifact | Theme |
|---|---|---|---|
| [v0.30.1](https://github.com/StartupBros-com/pro-gate/releases/tag/v0.30.1) | 2026-08-03 | Release | Hygiene close-out: consent stderr leak, run-log sweep allowlist, autoupdate.log bound, `.env` perms, salvage-window knob |
| [v0.30.0](https://github.com/StartupBros-com/pro-gate/releases/tag/v0.30.0) | 2026-08-03 | Release | Residuals close-out: daemon recoverable-state guard, scratch hygiene, memoized-URL recovery (plus the #58–#60 docs wave) |
| [v0.29.0](https://github.com/StartupBros-com/pro-gate/releases/tag/v0.29.0) | 2026-08-02 | Release | ChatGPT sidebar titling: run-naming prompt line |
| [v0.28.0](https://github.com/StartupBros-com/pro-gate/releases/tag/v0.28.0) | 2026-08-02 | Release | Capture provenance: nonce run-binding, early URL capture, immutable artifacts |
| [v0.27.0](https://github.com/StartupBros-com/pro-gate/releases/tag/v0.27.0) | 2026-08-01 | Release | `--status` run rediscovery, ledger identity fields |
| [v0.26.0](https://github.com/StartupBros-com/pro-gate/releases/tag/v0.26.0) | 2026-08-01 | Release | Convergence-based rounds policy, work-disposition rule |
| [v0.25.0](https://github.com/StartupBros-com/pro-gate/releases/tag/v0.25.0) | 2026-07-28 | Release | Tab-death recovery via remembered conversation URL |
| [v0.24.1](https://github.com/StartupBros-com/pro-gate/releases/tag/v0.24.1) | 2026-07-22 | Release | Direction-aware version precheck; launchd auto-update timer dropped |
| [v0.24.0](https://github.com/StartupBros-com/pro-gate/releases/tag/v0.24.0) | 2026-07-22 | Release | Cook-and-harvest oversized diffs; low-memory diagnosis |
| [v0.23.1](https://github.com/StartupBros-com/pro-gate/releases/tag/v0.23.1) | 2026-07-17 | Release | Follow the marketplace's declared plugin name |
| [v0.23.0](https://github.com/StartupBros-com/pro-gate/releases/tag/v0.23.0) | 2026-07-17 | Release | Automated release chain end to end |
| v0.22.0 | 2026-07-16 | Untagged (VERSION bump only) | Per-change round budget |
| [v0.21.0](https://github.com/StartupBros-com/pro-gate/releases/tag/v0.21.0) | 2026-07-17 | Release | First packaged, versioned runtime distribution |
| v0.11–v0.20 | 2026-07-02 → 07-11 | Untagged (pre-repo versions) | Salvage and resilience, run ledger, harvest and reservations |
| [v0.1.0](https://github.com/StartupBros-com/pro-gate/releases/tag/v0.1.0) | 2026-06-30 | Release | Bootstrap: engine, daemon, installer, doctor |

## Capability waves

### 1. Bootstrap: the final-tier gate (2026-06-29 → 06-30, v0.1.0)

The founding commit set: drive the web-only ChatGPT Pro reasoning model as an automated
last review tier on a PR, then route findings to a tiered fixer. Everything since is
hardening of this loop.

Delivered capability: `oracle-review.sh` engine, shared platform lib (macOS/WSL/Linux),
label-gated daemon, cross-platform installer with service templates, `pro-gate-doctor.sh`,
tiered fixer routing, portable locking, model-strategy auto-fallback.

Representative commits:
[c68a1e8](https://github.com/StartupBros-com/pro-gate/commit/c68a1e8) (engine),
[4beaad4](https://github.com/StartupBros-com/pro-gate/commit/4beaad4) (platform core),
[942759d](https://github.com/StartupBros-com/pro-gate/commit/942759d) (installer + doctor),
[cd736c0](https://github.com/StartupBros-com/pro-gate/commit/cd736c0) (model-strategy fallback).

### 2. Browser-drift resilience and salvage (2026-07-02 → 07-03, v0.11–v0.18.1, untagged)

ChatGPT UI drift broke oracle's thinking-detection and capture paths in production; this
wave made the browser the ground truth and built recovery around it. The repo also became
the source of truth here:
[0a5ef27](https://github.com/StartupBros-com/pro-gate/commit/0a5ef27) synced live daemon
versions v0.11–v0.14 back into git, which is why v0.2–v0.14 have no tags.

Delivered capability: CDP tab salvage, run-marker tab identity, strict review-completeness
checks, forced-retry safety (`--force`, probe-before-kill), fresh-tab render fallback for
dead renderers, throttle-aware salvage with cooldown files, machine-readable status JSON.

Representative commits:
[3bb5891](https://github.com/StartupBros-com/pro-gate/commit/3bb5891) (first CDP salvage),
[f20282c](https://github.com/StartupBros-com/pro-gate/commit/f20282c) (run-marker identity, v0.15),
[422b2a0](https://github.com/StartupBros-com/pro-gate/commit/422b2a0) (fresh-tab render, v0.17),
[8e0ace1](https://github.com/StartupBros-com/pro-gate/commit/8e0ace1) (throttle-aware salvage, v0.18).

### 3. Operations at scale: ledger and governor (2026-07-08 → 07-09, v0.19–v0.19.1, untagged)

Once runs were surviving, the problem became fleet behavior: how many runs, how fast, and
what actually happened. This wave added the run ledger every later analysis relies on.

Delivered capability: append-only run ledger, adaptive concurrency governor (earn
parallelism on clean streaks, drop on throttle), self-healing Chrome restart,
`pro-gate-stats.sh`; fixes for the archive/probe double-spend, GPT-5.6 verdict-format
tolerance, and Cloudflare challenge backoff.

Closed workstreams:
[#11](https://github.com/StartupBros-com/pro-gate/pull/11) (double-spend),
[#12](https://github.com/StartupBros-com/pro-gate/pull/12) (Cloudflare backoff),
[#13](https://github.com/StartupBros-com/pro-gate/pull/13) (verdict tolerance).

Representative commits:
[a5d94ba](https://github.com/StartupBros-com/pro-gate/commit/a5d94ba) (ledger + governor, v0.19),
[a2cfade](https://github.com/StartupBros-com/pro-gate/commit/a2cfade) (double-spend fix),
[10b9e24](https://github.com/StartupBros-com/pro-gate/commit/10b9e24) (Cloudflare backoff).

### 4. Harvest and reservations: spend protection (2026-07-10 → 07-11, v0.20–v0.21 era, untagged)

The Pro model can reason far longer than any caller can wait. This wave stopped treating
that as a loss: an interrupted run leaves a reservation and its review is collected later.
Exit 9 plus `--harvest` date from here, and spend protection became the engine's prime
directive.

Delivered capability: preserve-and-harvest for long-running reviews (exit 9), reservation
reconciliation with serialized harvests, repo-scoped reservations with slot-true capacity,
atomic runtime installs, leaked root-tab sweep, de-versioned model labels (capture the
resolved model at runtime), daemon self-reload on redeploy.

Representative commits:
[55c21a5](https://github.com/StartupBros-com/pro-gate/commit/55c21a5) (harvest),
[36ebf9d](https://github.com/StartupBros-com/pro-gate/commit/36ebf9d) (reconciliation),
[a1e958a](https://github.com/StartupBros-com/pro-gate/commit/a1e958a) (repo-scoped reservations),
[b1a1d54](https://github.com/StartupBros-com/pro-gate/commit/b1a1d54) (daemon self-reload).

### 5. Distribution and release automation (2026-07-15 → 07-18, v0.21.0 → v0.23.1)

pro-gate became an installable product: a packaged, versioned, checksummed runtime promoted
through the HOV marketplace, with the release chain automated end to end. The `VERSION`
file was born at 0.21.0; from v0.23.0 every VERSION bump auto-produces a tag, tested
release assets, and a marketplace promotion.
[#27](https://github.com/StartupBros-com/pro-gate/issues/27) records the era's main bug
(release train never fired for workflow-published releases), which is also why v0.22.0
exists only as a VERSION bump with no tag.

Delivered capability: versioned plugin runtime packaging, marketplace deploy key, checksum
verification from dist, auto-release chain (`auto-release.yml` → `release.yml` → release
train), marketplace-declared plugin name (`pro-gate@hov`), oracle version floor in the
doctor, gpt-5.6 model hint with select→current fallback, lead-paragraph release
announcements.

Closed workstreams:
[#22](https://github.com/StartupBros-com/pro-gate/pull/22),
[#25](https://github.com/StartupBros-com/pro-gate/pull/25),
[#27](https://github.com/StartupBros-com/pro-gate/issues/27),
[#28](https://github.com/StartupBros-com/pro-gate/pull/28).

Representative commits:
[f28b7b3](https://github.com/StartupBros-com/pro-gate/commit/f28b7b3) (packaged runtime),
[6ff616a](https://github.com/StartupBros-com/pro-gate/commit/6ff616a) (release chain, v0.23),
[c3f9367](https://github.com/StartupBros-com/pro-gate/commit/c3f9367) (marketplace name, v0.23.1).

### 6. Budgets and bounded loops (2026-07-16 → 07-17, v0.22.0, untagged)

Review→fix→re-review loops needed a governor: a per-change budget of slot-spending rounds
per rolling window (default 4 per 24 h, exit 12 above it, no spend), with loud flagging
when the budget refuses a run that has an unconfirmed open P0. The confirming pass
(`--confirm`: verify every prior P0/P1 as RESOLVED or STILL-PRESENT) was hardened in the
same wave through two dogfood gate rounds.

Representative commits:
[f049eb7](https://github.com/StartupBros-com/pro-gate/commit/f049eb7) (round budget, v0.22),
[821d353](https://github.com/StartupBros-com/pro-gate/commit/821d353) (open-P0 flag),
[88e560d](https://github.com/StartupBros-com/pro-gate/commit/88e560d) (confirming-pass gaps).

### 7. Large diffs and low memory (2026-07-21 → 07-22, v0.24.0 → v0.24.1)

Oversized diffs flipped from refuse-at-6000-lines to cook-and-harvest: the run proceeds and
lands as an in-progress harvest, and only past the hard ceiling (25,000 lines) does the
engine refuse without spend. Low-memory hosts got honest OOM diagnosis. v0.24.1 is a
deliberate subtraction: a macOS launchd auto-update timer was built, gate-reviewed twice,
and then dropped as too fragile for a distributable; the lesson is written up in
[#43](https://github.com/StartupBros-com/pro-gate/pull/43) (ship the legible core, decline
fragile automation). [#37](https://github.com/StartupBros-com/pro-gate/issues/37) made the
version-mismatch precheck direction-aware.

Representative commits:
[c1abb51](https://github.com/StartupBros-com/pro-gate/commit/c1abb51) (cook-and-harvest, v0.24),
[20e9b5b](https://github.com/StartupBros-com/pro-gate/commit/20e9b5b) (OOM diagnosis),
[7f0cfc6](https://github.com/StartupBros-com/pro-gate/commit/7f0cfc6) (timer dropped, v0.24.1).

### 8. The recovery-correctness campaign (2026-07-28 → 08-02, v0.25.0 → v0.29.0)

A ledger-driven usage analysis (723 runs) showed salvage had become the primary capture
path and that runs were being falsely declared lost. Five releases in six days rebuilt
recovery on positive evidence instead of heuristics; each PR was itself reviewed through
the Pro gate it modifies.

Delivered capability, by release:

- **v0.25.0**: recover reviews whose tab died by remembering the conversation URL at
  submission instead of equating "no open tab" with "review lost"
  ([#44](https://github.com/StartupBros-com/pro-gate/pull/44),
  [f65acf7](https://github.com/StartupBros-com/pro-gate/commit/f65acf7)).
- **v0.26.0**: convergence-based rounds policy (continue while findings strictly shrink,
  stop on oscillation), explicit work-disposition rule (committed work stays at any stop;
  the gate never reverts as a budget response), engine-first lost-run recovery, active-run
  index ([#46](https://github.com/StartupBros-com/pro-gate/issues/46),
  [#51](https://github.com/StartupBros-com/pro-gate/pull/51),
  [45b8eae](https://github.com/StartupBros-com/pro-gate/commit/45b8eae)).
- **v0.27.0**: `--status` read-only run rediscovery (answers "what runs exist, what do I
  harvest, how many rounds remain" from a bare PR number), marker and round-key identity in
  the ledger ([#47](https://github.com/StartupBros-com/pro-gate/issues/47),
  [#53](https://github.com/StartupBros-com/pro-gate/pull/53),
  [b1b7d22](https://github.com/StartupBros-com/pro-gate/commit/b1b7d22)).
- **v0.28.0**: positive capture provenance. Every run embeds a nonce the model echoes on
  its verdict line; browser-matched captures are accepted nonce-or-nothing by default.
  Early conversation-URL capture per attempt, an immutable completed-artifact store with a
  durability ladder, idempotent harvests
  ([#48](https://github.com/StartupBros-com/pro-gate/issues/48),
  [#55](https://github.com/StartupBros-com/pro-gate/issues/55),
  [#56](https://github.com/StartupBros-com/pro-gate/issues/56),
  [#54](https://github.com/StartupBros-com/pro-gate/pull/54),
  [3e8cc3f](https://github.com/StartupBros-com/pro-gate/commit/3e8cc3f)).
- **v0.29.0**: review chats open by naming the PR, round, and repo, so ChatGPT sidebar
  titles identify each run; monotonic per-change round ordinals survive rollbacks
  ([#49](https://github.com/StartupBros-com/pro-gate/issues/49) phase 1,
  [#57](https://github.com/StartupBros-com/pro-gate/pull/57),
  [b2eb3c4](https://github.com/StartupBros-com/pro-gate/commit/b2eb3c4)).

### 9. Announcements, documentation, and residuals close-out (2026-08-02 → 08-03, v0.30.0)

Release announcement cards stopped being identical: the release train now derives
card-ready "What's new" bullets from each release body (an author-written `## Highlights`
section wins), and the README was rebuilt value-first with the full engine command and
exit-code reference. v0.30.0 then closed the standing residuals: the daemon consults
`--status --json` and skips fail-counting engine states that are recoverable, run scratch
dirs are cleaned on exit (with a backfill sweep for pre-trap leaks), and an exit-6 run
that remembered its conversation URL prints the exact free `--harvest` command. The first
v0.30.0 tag failed CI on a test-environment flake (a test reaching the real default CDP
port, absent on CI); [#62](https://github.com/StartupBros-com/pro-gate/pull/62) pinned the
mock port and the release chain went green.

Representative commits:
[8077d12](https://github.com/StartupBros-com/pro-gate/commit/8077d12) (card bullets, [#58](https://github.com/StartupBros-com/pro-gate/pull/58)),
[5d3e47e](https://github.com/StartupBros-com/pro-gate/commit/5d3e47e) (README revamp, [#59](https://github.com/StartupBros-com/pro-gate/pull/59)),
[9020281](https://github.com/StartupBros-com/pro-gate/commit/9020281) (residuals close-out, [#61](https://github.com/StartupBros-com/pro-gate/pull/61)),
[cf59d37](https://github.com/StartupBros-com/pro-gate/commit/cf59d37) (release-test fix, [#62](https://github.com/StartupBros-com/pro-gate/pull/62)).

### 10. Hygiene close-out and salvage-window decoupling (2026-08-03, v0.30.1)

A post-v0.30.0 field audit (22 production runs in the first day: zero regressions, both
exit-9 runs harvested clean) surfaced a handful of small residuals this release closes:
`pg_dangerous_consent_ok` no longer leaks a raw bash "No such file or directory" to stderr
when the consent file is absent (redirect-order bug — `2>/dev/null` cannot catch a failed
`<` open listed before it); the run-log sweep matches an allowlist of run-log shapes
(`pg-run-*` plus the pre-v0.27 epoch-suffixed names) so pre-v0.27 logs finally retire while
`autoupdate.log` and the launchd daemon's open `daemon.{out,err}.log` are structurally
unmatched; `autoupdate.log` is bounded by the new `pg_trim_file` helper, only while the updater's
singleton lock is actually held (lock losers announce the skip on stderr without touching
the log; no-flock platforms never trim); `.env` is installed owner-only (a failed `chmod 600` now aborts
the install before the version stamps land) and the doctor warns when it is
group/other-readable. The non-live salvage window became its own knob
(`PRO_GATE_SALVAGE_SECS`, default: follows `PRO_GATE_STALL_SECS` as before) so the stall
watchdog can be tuned without silently halving recovery windows. Two candidate cleanups
were deliberately REJECTED by the gate's own two-round review of this change:
`title-seq/` counters stay unswept (documented monotonic-ordinal invariant, gate #57 r4 —
pruning one would re-title a post-idle round r1 beside the old r1 conversation), and the
multi-writer salvage blacklist stays append-only (a read→rename compaction can drop a
concurrent bash/Node append without one cross-platform lock shared by every writer;
~16KB/week does not earn that machinery). Comments calling CDP salvage "defense-in-depth"
were updated to match observed reality (100% of clean runs 2026-07-22 → 08-03 landed via
salvage/harvest; oracle 0.17.0 restored primary capture for runs that finish inside the
stall fuse).

## Notes for agents

- **Start with the caller contract, not the code.** `skills/pro-gate/SKILL.md` is the
  authoritative caller guide (exit codes, recovery semantics, round policies);
  `bin/oracle-review.sh` is the engine; the two change in the same PR by convention.
- **The engine's exit codes are the API.** 0 review, 8 deferred without spend, 9 harvest
  later, 11 oversized, 12 round-capped; full table in the README.
- **For any lost or unclear run, `oracle-review.sh --status <pr>` first.** It joins
  reservations, round budget, remembered URLs, and the ledger, and prints the exact next
  command.
- **History habit to know:** since v0.22 nearly every feature PR was dogfooded through the
  Pro gate it modifies, and the gate's findings landed as follow-up commits in the same PR
  (subjects like "address the Pro gate's findings…"). Reading a PR's commit sequence shows
  you the reviewed evolution, not just the end state.
- **Open residuals** as of 2026-08-03:
  [#31](https://github.com/StartupBros-com/pro-gate/issues/31) (gate deferrals needing
  human decision), [#35](https://github.com/StartupBros-com/pro-gate/issues/35) (manual
  OOM recovery hint), [#39](https://github.com/StartupBros-com/pro-gate/issues/39) (macOS
  launchd timer follow-up), [#41](https://github.com/StartupBros-com/pro-gate/issues/41)
  (version-drift design), [#50](https://github.com/StartupBros-com/pro-gate/issues/50)
  (hygiene batch), [#52](https://github.com/StartupBros-com/pro-gate/issues/52) (engine
  follow-ups, partially closed by v0.28).
