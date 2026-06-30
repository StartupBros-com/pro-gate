# Changelog

All notable changes to pro-gate are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions are git tags.

## [Unreleased] — v0.1.1 reliability hardening

Motivated by a live run where a transient WSL Chrome network-service crash (`net error -2`)
mid-review tripped `oracle-chrome.service`'s `Restart=always`, killed the review tab, and lost a
~10-30 min GPT-5.5 Pro Extended slot with no recovery — and a queued retry would have fired
unattended into the still-thrashing box.

### Added
- **Pre-slot health gate** (`pg_health_gate`): before spending a Pro Extended slot (and before each
  retry) the engine checks Chrome CDP reachability, `oracle-chrome` service uptime (not just-restarted
  / flapping), and RAM/swap headroom. An unfit box **defers with exit 8 and spends no slot** instead
  of burning one. Deliberately conservative — a full swap with ample free RAM does not block.
  Knobs: `PRO_GATE_MIN_UPTIME` (60s), `PRO_GATE_MIN_AVAIL_MB` (1024), `PRO_GATE_MAX_SWAP_PCT` (97).
- **Auto-salvage on dropped connection** (`pg_reattach_render`): when a run produces no output, a
  bounded (`timeout`-wrapped, never-hangs) `oracle session <slug> --harvest` attempts to recover an
  answer that completed server-side after the live connection dropped. Accepted only if it is a
  *complete* review (ends with `VERDICT:`) — a partial snapshot is rejected. `PRO_GATE_REATTACH_TIMEOUT`
  (150s).
- **One guarded auto-retry**: a truly-lost run (no output, nothing to salvage) is retried once, after
  a health re-check + backoff. The salvage step is the double-spend guard — a completed answer is
  recovered, never re-generated. `PRO_GATE_MAX_RETRIES` (1), `PRO_GATE_RETRY_BACKOFF` (20s).
- **Diff hygiene** (`pg_filter_diff`): lockfiles / generated / vendored / minified / snapshot paths
  are stripped from the review payload, so Pro Extended spends its (disconnect-exposed) thinking
  window on real code. On the motivating PR this cut the payload 3,685 → 630 lines. Off via
  `PRO_GATE_DIFF_FILTER=0`; override the match with `PRO_GATE_DIFF_EXCLUDE`.
- **Doctor surfaces fitness**: `pro-gate-doctor.sh` now reports service uptime and memory headroom,
  so it predicts a defer before you spend a slot.

### Changed
- `oracle-review.sh` exit codes are now meaningful: `0` success · `6` ran but empty after
  salvage+retry · `7` lock-wait timeout · **`8` deferred (unfit box, no slot spent)**. The `/pro-gate`
  skill documents how to act on each.

### Notes
- The underlying Chrome flake (network-service crash → full service restart losing the tab) is **not**
  fixed here; this pass makes the engine *survive* it without wasting slots. A tab-recovery watchdog +
  `oracle-chrome.service` resilience are tracked as a follow-up (Tier 3).

## [0.1.0] — initial release
- GPT-5.5 Pro Extended final-tier PR review via steipete/oracle, cross-platform (macOS native Chrome /
  WSL Xvfb Chrome over CDP), flock-serialized against the single ChatGPT account, tiered fixer
  (CE → codex → Claude Code), on-demand `/pro-gate` skill + set-and-forget `pro-review` label daemon.
