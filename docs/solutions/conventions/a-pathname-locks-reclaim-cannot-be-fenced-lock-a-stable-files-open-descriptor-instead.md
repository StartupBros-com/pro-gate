---
title: "A pathname lock's reclaim cannot be fenced; lock a stable file's open descriptor instead"
module: "pro-gate"
date: "2026-09-21"
category: "conventions"
problem_type: "design_pattern"
component: "development_workflow"
severity: "high"
applies_when:
  - "implementing mutual exclusion with a pathname-based lock (mkdir, lock directory, or plain rename) that includes any reclaim-of-a-dead-owner path"
  - "the target platform offers an advisory-lock primitive (flock, fcntl) that can be held on a stable, never-unlinked file"
  - "the set of lock keys is open-ended (one lock per fingerprint or id) and would otherwise need one dedicated lock file per key"
  - "extending a single-crashed-owner lock design to survive two concurrent reclaimers racing the same dead lock"
  - "a prune or reap sweep can run concurrently with lock acquisition on the same key"
symptoms:
  - "two reclaimers both pass a lock's liveness or staleness check and both believe they own the reclaimed lock"
  - "a delayed reclaimer's rename-aside silently relocates a different, live lock that was re-created at the same path after an earlier reclaim"
  - "a prune or reap pass removes a lock file that a legitimate acquirer is concurrently re-creating"
  - "the count of on-disk lock files grows without bound as distinct keys accumulate"
tags:
  - "pro-gate"
  - "flock"
  - "advisory-lock"
  - "pathname-lock"
  - "lock-reclaim"
  - "race-condition"
  - "slot-pool"
  - "mutual-exclusion"
---

# A pathname lock's reclaim cannot be fenced; lock a stable file's open descriptor instead

## Context

pro-gate's throttle-seen sidecar dedupes repeated sightings of a stale ChatGPT throttle modal by
recording a per-fingerprint file (one file per `(url, text-hash)` pair) that suppresses re-charging
a cooldown until the record's TTL expires. That created a mutual-exclusion problem: the prune path
that expires an old record for a fingerprint and the claim path that admits a new sighting of the
*same* fingerprint can run concurrently, and without a lock between them a delayed prune can delete
a fresh record a concurrent claim just wrote, or a claim can read "no record" a moment before a
racing writer creates one and silently lose its own write. PR #215's paid-review round 9 first
closed this with a pathname lock: `mkdirSync` as a mutex, reclaimed when stale by mtime plus a
liveness-checked owner token — the same shape the project already used elsewhere for dead-owner
lock reclaim (see the sibling doc in Related).

Round 10 found that shape insufficient, reproduced by the reviewer: two reclaimers can both
validate the same dead lock as dead, and after the faster one (B) renames it aside and re-creates a
live lock at the same pathname, a delayed reclaimer's (A's) rename lands on B's *live* lock instead
of failing with `ENOENT` — so A deletes a live lock and enters the protected section concurrently
with its own winner. `pruneThrottleSeen`'s own lock-reap repeated the identical check-then-rename
race. The fix comment records the conclusion directly: no amount of fencing on a pathname primitive
closes this, because reclaim is itself a pathname operation — the only fix is to stop reclaiming
pathnames and hand the mutex to the kernel (`bin/cdp-salvage.mjs:541-548`).

## Guidance

Replace a reclaimable pathname lock with an OS advisory lock (`flock(2)`) on a stable file that is
opened, never written, and never unlinked. The shipped shape in `withThrottleSeenLock`
(`bin/cdp-salvage.mjs:568-611`), abridged:

```js
function withThrottleSeenLock(name, fn) {
  try { fs.mkdirSync(THROTTLE_SEEN_DIR, { recursive: true }); } catch {}
  const lockPath = path.join(THROTTLE_SEEN_DIR, throttleSeenLockSlot(name));
  let fd = null;
  try {
    try {
      fd = fs.openSync(lockPath, 'a');           // created if missing, never written, never unlinked
    } catch (err) {
      console.error(`throttle-seen lock file unavailable for ${name} (${err?.code ?? err}); proceeding without it (fail-open)`);
    }
    if (fd !== null) {
      let result;
      try {
        result = spawnSync('flock', ['-x', '-w', THROTTLE_SEEN_LOCK_WAIT_SECS, '3'], {
          stdio: ['ignore', 'ignore', 'pipe', fd],   // fd inherited as fd 3
        });
      } catch (err) { result = { error: err }; }
      if (result.error) {
        // ENOENT (no flock binary, e.g. macOS): fixed fact about the host, warn once per process
        if (!throttleSeenFlockMissingWarned) { throttleSeenFlockMissingWarned = true; /* ... */ }
      } else if (result.status !== 0) {
        // status 1 = the -w timeout: contended past budget, fail open
      }
      // status === 0: acquired — the exclusive lock lives on the open file description `fd`
    }
    return fn();
  } finally {
    if (fd !== null) { try { fs.closeSync(fd); } catch {} }   // this IS the release
  }
}
```

Key behaviors, each cited at the current tree:

- **Open, never unlink.** `fs.openSync(lockPath, 'a')` creates the file if missing but never
  writes or deletes it (`bin/cdp-salvage.mjs:574`); there is nothing to reclaim because a crashed
  holder's lock is released by the kernel the instant the process dies
  (`bin/cdp-salvage.mjs:549-553`).
- **Inherit the fd into the lock utility, hold on the description.** `flock -x -w <secs> 3` is
  spawned with the open fd passed through `stdio` as fd 3 (`bin/cdp-salvage.mjs:583-585`); the
  exclusive lock is associated with the *open file description*, which the parent process retains
  after the child exits, so the lock is held by this process regardless of the short-lived `flock`
  child (`bin/cdp-salvage.mjs:554-558`, `:601-602`).
- **`finally`-only release.** `fs.closeSync(fd)` in the `finally` block is the sole release path
  (`bin/cdp-salvage.mjs:605-609`).
- **Slot mapping bounds the key space.** `THROTTLE_SEEN_LOCK_SLOTS = 64` (`bin/cdp-salvage.mjs:535`)
  and `throttleSeenLockSlot(name)` maps a fingerprint's basename to `lock-NN.lockf` by taking the
  last 32 bits of its sha256 hex mod 64 (`bin/cdp-salvage.mjs:536-540`). Both admission
  (`claimThrottleSeen`, `bin/cdp-salvage.mjs:777`) and removal (`removeThrottleSeenGeneration`,
  `bin/cdp-salvage.mjs:640`) call `withThrottleSeenLock` with the same fingerprint name, so the same
  fingerprint is always serialized against itself; two different fingerprints sharing a slot merely
  serialize against each other for the microseconds a critical section lasts, and no lock in the
  file is ever held while acquiring another, so shared slots cannot deadlock
  (`bin/cdp-salvage.mjs:525-534`).
- **The pruner treats `.lockf` names as neither record nor temp.** `throttleSeenIsLockFile(name)`
  (`bin/cdp-salvage.mjs:524`) is checked first in `pruneThrottleSeen`'s scan loop, before any
  `statSync`, so the fixed 64-file pool bounds prune work regardless of lifetime fingerprint history
  (`bin/cdp-salvage.mjs:695`, the `if (throttleSeenIsLockFile(name)) continue;` line inside the loop; the function starts at `:682`).
- **Fail-open on both failure modes.** A timeout (`flock` exit 1, or a killed child) logs and
  proceeds without the lock (`bin/cdp-salvage.mjs:597-600`); a missing `flock` binary (`spawnSync`
  `ENOENT`) also proceeds without it but warns only once per process, since a missing binary is a
  fixed host fact rather than a per-fingerprint one (`bin/cdp-salvage.mjs:589-596`). Every sidecar
  path in the file follows this fail-open rule (`bin/cdp-salvage.mjs:559-560`).
- **The `'wx'` create remains the race arbiter under the lock, not a replacement for it.**
  `recordThrottleSeen` creates with the `'wx'` flag and reports whether *its own* write won
  (`bin/cdp-salvage.mjs:739-752`). `claimThrottleSeen` runs its stat-then-create sequence inside
  `withThrottleSeenLock` (`bin/cdp-salvage.mjs:777-798`); admission checks the record's *age*
  under the lock, not just existence, and only treats an unlink failure as the fail-open charge case
  when that failure is not `ENOENT` — an `ENOENT` on the expired-record unlink means a concurrent
  writer already removed it, not a failed expiry (round 12, `bin/cdp-salvage.mjs:793`).

## Why This Matters

A pathname-based reclaim (mkdir-as-mutex, delete-and-recreate when the owner looks dead) can never
be made race-free by adding more checks to the reclaim decision, because the reclaim *action itself*
is a second pathname operation racing the first: proving a lock dead and then acting on that proof
are two separate filesystem calls, and anything can happen to the pathname between them — including
a legitimate winner recreating a live lock there. Round 10's reproduction showed the concrete
failure: a delayed reclaimer's rename lands on the winner's fresh lock instead of failing closed.
Moving the mutex into the kernel via `flock(2)` on a file that is never deleted removes the entire
state class this bug lived in — "stale lock" stops being a state, because the kernel drops the
`flock` the instant the holding process's last fd on that open file description closes (on exit or
on `SIGKILL`), with no window for another process to observe a lock as dead while still needing to
prove it.

The fixed 64-slot pool exists because the fingerprint key space is unbounded (one lock file per
distinct `(url, hash)` pair would grow forever and get stat'ed on every prune) but the file only
needs to serialize *concurrent* operations on the *same or colliding* fingerprint, not preserve a
lock file per fingerprint that was ever seen. The cost model: shared-slot contention only serializes
two different fingerprints for the duration of one critical section (microseconds), and the wait
budget itself (`THROTTLE_SEEN_LOCK_WAIT_MS = 250`, `bin/cdp-salvage.mjs:565`) bounds how long any
single claim or prune can block before it falls back to fail-open behavior — a fixed, small latency
cost purchased in exchange for eliminating an entire class of lost-write and double-charge races.

## When to Apply

- A sidecar or cache directory needs per-key mutual exclusion between two operations that read,
  expire, and (re)write the same on-disk record (a prune/expire path and a claim/admit path for the
  same key).
- The existing or considered lock implementation is a pathname primitive (`mkdir` as mutex, a lock
  *directory* or *file* that gets deleted and recreated) with any "is the owner dead" reclaim logic
  layered on top — this is the smell that predicts the round-10 class of bug, not just a specific
  reported failure.
- The key space is unbounded or grows with history (per-fingerprint, per-URL, per-session) and a
  literal one-lock-file-per-key scheme would itself become an unbounded resource the sidecar's own
  prune has to scan.
- `flock` availability is not guaranteed on every target platform (macOS ships no `flock`
  binary by default) — the fail-open behavior, not a portability shim, is the intended answer; see
  `lib/pro-gate-lib.sh`'s `pg_lock` for the sibling case that already branches on `flock`
  availability with a still-reclaim-based fallback.

## Examples

**Before (round 9): a reclaimable pathname lock.** `mkdirSync` created the lock directory; when a
waiter found it already present, it checked the owner's mtime and a liveness-checked token, and if
the owner looked dead, renamed the directory aside and removed it before retrying the mkdir. Two
reclaimers could each independently conclude the same lock was dead and each act on that conclusion
— the delayed one's rename-then-remove could land on the fast one's freshly recreated *live* lock
(round 10 finding, reproduced by the reviewer; per the PR #215 review record).

**After (shipped): a kernel-held advisory lock on a stable file.** `withThrottleSeenLock` opens
`lock-NN.lockf` with `'a'`, spawns `flock -x -w 0.250 3` against the inherited fd, and releases only
by `closeSync` in `finally` (`bin/cdp-salvage.mjs:568-611`). There is no reclaim step because there
is no state to reclaim from.

**Churn numbers from the regression suite** (`tests/cdp-salvage.test.mjs`, blocks tagged `#215 gate
r10 P2` and `#215 gate r11 P2`): a `SIGKILL`ed lock holder releases the lock for the next claim on
the same fingerprint in well under the 250 ms wait budget, versus waiting out the full budget under
the old staleness check (`'#215 gate r10 P2 (c) the very next claim on the same fingerprint proceeds
near-instantly after a SIGKILL, not after the 250ms wait budget'`); a missing `flock` binary prints
its warning exactly once despite two lock attempts in the same run (`'#215 gate r10 P2 (d) the
missing-binary note prints exactly once despite two lock attempts (prune + admission)'`); 200
distinct fingerprints each charge once and leave one record each, while the lock-file count never
exceeds the fixed 64-slot pool, and a prune never `stat`s a `.lockf` name (skipped by name first)
(`'#215 gate r11 P2 (a)'` block, `N_R11 = 200`); a fingerprint sharing a held slot waits the budget
and fails open naming itself, while a fingerprint mapped to a different slot is not delayed at all
(`'#215 gate r11 P2 (b)'` block).

**What green does not prove:** the suite exercises real child processes and real `SIGKILL` timing
on this host's filesystem, but it does not establish `flock` semantics on a network filesystem
(NFS's `flock` support is notoriously inconsistent), behavior under `ENOSPC` while creating the lock
file itself, or true multi-process timing under contention beyond the fixed wait budget the tests
exercise.

## Related

- `./a-dead-owner-lock-reclaim-must-prove-death-not-infer-it-from-absence.md` — the sibling
  convention this learning extends: that doc catalogs ways a *reclaim-based* mkdir spinlock gets
  dead-owner detection wrong; this learning is the case where the answer was to stop reclaiming
  pathnames entirely rather than fix the reclaim check.
- PR #215 (merged) — introduced the throttle-seen per-fingerprint lock across rounds 9–12,
  including the flock rewrite, the fixed slot pool, and the age-aware admission fix.
- PR #219 / release v0.54.0 (merged, published 2026-09-21) — ships PR #215's fix.
- Issue #208 (closed) — the original stale-throttle-modal cooldown re-arm problem the throttle-seen
  sidecar and its locking exist to solve.
- Issue #217 (open) — follow-on design work for retire-on-healthy stale-fingerprint handling,
  tracking constraints this PR's attempt surfaced.
- `lib/pro-gate-lib.sh` `pg_lock` (`lib/pro-gate-lib.sh:306-313`) — the project's other cross-process
  lock helper: uses `flock` when present exactly like this fix, but its no-`flock` fallback is still
  a reclaim-based `mkdir` spinlock governed by the sibling doc above, not this file's slot-pool
  approach.
