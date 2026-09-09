---
title: "A dead-owner lock reclaim must prove death, not infer it from absence"
module: "pro-gate"
date: "2026-09-08"
category: "conventions"
problem_type: "design_pattern"
component: "development_workflow"
severity: "high"
applies_when:
  - "implementing a self-healing directory-based (mkdir) spinlock that must reclaim a lock left by a dead owner"
  - "a liveness check can transiently fail to read process state (/proc, ps) for a process that is genuinely still alive"
  - "a lock's marker write happens after its directory create, leaving a window where the directory exists but is not yet attributable to an owner"
  - "extracting a shared timeout or config helper for one call site while a sibling call site keeps its own duplicated literal"
symptoms:
  - "a reclaimed lock directory ends up simultaneously marked by two owners (owner.1111 and owner.2222 both present)"
  - "acquire spins at 100% CPU past its own configured wait bound when mkdir fails for a reason other than EEXIST"
  - "a guard wedges permanently once the OS reuses a dead owner's pid for an unrelated live process"
  - "a live owner's directory and marker are removed (reclaim reports rc=0) after a transient liveness-check read failure, not an actual death"
tags:
  - "pro-gate"
  - "mkdir-spinlock"
  - "dead-owner-reclaim"
  - "self-heal"
  - "concurrency"
  - "pid-reuse"
  - "fail-closed"
  - "liveness-check"
---

# Four ways to get a mkdir-spinlock dead-owner self-heal wrong

## Context

pro-gate serializes reservation writes against review-slot acquisition with a single guard,
`pg_reservation_guard_acquire`/`pg_reservation_guard_release`. Its own docstring states why this
matters: it makes "an exit-9 run writes its durable reservation while it still owns the process
slot" atomic, so "no waiter can observe 'slot released, reservation not counted' (or compute
capacity before the write and acquire the just-released slot on stale information)"
(`lib/pro-gate-lib.sh:1107-1110`). Two simultaneous holders of this guard is a top-severity defect:
it lets two runs both believe they own the account's single review slot.

On Linux this guard is `flock`-based (`lib/pro-gate-lib.sh:1114-1125`, current tree). The fallback
path -- for macOS's stock `bash` 3.2, which has no `flock` -- is a `mkdir` spinlock. As checked out
on `main` as this was written -- after PR #148 merged, and with PR #178 still open -- that fallback
has **no dead-owner reclaim at all**: a stale directory just wedges every waiter for the configured
wait (ten seconds by default) and then acquisition fails
(`lib/pro-gate-lib.sh:1126-1145`):

```sh
PG_RESERVATION_GUARD_DIR="${lock}.d"
local waited=0
while ! mkdir "$PG_RESERVATION_GUARD_DIR" 2>/dev/null; do
  waited=$(( waited + 1 ))
  [ "$waited" -ge "$wait_s" ] && { PG_RESERVATION_GUARD_DIR=""; return 1; }
  sleep 1
done
```

That is deliberate rather than an oversight: the merged change carries a comment saying self-healing
this path "is deliberately NOT in this release", because the mechanism "needs dead-owner detection
that tolerates pid reuse, an orphan grace so a live contender is not reclaimed between its mkdir and
its marker, and removal that can never touch a replacement directory; every one of those was gotten
wrong at least once, in six consecutive review rounds." Those are the four rules below.

PR #148 set out to add self-healing here -- reclaim a guard directory whose owner process died.
That work would not converge: per the PR #178 commit message that eventually split it out, "six
consecutive review rounds each found a NEW defect here, twice because a fix introduced the next
one." Two of those instances are directly traceable in the review history: a comment written to
justify round 2's fix asserted a safety property that round 3's review disproved by reproduction,
and round 3's own fix for the pid-reuse hazard introduced the exact fail-open bug round 8 later
found. This doc is the four rules that sequence converged on, each one a rule a future
directory-lock implementation should check itself against before it ships, not after a round finds
it missing.

The two siblings this guard was modeled on, `pg_lock` (`lib/pro-gate-lib.sh:286-309`) and
`pg_lock_n` (`lib/pro-gate-lib.sh:316-361`), are live in the current tree and still carry two of the
four defects described below -- tracked separately as #152/#155.

## Guidance

Four rules for any mkdir-spinlock dead-owner reclaim, each one a round of PR #148 review paid for:

### 1. An unmarked lock directory is not an orphan yet

A contender that just won `mkdir` is, for a brief window, indistinguishable from an abandoned
directory: it has no owner marker yet. A reclaimer that treats "no marker" as "abandoned" can
`rmdir` that directory while the contender is still between its `mkdir` and its marker write. The
contender's subsequent marker write does not fail -- it succeeds, but into a *replacement* directory
another shell has since `mkdir`'d at the same pathname. Both sides then report success and both
believe they hold the guard.

The version of the reclaim helper written for PR #148's round 2 asserted the opposite was true. Its
comment reasoned: "The one window is a directory a contender has mkdir'd but not yet marked; rmdir
can take it, and the contender learns that when its marker creation fails and simply tries again."
Round 3's review reproduced the failure directly against that code: the marker write does not fail,
because the pathname was recreated out from under it, and the reproduction left the guard directory
"holding owner.1111 and owner.2222 at once" (two owner markers, one directory, per PR #178's commit
message).

The rule that survived: an unmarked directory is reclaimable only once it is older than a grace
period a live contender never reaches -- because a live contender writes its marker within the same
few syscalls as its `mkdir` -- and a process that died between `mkdir` and its marker write always
does reach. As a second, independent line of defense, an acquirer checks its own owner count
immediately after publishing its marker; finding more than one means a reclaimer already took its
directory and a replacement raced in, so it stands down and retries instead of reporting a false
hold.

```
before (asserted safe, not actually safe):
  for f in "$lockdir"/owner.*; do ...; done   # no markers found -> straight to rmdir
  rmdir "$lockdir" 2>/dev/null || [ ! -d "$lockdir" ]

after (pending, PR #178):
  # no markers found -> only reclaim once the directory is older than the grace window
  age="$(pg_dir_age_secs "$lockdir")" || return 1
  [ "$age" -ge "$grace" ] || return 1
  rmdir "$lockdir" ...
  # acquirer side: publish the marker, then confirm owner count == 1 before reporting a hold
```

### 2. Absence is not success

The reclaim helper's failure path was `rmdir "$lockdir" 2>/dev/null || [ ! -d "$lockdir" ]` -- so a
directory that was never there in the first place (a missing or unwritable parent, not contention)
reported success. The acquire loop's `mkdir` failure branch called this helper and `continue`d on
success with no sleep and no counter increment, so a non-contention `mkdir` failure spun the loop at
100% CPU forever, ignoring its own wait bound entirely. PR #178's commit message records the
reproduction: "a 3s bound ran until killed at 12s."

The rule: absence must return failure, not success. The caller gates reclaim on the directory
actually existing (`[ -d "$PG_RESERVATION_GUARD_DIR" ] && pg_dirlock_reclaim_dead ...`), and reclaim
retries get their own bounded counter independent of the sleep-based wait counter, so a pathological
alternation between "reclaim looks like it worked" and "mkdir fails again" cannot loop forever
either.

### 3. A recycled pid is not a live owner

Liveness checked with bare `kill -0` on a stored pid is only valid until the OS recycles that pid to
an unrelated, genuinely live process -- at which point `kill -0` succeeds forever and the guard
directory is never reclaimed. This exact hazard was already known and fixed once elsewhere in this
file: `pg_pid_token`'s own comment cites it -- "gate #61 r2 P1: kill -0 alone made a stale active
record/lock 'live' forever once an unrelated long-lived process inherited the pid"
(`lib/pro-gate-lib.sh:269-271`) -- yet the guard's first self-heal draft (PR #148 round 1) shipped
with plain `kill -0` and no token check, reintroducing the same known hazard in a new call site.

The rule: an owner marker's *contents*, not just its filename, must be the owner's process
start-time token (`pg_pid_token`, `lib/pro-gate-lib.sh:272-284`), and liveness requires the pid to
answer to `kill -0` **and** its currently-recomputed token to match the token stored in the marker.
`pg_harvest_claimed` already applies this pattern; the guard's reclaim (pending, PR #178) makes it
explicit for a second call site.

### 4. Liveness must be positively disproved, never inferred from a failed measurement

This is the rule the previous one's own fix violated, and the subtlest of the four. Round 3's
token-check landed as:

```
tok="$(head -c 64 "$f" 2>/dev/null | tr -d '\n')"
[ -n "$tok" ] || return 1                                            # unreadable STORED token: fail closed
[ "$tok" = "$(pg_pid_token "$pid" 2>/dev/null || true)" ] && return 1
rm -f "$f" 2>/dev/null
```

It fail-closed correctly when the *stored* token was unreadable, but not when the *recomputed* one
was. A transient `/proc` read or `ps` fork failure for a genuinely live pid makes
`pg_pid_token "$pid"` return empty; an empty recomputed value compares unequal to a valid stored
token, and the comparison falls through to `rm -f "$f"` -- deleting a live owner's marker. Round 8's
review reproduced this against the pre-fix code: "the holder's guard was taken outright -- rc=0,
directory gone, marker gone" (PR #178 commit message). The fix reads the recomputed token into its
own variable first and fails closed on it exactly as it does on the stored one, before ever
comparing:

```
cur="$(pg_pid_token "$pid" 2>/dev/null || true)"
[ -n "$cur" ] || return 1
[ "$tok" = "$cur" ] && return 1
```

The rule generalizes past this one check: a measurement that fails to return a value is not
evidence the thing it was measuring is absent. Treating "I couldn't measure X" as "X is false" is
the same shape of bug as rule 1 (treating "no marker present yet" as "no live owner") -- both infer
death from the absence of proof of life, rather than requiring proof of death.

### Related pattern worth watching for elsewhere: a shared knob with a raw-literal sibling

While closing round 3, the same commit introduced `pg_harvest_hint_timeout` as the single shared
definition of a 45-minute collection-wait default, specifically because the prior sizing pass had
left that value duplicated and drifted (per that commit's own message: "one harvest hint still said
20m... The wait now has one definition... that every renderer shares, and the check reads every
shipped shell file"). The lesson generalizes beyond that one variable: giving one knob a shared
helper while its sibling knob (there, a 60-minute fresh-review default) stays a raw literal at
multiple call sites reintroduces, on the sibling, exactly the drift the helper was built to close on
the first knob -- and a "single definition" test that only greps the file where the first knob lives
will not catch it.

## Why This Matters

The unifying principle behind all four rules: a lock's identity cannot be its pathname alone, and
liveness must be positively **disproved**, never inferred from a measurement that failed or from an
absence of evidence. Rule 1 fails this because "no marker" was treated as proof of abandonment
rather than requiring a grace period to rule out "marker not written yet." Rule 3 fails it because a
bare pid match is not disproof that the pid was reused. Rule 4 fails it in its purest form: a failed
*measurement* of liveness (an empty recompute) was treated as a successful *disproof* of liveness.

The cost of not having these rules up front was real, not theoretical: six consecutive review
rounds on PR #148 each surfaced a new defect in this one function, and -- per PR #178's own
retrospective commit message -- twice a fix written to close one round's finding is what introduced
the next round's. The comment written to justify round 2's fix ("the contender learns that when its
marker creation fails") is the clearest artifact of this: it was a plausible-sounding safety
argument that was never executed against a concurrent reproduction, and round 3 disproved it by
running exactly the scenario the comment dismissed. Round 3's own token-check fix for the pid-reuse
hazard (rule 3) is the second instance -- the code that closed rule 3 is the exact code round 8 later
found violating rule 4. A rule stated in a comment without an executable regression proving the
counter-case is not a rule that survives review; every one of the four rules above is described in
the pending PR #178 change alongside a regression that is proven red against the pre-fix code before
being fixed.

## When to Apply

- Implementing or reviewing **any** directory-based (mkdir-spinlock) lock with dead-owner
  reclamation -- not just this guard. Check the design against all four rules before it ships, not
  after a round finds one missing.
- Specifically: `pg_lock` (`lib/pro-gate-lib.sh:286-309`) and `pg_lock_n`
  (`lib/pro-gate-lib.sh:316-361`) in this same file, in the current tree, still fail rule 3 and by
  extension the identity half of rule 1. Both write a start-time token beside the owner pid
  (`pg_pid_token "$$" > "$lockdir/token"`, lines 306 and 349) but **never read it back** on
  reclaim -- their dead-owner check is bare `kill -0` on the stored pid alone
  (`lib/pro-gate-lib.sh:301`, `lib/pro-gate-lib.sh:355`), and their reclaim is an unscoped
  `rm -rf "$lockdir"` rather than an exact-name unlink plus `rmdir`. This is tracked as #152/#155
  (open at time of writing); the fix described there deliberately reuses the hardened helper this
  doc describes rather than shipping a second, divergent implementation.
- Any place a "single definition" helper is introduced for one time-out/threshold knob: check
  whether a sibling knob of the same kind still has a raw-literal default at other call sites, and
  whether the test guarding the new helper actually scans every file that could carry the drift
  (not just the file the helper lives in).

## Examples

**Double-hold (rule 1).** Pre-fix reproduction, per PR #178's commit message: two shells both
`mkdir` the same lock directory in sequence (the second only after a reclaimer removed the first's
unmarked directory), both write an owner marker, and the directory ends up holding
`owner.1111` and `owner.2222` simultaneously -- two live processes, one guard, both believing they
hold it.

**Fail-open on a failed re-measurement (rule 4).** Pre-fix reproduction, per PR #178's commit
message: force `pg_pid_token`'s recompute to fail for a still-live owner pid (simulating a
transient `/proc` or `ps` failure). Before the fix, `pg_dirlock_reclaim_dead` returns `rc=0` and
both the lock directory and the live owner's marker are gone -- the guard was taken out from under
its holder. After the fix, the same call returns `rc=1` with the directory and marker both intact,
because an unreadable recomputed token now fails closed exactly as an unreadable stored token
already did.

Both fixes, and the other two rules, are pending in PR #178. PR #148 -- which carried the wait
sizing and the validator move, and from which this guard work was split out -- merged as this was
written; #178 was still open. So `main` runs the pre-self-heal fallback shown in Context above,
with none of the four rules applied. Check #178's state before assuming otherwise: this doc's value
is the four rules, which hold regardless of where that change eventually lands.

## Related

- [Ship the legible core; let the terminal gate decline fragile automation](./ship-the-legible-core-let-the-gate-decline-fragile-automation.md)
  — same triggering episode. That doc says repeated `FIX-FIRST` on one feature is a convergence
  signal to drop it; this one is the case where the failing code could not simply be dropped,
  because it was a correctness fix rather than optional automation. It was deferred to its own
  change instead. Read the two together: the rule there needs the required-vs-optional carve-out
  this episode supplies.
- [Separate review lifecycle, applicability, capacity, and input trust](./separate-review-lifecycle-applicability-capacity-and-input-trust.md)
  — the decision layer above this guard, for orientation when working in the same subsystem.
