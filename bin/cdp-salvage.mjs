#!/usr/bin/env node
// Last-resort review salvage: read the finished Pro review
// straight off the ChatGPT conversation tab's DOM via CDP.
//
// Why this exists: oracle (historically <=0.15.x) could fail to DETECT the thinking state
// after a ChatGPT UI change even though the submission landed. The engine's
// no-think watchdog then kills a LIVE run, and `oracle session --harvest`
// reattaches to a stale tab target ("Assistant turns: 0") while the real
// conversation keeps generating in another tab. This helper finds the
// conversation tab by PR marker, waits for the VERDICT line, and prints the
// review block. First seen: pushbot PR #863, 2026-07-02. 0.16.0 hardened detection
// upstream (positive terminal evidence + tightened Cloudflare / Work-tab handling), but the
// 2026-07 GPT-5.6 UI re-broke it: 100% of clean runs 2026-07-22 → 08-03 landed via this
// path or --harvest. Treat it as the first-class capture path whenever oracle's own
// detection lags the live UI — defense-in-depth is the aspiration, not the observed role.
//
// v0.18: ChatGPT-throttle awareness + polite fresh-render budget.
//   - Detects ChatGPT's anti-scraping interstitial ("You're making requests
//     too quickly" / "temporarily limited access to your conversations"),
//     writes a cooldown file the engine's health gate honors, and exits 5
//     immediately — continuing to hammer a throttled account only sustains
//     the throttle (observed 2026-07-03).
//   - Fresh renders are budgeted PER URL (each one is a full conversation
//     page load against chatgpt.com — exactly the request pattern the
//     throttle targets; 42 loads in one salvage on 2026-07-02). URLs that
//     never match this run get at most MAX_RENDERS_PER_URL loads per
//     invocation; the one URL that DOES match is re-rendered at most once
//     per RENDER_INTERVAL_MS while waiting for its VERDICT.
//   - Foreign-marker URLs are blacklisted PERSISTENTLY (salvage-nonmatching.txt
//     in $PRO_GATE_HOME) so later invocations never re-render conversations
//     that are provably another run's.
//   - A transient CDP /json failure no longer aborts the whole salvage (an
//     exit 2 mid-probe read as "dead submission" and green-lit a
//     double-spending retry); it now backs off and retries until the deadline.
//   - After a successful (non-probe) harvest the matched conversation tab is
//     closed: watchdog-killed runs never archive their tab, and those
//     orphaned tabs were the pool every later salvage burned renders on.
//
// v0.25: conversation-URL memory, so a review is never "lost" just because its TAB is.
//   The salvage used to define "the conversation exists" as "an open Chrome tab carries the
//   marker". ChatGPT conversations live SERVER-SIDE, so those are different facts: a Chrome
//   restart (routine on a memory-pressured box), a discarded renderer, or a stray close turned
//   a finished, fully recoverable review into "confirmed gone" — while the human who opened
//   chatgpt.com saw it sitting there complete. 46 of 200 logged runs died this way.
//   Now: the FIRST time a tab is proven to carry this run's marker, its conversation URL is
//   remembered under $PRO_GATE_HOME/conversation-urls/<marker>. Later invocations (salvage,
//   harvest AND --probe, so reservation reconciliation inherits it too) re-render that URL in a
//   scratch tab when no open tab matches. A remembered URL is authoritative for its marker: it
//   is exempt from the foreign-marker blacklist and from the per-URL render cap.
//   v0.42 (#109): authority is conditional on the memo's conversation id passing the shape gate
//   below (CONVERSATION_URL_RE), checked when a URL is remembered AND every time one is read. A
//   memo that fails is revoked on read with the same claim-and-verify as a foreign memo, so the
//   pass rescans candidates instead of re-rendering a placeholder page forever.
//
// Usage: cdp-salvage.mjs [--probe] <pr-marker> [timeout-secs] [cdp-port]
//   pr-marker    substring identifying the right conversation (e.g. the PR
//                URL or the engine's pg-run marker); required because several
//                review slots may have concurrent conversation tabs open.
//   --probe      liveness check only: exit 0 as soon as a conversation tab
//                matching the marker EXISTS (no VERDICT wait). Used by the
//                engine's no-think watchdog to distinguish "dead submission,
//                safe to retry" from "live run, retry would double-spend".
//                Also prints `probe-state: complete|generating|terminal-infrastructure|throttled`
//                on stderr so the reservation reconciler can release the account slot of a
//                review that has finished but has not been collected yet (#82). This is
//                an additive LINE, never a new exit code: callers above key on
//                rc 0 meaning "live", and a new code would fall through them.
//                `throttled` (#162): the conversation renders this run's marker UNDER
//                ChatGPT's "Too many requests" modal. It exists (rc 0: a retry would
//                double-spend) but is not progressing; the cooldown file is written, the
//                reconciler leaves the miss streak untouched, and callers back off.
// Exit: 0 = review printed (probe: tab found); 4 = scanned successfully, nothing matched;
//       2 = usage error;
//       3 = timeout but a conversation matching the marker IS live with no VERDICT yet (the
//           model is still generating; the tab is left open so a later --harvest can collect
//           the finished review without respending the Pro slot);
//       5 = ChatGPT throttle detected (cooldown written — do NOT resubmit);
//       7 = INCONCLUSIVE: either not one successful CDP tab list all invocation (browser down/
//           restarting), or this run's remembered conversation could not be resolved either way
//           (it never rendered decisively). Distinct from 4 because 4 is evidence of absence and
//           feeds the engine's consecutive-miss counter toward "conversation gone"; 7 is absence
//           of evidence and must never be counted as a miss. A successful TAB listing says
//           nothing about SERVER-SIDE state, so it alone cannot promote 7 to 4 — only decisive
//           evidence that the remembered conversation is another run's does that;
//       10 = exact-owned terminal ChatGPT infrastructure error after this run's prompt. No review
//            exists to harvest; the caller keeps the charge but releases recovery ownership.
// Requires Node >= 21 (global WebSocket); the box runs Node 24.

import { createHash, randomBytes } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  buildArchiveConversationExpression,
  buildCancelOrganizerMutationExpression,
  buildRenameConversationExpression,
  buildThrottleModalExpression,
  ORGANIZER_MUTATION_LEASE_MS,
  THROTTLE_RE,
  readReviewText,
  reviewTextContext,
} from './cdp-organizer-expressions.mjs';
import {
  parseTestPollMs,
  parseTestRenderSampleMs,
} from './cdp-test-timing.mjs';

const usage = () => {
  console.error('usage: cdp-salvage.mjs [--probe|--close|--sweep-root|--organize [--finalize --result-file <path>] [--accepted-url <url>] [--archive] [--no-rename]] <pr-marker|-> [timeout-secs] [cdp-port]');
  process.exit(2);
};
const argv = process.argv.slice(2);
let mode = 'salvage';
let finalize = false;
let archive = false;
let rename = true;
let resultFile = null;
let acceptedUrl = null;
for (;;) {
  const arg = argv[0];
  if (!arg?.startsWith('--')) break;
  argv.shift();
  if (['--probe', '--close', '--sweep-root', '--organize'].includes(arg)) {
    if (mode !== 'salvage') usage();
    mode = arg.slice(2);
  } else if (arg === '--finalize') {
    finalize = true;
  } else if (arg === '--result-file') {
    resultFile = argv.shift() ?? null;
  } else if (arg === '--accepted-url') {
    acceptedUrl = argv.shift() ?? null;
  } else if (arg === '--archive') {
    archive = true;
  } else if (arg === '--no-rename') {
    rename = false;
  } else {
    usage();
  }
}
if (mode !== 'organize' && (finalize || archive || !rename || resultFile || acceptedUrl)) usage();
if (archive && !finalize) usage();
if (finalize !== !!resultFile || (acceptedUrl && !finalize)) usage();
if (acceptedUrl && !/^https:\/\/chatgpt\.com\/c\//.test(acceptedUrl)) usage();
const probe = mode === 'probe';
const close = mode === 'close';
const sweepRoot = mode === 'sweep-root';
const organize = mode === 'organize';
const [marker, timeoutSecs = probe || organize ? '30' : '600', port = process.env.ORACLE_CDP_PORT ?? '9222'] = argv;
if (!marker || argv.length > 3 || !/^\d+$/.test(String(timeoutSecs)) || Number(timeoutSecs) <= 0 || !/^\d+$/.test(String(port))) usage();
const deadline = Date.now() + Number(timeoutSecs) * 1000;
// Test-only timing overrides (see cdp-test-timing.mjs): only deliberately tagged fixture
// children may shorten these waits. Unset, malformed, or any other mode preserves the exact
// production literals below; this token is intentionally not a production configuration surface.
const TEST_TIMING_ENABLED = process.env.PRO_GATE_TEST_MODE === 'ci-fixture';
const POLL_MS = TEST_TIMING_ENABLED ? (parseTestPollMs(process.env.PRO_GATE_TEST_POLL_MS) ?? 20_000) : 20_000;
const RENDER_SAMPLE_MS = TEST_TIMING_ENABLED
  ? (parseTestRenderSampleMs(process.env.PRO_GATE_TEST_RENDER_SAMPLE_MS) ?? 2_500)
  : 2_500;

const PG_HOME = process.env.PRO_GATE_HOME ?? path.join(os.homedir(), '.pro-review-daemon');
const BLACKLIST_FILE = path.join(PG_HOME, 'salvage-nonmatching.txt');
// honor the same override pg_health_gate reads, or a detected throttle would never defer runs
const COOLDOWN_FILE = process.env.PRO_GATE_COOLDOWN_FILE ?? path.join(PG_HOME, 'throttle.cooldown');
// #208: an abandoned modal on an UNOWNED tab (another run's stale conversation) is account-wide
// throttle evidence just like our own, but nothing ever closes that tab or clears its modal — so
// a caller that waits out seconds_remaining and retries has the sweep re-detect the exact same
// stale sighting and rewrite COOLDOWN_FILE again, forever (observed 3 attempts / 1h45m, pushbot
// PR #3225). This sidecar remembers which (tab, page/modal-text) pairs already charged a
// cooldown so a repeat of the SAME stale tab is ignored instead of re-arming the timer.
// #208 gate r2 P2: one record file per (url, hash) fingerprint in this DIRECTORY, not a single
// file loaded once and rewritten wholesale. Two scans of the same invocation window (probe +
// harvest, or two overlapping probes) each used to load the sidecar once at first use and
// rewrite it wholesale on every new sighting — a second process's load-then-mutate-then-rewrite
// could always land after the first's, silently dropping whichever sighting lost the race. A
// directory of independently created files removes the shared mutable state entirely: each
// record is created with the 'wx' flag (openThrottleSeenRecord below), which fails if the file
// already exists, so no writer can ever clobber another's record and "already charged" is a
// plain existence check. `||` (not `??`) matches this repo's env-override convention (bash reads
// `${VAR:-default}`, so an exported-but-empty override falls back too, same as here).
const THROTTLE_SEEN_DIR = process.env.PRO_GATE_THROTTLE_SEEN_DIR || path.join(PG_HOME, 'throttle.cooldown.seen.d');
// Records older than this are pruned (best-effort) the first time this invocation touches the
// directory, and the survivors are capped to THROTTLE_SEEN_MAX (oldest mtime first) even inside
// the TTL window — otherwise a long-lived box accumulates one file per distinct stale (url,
// hash) pair forever. `||` matches the same env-override convention as above.
const THROTTLE_SEEN_TTL_MS = Number(process.env.PRO_GATE_THROTTLE_SEEN_TTL) || 7 * 24 * 60 * 60 * 1000;
// #208 gate r3 P2: overridable so a test can shrink the cap without waiting for 512 distinct
// tabs. `||` matches the same env-override convention as above.
const THROTTLE_SEEN_MAX = Number(process.env.PRO_GATE_THROTTLE_SEEN_MAX) || 512;

// --- conversation-URL memory (v0.25) -------------------------------------------------
// One file per run marker holding the conversation URL we PROVED carries it. This is the
// engine's only handle on a conversation whose tab is gone, so it is written on every positive
// match (probe included) and read before we ever conclude "not found".
const URL_MEMO_DIR = path.join(PG_HOME, 'conversation-urls');
const TITLE_MEMO_DIR = path.join(PG_HOME, 'conversation-titles');
const COMPLETED_DIR = process.env.PRO_GATE_COMPLETED_DIR ?? path.join(PG_HOME, 'completed');
const PENDING_DIR = path.join(PG_HOME, 'pending');
const MEMO_KEEP = 200;                  // newest N memos retained; older ones are pruned on write
// #208 gate r1 P1: a stale unowned tab can legitimately fingerprint under TWO different hashes
// across invocations (modal text vs. whole-page text) when a marker-less interstitial also
// carries a throttle modal — the two trip sites used to disagree on which text to hash. Every
// trip site now consistently prefers the modal text when one is present (classifyEvidence and
// every direct caller below), and #208 gate r2 P2's one-file-per-(url, hash) sidecar (see
// THROTTLE_SEEN_DIR above) keeps every distinct fingerprint ever seen for a URL rather than a
// short bounded history of them, so "already charged" recognizes either fingerprint without a
// per-URL cap here at all.
const MARKER_SAFE_RE = /^pg-run-[A-Za-z0-9.-]+$/;
// #167: the marker is EXTRACTED case-insensitively everywhere but used to be COMPARED
// case-sensitively, so a model that lowercased its own echo — markers legitimately carry
// un-lowercased repo text, e.g. pg-run-StartupBros-com-pro-gate-166-... — read as another run
// and got its own finished answer convicted cross-bound. Two genuinely different runs cannot
// differ only in letter case: a marker ends in "-<launch epoch>-<pid>" and one process has one
// of each, so folding case cannot mask another run's claim.
//
// ASCII-only and arithmetic ON PURPOSE. toLowerCase() is NOT length-preserving ('İ' folds
// to two code units) and is not what the engine's shell side can cheaply agree with; every
// marker position in this file is compared against other positions in the SAME string
// (verdict.at, promptMarkerAt, lastMarkerAt, foreignAt, every text.slice boundary), so a fold
// that shifted indices would silently corrupt ownership adjudication. A +32 fold over [A-Z]
// leaves every other code unit — and therefore every index — exactly where it was.
const asciiFold = (value) => String(value ?? '').replace(/[A-Z]/g, (c) => String.fromCharCode(c.charCodeAt(0) + 32));
const foldedIncludes = (text, wanted) => asciiFold(text).includes(asciiFold(wanted));
// Marker identity. Null/empty on either side is NOT a match: an absent echo is "unproven", never
// "ours" (organizerOwnership and finalizerOwnership both depend on that distinction).
const sameMarker = (a, b) => !!a && !!b && asciiFold(a) === asciiFold(b);
// v0.42 (#109): the shape a remembered conversation URL must have. A synthetic placeholder such as
// https://chatgpt.com/c/WEB:<uuid> passed the old prefix-only check, was remembered as
// authoritative, and rendered a page with no marker on every later pass — an inconclusive result
// the engine deliberately never counts as a miss — so its run held a ChatGPT slot for days. The
// boundary enforced here: the segment after /c/ is one path segment of letters, digits, and
// dashes, optionally followed by a query or fragment. Every real id observed on the operator's box
// (36-char hex-and-dash, 196 of 196) passes; the placeholder's colon fails, including one whose
// body after the prefix is a well-formed UUID, because the whole segment is anchored. This is a
// shape gate like MARKER_SAFE_RE, not proof the conversation exists; a stricter hex-and-dash
// shape is deferred until test fixtures stop using named ids such as mock-conversation.
const CONVERSATION_URL_RE = /^https:\/\/chatgpt\.com\/c\/[A-Za-z0-9-]+(?:[?#].*)?$/;
const conversationUrlOk = (url) => CONVERSATION_URL_RE.test(url || '');
const memoPath = (m) => (MARKER_SAFE_RE.test(m) ? path.join(URL_MEMO_DIR, m) : null);
const titleMemoPath = (m) => (MARKER_SAFE_RE.test(m) ? path.join(TITLE_MEMO_DIR, m) : null);

function recallUrl(m) {
  const f = memoPath(m);
  if (!f) return null;
  let url = '';
  try { url = fs.readFileSync(f, 'utf8').trim(); } catch { return null; }
  if (conversationUrlOk(url)) return url;
  if (!url) return null;
  // v0.42 (#109): a memo whose id fails the shape gate is revoked HERE, on read, so this very pass
  // rescans candidates instead of trusting it. Claim-and-verify (forgetUrl), never a plain unlink:
  // a concurrently republished genuine memo survives and is used instead. This is memo hygiene,
  // not termination — the pass still has to find or miss the conversation on its own evidence.
  const survivor = forgetUrl(m, url);
  console.error(`memo-revoked: the remembered conversation for "${m}" is not a conversation id (${url}); rescanning candidates`);
  if (survivor && conversationUrlOk(survivor)) return survivor;
  // v0.42 review finding #2: forgetUrl only restores a genuine memo republished DURING its
  // claim rename (the file existed as `f` again by the time forgetUrl read `claim`). A memo
  // republished in the window between that rename and the unlink of `claim` lands back at `f`
  // unheld and unseen by forgetUrl, so re-read `f` once more here to close it before giving up.
  let value = '';
  try { value = fs.readFileSync(f, 'utf8').trim(); } catch { return null; }
  if (conversationUrlOk(value)) {
    console.error(`memo-republished: a genuine conversation for "${m}" was published while the placeholder was being revoked; using ${value}`);
    return value;
  }
  return null;
}

function recallTitle(m) {
  const f = titleMemoPath(m);
  if (!f) return null;
  try {
    const title = fs.readFileSync(f, 'utf8').replace(/\n$/, '');
    return title && title.length <= 200 && !/[\r\n\0]/.test(title) ? title : null;
  } catch { return null; }
}

// #67: drop a memo proven to point at another run's conversation. CLAIM-and-verify, not
// compare-then-delete (#68 gate P1): read-then-unlink leaves a window in which a concurrent
// probe republishes the GENUINE url and this process deletes it, destroying the only
// server-side recovery handle. Rename the memo aside first (atomic), inspect the bytes we
// actually hold, and restore via link() — which fails atomically if a new memo already
// exists — when they name a different conversation. Mirrors the shell's pg_provenance_reject.
// Returns the SURVIVING memo url when a concurrent writer had already republished a different
// (potentially genuine) conversation, else null. The caller must keep using that url rather
// than declaring absence (#68 gate r3 P1): restoring the file but then clearing knownUrl left
// this invocation blind to a recovery handle that exists on disk, and its exit 4 could supply
// the final miss that retires the reservation.
function forgetUrl(m, url) {
  const f = memoPath(m);
  if (!f) return null;
  const claim = `${f}.rej.${process.pid}`;
  try { fs.renameSync(f, claim); } catch { return null; }   // nothing to claim: someone else won
  let held = '';
  try { held = fs.readFileSync(claim, 'utf8').trim(); } catch {}
  let survivor = null;
  if (held && held !== url) {
    try { fs.linkSync(claim, f); survivor = held; } catch {}  // genuine memo republished: put it back
  }
  try { fs.unlinkSync(claim); } catch {}
  return survivor;
}

// #68 gate r3 P2: cross-bind convictions are ACCUMULATED per candidate URL and only persisted
// at exit, when the whole scan is known. Writing mid-scan made the terminal "cross-bound"
// state depend on /json tab ORDER — a foreign tab seen after a genuine one would re-flag a
// live review as stuck and have --status advise deleting its reservation.
//
// #76: these live HERE, above the exit hook below, not with the scan state further down.
// The hook reads them, and `const`/`let` are in the temporal dead zone until their
// declaration is evaluated — so declaring them after the hook made every exit that happens
// before that point (--sweep-root, --close, an unreachable CDP port) throw
// "Cannot access 'ownershipProven' before initialization" instead of flushing.
const crossBindHits = new Map();   // url -> foreign marker
let ownershipProven = false;       // any candidate positively proved ours this invocation

// #68 gate P2: record that THIS marker was positively convicted of a cross-bind (its page held
// another run's completed answer BELOW our prompt). Only that state is terminally stuck; an
// ordinary nonce-less .unbound capture may still be an older answer while ours generates, and
// is genuinely retryable. The engine's --status reads this sidecar to tell them apart.
// Record a per-candidate conviction. Persisted only by flushCrossBind() at exit.
function noteCrossBind(_m, url, foreign) { crossBindHits.set(url, foreign); }

// #170: does salvage-nonmatching.txt still hold an entry for this marker? Read from the FILE,
// not from the `nonMatching` Set: that Set is declared with the blacklist block far below, and
// --sweep-root (exits at the "closed N idle root tab(s)" line) and --close both exit ABOVE it,
// so touching it from the exit hook would resurrect exactly the #76 temporal-dead-zone crash
// this state placement exists to prevent. Re-reading also answers the question that actually
// matters — "will the NEXT scan skip this marker's URLs?" — including entries the shell's
// pg_provenance_reject appended concurrently. Line filter is the load's, character for character.
function markerHasBlacklistEntry(m) {
  try {
    for (const raw of fs.readFileSync(BLACKLIST_FILE, 'utf8').split('\n')) {
      const line = raw.trim();
      if (!line) continue;
      const sep = line.indexOf('\t');
      if (sep < 0) continue;         // legacy global entry: ignore (same filter as the load below)
      if (line.slice(0, sep) === m) return true;
    }
  } catch {}
  return false;
}

// Persist terminal cross-bound state ONLY when the completed scan found no candidate we could
// prove is ours. Order-independent by construction: every candidate has been classified by the
// time this runs.
function flushCrossBind(m) {
  const dir = path.join(PG_HOME, 'crossbound');
  const f = path.join(dir, m);
  // Positive ownership is the ONLY proof a conviction went stale, so it is the only thing that
  // clears the sidecar unconditionally.
  if (ownershipProven) {
    try { fs.unlinkSync(f); } catch {}
    return;
  }
  if (crossBindHits.size === 0) {
    // #170: an empty scan is NOT that proof. A conviction blacklists its own URL
    // (rejectCrossBound -> discardForeignUrl -> blacklist), and every later scan skips a
    // blacklisted URL before it can be re-classified — both the open-tab loop and the dead-tab
    // re-render loop test `nonMatching.has(tab.url)` ahead of any marker comparison. So a
    // still-suppressed conviction produces exactly the same empty crossBindHits as a genuinely
    // cleared one. Unlinking on that emptiness left the append-only blacklist (never swept, by
    // design — see the housekeeping note in oracle-review.sh) still hiding the conversation
    // while --status downgraded "STUCK (cross-bound)" to a retry hint, and threw away the
    // sidecar's URL, which is the only surviving handle to that conversation: the conviction
    // deleted conversation-urls/<marker> in the same breath.
    // Clear only when this marker has no blacklist entry that could have produced the emptiness.
    // --close/--sweep-root keep clearing an otherwise-unsupported stale conviction (#76).
    if (!markerHasBlacklistEntry(m)) { try { fs.unlinkSync(f); } catch {} }
    return;
  }
  try {
    fs.mkdirSync(dir, { recursive: true });
    const ts = new Date().toISOString();
    const body = [...crossBindHits].map(([u, fm]) => `${ts}\t${u}\t${fm}\n`).join('');
    fs.writeFileSync(f, body);
  } catch {}
}


// One hook rather than seven call sites: every salvage exit path (0/3/4/5/7)
// persists the scan's verdict exactly once, so no future exit can forget to.
// Organizer/cleanup modes are deliberately read-only with respect to cross-bound recovery state.
// #76 keeps close/sweep-root flushing (they clear a stale conviction, and their test asserts it);
// v0.32 excludes only --organize. It exits before the scan that can call noteCrossBind, so it
// never has hits and never proves ownership — flushing there would just DELETE a genuine
// conviction an earlier salvage recorded.
process.on('exit', () => {
  if (organize) return;
  // #170: a probe still never RECORDS a conviction — with ownershipProven false it returns right
  // here, so a probe's crossBindHits can never reach the write branch below. What it may now do
  // is CLEAR one, because a probe that positively proved ownership holds exactly the proof the
  // flush requires, and refusing to act on it is what turned a transient mis-report into a
  // durable one: sidecars stopped self-clearing (above), and pg_reservation_reconcile's periodic
  // probe is the invocation that notices a review finished. A run whose earlier salvage convicted
  // a duplicate tab would otherwise keep reporting "STUCK (cross-bound)" — telling the operator
  // NOT to run the free harvest that would in fact succeed — until the 14-day sweep.
  if (probe && !ownershipProven) return;
  flushCrossBind(marker);
});

function rememberUrl(m, url) {
  const f = memoPath(m);
  if (!f) return;
  if (!conversationUrlOk(url)) {
    // v0.42 (#109): a /c/ URL whose id fails the shape gate is the placeholder class; say so once
    // rather than silently dropping it. Non-conversation URLs (the root page, a login wall) stay
    // silent exactly as before.
    if (/^https:\/\/chatgpt\.com\/c\//.test(url || '')) {
      console.error(`memo-rejected: not remembering ${url} for "${m}": its conversation id is not letters, digits, and dashes`);
    }
    return;
  }
  if (recallUrl(m) === url) return;     // already known: no churn, no prune
  try {
    fs.mkdirSync(URL_MEMO_DIR, { recursive: true });
    // Atomic publish (gate #54 r7): an in-place writeFileSync truncates first, so the shell's
    // claim-and-verify rejection could grab (and unlink) an empty mid-write memo, losing the
    // refreshed genuine URL. Rename swaps complete content or nothing.
    const tmp = `${f}.tmp.${process.pid}`;
    fs.writeFileSync(tmp, `${url}\n`);
    fs.renameSync(tmp, f);
    const entries = fs.readdirSync(URL_MEMO_DIR);
    if (entries.length > MEMO_KEEP) {
      entries
        .map((n) => { try { return { n, t: fs.statSync(path.join(URL_MEMO_DIR, n)).mtimeMs }; } catch { return { n, t: 0 }; } })
        .sort((a, b) => b.t - a.t)
        .slice(MEMO_KEEP)
        .forEach(({ n }) => { try { fs.unlinkSync(path.join(URL_MEMO_DIR, n)); } catch {} });
    }
  } catch {}
}
// THROTTLE_RE (the limiter's two distinctive sentences) is shared with the in-page modal
// evaluator in cdp-organizer-expressions.mjs so both surfaces recognize the same copy.
// Any pro-gate run marker. On a page that does NOT carry our own marker, a hit here is positive
// evidence the page rendered a DIFFERENT run's conversation (vs. merely not having loaded yet).
// Case-insensitive in lockstep with the ownership checks that gate it (#167): every caller asks
// "is this ours?" first, and that question is now answered under asciiFold. Were this pattern
// stricter than its gate, an UPPERCASED self-echo would newly read as foreign and blacklist the
// run's own conversation — the exact conviction this issue exists to stop, in the other direction.
const FOREIGN_MARKER_RE = /pg-run-[A-Za-z0-9.-]+/i;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A page is the throttle interstitial only if it carries the phrase, no run
// marker at all (ours or foreign — real conversations can QUOTE the phrase,
// e.g. a review of this very engine), and is short like an error page.
function isThrottlePage(text) {
  return !!text && text.length < 5000 && !FOREIGN_MARKER_RE.test(text) && THROTTLE_RE.test(text);
}
// #215 gate r4 P2 (1): "a conversation actually rendered here" — the ONE readiness test the
// throttle dedupe's health side and both memo renders share, so the two cannot drift apart.
// chatgpt.com answers a conversation URL with a SHELL long before it answers with the
// conversation: `ChatGPT\nLoading…` during a reload, a login wall after a session expires, an
// error page, or the history sidebar alone all come back as perfectly good non-empty text with no
// limiter dialog over them. scanThrottleHealth used to count any non-empty text as health, so one
// of those shells retired the charged fingerprints of a conversation nobody had observed recover
// — and the same limiter reappearing a moment later then charged a SECOND cooldown for one
// unchanged episode: the #208 livelock, reached through a reload instead of a read failure.
// The test is exactly the one freshRenderText and openOrganizerScratch already reach their
// DECISIVE reasons by (marker-found, foreign-marker, ok, stale-memo): a pro-gate run marker is on
// the page. FOREIGN_MARKER_RE matches ANY run marker, this run's included (#215 gate r1 P1), so
// this reads "some pro-gate conversation rendered here" — the only rendered conversation content
// this engine can recognize with certainty from page text alone, and the same evidence
// readReviewText's turn scoping recognizes structurally when it finds the marker's user turn.
// Deliberate trade: a conversation carrying no run marker at all (one of the operator's own chats,
// left open at a URL that once showed the limiter) is never counted as health evidence, so its
// fingerprints are retired by the TTL alone. That is under-retire, the safe direction this file
// takes everywhere — it can suppress a repeat sighting, never re-arm a live 900s account cooldown,
// which is the failure this whole file exists to avoid.
function isRenderedConversation(text) {
  return !!text && text.trim() !== '' && FOREIGN_MARKER_RE.test(text);
}
// #208 gate r6 P2: fingerprint records recordThrottleSeen creates below are provisional until the
// cooldown they gate actually lands — tracked here so a failed or interrupted write can be rolled
// back instead of leaving a "seen" record with no cooldown behind it, which would suppress that
// sighting forever. Always drained by the very next recordThrottle call: every charging site in
// this file is synchronous between creating a record and publishing the cooldown it gates.
let pendingThrottleSeenRecords = [];
function recordThrottle(where) {  // -> true when the cooldown was actually written
  try {
    fs.mkdirSync(PG_HOME, { recursive: true });
    fs.writeFileSync(COOLDOWN_FILE, `${new Date().toISOString()} ${where}\n`);
  } catch {
    // The sighting is real even though the write failed; do not claim otherwise on stderr, and do
    // not let a record already committed by recordThrottleSeen outlive this failure — roll back
    // every fingerprint this charge provisionally created so it stays re-chargeable on a later
    // scan instead of silently suppressed by a "seen" record with no cooldown behind it.
    for (const recordPath of pendingThrottleSeenRecords.splice(0)) { try { fs.unlinkSync(recordPath); } catch {} }
    console.error(`ChatGPT throttle interstitial detected (${where}) but the cooldown could not be written to ${COOLDOWN_FILE} — leaving the sighting re-chargeable, NOT suppressed.`);
    return false;
  }
  pendingThrottleSeenRecords.length = 0;
  console.error(`ChatGPT throttle interstitial detected (${where}) — cooldown written to ${COOLDOWN_FILE}. Back off; do NOT resubmit.`);
  return true;
}
// #208: sha256 of the modal/page text, not the raw text — the sidecar never persists scraped
// conversation content to disk, only a fingerprint of it.
function throttleTextHash(text) {
  return createHash('sha256').update(text ?? '').digest('hex');
}
// #208 gate r2 P2: the record file for one (url, hash) fingerprint. Named by hashing the pair
// (not the raw url/hash, which could collide with path separators or exceed filename limits) so
// two concurrent writers computing the SAME fingerprint always agree on the SAME path — that
// agreement, not a lock, is what makes the 'wx'-flag create in recordThrottleSeen race-safe.
function throttleSeenKey(url, hash) {
  return createHash('sha256').update(`${url}\n${hash}`).digest('hex');
}
function throttleSeenRecordPath(url, hash) {
  return path.join(THROTTLE_SEEN_DIR, throttleSeenKey(url, hash));
}
// Runs once per invocation, on first touch of the sidecar: deletes records older than
// THROTTLE_SEEN_TTL_MS, then — even inside the TTL window — trims the survivor count down to
// THROTTLE_SEEN_MAX, oldest mtime first. Best-effort: a failure here (races with another
// process's own prune, permissions, ENOENT) never blocks charging or reading a record.
// #208 gate r3 P2: `protectedKeys` (record-file basenames the CURRENT scan already knows it is
// about to check — computed by the caller BEFORE this prune runs) are never evicted, by capacity
// OR by TTL. Without this, a fingerprint that is still visible every single scan could be the
// one the capacity trim picks (oldest mtime first) — evicted, then immediately rediscovered as
// "new" by the same scan's own throttleAlreadyCharged check and recreated with a fresh mtime, so
// a persistent batch above THROTTLE_SEEN_MAX charges a fresh cooldown on every invocation
// forever instead of exactly once. A protected fingerprint can still exceed the nominal cap on
// disk; that is the correct trade — the cap is only ever enforced against records this scan does
// NOT need.
// #215 skeptic r3 D2/D3: the infix retireThrottleSeenRecord below names its temp with. A temp is
// NEVER a record: it is a record mid-removal, and every walk of this directory has to say so.
const THROTTLE_RETIRE_INFIX = '.retire.';
// #215 gate r4 P2 (2): every throttle-surface fingerprint an observation in THIS invocation has
// actually seen. scanThrottleHealth fills it as it classifies each listed tab; the prune below
// honours it on top of whatever its caller passes.
// Eviction protection used to be rebuilt at each charge site from that site's CHARGEABLE hits
// alone — and the health pass deliberately recognizes MORE throttle surfaces than the charge path
// does: a tab whose dialog read succeeded but whose text read failed or came back empty is a
// throttle surface for health purposes and is excluded from the charge batch (skeptic r2 D2), so
// its fingerprint reached the prune unprotected. Any other tab's charge then fired the one-shot
// prune, the TTL or the capacity trim evicted that still-visible modal's record, and the moment
// its text became readable again the unchanged modal charged a second cooldown.
// Accumulated here rather than threaded through the two scan call sites on purpose: the main scan
// is a polling LOOP and the prune fires on whichever iteration first finds a chargeable hit, so an
// EARLIER iteration's observations have to survive it too — and the trip sites that never see a
// scanHealth at all (the organizer's scratch render, every tripThrottleEvidence caller) are then
// covered by the same set instead of by another argument each of them has to remember to pass.
const observedThrottleSeenKeys = new Set();
// #215 skeptic r3 D2: a retire renames the record to `<name>.retire.<pid>` BEFORE deciding what
// it took (see retireThrottleSeenRecord), so there is a window in which the record exists only
// under that temp name. A kill, an OOM, a power loss or a failed link-back inside that window
// used to free the record's name forever: "already charged" is an exact-name existsSync, so the
// next scan read the unchanged modal as new and charged a SECOND account cooldown — the #208
// livelock, reached through an abort. So an orphan is reclaimed here: a temp whose base name is
// free IS the record and is linked back under it; a temp whose base name is taken is redundant
// (the record sitting there already carries the same "charged" meaning) and is dropped. A link
// failure other than EEXIST leaves the temp alone for the next invocation to retry, exactly as
// D1 leaves it — losing the only copy is the one outcome that costs a cooldown.
// Racing a LIVE retire can only adopt a record back that the retire was legitimately removing:
// one suppressed repeat, never a double-charged cooldown, which is the safe direction this file
// takes everywhere. There is no protectedKeys argument — adoption never deletes a record, and the
// fingerprint a scan is about to check is exactly the one worth reclaiming.
//
// #215 gate r4 P2 (3): its own pass, run at the start of every scan and every memo render (see
// beginThrottleObservation) rather than riding the one-shot TTL/capacity prune. Inside that prune
// it was only ever reached by an invocation that CHARGED something: a decisively healthy scan
// never calls it, and both the generation snapshot and the healthy-retirement loop skip temps, so
// an orphan survived the very observation that proved the conversation had recovered — and was
// adopted only later, by the scan that met the NEXT episode, which then read that new episode as
// already charged and left a live limiter with no cooldown. Cheap enough to run unconditionally:
// one readdir, and nothing but a temp is ever touched.
function adoptThrottleSeenOrphans() {
  let names;
  try { names = fs.readdirSync(THROTTLE_SEEN_DIR); } catch { return; }
  for (const name of names) {
    const at = name.indexOf(THROTTLE_RETIRE_INFIX);
    if (at < 0) continue;
    const tempPath = path.join(THROTTLE_SEEN_DIR, name);
    const base = name.slice(0, at);
    if (base) {
      const basePath = path.join(THROTTLE_SEEN_DIR, base);
      if (!fs.existsSync(basePath)) {
        try { fs.linkSync(tempPath, basePath); }
        catch (err) { if (err?.code !== 'EEXIST') continue; }   // keep the temp: it is still the record
      }
    }
    try { fs.unlinkSync(tempPath); } catch {}
  }
}
let throttleSeenPruned = false;
function pruneThrottleSeen(protectedKeys = new Set()) {
  // Every scan and every memo render adopts before it looks (beginThrottleObservation), but a
  // charge can be reached by a path that made no such observation, and D2's guarantee — an
  // interrupted retire never frees a record's name for good — must not depend on which path got
  // here. Adoption is idempotent and touches only temps, so repeating it costs one readdir.
  adoptThrottleSeenOrphans();
  let names;
  try { names = fs.readdirSync(THROTTLE_SEEN_DIR); } catch { return; }
  const now = Date.now();
  const stats = [];
  // #215 skeptic r3 D3: a temp is NOT a record and is never counted — otherwise the capacity trim
  // could evict a LIVE record (oldest mtime first) to stay under the cap while keeping an orphan
  // that gates nothing. Adoption above has already linked back every temp whose base name was
  // free, and an adopted record carries the temp's mtime, so the TTL below still reaches an aged
  // one in this same pass.
  for (const name of names) {
    if (name.includes(THROTTLE_RETIRE_INFIX)) continue;
    // #215 gate r4 P2 (2): the caller's own keys AND every fingerprint this invocation has
    // observed anywhere. Eviction protection is never derived from chargeable hits alone.
    if (protectedKeys.has(name) || observedThrottleSeenKeys.has(name)) continue;
    const recordPath = path.join(THROTTLE_SEEN_DIR, name);
    let mtimeMs;
    try { ({ mtimeMs } = fs.statSync(recordPath)); } catch { continue; }
    if (now - mtimeMs > THROTTLE_SEEN_TTL_MS) {
      try { fs.unlinkSync(recordPath); } catch {}
      continue;
    }
    stats.push({ name, mtimeMs });
  }
  if (stats.length > THROTTLE_SEEN_MAX) {
    stats
      .sort((a, b) => a.mtimeMs - b.mtimeMs)
      .slice(0, stats.length - THROTTLE_SEEN_MAX)
      .forEach(({ name }) => { try { fs.unlinkSync(path.join(THROTTLE_SEEN_DIR, name)); } catch {} });
  }
}
// #215 gate r2 P2: a throttle modal that comes BACK after the same conversation was observed
// rendering normally is a NEW episode, not the stale repeat this dedupe exists to suppress. A
// record only ever meant "this (url, hash) was charged once", and nothing invalidated it, so the
// sequence throttled -> healthy -> throttled wrote exactly ONE cooldown: the returning modal
// hashes identically and the existence check in throttleAlreadyCharged swallows it. With another
// run's marker under that modal and no owned conversation found, the scan then falls through to
// the confirmed-absent exit 4 while the account is actively limited — the engine left without a
// fresh cooldown on a live rate limit. TTL cannot bound it either: pruneThrottleSeen deliberately
// protects the fingerprint the current scan is observing, however old its record is.
// So retire a URL's fingerprints the moment a scan positively observes that URL healthy (see
// scanThrottleHealth). An UNINTERRUPTED run of stale sightings still deduplicates exactly as
// before, because a URL throttled anywhere in a scan is never healthy in that same scan.
// Records written by builds before this change are EMPTY: attributable to no URL, so this pass
// never retires one — only TTL/capacity pruning can. Best-effort like every other sidecar write
// here; a failure leaves the record in place, which is the safe direction (one suppressed
// repeat, never a double-charged cooldown).
//
// #215 gate r3 P2: a retire may only remove the record GENERATION the observation behind it
// actually covered. A health observation takes time — a scan reads every listed tab, a memo
// render waits for a page to hydrate — and nothing in this directory is process-local. Scan A
// could read URL U as healthy, then block on another tab's evaluate; in that window process B
// observes U throttled, creates U's fingerprint and publishes the cooldown it gates. A's
// unconditional unlink then deleted B's NEWER record on the strength of A's OLDER observation,
// and the next scan charged the unchanged modal all over again — the #208 livelock, reached
// through a delayed healthy scan rather than a read failure. Neither protectedKeys nor
// pendingThrottleSeenRecords can help: both describe THIS process, and B is another one.
// A record is only ever created ('wx', never rewritten), so a record's identity is whatever
// distinguishes one create at a name from the next one. snapshotThrottleSeenGenerations is taken
// BEFORE an observation starts reading, and only a record still carrying the generation that
// snapshot saw may be retired; anything created or replaced afterwards lies outside what the
// observation covers and survives.
//
// #215 skeptic r3 D4: that identity is NOT (ino, mtimeMs). The mtime resolution reachable here is
// coarse (4 ms, measured on the host this ships from) and ext4 hands a freed inode straight back
// to the next create in the same directory — so another process deleting a record and creating
// its replacement inside one tick presents the EXACT pair the snapshot saw, and the retire deletes
// a record it knows nothing about, which is the very delete this guard exists to prevent. So every
// record carries a random nonce on a second content line, written once at creation beside the URL
// (recordThrottleSeen), and the identity is (ino, mtimeMs, nonce). Records written before this
// change have no nonce line: they read as '' on both sides, which is exactly the (ino, mtimeMs)
// behaviour they had before — an unchanged one is still retired — while any replacement THIS build
// writes carries a nonce and so can never be mistaken for one of them.
function readThrottleSeenRecord(recordPath) {   // -> { url, nonce }, or null when unreadable
  let raw;
  try { raw = fs.readFileSync(recordPath, 'utf8'); } catch { return null; }
  const lines = raw.split('\n');
  return { url: (lines[0] ?? '').trim(), nonce: (lines[1] ?? '').trim() };
}
// #215 gate r4 P2 (3): the single entry point for an observation — adopt orphans, THEN snapshot.
// Order is the whole point: a record adopted after the snapshot is absent from it, so the retire
// this observation is about to perform would skip it and leave the old charge on disk to suppress
// the NEXT episode. Every scan and every memo render calls this instead of snapshotting directly,
// so a future observation site cannot forget the adoption half.
function beginThrottleObservation() {
  adoptThrottleSeenOrphans();
  return snapshotThrottleSeenGenerations();
}
function snapshotThrottleSeenGenerations() {
  const generations = new Map();
  let names;
  try { names = fs.readdirSync(THROTTLE_SEEN_DIR); } catch { return generations; }   // no directory yet: nothing observed
  for (const name of names) {
    if (name.includes(THROTTLE_RETIRE_INFIX)) continue;   // a retire temp is not a record (r3 D2)
    try {
      const recordPath = path.join(THROTTLE_SEEN_DIR, name);
      const { ino, mtimeMs } = fs.statSync(recordPath);
      // One extra small read per record per observation, over a directory capped at
      // THROTTLE_SEEN_MAX (512) tiny files — and only on a scan that is about to issue CDP
      // evaluates over every open tab anyway.
      generations.set(name, { ino, mtimeMs, nonce: readThrottleSeenRecord(recordPath)?.nonce ?? '' });
    } catch {}   // vanished between readdir and stat: not this observation's to retire
  }
  return generations;
}
// Removing the record must also be serialized with a concurrent create at the SAME name, or the
// generation check is merely a narrower race: B can replace the record between the check and the
// unlink. So take the name away atomically FIRST (rename to a sibling temp only this process can
// name), then decide what was taken. From that instant the 'wx' create in recordThrottleSeen
// sees the name free and whatever it writes there is safe from everything below.
//
// #215 skeptic r3 D5: an ACCEPTED residual of taking the name away first. Between the rename and
// the link-back the record is invisible at its name, so a THIRD process checking
// throttleAlreadyCharged in that window reads the fingerprint as new and can charge one duplicate
// cooldown. The window is a rename, a stat and a read wide, and it is strictly narrower than what
// it replaced: before this guard the retire unlinked the record unconditionally, leaving the name
// free until some later scan recharged it. One duplicate charge in a microsecond-wide window is
// the price of never deleting another process's newer record; closing it needs a lock over the
// whole directory, which is the shared mutable state this design deliberately has none of.
function retireThrottleSeenRecord(recordPath, name, observed) {
  const tempPath = path.join(THROTTLE_SEEN_DIR, `${name}${THROTTLE_RETIRE_INFIX}${process.pid}`);
  // ENOENT: another retire got there first. Any other failure leaves the record in place, which
  // is the safe direction (one suppressed repeat, never a double-charged cooldown).
  try { fs.renameSync(recordPath, tempPath); } catch { return; }
  let current;
  try { current = fs.statSync(tempPath); } catch { return; }
  const nonce = readThrottleSeenRecord(tempPath)?.nonce ?? '';
  if (current.ino === observed.ino && current.mtimeMs === observed.mtimeMs
      && nonce === (observed.nonce ?? '')) {
    try { fs.unlinkSync(tempPath); } catch {}   // exactly the generation this observation covered
    return;
  }
  // Someone replaced the record between the snapshot and the rename, so this is a NEWER record
  // whose cooldown this observation says nothing about: put it back under its name. linkSync,
  // never renameSync — a record created at that name in the meantime must not be clobbered.
  try {
    fs.linkSync(tempPath, recordPath);
  } catch (err) {
    // #215 skeptic r3 D1: the two failures are NOT the same and must not share a handler. EEXIST
    // means the name is taken by a record that already carries the same "charged" meaning, so the
    // temp is redundant and is dropped below. Anything else (ENOSPC, EDQUOT, EIO, EPERM) means the
    // link did not happen and this temp is the ONLY copy of that newer record — unlinking it here
    // destroyed exactly what this branch exists to preserve, and the next scan then charged the
    // unchanged modal a second cooldown. Leave it: pruneThrottleSeen adopts it back under its name
    // on the next invocation, and the TTL still bounds it if nothing ever does.
    if (err?.code !== 'EEXIST') return;
  }
  try { fs.unlinkSync(tempPath); } catch {}
}
function retireThrottleSeenForHealthyUrls(healthyUrls, protectedKeys = new Set(), generations = null) {
  if (!healthyUrls || healthyUrls.size === 0) return;
  // No snapshot means no observation window to bound this retire to, so it retires nothing:
  // under-retire is the safe direction everywhere in this file, and every caller passes one.
  if (!(generations instanceof Map)) return;
  let names;
  try { names = fs.readdirSync(THROTTLE_SEEN_DIR); } catch { return; }
  for (const name of names) {
    if (name.includes(THROTTLE_RETIRE_INFIX)) continue;              // a retire temp is not a record (r3 D2)
    if (protectedKeys.has(name)) continue;                           // a fingerprint THIS scan is about to check
    const observed = generations.get(name);
    if (!observed) continue;                                         // created after this observation started
    const recordPath = path.join(THROTTLE_SEEN_DIR, name);
    if (pendingThrottleSeenRecords.includes(recordPath)) continue;   // created moments ago, cooldown not yet published
    // Records carry the URL on their first line and (since r3 D4) a nonce on their second, so the
    // whole file is no longer the URL: parse it. An empty record (written by builds before the
    // URL line existed) is attributable to no URL and is still never retired here.
    const stored = readThrottleSeenRecord(recordPath);
    if (!stored?.url || !healthyUrls.has(stored.url)) continue;
    retireThrottleSeenRecord(recordPath, name, observed);
  }
}
// The health half of that rule, shared by the main scan and the organizer scan so both read ONE
// definition. Every LISTED tab falls into exactly one of three states for its URL:
//   throttled — a dialog read that SUCCEEDED and found the limiter's copy, or body text still
//               carrying that copy (THROTTLE_RE, the same regex isThrottlePage tests);
//   unknown   — the dialog read FAILED, or the text read failed, came back empty, or came back a
//               page that is not a rendered conversation (a loading shell, a login wall, an error
//               page): evidence of nothing, in either direction;
//   healthy   — the dialog read succeeded and found no dialog, and the text read returned a
//               RENDERED CONVERSATION (isRenderedConversation) with no limiter copy in it.
// A URL is healthy in a scan when at least one tab at it is healthy AND no tab at it is throttled
// AND no tab at it is unknown. The throttled clause keeps a URL that is both healthy and
// throttled right now out of the retire set, so a scan can never retire a record it is itself
// about to charge or check. The unknown clause (#215 gate r3 P2) keeps a healthy tab from
// speaking for a SIBLING instance of the same URL that nobody could read — which may still be
// holding the charged modal, ready to charge a second cooldown the moment it answers again.
//
// #215 skeptic r2 D1: "unknown" used to be indistinguishable from "healthy" for the dialog,
// because tabThrottleModal returned null for a failed read (evaluate timeout, websocket error,
// detached target, a dialog momentarily not laid out) exactly as it did for a genuinely absent
// one. A single flaky evaluate over a still-throttled stale tab therefore retired that URL's
// fingerprint and let the very next scan re-arm a fresh 900s account cooldown — the #208 livelock
// reached through read flakiness instead of a real new episode. Hence throttleModalOk, carried
// out of tabThrottleModalRead by the two callers that build these reads. Hence, too, the
// THROTTLE_RE clause: isThrottlePage can never fire on a marker-bearing conversation page (it
// rejects any text carrying a pg-run marker at all), so the interstitial test alone was blind on
// the one surface that matters here, a modal over somebody's conversation. Deliberate trade-off:
// a conversation that merely QUOTES the limiter copy (a review of this very engine does) now
// counts as a throttle surface for RETIRE purposes, so that URL keeps its pre-fix behaviour and
// is never retired. That direction can only suppress a repeat sighting; the other direction
// re-arms a live account cooldown, which is the bug this whole file exists to avoid.
//
// #215 skeptic r2 D2: this deliberately DIVERGES from the main scan's hit filter, which requires
// non-empty text alongside the dialog before it will CHARGE a sighting. For HEALTH purposes any
// successful dialog read at a URL is a throttle surface even when that tab's text read failed:
// charging a cooldown needs an attributable page beneath the modal, refusing to retire does not,
// and under-retire is the safe direction.
//
// Scratch re-renders are deliberately not counted here: they are a recovery probe of ONE
// remembered URL, not an observation of what the browser is showing. That single URL is retired,
// when its render is decisive, by retireThrottleSeenForHealthyRender below.
//
// The two guards on the same-scan clause are NOT the same guard, though a single-fingerprint
// fixture cannot tell them apart (#215 skeptic r2 D5). throttledUrls covers EVERY record at a
// throttled URL, including fingerprints this scan never observed; protectedKeys covers only the
// exact (url, modal-or-page-text) fingerprints this scan DID observe, and its real job is being
// handed to pruneThrottleSeen so the one-time TTL and capacity trim cannot evict a record this
// scan is still about to check.
function scanThrottleHealth(reads) {
  const healthyUrls = new Set();
  const throttledUrls = new Set();
  const unknownUrls = new Set();
  const protectedKeys = new Set();
  for (const { tab, text, throttleModal, throttleModalOk = true } of reads) {
    const url = tab?.url;
    if (!url) continue;
    if (throttleModal || THROTTLE_RE.test(text ?? '')) {
      throttledUrls.add(url);
      const observedKey = throttleSeenKey(url, throttleTextHash(throttleModal ?? text));
      protectedKeys.add(observedKey);
      // #215 gate r4 P2 (2): and remember it for EVERY prune this invocation may still run, not
      // only the one this scan's own charge batch happens to trigger. This branch is reached by
      // tabs the charge path filters out (a readable dialog over an unreadable page), which are
      // exactly the fingerprints that used to reach the prune unprotected.
      observedThrottleSeenKeys.add(observedKey);
      continue;
    }
    // unknown: proof of neither throttle nor health — a failed dialog read, or a text read that
    // failed (null) or came back empty. #215 gate r3 P2: collected, not merely skipped. Two tabs
    // can sit at ONE url; with a healthy sibling beside an unreadable instance, skipping the
    // unreadable one let the sibling speak for the whole url and retire a fingerprint whose modal
    // was still on screen in the tab nobody could read — and the next scan that CAN read it
    // charges the unchanged modal a second cooldown. A url one tab could not be read at is not a
    // url this scan proved healthy, so it leaves the retire set exactly as a throttled one does.
    // #215 gate r4 P2 (1): and a successful text read is not health either unless what came back
    // is a RENDERED CONVERSATION. `ChatGPT\nLoading…`, a login wall and an error page are all
    // non-empty text with no dialog over them, and treating one as proof the conversation
    // recovered retired a charged fingerprint on the strength of a page that never rendered — the
    // limiter then reappears on the reload and charges a second cooldown for the same episode.
    // Unknown, exactly as an unreadable tab is: this scan proved nothing about that URL.
    if (!throttleModalOk || !isRenderedConversation(text)) { unknownUrls.add(url); continue; }
    healthyUrls.add(url);
  }
  for (const url of throttledUrls) healthyUrls.delete(url);
  for (const url of unknownUrls) healthyUrls.delete(url);
  return { healthyUrls, throttledUrls, unknownUrls, protectedKeys };
}
// #215 skeptic r2 D3: the memo-recovery renders (the organizer's scratch open, and the main
// scan's seeded re-render of the remembered URL) are the ONLY observation an invocation makes
// when the conversation has no tab at all — and scanThrottleHealth deliberately ignores scratch
// renders. So throttle -> healthy -> throttle through that path charged exactly ONE cooldown: the
// third invocation reported throttle again while the engine's mtime-based clock
// (pg_cooldown_remaining_secs, 900s) reported nothing left, with the limiter live. A render that
// reaches a DECISIVE non-throttle outcome with a successful text read is positive evidence about
// exactly ONE conversation, so it retires exactly that ONE URL's records and can never touch
// another's. Timeouts, empty reads and inconclusive hydration are not decisive and retire
// nothing. #215 skeptic r2c A: neither does a render whose DIALOG read failed, nor one whose page
// still carries the limiter copy — both arrive here with decisive=false (the callers' retireSafe),
// because "I could not look" and "the copy is still on the page" are not evidence of health, and
// laundering either one into health re-arms a live account cooldown on the very next scan.
// `throttledUrls` is this scan's listed-tab throttle set: a URL some open tab showed the
// limiter on in this same scan is never retired on a scratch render's say-so.
const DECISIVE_HEALTHY_RENDER_REASONS = new Set(['marker-found', 'foreign-marker']);
// #215 gate r3 P2: `unknownUrls` is the other half of that listed-tab veto. A url some listed tab
// could not be read at this scan is not a url a render may retire on its own say-so either: the
// render proves one conversation is healthy NOW, while the unreadable tab may still be holding
// the very modal whose fingerprint would be retired. `generations` is the caller's snapshot,
// taken before the render was opened — a render can take tens of seconds, which is exactly the
// window another process needs to charge a fresh cooldown.
function retireThrottleSeenForHealthyRender(url, decisive, throttledUrls = null, unknownUrls = null, generations = null) {
  if (!url || !decisive) return;
  if (throttledUrls?.has(url)) return;
  if (unknownUrls?.has(url)) return;
  retireThrottleSeenForHealthyUrls(new Set([url]), new Set(), generations);
}
// "Already charged" is now a plain existence check on the record file, not a load-then-scan of
// an in-memory snapshot — there is no snapshot to go stale, so two processes checking/creating
// records for the SAME or DIFFERENT fingerprints can never clobber one another (#208 gate r2 P2).
function throttleAlreadyCharged(url, hash, protectedKeys) {
  if (!throttleSeenPruned) { throttleSeenPruned = true; pruneThrottleSeen(protectedKeys); }
  return fs.existsSync(throttleSeenRecordPath(url, hash));
}
// Creates the record with the 'wx' flag: this throws EEXIST (caught, ignored) if another
// process already created the SAME fingerprint's file between this call's caller checking
// throttleAlreadyCharged and reaching here — the exact race #208 gate r2 P2 closes. Either way
// the record exists once this returns (best-effort on mkdir/write failure, same as every other
// sidecar write in this file).
function recordThrottleSeen(url, hash) {  // -> true when THIS call may charge the sighting
  let fd = null;
  // Hoisted out of the try (it only hashes) so the catch below can unlink the exact path the
  // 'wx' create won — #215 skeptic r2c B.
  const recordPath = throttleSeenRecordPath(url, hash);
  try {
    fs.mkdirSync(THROTTLE_SEEN_DIR, { recursive: true });
    // #215 gate r2 P2: the record's CONTENT is the URL it was charged for. The filename is a
    // hash of (url, text-hash) and cannot be reversed, so without this a record could never be
    // attributed back to a conversation and retireThrottleSeenForHealthyUrls below would need a
    // second index to maintain (and to keep consistent through every crash and race this
    // directory's whole design exists to survive). Records written by earlier builds are empty;
    // that is handled there, not here.
    // #215 skeptic r2 D4: create and fill in two steps, with the rollback registration BETWEEN
    // them. As one writeFileSync, a content-write failure after the file was created (ENOSPC is
    // the real-world one) left an EMPTY record behind that the rollback below could not remove —
    // the path had not been pushed yet — while the catch still returned "charge me". Being empty,
    // that record is also exempt from retire-on-healthy, so it suppressed its fingerprint for the
    // full 7-day TTL. The 'wx' open remains the sole race arbiter and still throws EEXIST.
    fd = fs.openSync(recordPath, 'wx');
    // #208 gate r6 P2: this record is provisional — the 'wx' create still has to win the race
    // BEFORE the cooldown it gates is attempted, but it must not outlive a failed publish.
    // recordThrottle rolls it back if that write fails, and (since #215 skeptic r2 D4) if this
    // call's own content write fails too.
    pendingThrottleSeenRecords.push(recordPath);
    // #215 skeptic r3 D4: a random nonce on the SECOND line, so two creates at one name are
    // distinguishable even when the filesystem hands the replacement the freed inode inside the
    // mtime's resolution — see snapshotThrottleSeenGenerations. Written in the same call as the
    // URL: a record that exists without its nonce is a record two generations of which can be
    // confused, so it must never be reachable as a separate failure.
    // writeFileSync loops on short writes; the bare writeSync it replaces did not, so it could
    // strand a TRUNCATED record as easily as an empty one (#215 skeptic r2c B).
    fs.writeFileSync(fd, `${url}\n${randomBytes(16).toString('hex')}\n`);
    return true;
  } catch (err) {
    // #215 skeptic r2c B: the create WON (fd is set) but the content write failed — the record
    // exists and is empty. Registering it for rollback is not enough: recordThrottle only drains
    // that list when the COOLDOWN write fails, and the overwhelmingly likely next step is a
    // cooldown write that SUCCEEDS and clears the list, leaving a zero-byte record behind.
    // Empty means attributable to no URL, so retire-on-healthy can never remove it, and
    // pruneThrottleSeen protects it whenever the fingerprint is observed: a 7-day silent
    // suppression of a live limiter. So remove it here, and still return true — charging is the
    // safe direction (two racers each writing a cooldown only over-backs-off).
    if (fd !== null) {
      const pendingAt = pendingThrottleSeenRecords.lastIndexOf(recordPath);
      if (pendingAt >= 0) pendingThrottleSeenRecords.splice(pendingAt, 1);
      try { fs.unlinkSync(recordPath); } catch {}
    }
    // EEXIST: another invocation won the race for this exact fingerprint between the caller's
    // pre-check and this write, and it is the one charging the cooldown — this call must treat
    // the sighting as already charged (local skeptic on gate r2: two racers both returning
    // "new" would each write a cooldown). Any OTHER failure keeps the best-effort rule every
    // sidecar write in this file follows: charge anyway, so a sidecar problem can never silence
    // a real throttle.
    return err?.code !== 'EEXIST';
  } finally {
    if (fd !== null) try { fs.closeSync(fd); } catch {}
  }
}
// #208 gate r2 P1: true once ANY throttle surface not proven to belong to another run (no
// FOREIGN exact marker readable in its text) was observed this invocation — set inside
// tripThrottleUnowned below, the one shared gate every unowned throttle trip already routes
// through, regardless of whether that sighting turned out to be charged (genuinely new) or
// ignored (already charged earlier). Consulted only once, at the very end of the scan: a
// throttle surface that is not POSITIVELY someone else's conversation is inconclusive evidence,
// never proof "marker" is gone, so it must not let the scan fall through to a confirmed-absent
// exit 4 — that wrongly spends a paid review's finite recovery-miss budget on a rate limit.
let inconclusiveThrottleSeen = false;
let inconclusiveThrottleWhere = null;
// #208: the CENTRAL gate every UNOWNED throttle trip routes through — the whole-scan modal
// fallback, the per-tab interstitial check in the probe/harvest reads loop, and the organizer
// scan's direct throttle check all call this before charging a cooldown. OWNED sightings (this
// run's exact marker under the modal) never call it: #162's contract is that those re-arm
// unconditionally every time, because they are this run's own positive existence proof.
// `foreign` (default false — the common case: a markerless interstitial can never be foreign by
// isThrottlePage's own construction) is true only when the caller already proved the page under
// the surface carries ANOTHER run's exact marker; that is the ONLY case allowed to skip setting
// inconclusiveThrottleSeen, per the r2 P1 rule above.
// Returns false — and charges no NEW record — when (url, hash-of-text) was already charged by an
// earlier unowned trip (this scan or a prior invocation's): the caller must skip
// recordThrottle/exit and treat the tab as though it carried no modal at all. Returns true for a
// genuinely new sighting, after recording it so a later trip (this scan or the next invocation)
// recognizes it too.
// `protectedKeys` (default: just this call's own fingerprint) is forwarded to
// throttleAlreadyCharged's one-time prune so it never evicts a fingerprint the CURRENT scan
// still needs (#208 gate r3 P2) — a batch call passes the whole batch's keys so all of them
// survive the same prune, not just whichever happens to be checked first.
function tripThrottleUnowned(url, text, where, foreign = false, protectedKeys = null) {
  const hash = throttleTextHash(text);
  if (!foreign) {
    // Name the FIRST surface that made this scan inconclusive; later hits keep the flag set.
    if (!inconclusiveThrottleSeen) inconclusiveThrottleWhere = where;
    inconclusiveThrottleSeen = true;
  }
  const keys = protectedKeys ?? new Set([throttleSeenKey(url, hash)]);
  // The pre-check answers the common case cheaply; the 'wx' create is the authority for the
  // race window after it (exactly one of two simultaneous racers wins and charges).
  if (throttleAlreadyCharged(url, hash, keys) || !recordThrottleSeen(url, hash)) {
    console.error(`stale throttle modal on unowned tab ${url} already charged; ignoring (${where})`);
    return false;
  }
  return true;
}
// #208 gate r2 P2: charge EVERY genuinely new sighting in `hits` (not merely the first) before
// the caller writes its single cooldown. `hits` is [{ url, text, foreign, where }]. The old
// per-hit walk stopped at the first newly admitted sighting and exited immediately, so one
// already-open batch of N stale tabs cost N separate invocations' worth of cooldowns — one
// newly-discovered tab at a time — instead of the one cooldown this single scan, which saw every
// hit in the batch at once, should have charged. This helper only decides and records which
// hits were new; exiting or returning is left to the caller (the main scan exits 5, the
// organizer instead returns a result object). Returns the first newly admitted hit's `where`
// (recordThrottle's message then names the same specific tab a single-shot trip site would have
// named), or null when every hit in the batch was already charged.
// #208 gate r3 P2: compute every hit's fingerprint key BEFORE any of them is checked, so the
// one-time prune this batch triggers (see pruneThrottleSeen) protects the WHOLE batch, not just
// whichever hit happens to be first in list order.
function tripThrottleUnownedBatch(hits) {
  const protectedKeys = new Set(hits.map(({ url, text }) => throttleSeenKey(url, throttleTextHash(text))));
  let firstNewWhere = null;
  for (const { url, text, foreign, where } of hits) {
    if (tripThrottleUnowned(url, text, where, foreign, protectedKeys) && firstNewWhere === null) firstNewWhere = where;
  }
  return firstNewWhere;
}
function tripThrottle(where) {
  recordThrottle(where);
  console.error('evidence-kind: throttle');
  process.exit(5);
}
// #162: the limiter's MODAL over a conversation that renders this run's EXACT marker. The
// conversation demonstrably exists — probe rc 0 keeps meaning "live; a retry would double-spend"
// — but the account is throttled, so probe reports the closed state `throttled` instead of
// `generating`: the reconciler neither resets the miss streak nor treats it as progress, and
// every caller backs off through the cooldown written here. Outside probe the existing exit 5
// applies unchanged: cooldown written, do NOT resubmit, harvest again after the pause.
function tripThrottleOverConversation(url, where) {
  recordThrottle(where);
  if (!probe) process.exit(5);
  console.error(`live conversation: ${url}`);
  console.error('probe-state: throttled');
  process.exit(0);
}
// Route throttle evidence from any surface: owned (modal over our marker) proves existence,
// anything else (interstitial, modal over a foreign or blacklisted page) proves only the limiter
// — and only when tripThrottleUnowned confirms it is not a stale repeat of a sighting already
// charged (#208).
function tripThrottleEvidence(url, evidence, where) {
  if (evidence.owned) tripThrottleOverConversation(url, where);
  if (!tripThrottleUnowned(url, evidence.hashText, where, evidence.foreign)) return;
  tripThrottle(where);
}

let evaluateRequestId = 0;
async function evaluateTab(tab, expression, awaitPromise = false, timeoutMs = 5_000) {
  return await new Promise((resolve) => {
    const requestId = ++evaluateRequestId;
    let ws;
    try {
      ws = new WebSocket(tab?.webSocketDebuggerUrl);
    } catch {
      resolve({ ok: false, reason: 'invalid-websocket-url' });
      return;
    }
    // Read-only probes retain the short bail because suspended renderers accumulate. UI actions
    // pass a longer operation-specific timeout and carry an in-page lease that expires first.
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(bail);
      try { ws.close(); } catch {}
      resolve(value);
    };
    const bail = setTimeout(() => finish({ ok: false, reason: 'evaluate-timeout' }), timeoutMs);
    ws.onerror = () => finish({ ok: false, reason: 'websocket-error' });
    ws.onopen = () => {
      try {
        ws.send(JSON.stringify({
          id: requestId,
          method: 'Runtime.evaluate',
          params: { expression, returnByValue: true, awaitPromise },
        }));
      } catch {
        finish({ ok: false, reason: 'websocket-send-failed' });
      }
    };
    ws.onmessage = (ev) => {
      try {
        const m = JSON.parse(ev.data);
        if (m.id !== requestId) return;
        if (m.error || m.result?.exceptionDetails) finish({ ok: false, reason: 'evaluate-failed' });
        else finish({ ok: true, value: m.result?.result?.value });
      } catch { finish({ ok: false, reason: 'invalid-cdp-response' }); }
    };
  });
}

const testMutationEvaluateMs = Number(process.env.PRO_GATE_TEST_MUTATION_EVALUATE_MS ?? 0);
const MUTATION_EVALUATE_MS = Number.isFinite(testMutationEvaluateMs) && testMutationEvaluateMs >= 50
  ? testMutationEvaluateMs
  : 15_000;
const testMutationLeaseMs = Number(process.env.PRO_GATE_TEST_MUTATION_LEASE_MS ?? 0);
const MUTATION_LEASE_MS = Number.isFinite(testMutationLeaseMs) && testMutationLeaseMs >= 50
  ? testMutationLeaseMs
  : ORGANIZER_MUTATION_LEASE_MS;
let mutationSequence = 0;
const nextMutation = () => ({
  mutationToken: `${process.pid}.${++mutationSequence}`,
  mutationExpiresAt: Date.now() + MUTATION_LEASE_MS,
});

async function evaluateMutation(tab, buildExpression) {
  const mutation = nextMutation();
  const result = await evaluateTab(
    tab,
    buildExpression(mutation),
    true,
    MUTATION_EVALUATE_MS,
  );
  if (result.ok) return result;
  // Closing the DevTools socket does not cancel Runtime.evaluate. Revoke this token in the renderer
  // so work that already armed its lease stops immediately. Cancellation acknowledgement alone is
  // not enough to release serialization: the original expression may still be queued and can arm
  // after cancellation observes no token, so every timed-out mutation stays locked through the
  // absolute pre-issued expiry.
  await evaluateTab(
    tab,
    buildCancelOrganizerMutationExpression(
      marker,
      mutation.mutationToken,
      mutation.mutationExpiresAt,
    ),
    false,
    5_000,
  );
  const leaseRemainingMs = mutation.mutationExpiresAt - Date.now();
  if (leaseRemainingMs > 0) await sleep(leaseRemainingMs + 25);
  return result;
}

const scopedResponses = new Set();
async function tabText(tab) {
  const expression =
    '/* pro-gate:review-text */ (' +
    readReviewText.toString() +
    ')(document, ' +
    JSON.stringify(marker) +
    ')';
  const result = await evaluateTab(tab, expression);
  if (!result.ok) return null;
  if (typeof result.value === 'string') return result.value;
  if (typeof result.value?.text !== 'string') return null;
  if (result.value.promptAt === 0) scopedResponses.add(result.value.text);
  return result.value.text;
}

async function tabTerminalInfrastructure(tab) {
  const expression = `(() => {
    /* pro-gate:terminal-infrastructure */
    const accepted = new Set(${JSON.stringify([...TERMINAL_INFRA_LINES])});
    const text = (node) => (node?.innerText || node?.textContent || '').trim();
    const candidates = Array.from(document.querySelectorAll('[role="alert"], [data-testid*="error" i], [class*="error" i], p, div, span'));
    for (const node of candidates) {
      const value = text(node);
      if (!accepted.has(value)) continue;
      if (node.closest('[data-message-author-role="user"]')) continue;
      let scope = node;
      for (let depth = 0; scope && depth < 6; depth += 1, scope = scope.parentElement) {
        const retry = Array.from(scope.querySelectorAll('button')).some((button) => /^(retry|try again|regenerate)$/i.test(text(button)));
        if (retry) return value;
      }
    }
    return null;
  })()`;
  const result = await evaluateTab(tab, expression);
  return result.ok && TERMINAL_INFRA_LINES.has(result.value) ? result.value : null;
}

// #162: the "Too many requests" modal over a rendered conversation, read as an ELEMENT rather
// than from whole-page text (see buildThrottleModalExpression). Returns the bounded dialog text
// or null; the shared THROTTLE_RE recheck keeps an unexpected evaluator value from counting.
// #215 skeptic r2 D1: `ok` says whether the READ itself succeeded, which is a different question
// from what it found. A failed evaluate (timeout, websocket error, detached target, a dialog
// momentarily not laid out) is not evidence the dialog is absent, and scanThrottleHealth must not
// read it as one — see the three-state classification there.
// #215 skeptic r2c A: the two memo-recovery renders were the last callers of the thin
// tabThrottleModal wrapper below, for the same reason — they may RETIRE a charged fingerprint,
// and null-for-both cannot tell a healthy page from an unreadable one. The wrapper is kept as
// the read for any future caller that genuinely only wants the dialog text; it currently has
// none.
async function tabThrottleModalRead(tab) {
  const result = await evaluateTab(tab, buildThrottleModalExpression());
  const modal = result.ok && typeof result.value === 'string' && THROTTLE_RE.test(result.value)
    ? result.value
    : null;
  return { ok: result.ok, modal };
}
async function tabThrottleModal(tab) {
  return (await tabThrottleModalRead(tab)).modal;
}

async function closeTab(id) {
  try { return (await fetch(`http://127.0.0.1:${port}/json/close/${id}`)).ok; } catch { return false; }
}

// --sweep-root: close idle chatgpt.com ROOT tabs (no /c/ path). A run killed before it submits
// leaves its tab parked at the root, where the marker-based --close can never match it; a week
// of watchdog/hard-cap kills accumulated 23 such renderers (real memory pressure: the health
// gate defers reviews below 1GB free). Callers must only invoke this when no oracle CLI is
// young enough to still be pre-navigation (the engine gates on process age). Never closes
// conversation (/c/) tabs, and always leaves at least one tab so Chrome itself stays alive.
if (sweepRoot) {
  let tabs = [];
  try {
    tabs = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).filter((t) => t.type === 'page');
  } catch { process.exit(0); }
  const isRoot = (t) => /^https:\/\/chatgpt\.com\/?(\?.*)?$/.test(t.url || '');
  const roots = tabs.filter(isRoot);
  const keepers = tabs.length - roots.length;
  // Keep one tab alive when root tabs are all Chrome has left.
  const closable = keepers >= 1 ? roots : roots.slice(1);
  let closed = 0;
  for (const tab of closable) { await closeTab(tab.id); closed += 1; }
  console.error(`cdp-salvage --sweep-root: closed ${closed} idle root tab(s); ${tabs.length - closed} tab(s) remain`);
  process.exit(0);
}

// --close: post-review cleanup. Because we run oracle with --browser-archive=never (so the
// probe/salvage can always find the conversation by marker), the wrapper must close the tab
// itself once the review is confirmed, or /c/ tabs would accumulate. Close every conversation
// tab carrying THIS run's marker. Best-effort, bounded, non-fatal (never fail a finished run).
// v0.17: renderer-dead-tab fallback. Under Xvfb a background conversation
// tab's renderer can suspend or crash: Runtime.evaluate then returns nothing
// (and /json/activate does NOT revive it) even though the finished review
// exists in ChatGPT server state. Re-render the SAME conversation URL in a
// fresh scratch tab (non-destructive; uses the signed-in profile), read the
// text there, and close the scratch tab.
const FRESH_RENDERS_PER_CYCLE = 3;
// v0.18: per-URL budgets — each fresh render is a server-side conversation
// fetch, so unmatched URLs get a hard per-invocation cap and the matched URL
// is re-rendered at most once per interval while its VERDICT lands.
const MAX_RENDERS_PER_URL = probe ? 1 : 2;
const RENDER_INTERVAL_MS = 90_000;
const renderTried = new Map();   // url -> renders spent this invocation (unmatched URLs only)
const nextRenderAt = new Map();  // url -> earliest timestamp for the next render
const ourUrls = new Set();       // URLs proven to carry THIS run's marker (exempt from the cap)

// The remembered conversation for THIS marker (see the header note). Proven ours by an earlier
// invocation, so it joins ourUrls: exempt from the per-URL render cap and from the blacklist.
// Bounded like every other render source — each one is a real chatgpt.com page load, and
// hammering the account is what tripped the 2026-07-03 anti-scraping limiter.
// MUTABLE: a conversation proven ours THIS invocation must be usable immediately. The tab we
// just matched is exactly the one that dies mid-salvage when the box runs out of memory — the
// failure this file exists for — so a snapshot read once at startup would leave the recovery
// branch blind for the whole run and only help the NEXT invocation (gate P1).
let knownUrl = recallUrl(marker);
const MAX_SEEDED_RENDERS = probe ? 1 : 8;
let seededRenders = 0;
// Liveness proven against SERVER-SIDE state, tracked separately from the open-tab scan below.
// It is evidence about ChatGPT, not about this Chrome's tab list, so a later empty scan must
// not erase it (gate P1): otherwise a harvest can prove the conversation live over and over,
// exhaust its render budget, and still report "gone".
let seededLiveUrl = null;
let memoStale = false;       // the remembered URL decisively carries ANOTHER run's conversation
// crossBindHits / ownershipProven are declared next to flushCrossBind() above, because the
// exit hook registered there reads them (#76).
if (knownUrl) ourUrls.add(knownUrl);

// Persistent blacklist: conversations proven (by a foreign run marker) to belong to another
// review. SCOPED TO THE MARKER that proved it (v0.25). It used to hold bare URLs and was
// therefore GLOBAL — but "this URL is some other run's conversation" is true only relative to
// the run that observed it. Run A rendering run B's conversation permanently blacklisted B's
// own URL, hiding B's finished review from B itself. Observed on a live box: a completed
// review sat on the blacklist while its own run reported "conversation gone".
// Lines are "<marker>\t<url>". Legacy bare-URL lines are ignored and dropped on the next
// rewrite: they cannot be attributed to a marker, and honoring them would preserve exactly the
// poisoning this fixes.
const nonMatching = new Set();     // URLs proven foreign TO THIS MARKER
const blacklistLines = [];         // retained lines (other markers' entries survive a rewrite)
try {
  for (const raw of fs.readFileSync(BLACKLIST_FILE, 'utf8').split('\n')) {
    const line = raw.trim();
    if (!line) continue;
    const sep = line.indexOf('\t');
    if (sep < 0) continue;         // legacy global entry: ignore (and do not carry it forward)
    blacklistLines.push(line);
    if (line.slice(0, sep) === marker) nonMatching.add(line.slice(sep + 1));
  }
} catch {}
function blacklist(url) {
  // Never blacklist a URL already proven ours (notably the remembered conversation): that is
  // the one entry that could make a real review permanently unreachable.
  if (ourUrls.has(url) || nonMatching.has(url)) return;
  nonMatching.add(url);
  blacklistLines.push(`${marker}\t${url}`);
  try {
    fs.mkdirSync(PG_HOME, { recursive: true });
    // APPEND-ONLY (gate #54 r14): the shell rejection path appends concurrently, and a
    // whole-file rewrite from a stale in-memory snapshot could erase its freshly rejected
    // entry — letting the rejected open tab replay. Compaction is opportunistic, under a
    // lock both writers respect, and skipped on contention.
    fs.appendFileSync(BLACKLIST_FILE, `${marker}\t${url}\n`);
    if (blacklistLines.length > 800) {
      const lockDir = `${BLACKLIST_FILE}.lock.d`;
      try {
        fs.mkdirSync(lockDir);
        try {
          const fresh = fs.readFileSync(BLACKLIST_FILE, 'utf8').split('\n').filter((l) => l.includes('\t'));
          const tmp = `${BLACKLIST_FILE}.tmp.${process.pid}`;
          fs.writeFileSync(tmp, fresh.slice(-500).join('\n') + '\n');
          fs.renameSync(tmp, BLACKLIST_FILE);
        } finally { try { fs.rmdirSync(lockDir); } catch {} }
      } catch {}
    }
  } catch {}
}

// A fresh render runs inside a watchdog/probe deadline. Native fetch has no deadline of its
// own, so every scratch CDP request carries the caller's remaining budget for the part that can
// genuinely hang forever: waiting for headers from a peer that never answers at all (the
// hangScratchOpen/hangScratchList case). Body consumption is a TWO-STAGE bound instead of
// sharing that same signal to its end: once headers land, the response — and any CDP target it
// names — is real, already-created server-side state, so a deadline landing mid-JSON-parse must
// not lose the only reference to it. Headers-received swaps the caller's (possibly near-zero)
// remaining budget for a small independent grace window to let `consume` finish.
const CONSUME_GRACE_MS = 2_000;
async function fetchBeforeDeadline(url, options, requestDeadline, consume = null) {
  const remaining = requestDeadline - Date.now();
  if (remaining <= 0) throw new Error('caller-deadline-expired');
  const controller = new AbortController();
  let timeout = setTimeout(() => controller.abort(), remaining);
  try {
    const response = await fetch(url, { ...options, signal: controller.signal });
    if (!consume) return response;
    // Headers arrived: replace the caller's-deadline timer with the fixed grace window so a
    // slow-but-arriving body still completes and callers can capture the target it names.
    clearTimeout(timeout);
    timeout = setTimeout(() => controller.abort(), CONSUME_GRACE_MS);
    return await consume(response);
  } finally {
    clearTimeout(timeout);
  }
}

async function fetchJsonBeforeDeadline(url, options, requestDeadline) {
  return await fetchBeforeDeadline(url, options, requestDeadline, async (response) => (
    // Parse only a successful body. A pre-v111 Chrome answering PUT /json/new (or any other
    // non-2xx CDP response) with a plain-text or empty error body used to get parsed
    // unconditionally here, so response.json() threw before the caller ever got to inspect
    // response.ok — turning the documented PUT-to-GET fallback into an immediate
    // scratch-open-failed/memo-open-failed instead. Callers branch on response.ok themselves;
    // handing them value: null on failure keeps that branch reachable without a parse throw.
    response.ok ? { response, value: await response.json() } : { response, value: null }
  ));
}

async function freshRenderText(url, port, outerDeadline, waitForDecisiveEvidence = false) {
  let target = null;
  try {
    const openUrl = `http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`;
    let opened = await fetchJsonBeforeDeadline(openUrl, { method: 'PUT' }, outerDeadline);
    if (!opened.response.ok) opened = await fetchJsonBeforeDeadline(openUrl, {}, outerDeadline); // pre-v111 Chrome used GET
    if (!opened.response.ok) return { text: null, reason: 'scratch-open-failed' };
    target = opened.value;
    // never grant more than the caller's remaining budget (a 30s probe must
    // not stall watchdog/retry decisions by overrunning its own window)
    const renderDeadline = Math.min(Date.now() + 25_000, outerDeadline);
    let text = null;
    let evidence = null;
    while (Date.now() + RENDER_SAMPLE_MS < renderDeadline) {
      await sleep(RENDER_SAMPLE_MS);
      let tabs;
      try {
        ({ value: tabs } = await fetchJsonBeforeDeadline(`http://127.0.0.1:${port}/json`, {}, renderDeadline));
      } catch { return { text: null, reason: 'cdp-list-failed' }; }
      // A non-2xx /json listing now carries value: null (see fetchJsonBeforeDeadline) instead of
      // throwing — this is CDP-list failure just like the caught exception above, not a tab that
      // legitimately vanished, so it must not fall through to tabs.find() on null.
      if (!tabs) return { text: null, reason: 'cdp-list-failed' };
      const live = tabs.find((t) => t.id === target.id);
      if (!live) return { text: null, reason: 'target-disappeared' };
      // A scratch target may redirect, be reused, or be replaced underneath us. Its DOM is
      // evidence only for the canonical URL requested above, never merely for a matching target id.
      if (live.url !== url) return { text: null, reason: 'target-url-drift' };
      // #162: a scratch render against a limited account can paint the modal over the
      // conversation it just loaded. Read the element alongside the text (one bail, not two)
      // before any marker test below can call that page "ours and still generating".
      // #215 skeptic r2c A: read the dialog through tabThrottleModalRead, not the thin wrapper.
      // This render is one of only two observations allowed to RETIRE a charged fingerprint (see
      // retireThrottleSeenForHealthyRender), and the thin wrapper answers null both for "no dialog"
      // and for a read that FAILED — so one flaky evaluate over a still-limited conversation used
      // to reach a decisive non-throttle reason, retire that URL's record, and let the next scan
      // re-arm a fresh account cooldown on an unchanged limiter. Same for a page whose body still
      // carries the limiter copy, which isThrottlePage cannot see under a run marker.
      const [sample, modalRead] = await Promise.all([tabText(live), tabThrottleModalRead(live)]);
      const throttleModal = modalRead.modal;
      if (!sample) continue;
      text = sample;
      // Permission to RETIRE, and nothing else: the CHARGE branches below still test
      // isThrottlePage || modal, so a conversation that merely QUOTES the limiter copy (a review
      // of this very engine does) still never charges a cooldown — it only stops being counted as
      // proof of health. Under-retire suppresses at most a repeat sighting; over-retire re-arms a
      // live 900s account cooldown, which is the failure this whole file exists to avoid.
      const retireSafe = modalRead.ok && !THROTTLE_RE.test(sample);
      // Return only on DECISIVE evidence, never on "looks long enough".
      //
      // The old gate returned as soon as innerText passed 200 chars, but innerText covers the
      // whole body — chatgpt.com's shell plus the conversation-history SIDEBAR is ~1.2k chars
      // before the conversation itself has hydrated. Measured on a real box: t=2.5s -> 1172
      // chars, no marker, no VERDICT; t=5.0s -> 5766 chars with both. So the very first sample
      // reliably passed the gate carrying none of the content we came for, the URL failed the
      // marker test, and one of just TWO per-URL attempts was burnt on a page that was merely
      // still loading. Three such invocations in a row is exactly the "conversation gone" storm.
      if (waitForDecisiveEvidence) {
        // A readable source can be a stale snapshot, so this one revalidation must not spend its
        // only scratch navigation on the prompt marker ChatGPT hydrates before the answer. Reuse
        // the shared classifier: marker-only text remains owned-incomplete through the deadline.
        evidence = classifyEvidence(sample, null, throttleModal);
        if (['terminal', 'terminal-infrastructure', 'foreign', 'cross-bound', 'throttle'].includes(evidence.kind)) {
          return { text, reason: `${evidence.kind}-evidence`, evidence };
        }
      } else {
        // Throttle first: the modal sits OVER a marker-bearing page, so a marker test taken
        // first would report a limited account as an ordinary hydrated conversation.
        if (isThrottlePage(sample) || throttleModal) {
          evidence = classifyEvidence(sample, null, throttleModal);
          return { text, reason: 'throttle', evidence }; // interstitial or modal — done
        }
        // #215 gate r4 P2 (1): one shared readiness test with the listed-tab health pass. These
        // two branches ARE isRenderedConversation's disjuncts — only the reason differs — so the
        // render path and scanThrottleHealth can never disagree about what "it rendered" means.
        if (isRenderedConversation(sample)) {
          return hasExactMarker(sample, marker)
            ? { text, reason: 'marker-found', retireSafe }       // ours — done
            : { text, reason: 'foreign-marker', retireSafe };    // provably another run's — done
        }
      }
      // Anything else (shell, pre-hydration, login wall, or a marker-only stale-source render)
      // is NOT an answer: keep sampling and return the last text at the render deadline.
    }
    return { text, reason: text ? 'not-hydrated' : 'read-failed', evidence };
  } catch {
    return { text: null, reason: 'scratch-cdp-failed' };
  } finally {
    // Cleanup ALWAYS gets attempted when a scratch target was opened, even though the caller's
    // budget is usually already spent by the time we get here (that is exactly when a stranded
    // scratch tab does the most damage: it sits open in the user's real Chrome profile, and a
    // later /json list against it can itself hang forever). So this gets a small FIXED budget of
    // its own, independent of outerDeadline, rather than inheriting whatever (possibly zero or
    // negative) time the caller has left. Still best-effort (the try/catch stays).
    if (target?.id) {
      try { await fetchBeforeDeadline(`http://127.0.0.1:${port}/json/close/${target.id}`, {}, Date.now() + 2000); } catch {}
    }
  }
}

const responseClaims = (text) => reviewTextContext(text, marker, scopedResponses.has(text) ? 0 : null);
const mixedAnswer = (text) => responseClaims(text).mixed;
const extractReview = (text) => responseClaims(text).review;

function foreignAnswerMarker(text) {
  const { claims } = responseClaims(text);
  if (claims.some((claim) => claim.markers.some((value) => value.toLowerCase() === marker.toLowerCase()))) return null;
  const verdict = claims.at(-1);
  if (!verdict) return null;
  const foreign = verdict.markers.find((value) => value.toLowerCase() !== marker.toLowerCase());
  if (!foreign || verdict.at < lastExactMarkerAt(text, marker)) return null;
  return foreign;
}

const organizerToken = (value, fallback = 'unknown') => {
  const token = String(value ?? fallback).toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '');
  return (token || fallback).slice(0, 64);
};
function emitOrganizerResult({ source = 'none', renameStatus = 'skipped', archiveStatus = 'disabled', closeStatus = 'skipped', reason = 'ok' }) {
  process.stdout.write(`organizer source=${organizerToken(source)} rename=${organizerToken(renameStatus)} archive=${organizerToken(archiveStatus)} close=${organizerToken(closeStatus)} reason=${organizerToken(reason)}\n`);
}

const isRunMarkerChar = (char) => /[A-Za-z0-9.-]/.test(char ?? '');
// "Exact" here means TOKEN-EXACT — the whole marker, bounded by non-marker characters — not
// byte-exact. Letter case is folded (#167); asciiFold is length-preserving, so every index
// returned still points into the caller's original `text`.
function lastExactMarkerAt(text, wanted) {
  const haystack = asciiFold(text);
  const needle = asciiFold(wanted);
  let found = -1;
  let from = 0;
  while (from <= haystack.length - needle.length) {
    const at = haystack.indexOf(needle, from);
    if (at < 0) break;
    const before = at > 0 ? haystack[at - 1] : '';
    const after = haystack[at + needle.length] ?? '';
    if (!isRunMarkerChar(before) && !isRunMarkerChar(after)) found = at;
    from = at + 1;
  }
  return found;
}
const hasExactMarker = (text, wanted) => !!text && lastExactMarkerAt(text, wanted) >= 0;
function lastExactRunMarkerAt(text) {
  let found = -1;
  for (const match of text.matchAll(/pg-run-[A-Za-z0-9.-]+/gi)) {
    const at = match.index;
    const before = at > 0 ? text[at - 1] : '';
    const after = text[at + match[0].length] ?? '';
    if (!isRunMarkerChar(before) && !isRunMarkerChar(after)) found = at;
  }
  return found;
}

function ownedVerdict(text) {
  return responseClaims(text).verdict;
}

// Mutation authority is intentionally stricter than salvage extraction. The engine may capture a
// nonce-less completed answer and adjudicate it as retryable, but the organizer must not mutate that
// page: once a verdict follows this run's prompt, only an exact marker echo proves it is our answer.
// "Exact" is token-exact, not case-exact (#167): an absent or genuinely different marker still
// refuses, but this run's own lowercased self-echo is this run's answer.
// Any exact run marker AFTER `from` that is not ours. A conversation two runs wrote to is not
// this run's to rename, archive or close: the other run may still be collecting from it.
function foreignRunMarkerAfter(text, from) {
  const tail = text.slice(from);
  for (const match of tail.matchAll(/pg-run-[A-Za-z0-9.-]+/gi)) {
    const at = match.index;
    if (isRunMarkerChar(at > 0 ? tail[at - 1] : '') || isRunMarkerChar(tail[at + match[0].length] ?? '')) continue;
    if (!sameMarker(match[0], marker)) return match[0];
  }
  return null;
}

function organizerOwnership(text) {
  if (!hasExactMarker(text, marker)) return { owned: false, reason: 'marker-missing' };
  if (mixedAnswer(text)) return { owned: false, reason: 'shared-conversation' };
  const verdict = ownedVerdict(text);
  if (!verdict) return { owned: true, reason: 'live' };
  const answerMarker = verdict.line.match(/\(run marker:\s*(pg-run-[A-Za-z0-9.-]+)\s*\)/i)?.[1] ?? null;
  if (sameMarker(answerMarker, marker)) {
    // A later prompt may still be generating in this shared conversation.
    const shared = foreignRunMarkerAfter(text, verdict.at + verdict.line.length);
    if (shared) return { owned: false, reason: 'shared-conversation', foreignMarker: shared };
    return { owned: true, reason: 'completed' };
  }
  if (verdict.at < lastExactMarkerAt(text, marker)) return { owned: true, reason: 'old-verdict' };
  return answerMarker
    ? { owned: false, reason: 'cross-bound', foreignMarker: answerMarker }
    : { owned: false, reason: 'answer-marker-missing' };
}

function normalizeReviewBytes(value) {
  return String(value ?? '').replace(/\r\n?/g, '\n').replace(/\n$/, '');
}

// Locate the token case-insensitively, but slice the ORIGINAL line (#167): the fold is only a
// lookup key, never the published bytes. Must stay in step with pg_strip_nonce and with the twin
// inside cdp-organizer-expressions.mjs — the finalizer compares this output against the bytes the
// engine already stripped, so one of the three folding and the others not is a result-mismatch.
function stripMarkerEcho(value) {
  const token = `(run marker: ${marker})`;
  const foldedToken = asciiFold(token);
  return String(value ?? '').split('\n').map((line) => {
    const at = asciiFold(line).indexOf(foldedToken);
    if (at < 0) return line;
    return `${line.slice(0, at)}${line.slice(at + token.length)}`.replace(/[ \t]+$/, '');
  }).join('\n');
}

let acceptedReview = null;
function finalizerOwnership(text) {
  if (acceptedReview === null) return { owned: false, reason: 'result-file-missing' };
  if (mixedAnswer(text)) return { owned: false, reason: 'shared-conversation' };
  const verdict = ownedVerdict(text);
  if (!verdict) return { owned: false, reason: 'answer-incomplete' };
  const promptMarkerAt = lastExactMarkerAt(text.slice(0, verdict.at), marker);
  if (promptMarkerAt < 0) return { owned: false, reason: 'answer-incomplete' };
  if (lastExactRunMarkerAt(text.slice(verdict.at + verdict.line.length)) >= 0) {
    return { owned: false, reason: 'newer-run-marker' };
  }
  const answerMarker = verdict.line.match(/\(run marker:\s*(pg-run-[A-Za-z0-9.-]+)\s*\)/i)?.[1] ?? null;
  if (!answerMarker) return { owned: false, reason: 'answer-marker-missing' };
  if (!sameMarker(answerMarker, marker)) {
    return { owned: false, reason: 'cross-bound', foreignMarker: answerMarker };
  }
  const review = extractReview(text);
  if (!review || normalizeReviewBytes(stripMarkerEcho(review)) !== acceptedReview) {
    return { owned: false, reason: 'result-mismatch' };
  }
  return { owned: true, reason: 'completed' };
}

function mutationOwnership(text) {
  return finalize ? finalizerOwnership(text) : organizerOwnership(text);
}

async function openOrganizerScratch(url) {
  let target = null;
  try {
    // Bound like freshRenderText's scratch open/list (gate: these were bare fetch() calls, so
    // --organize/--finalize was bounded only by the shell's outer SIGKILL, which skips JS
    // cleanup entirely). Open is bound to the module-level deadline (the whole invocation's
    // budget); the list poll below is bound to renderDeadline, its own tighter sub-budget.
    const openUrl = `http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`;
    let opened = await fetchJsonBeforeDeadline(openUrl, { method: 'PUT' }, deadline);
    if (!opened.response.ok) opened = await fetchJsonBeforeDeadline(openUrl, {}, deadline); // pre-v111 Chrome used GET
    if (!opened.response.ok) return { target: null, reason: 'memo-open-failed' };
    target = opened.value;
    const renderDeadline = Math.min(deadline, Date.now() + 25_000);
    let sawLogin = false;
    while (Date.now() < renderDeadline) {
      await sleep(Math.min(250, Math.max(0, renderDeadline - Date.now())));
      let live = target;
      try {
        const { value: tabs } = await fetchJsonBeforeDeadline(`http://127.0.0.1:${port}/json`, {}, renderDeadline);
        // A non-2xx listing carries value: null rather than throwing (see fetchJsonBeforeDeadline);
        // treat it the same as the caught exception below instead of dereferencing null.
        if (!tabs) return { target, reason: 'cdp-list-failed' };
        live = tabs.find((tab) => tab.id === target.id) ?? null;
      } catch { return { target, reason: 'cdp-list-failed' }; }
      if (!live) return { target, reason: 'memo-tab-disappeared' };
      if (live.url !== url) return { target: live, reason: 'memo-url-drift' };
      const [text, modalRead] = await Promise.all([tabText(live), tabThrottleModalRead(live)]);
      const throttleModal = modalRead.modal;
      if (!text) continue;
      // #215 skeptic r2c A: exactly the freshRenderText rule, for the organizer's half of the same
      // memo-recovery path — permission to RETIRE only, never to charge. A dialog read that FAILED,
      // or a page whose body still carries the limiter copy, decides nothing about health.
      const retireSafe = modalRead.ok && !THROTTLE_RE.test(text);
      // #162: the modal is throttle evidence too; organizer traffic must stop on either form.
      // #208 gate r6 P2: carry back enough for the caller to apply the same unowned gate every
      // other throttle trip site in this file uses — an interstitial can never be owned
      // (isThrottlePage's own construction excludes any marker at all, ours or foreign); a
      // modal's underlying page can still carry this run's exact marker beneath it.
      if (isThrottlePage(text) || throttleModal) {
        const owned = !!throttleModal && hasExactMarker(text, marker);
        return {
          target: live,
          reason: 'throttle',
          throttleUrl: url,
          throttleHashText: throttleModal ?? text,
          throttleOwned: owned,
          throttleForeign: !owned && FOREIGN_MARKER_RE.test(text),
        };
      }
      // #215 skeptic r2 D3: `healthyUrl` marks a DECISIVE non-throttle outcome for this exact
      // URL, read from non-empty text with no throttle surface over it — ours, ours-but-rejected,
      // or provably another run's. Only these three branches set it; a login wall, an
      // unhydrated render, a drifted target or any CDP failure decides nothing and must not
      // retire a fingerprint. The caller retires that one URL's records with it.
      // #215 gate r4 P2 (1): the same shared readiness test the listed-tab health pass uses —
      // these branches ARE isRenderedConversation's disjuncts, and only the reason differs.
      if (isRenderedConversation(text)) {
        if (!hasExactMarker(text, marker)) return { target: live, reason: 'stale-memo', healthyUrl: url, retireSafe };
        const ownership = mutationOwnership(text);
        return ownership.owned
          ? { target: live, text, reason: 'ok', healthyUrl: url, retireSafe }
          : { target: live, reason: ownership.reason, healthyUrl: url, retireSafe };
      }
      if (/\b(log in|sign up)\b/i.test(text) && text.length < 10_000) sawLogin = true;
    }
    return { target, reason: sawLogin ? 'login-wall' : 'memo-not-hydrated' };
  } catch {
    return { target, reason: 'memo-open-failed' };
  }
}

function organizerUiStatus(result, action) {
  if (!result.ok || !result.value || typeof result.value !== 'object') {
    return { status: 'failed', reason: `${action}-evaluate-failed` };
  }
  const status = result.value.status;
  if (action === 'rename' && ['renamed', 'already'].includes(status)) return { status, reason: 'ok' };
  if (action === 'archive' && ['archived', 'already'].includes(status)) return { status, reason: 'ok' };
  if (status === 'skipped') return { status, reason: `${action}-${organizerToken(result.value.reason, 'skipped')}` };
  return { status: 'failed', reason: `${action}-ui-failed` };
}

async function validateOrganizerTarget(target, expectedUrl) {
  let tabs;
  try {
    tabs = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
  } catch {
    return { ok: false, reason: 'cdp-list-failed', tab: null };
  }
  const live = Array.isArray(tabs) ? tabs.find((tab) => tab.id === target?.id) : null;
  if (!live) return { ok: false, reason: 'target-disappeared', tab: null };
  if (live.url !== expectedUrl) return { ok: false, reason: 'target-url-drift', tab: live };
  const text = await tabText(live);
  const ownership = mutationOwnership(text);
  if (!ownership.owned) return { ok: false, reason: ownership.reason, tab: live };
  return { ok: true, reason: 'ok', tab: live, text };
}

async function closeOwnedOrganizerTabs(expectedUrl, authorizedTargetId, allowTargetUrlDrift) {
  let tabs;
  try {
    tabs = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
  } catch {
    return { status: 'failed', reason: 'cdp-list-failed' };
  }
  if (!Array.isArray(tabs)) return { status: 'failed', reason: 'cdp-list-failed' };
  const selected = tabs.find((tab) => tab.id === authorizedTargetId) ?? null;
  if (!selected) return { status: 'failed', reason: 'target-disappeared' };
  const sameUrl = tabs.filter((tab) => tab.type === 'page' && tab.url === expectedUrl);
  const toClose = [];
  for (const tab of sameUrl) {
    if (allowTargetUrlDrift && tab.id === authorizedTargetId) {
      toClose.push(tab);
      continue;
    }
    const text = await tabText(tab);
    const ownership = mutationOwnership(text);
    if (!ownership.owned) return { status: 'failed', reason: ownership.reason };
    toClose.push(tab);
  }
  if (selected.url !== expectedUrl) {
    if (!allowTargetUrlDrift) return { status: 'failed', reason: 'target-url-drift' };
    toClose.push(selected);
  }
  const unique = [...new Map(toClose.map((tab) => [tab.id, tab])).values()];
  if (!unique.length) return { status: 'failed', reason: 'target-disappeared' };
  let closed = 0;
  for (const tab of unique) if (await closeTab(tab.id)) closed += 1;
  return closed === unique.length
    ? { status: 'closed', reason: 'ok' }
    : { status: 'failed', reason: 'close-failed' };
}

async function organizeConversation() {
  const result = {
    source: 'none',
    renameStatus: rename ? 'skipped' : 'disabled',
    archiveStatus: archive ? 'skipped' : 'disabled',
    closeStatus: 'skipped',
    reason: 'ok',
  };
  if (!MARKER_SAFE_RE.test(marker)) return { ...result, reason: 'invalid-marker' };
  if (finalize) {
    const allowedResultFiles = [
      path.resolve(COMPLETED_DIR, marker),
      path.resolve(PENDING_DIR, marker),
    ];
    if (!allowedResultFiles.includes(path.resolve(resultFile))) {
      return { ...result, reason: 'result-file-invalid' };
    }
    let resultFd = null;
    try {
      resultFd = fs.openSync(resultFile, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
      const stat = fs.fstatSync(resultFd);
      const bytes = fs.readFileSync(resultFd, 'utf8');
      if (!stat.isFile() || !bytes) return { ...result, reason: 'result-file-invalid' };
      acceptedReview = normalizeReviewBytes(bytes);
    } catch {
      return { ...result, reason: 'result-file-invalid' };
    } finally {
      if (resultFd !== null) try { fs.closeSync(resultFd); } catch {}
    }
  }

  const rememberedUrl = recallUrl(marker);
  const title = recallTitle(marker);
  let tabs;
  try {
    tabs = (await (await fetch(`http://127.0.0.1:${port}/json`)).json())
      .filter((tab) => tab.type === 'page' && /^https:\/\/chatgpt\.com\/c\//.test(tab.url || ''));
  } catch { return { ...result, reason: 'cdp-list-failed' }; }

  // #215 gate r3 P2: the record generations this scan's observation covers, snapshotted before it
  // reads a single tab — a record another process creates while these reads are in flight is
  // newer than anything concluded below and must survive the retire.
  const scanGenerations = beginThrottleObservation();
  const reads = await Promise.all(tabs.map(async (tab) => {
    const [text, modalRead] = await Promise.all([tabText(tab), tabThrottleModalRead(tab)]);
    // #215 skeptic r2 D1: carry whether the dialog READ succeeded, not only what it found, so
    // scanThrottleHealth can tell "no dialog" from "could not look".
    return { tab, text, throttleModal: modalRead.modal, throttleModalOk: modalRead.ok };
  }));
  // #215 gate r2 P2: the organizer builds the same listed-tab reads/throttleHits pair as the main
  // scan and shares its dedupe store, so it retires on a healthy observation identically and for
  // the same reason — before its own batch below decides "already charged".
  const scanHealth = scanThrottleHealth(reads);
  retireThrottleSeenForHealthyUrls(scanHealth.healthyUrls, scanHealth.protectedKeys, scanGenerations);
  const throttleHits = reads.filter(({ text, throttleModal }) => isThrottlePage(text) || throttleModal);
  if (throttleHits.length > 0) {
    // #162 semantics preserved: an OWNED sighting (this run's exact marker under the modal)
    // always re-arms, decided over the whole scan so a foreign tab listed first cannot hide it.
    const ownedHit = throttleHits.find(({ tab, text }) => !nonMatching.has(tab.url) && hasExactMarker(text, marker));
    if (ownedHit) {
      recordThrottle('organizer scan');
      return { ...result, reason: 'throttle' };
    }
    // Unowned: route through the same dedupe gate (#208) every other unowned trip uses, or a
    // stale foreign tab left open re-arms the account cooldown on every later organizer scan.
    // #208 gate r2 P2: charge EVERY unowned hit in list order first, then write exactly one
    // cooldown — mirroring the main loop's whole-scan walk. The old per-hit walk returned on the
    // first newly admitted hit, leaving the rest of a batch un-recorded for the next organizer
    // scan to rediscover one stale tab at a time (checking only throttleHits[0] had the same bug
    // one layer up: an already-charged stale tab listed first hid a genuinely new unowned modal
    // listed behind it). Each skipped repeat still logs "ignoring" via tripThrottleUnowned itself.
    const firstNewWhere = tripThrottleUnownedBatch(throttleHits.map((hit) => ({
      url: hit.tab.url,
      text: hit.throttleModal ?? hit.text,
      // #215 gate r1 P1: FOREIGN_MARKER_RE matches ANY pg-run marker, THIS run's included, so a
      // BLACKLISTED tab bearing our own marker used to read as another run's conversation — the
      // one classification allowed to skip inconclusiveThrottleSeen — and dropped the scan into
      // confirmed-absent exit 4 on nothing but a rate limit. Ask "is this ours?" first, exactly as
      // classifyEvidence's reference predicate does (`foreign: !owned && FOREIGN_MARKER_RE...`).
      // Blacklisted URLs remain excluded from POSITIVE ownership by ownedHit above; this decides
      // only whether the surface is proven to be SOMEONE ELSE'S, the sole basis for disregarding
      // a throttle sighting when deciding absence.
      foreign: !!hit.text && !hasExactMarker(hit.text, marker) && FOREIGN_MARKER_RE.test(hit.text),
      where: 'organizer scan',
    })));
    if (firstNewWhere !== null) {
      recordThrottle(firstNewWhere);
      return { ...result, reason: 'throttle' };
    }
    // No unowned hit was newly admitted — every sighting this scan found was already charged.
    // Fall through as though no modal/interstitial were present at all.
  }

  const candidatesByUrl = new Map();
  const conflictedUrls = new Set();
  let rejectionReason = 'owned-target-not-found';
  for (const { tab, text } of reads) {
    if (!text || !hasExactMarker(text, marker)) continue;
    const ownership = mutationOwnership(text);
    if (!ownership.owned) {
      conflictedUrls.add(tab.url);
      rejectionReason = ownership.reason;
      continue;
    }
    if (nonMatching.has(tab.url)) {
      rejectionReason = 'provenance-rejected';
      continue;
    }
    if (!candidatesByUrl.has(tab.url)) candidatesByUrl.set(tab.url, []);
    candidatesByUrl.get(tab.url).push({ tab, text });
  }
  for (const url of conflictedUrls) candidatesByUrl.delete(url);

  let target = null;
  let source = 'none';
  const candidateUrls = [...candidatesByUrl.keys()];
  let selectedUrl = null;
  if (acceptedUrl) {
    if (conflictedUrls.has(acceptedUrl)) return { ...result, reason: rejectionReason };
    if (candidatesByUrl.has(acceptedUrl)) selectedUrl = acceptedUrl;
  } else if (candidateUrls.length > 0) {
    if (finalize) {
      selectedUrl = candidateUrls.length === 1 ? candidateUrls[0] : null;
    } else {
      selectedUrl = rememberedUrl && candidatesByUrl.has(rememberedUrl)
        ? rememberedUrl
        : candidateUrls.length === 1 ? candidateUrls[0] : null;
    }
    if (!selectedUrl) return { ...result, reason: 'ambiguous-owned-targets' };
  }
  if (selectedUrl) {
    target = candidatesByUrl.get(selectedUrl)[0].tab;
    source = 'open';
  } else {
    const recoveryUrl = acceptedUrl ?? (candidateUrls.length === 0 ? rememberedUrl : null);
    if (!recoveryUrl) {
      // #208 gate r2 P1: this scan found no owned target anywhere (no open owned tab, no usable
      // remembered URL) — the organizer's analog of the main scan's confirmed-absent exit 4. If
      // an unowned throttle surface not proven foreign was also observed this scan (the walk
      // above charged or ignored it), that surface is the reason nothing owned was found and it
      // is NOT proof "marker" is gone — report inconclusive throttle instead, same as the main
      // scan, without rewriting the cooldown (tripThrottleUnowned already decided that).
      if (inconclusiveThrottleSeen) {
        console.error(`inconclusive: an unowned throttle surface was observed this scan (${inconclusiveThrottleWhere}) `
          + `and not proven to belong to another run — NOT evidence "${marker}" is gone`);
        return { ...result, reason: 'throttle' };
      }
      return { ...result, reason: rejectionReason };
    }
    if (nonMatching.has(recoveryUrl)) return { ...result, reason: 'provenance-rejected' };
    // #215 gate r3 P2: this render's own generation snapshot, taken before it is opened.
    const renderGenerations = beginThrottleObservation();
    const scratch = await openOrganizerScratch(recoveryUrl);
    // #215 skeptic r2 D3: a decisive healthy memo render retires exactly the URL it rendered (see
    // retireThrottleSeenForHealthyRender), so a recovered-then-limited-again conversation charges
    // a fresh cooldown instead of reporting throttle with an expired clock behind it.
    // #215 skeptic r2c A: healthyUrl already means DECISIVE; retireSafe is the second half of the
    // same question — was the observation readable enough to be evidence of health at all.
    retireThrottleSeenForHealthyRender(scratch.healthyUrl, scratch.retireSafe === true,
      scanHealth.throttledUrls, scanHealth.unknownUrls, renderGenerations);
    if (!scratch.text || !scratch.target) {
      // #208 gate r6 P2: an OWNED sighting (our own marker under the modal) still always
      // re-arms unconditionally; an unowned one routes through the same central gate every
      // other unowned trip in this file uses, so an already-charged repeat surfaced through
      // scratch recovery cannot re-arm the cooldown.
      if (scratch.reason === 'throttle') {
        if (scratch.throttleOwned
            || tripThrottleUnowned(scratch.throttleUrl, scratch.throttleHashText, 'organizer scratch', scratch.throttleForeign)) {
          recordThrottle('organizer scratch');
        }
      }
      if (scratch.target?.id) await closeTab(scratch.target.id);
      return { ...result, reason: scratch.reason };
    }
    target = scratch.target;
    source = 'memo';
  }

  result.source = source;
  const targetUrl = target.url;
  rememberUrl(marker, targetUrl);
  const before = await validateOrganizerTarget(target, targetUrl);
  if (!before.ok) return { ...result, reason: before.reason };
  target = before.tab;
  const expressionBinding = finalize ? acceptedReview : null;

  if (rename) {
    if (!title) {
      result.renameStatus = 'skipped';
      result.reason = 'title-memo-missing';
    } else {
      const renameOutcome = organizerUiStatus(
        await evaluateMutation(target, (mutation) => buildRenameConversationExpression(title, {
          marker,
          conversationUrl: targetUrl,
          expectedReview: expressionBinding,
          ...mutation,
        })),
        'rename',
      );
      result.renameStatus = renameOutcome.status;
      if (renameOutcome.reason !== 'ok') result.reason = renameOutcome.reason;
    }
  }

  const afterRename = await validateOrganizerTarget(target, targetUrl);
  if (!afterRename.ok) {
    if (result.reason === 'ok') result.reason = afterRename.reason;
    result.archiveStatus = archive ? 'skipped' : 'disabled';
    return result;
  }
  target = afterRename.tab;

  let closeAuthorized = false;
  if (archive) {
    const archiveOutcome = organizerUiStatus(
      await evaluateMutation(target, (mutation) => buildArchiveConversationExpression({
        marker,
        conversationUrl: targetUrl,
        expectedReview: expressionBinding,
        ...mutation,
      })),
      'archive',
    );
    result.archiveStatus = archiveOutcome.status;
    if (archiveOutcome.reason !== 'ok' && result.reason === 'ok') result.reason = archiveOutcome.reason;
    closeAuthorized = ['archived', 'already'].includes(archiveOutcome.status);
  }

  if (finalize && !closeAuthorized) {
    const beforeClose = await validateOrganizerTarget(target, targetUrl);
    closeAuthorized = beforeClose.ok;
    if (beforeClose.ok) target = beforeClose.tab;
    else if (result.reason === 'ok') result.reason = beforeClose.reason;
  }
  if (finalize && closeAuthorized) {
    const closeOutcome = await closeOwnedOrganizerTabs(
      targetUrl,
      target.id,
      ['archived', 'already'].includes(result.archiveStatus),
    );
    result.closeStatus = closeOutcome.status;
    if (closeOutcome.reason !== 'ok' && result.reason === 'ok') result.reason = closeOutcome.reason;
  }
  return result;
}

if (close) {
  let tabs = [];
  try {
    tabs = (await (await fetch(`http://127.0.0.1:${port}/json`)).json())
      .filter((t) => t.type === 'page' && /chatgpt\.com\/c\//.test(t.url || ''));
  } catch { process.exit(0); }
  let closed = 0;
  for (const tab of tabs) {
    const text = await tabText(tab);
    if (text && organizerOwnership(text).owned) { await closeTab(tab.id); closed += 1; }
  }
  console.error(`cdp-salvage --close: closed ${closed} conversation tab(s) matching "${marker}"`);
  process.exit(0);
}

if (organize) {
  let result;
  try {
    result = await organizeConversation();
  } catch {
    result = {
      source: 'none',
      renameStatus: rename ? 'failed' : 'disabled',
      archiveStatus: archive ? 'failed' : 'disabled',
      closeStatus: 'skipped',
      reason: 'organizer-exception',
    };
  }
  emitOrganizerResult(result);
  process.exit(0);
}

// All evidence sources (readable open tabs, dead-tab scratch renders, and remembered-URL
// scratch renders) enter here before a caller maps the result to an exit code. In particular,
// probe cannot call a terminal answer "complete" from an old or nonce-less verdict: only a
// verdict after this run's latest prompt marker that repeats the marker releases capacity.
const TERMINAL_INFRA_LINES = new Set([
  'A network error occurred',
  'Something went wrong while generating the response',
  'There was an error generating a response',
]);
function terminalInfrastructureAfterPrompt(text, structuredError = null) {
  if (!TERMINAL_INFRA_LINES.has(structuredError)) return null;
  const markerAt = lastExactMarkerAt(text, marker);
  if (markerAt < 0) return null;
  const afterPrompt = text.slice(markerAt + marker.length);
  const lines = afterPrompt.split('\n').map((value) => value.trim()).filter(Boolean);
  return lines.includes(structuredError) ? structuredError : null;
}

function classifyEvidence(text, structuredError = null, throttleModal = null) {
  if (!text || !text.trim()) return { kind: 'inconclusive', reason: 'empty-text' };
  // hashText (#208) is what an unowned trip fingerprints to recognize a repeat sighting of the
  // SAME stale tab: the modal's own short text when one is present (stable across re-renders),
  // else the interstitial page text itself. #208 gate r1 P1: prefer throttleModal here too — a
  // marker-less page can satisfy isThrottlePage on its whole-page text AND carry a modal; hashing
  // the page text here while every other site hashes the modal text let the SAME stale tab
  // alternate between two fingerprints forever, rewriting the cooldown on every other pass.
  // #208 gate r2 P1: `foreign` says whether this surface is POSITIVELY someone else's — the only
  // basis on which a throttle sighting may be disregarded when deciding absence (exit 4). An
  // interstitial is never foreign BY CONSTRUCTION (isThrottlePage already requires no run marker
  // at all, ours or another's); a modal's underlying page can still carry a foreign marker even
  // though the modal itself carries none.
  if (isThrottlePage(text)) {
    return { kind: 'throttle', reason: 'interstitial', owned: false, foreign: false, hashText: throttleModal ?? text };
  }
  // #162: the modal is account state painted over whatever conversation rendered. `owned` says
  // whether THIS run's exact marker is on the page beneath it (existence proof for --probe).
  if (throttleModal) {
    const owned = hasExactMarker(text, marker);
    return { kind: 'throttle', reason: 'modal', owned, foreign: !owned && FOREIGN_MARKER_RE.test(text), hashText: throttleModal };
  }
  if (!hasExactMarker(text, marker)) {
    return FOREIGN_MARKER_RE.test(text)
      ? { kind: 'foreign' }
      : { kind: 'inconclusive', reason: 'marker-not-hydrated' };
  }
  const foreignMarker = foreignAnswerMarker(text);
  if (foreignMarker) return { kind: 'cross-bound', foreignMarker };
  const infrastructureError = terminalInfrastructureAfterPrompt(text, structuredError);
  if (infrastructureError && !extractReview(text)) {
    return { kind: 'terminal-infrastructure', reason: infrastructureError };
  }
  const review = extractReview(text);
  if (!review) return { kind: 'owned-incomplete' };
  const verdict = ownedVerdict(text);
  const promptMarkerAt = verdict ? lastExactMarkerAt(text.slice(0, verdict.at), marker) : -1;
  const answerMarker = verdict?.line.match(/\(run marker:\s*(pg-run-[A-Za-z0-9.-]+)\s*\)/i)?.[1] ?? null;
  // The marker echoed in the terminal line is not a later prompt. A separate exact marker after
  // that line is, and proves this otherwise-owned verdict belongs to an older turn in the same chat.
  const newerPromptMarker = verdict && hasExactMarker(text.slice(verdict.at + verdict.line.length), marker);
  // A retry reuses this run's exact marker, so a stale SAME-marker verdict (one this run's own
  // marker binds) passes every other check here (owned, non-foreign, well-formed) AND the shell's
  // nonce check downstream — it would otherwise satisfy `kind: 'terminal'` while the newer
  // prompt it precedes is still generating, and the harvest path below emits on `kind` alone
  // (unlike --probe, which also gates on probeComplete), so that stale verdict would be reported
  // as THIS run's result and retire the reservation early. Fall back to owned-incomplete so every
  // caller (readable-tab match, scratch revalidation, remembered-URL render, freshRenderText's
  // decisive-evidence wait) keeps sampling instead of treating scrollback as a live answer.
  // Gated on sameMarker: a verdict carrying a DIFFERENT marker ahead of our prompt (#68 gate
  // P1's reused-conversation scrollback) already fails the shell's nonce check on its
  // own — that case must stay 'terminal' so the engine can adjudicate it, not be swallowed here.
  if (newerPromptMarker && sameMarker(answerMarker, marker)) return { kind: 'owned-incomplete', reason: 'stale-terminal' };
  return {
    kind: 'terminal',
    review,
    // newerPromptMarker can still be true here for a foreign answerMarker (scrollback case
    // above); the `&& !newerPromptMarker` term stays as a guard against that combination
    // ever being reported probe-complete, even though only --probe reads this field.
    probeComplete: promptMarkerAt >= 0 && sameMarker(answerMarker, marker) && !newerPromptMarker && !mixedAnswer(text),
    // Old foreign scrollback is retryable; the extracted review cannot carry this chronology.
    precedesPrompt: !!newerPromptMarker,
  };
}

// Positive evidence mutates URL ownership only after the shared classifier has excluded a
// cross-bound answer. The caller supplies the classification so readable incomplete sources can
// defer promotion until their canonical scratch revalidation resolves the ambiguity.
function onOurConversation(url, evidence) {
  if (!['owned-incomplete', 'terminal', 'terminal-infrastructure'].includes(evidence.kind)) return evidence;
  ourUrls.add(url);
  // Positive ownership: the run is demonstrably NOT terminally cross-bound, whatever other
  // candidates this scan rejected (#68 gate r2/r3 P2). Decided at exit, so tab order is
  // irrelevant.
  ownershipProven = true;
  rememberUrl(marker, url);
  knownUrl = url;                // usable by the recovery branch from the very next cycle
  return evidence;
}

// A readable incomplete source has proved only that its prompt is visible: its terminal answer
// can still be cross-bound. Preserve a pre-existing recovery handle through an inconclusive
// scratch pass, but retain this source as a future handle when no prior handle exists.
function rememberInconclusiveReadableSource(url) {
  if (knownUrl) return;
  ourUrls.add(url);
  rememberUrl(marker, url);
  knownUrl = url;
}

function emitEvidence(url, evidence) {
  if (probe) {
    console.error(`live conversation: ${url}`);
    console.error(`evidence-kind: ${evidence.kind}`);
    // rc 0 proves the conversation exists. Completeness is intentionally stricter than harvest
    // extraction: the terminal verdict must answer the latest exact prompt and echo this marker.
    const probeState = evidence.kind === 'terminal-infrastructure'
      ? 'terminal-infrastructure'
      : evidence.kind === 'terminal' && evidence.probeComplete ? 'complete' : 'generating';
    console.error(`probe-state: ${probeState}`);
    process.exit(0);
  }
  if (evidence.kind === 'terminal-infrastructure') {
    console.error('evidence-kind: terminal-infrastructure');
    console.error(`terminal-infrastructure: ${evidence.reason}`);
    process.exit(10);
  }
  if (evidence.kind === 'terminal') {
    // v0.28 (gate #54 r5): name the EXACT source of this capture so the engine can blacklist
    // precisely on a provenance rejection — reading the shared memo afterwards races probes.
    console.error('evidence-kind: terminal');
    console.error(`matched-url ${url}`);
    // Chronology the engine cannot see: this block predates the prompt below it (#166 gate r3 P1).
    if (evidence.precedesPrompt) console.error('answer-chronology precedes-prompt');
    console.log(evidence.review);
    process.exit(0);
  }
  return url;
}

let staleRevalidationAttempted = false;
async function revalidateReadableStaleSource(url) {
  if (staleRevalidationAttempted || Date.now() >= deadline || seededRenders >= MAX_SEEDED_RENDERS) return null;
  staleRevalidationAttempted = true;
  seededRenders += 1;
  nextRenderAt.set(url, Date.now() + RENDER_INTERVAL_MS);
  console.error(`readable conversation ${url} has no terminal verdict — re-rendering its canonical URL once in a scratch tab...`);
  const rendered = await freshRenderText(url, port, deadline, true);
  if (!rendered.text) {
    // URL drift, target loss, login/hydration and CDP failures are absence of fresh evidence.
    // Do not forget, blacklist, or otherwise mutate the already-proven canonical URL.
    console.error(`canonical scratch revalidation was inconclusive (${rendered.reason})`);
    return { kind: 'inconclusive', reason: rendered.reason };
  }
  return rendered.evidence ?? classifyEvidence(rendered.text);
}

function discardForeignUrl(url) {
  if (url === knownUrl) {
    ourUrls.delete(url);
    const survivor = forgetUrl(marker, url);
    knownUrl = survivor;
    memoStale = !survivor;
  }
  blacklist(url);
}

function rejectForeign(url, source) {
  discardForeignUrl(url);
  console.error(`${source} ${url} carries a DIFFERENT run's marker — not ours; ignoring it`);
}

function rejectCrossBound(url, foreignMarker, source) {
  discardForeignUrl(url);
  noteCrossBind(marker, url, foreignMarker);
  console.error(`${source} ${url} carries our marker but ANOTHER run's completed answer (${foreignMarker}) — not ours; ignoring it`);
}

let listFailures = 0;
let lastListOk = false;          // did the MOST RECENT CDP tab list succeed? (exit 4 vs exit 7)
                                 // Latching this on the first success would let one early
                                 // listing mask a Chrome death for the rest of the window:
                                 // scan once before the conversation appears, lose the browser,
                                 // and the deadline would claim a confirmed absence (gate P1).
let stillGeneratingUrl = null;   // marker-matched conversation seen this invocation, no VERDICT yet
let lastMatchWasSeeded = false;  // that sighting came from the remembered URL, which has no tab
while (Date.now() < deadline) {
  let tabs = [];
  try {
    tabs = (await (await fetch(`http://127.0.0.1:${port}/json`)).json())
      .filter((t) => t.type === 'page' && /chatgpt\.com\/c\//.test(t.url || ''));
    listFailures = 0;
    lastListOk = true;
  } catch (e) {
    // v0.18: transient — Chrome restarts and CDP hiccups happen mid-salvage.
    // Aborting here made the engine's pre-retry probe read "dead submission"
    // and green-light a double-spending retry. Back off, retry until deadline.
    listFailures += 1;
    lastListOk = false;
    console.error(`CDP list failed (${listFailures}x): ${e.message} — retrying until deadline`);
    await sleep(Math.min(5_000 * listFailures, 30_000));
    continue;
  }
  // Exit 3 means the matching conversation exists NOW, not merely that we saw it sometime
  // earlier in this invocation. Clear the latest-scan signal before each successful tab list;
  // if the tab closes/navigates/disappears, the deadline correctly exits 4 (lost) instead.
  stillGeneratingUrl = null;
  lastMatchWasSeeded = false;
  const deadTabs = [];
  // The three reads per tab are independent; run them concurrently so a suspended renderer
  // costs one evaluate bail per tab, not three, inside probe's fixed budget.
  // #215 gate r3 P2: the record generations this scan's observation covers, snapshotted before it
  // reads a single tab — see retireThrottleSeenForHealthyUrls.
  const scanGenerations = beginThrottleObservation();
  const reads = await Promise.all(tabs.map(async (tab) => {
    const [text, infrastructureError, modalRead] = await Promise.all([
      tabText(tab), tabTerminalInfrastructure(tab), tabThrottleModalRead(tab),
    ]);
    // #215 skeptic r2 D1: carry whether the dialog READ succeeded, not only what it found, so
    // scanThrottleHealth can tell "no dialog" from "could not look".
    return { tab, text, infrastructureError, throttleModal: modalRead.modal, throttleModalOk: modalRead.ok };
  }));
  // #215 gate r2 P2: retire the fingerprints of every URL this scan positively observed healthy
  // BEFORE the batch below decides "already charged" — a modal that returned after an EARLIER
  // scan saw that conversation rendering normally is a new episode and must charge its own
  // cooldown. A URL that is healthy and throttled in the SAME scan is excluded by
  // scanThrottleHealth, so this never retires a record this scan still needs.
  const scanHealth = scanThrottleHealth(reads);
  retireThrottleSeenForHealthyUrls(scanHealth.healthyUrls, scanHealth.protectedKeys, scanGenerations);
  // #162: the modal is account-wide, so decide ownership over the WHOLE scan, never on the first
  // tab in list order (the same order-independence onOurConversation documents): a foreign or
  // blacklisted tab listed ahead of ours must not hide the proof that our conversation exists.
  // Only a non-blacklisted page rendering our EXACT marker proves that; any other modal or
  // marker-less-interstitial hit is proof of the limiter alone.
  // #208 gate r3 P2: ONE whole-scan batch covers every unowned throttle sighting this scan sees —
  // modal hits AND marker-less interstitial hits on tabs without a modal. The old split (modal
  // hits batched here, interstitials tripped one at a time in the per-tab loop below) meant N
  // unchanged interstitial tabs in a single scan cost N separate cooldown windows: the per-tab
  // loop recorded the FIRST sighting and exited immediately, leaving this same scan's remaining
  // sightings unrecorded for the next invocation to rediscover one at a time.
  const throttleHits = reads.filter(({ text, throttleModal }) => (
    (throttleModal && text && text.trim() !== '') || (!throttleModal && isThrottlePage(text))
  ));
  if (throttleHits.length > 0) {
    const ownedHit = throttleHits.find(({ tab, text }) => !nonMatching.has(tab.url) && hasExactMarker(text, marker));
    if (ownedHit) {
      tripThrottleEvidence(
        ownedHit.tab.url,
        { kind: 'throttle', reason: 'modal', owned: true, foreign: false, hashText: ownedHit.throttleModal },
        `modal over tab ${ownedHit.tab.url}`,
      );
    } else {
      // #208 gate r2 P2 / r3 P2: a stale repeat listed first must not hide a genuinely new
      // foreign modal or interstitial behind it, AND one already-open batch of stale sightings
      // must cost this scan exactly one cooldown — not one per invocation as the old per-hit walk
      // exited on the FIRST newly admitted hit, leaving every hit behind it un-recorded for the
      // next invocation to rediscover one at a time. Charge every hit in list order first, then
      // exit once. Fingerprint is throttleModal ?? text — the same rule every other unowned trip
      // site in this file follows (isThrottlePage's own construction means an interstitial hit
      // never has a throttleModal or a foreign marker, so `text` and `foreign: false` fall out
      // naturally for those hits).
      const firstNewWhere = tripThrottleUnownedBatch(throttleHits.map((hit) => ({
        url: hit.tab.url,
        text: hit.throttleModal ?? hit.text,
        // #215 gate r1 P1: FOREIGN_MARKER_RE matches ANY pg-run marker, THIS run's included, so a
        // BLACKLISTED tab bearing our own marker used to read as another run's conversation — the
        // one classification allowed to skip inconclusiveThrottleSeen — and dropped the scan into
        // confirmed-absent exit 4 on nothing but a rate limit. Ask "is this ours?" first, exactly as
        // classifyEvidence's reference predicate does (`foreign: !owned && FOREIGN_MARKER_RE...`).
        // Blacklisted URLs remain excluded from POSITIVE ownership by ownedHit above; this decides
        // only whether the surface is proven to be SOMEONE ELSE'S, the sole basis for disregarding
        // a throttle sighting when deciding absence.
        foreign: !!hit.text && !hasExactMarker(hit.text, marker) && FOREIGN_MARKER_RE.test(hit.text),
        where: hit.throttleModal ? `modal over tab ${hit.tab.url}` : `tab ${hit.tab.url}`,
      })));
      if (firstNewWhere !== null) tripThrottle(firstNewWhere);
    }
  }
  for (const { tab, text, infrastructureError } of reads) {
    if (text === null || text.trim() === '') { deadTabs.push(tab); continue; }
    // #208 gate r1 P1 / r3 P2: every modal AND marker-less-interstitial throttle sighting in this
    // scan was already walked by the whole-scan batch above (tripped as owned, charged as the
    // first newly-admitted unowned hit, or ignored as an already-charged stale repeat) — a
    // marker-less interstitial no longer needs (or gets) its own per-tab trip here; the batch
    // subsumes it. Reaching this loop for a throttle tab a second time would fingerprint it
    // again and risk alternating the cooldown instead of converging.
    // v0.28 (gate #54 r2): honor the per-marker blacklist for OPEN tabs too, not only
    // re-renders. The engine appends here when a capture from this URL failed the provenance
    // check — even a marker-bearing tab must be skipped then, or every later harvest replays
    // the same rejected conversation and starves the real one.
    if (nonMatching.has(tab.url)) continue;
    if (!foldedIncludes(text, marker)) {
      // The remembered URL is open and rendered ANOTHER run's conversation: the memo is stale
      // (recycled URL, or it was never ours). This is the second way to prove staleness — the
      // first is a seeded render below — and without it an open-but-foreign remembered URL is
      // never re-rendered (it is already a tab), so nothing could ever decide it.
      if (tab.url === knownUrl && FOREIGN_MARKER_RE.test(text)) memoStale = true;
      continue;
    }
    const evidence = classifyEvidence(text, infrastructureError);
    if (evidence.kind === 'cross-bound') {
      rejectCrossBound(tab.url, evidence.foreignMarker, 'tab');
      continue;
    }
    if (evidence.kind === 'terminal' || evidence.kind === 'terminal-infrastructure') {
      onOurConversation(tab.url, evidence);
      emitEvidence(tab.url, evidence);
    }
    if (evidence.kind !== 'owned-incomplete') continue;
    stillGeneratingUrl = tab.url;
    lastMatchWasSeeded = false;
    // A readable DOM can be stale while its server-side conversation is complete. Do not promote
    // it over an earlier recovery memo until its one same-profile scratch navigation classifies it.
    //
    // The one-shot revalidation is spent on the REMEMBERED conversation (knownUrl) when we have
    // one, never on whichever owned-incomplete tab this scan happens to reach first. A
    // retry-created duplicate tab that stays incomplete carries our marker just as legitimately
    // as the real one, so without this a duplicate could burn the single scratch navigation every
    // cycle and permanently suppress the remembered-URL pass — reporting a completed, PAID review
    // sitting at knownUrl as still generating forever. Every downstream consequence (terminal
    // emit, cross-bound/foreign rejection, blacklist, stillGeneratingUrl) is attributed to the URL
    // actually rendered, never to the tab that merely triggered the pass — the tab itself is still
    // never navigated or closed.
    const revalidateUrl = knownUrl ?? tab.url;
    if (revalidateUrl !== tab.url) {
      console.error(`readable tab ${tab.url} is incomplete, but "${marker}" already has a proven `
        + `conversation (${revalidateUrl}) — spending the one canonical revalidation there instead`);
    }
    const fresh = await revalidateReadableStaleSource(revalidateUrl);
    if (fresh?.kind === 'throttle') tripThrottleEvidence(revalidateUrl, fresh, `canonical scratch ${revalidateUrl}`);
    if (fresh?.kind === 'cross-bound') {
      rejectCrossBound(revalidateUrl, fresh.foreignMarker, 'canonical scratch');
      // Only null the signal when the rejected URL IS the tab we were scanning: a rejected
      // knownUrl says nothing about a genuinely different, still-open, still-incomplete tab.
      if (revalidateUrl === tab.url) {
        stillGeneratingUrl = null;
      } else if (probe) {
        // The one-shot revalidation was spent on knownUrl, a DIFFERENT conversation from the
        // tab this iteration is actually scanning. Rejecting knownUrl proves nothing about that
        // tab — it already produced its own owned-incomplete `evidence` above (gate #91 r3 P1).
        // Without re-emitting it here, probe has no positive signal left this cycle: it falls
        // through past every `!probe` block below straight to the deadline's exit 4 (absent),
        // which increments the reservation's consecutive-miss count and can ultimately RELEASE a
        // live, still-generating review for double-spending.
        emitEvidence(tab.url, evidence);
      }
      continue;
    }
    if (fresh?.kind === 'foreign' || (fresh?.kind === 'throttle' && fresh.foreign)) {
      // #208 gate r6 P1 sibling: proven either directly (kind: 'foreign') or, same as the
      // remembered-render caller above, by a throttle modal painted over ANOTHER run's marker
      // (kind: 'throttle', foreign: true). tripThrottleEvidence already decided above whether
      // this sighting re-arms the cooldown; either way it is still positive proof the canonical
      // URL is stale, and a markerless repeat (foreign: false) must NOT land here — that stays
      // inconclusive below instead.
      rejectForeign(revalidateUrl, 'canonical scratch');
      if (revalidateUrl === tab.url) {
        stillGeneratingUrl = null;
      } else if (probe) {
        emitEvidence(tab.url, evidence);
      }
      continue;
    }
    if (fresh?.kind === 'terminal' || fresh?.kind === 'terminal-infrastructure') {
      onOurConversation(revalidateUrl, fresh);
      emitEvidence(revalidateUrl, fresh);
    }
    if (fresh?.kind === 'owned-incomplete') {
      onOurConversation(revalidateUrl, fresh);
      // Real scratch evidence for the rendered URL supersedes the tentative tab.url guess above.
      stillGeneratingUrl = revalidateUrl;
      lastMatchWasSeeded = revalidateUrl !== tab.url;
    }
    // Inconclusive scratch evidence preserves an existing recovery handle. With no prior handle,
    // retain this marker-bearing source without claiming ownershipProven.
    if (!fresh || fresh.kind === 'inconclusive') rememberInconclusiveReadableSource(revalidateUrl);
    if (probe) emitEvidence(tab.url, evidence);
    console.error(`conversation found (${tab.url}) but no VERDICT yet; waiting...`);
  }
  // v0.17 fallback: unreadable tabs get their URL re-rendered in a scratch tab
  let renders = 0;
  for (const tab of deadTabs) {
    if (Date.now() >= deadline) break;
    if (renders >= FRESH_RENDERS_PER_CYCLE) break;
    if (nonMatching.has(tab.url)) continue;
    if (Date.now() < (nextRenderAt.get(tab.url) ?? 0)) continue;
    if (!ourUrls.has(tab.url)) {
      const tried = renderTried.get(tab.url) ?? 0;
      if (tried >= MAX_RENDERS_PER_URL) continue;   // budget spent — re-checked next invocation, not hammered this one
      renderTried.set(tab.url, tried + 1);
    }
    nextRenderAt.set(tab.url, Date.now() + RENDER_INTERVAL_MS);
    renders += 1;
    console.error(`tab unreadable (renderer dead?): ${tab.url} — re-rendering in a scratch tab...`);
    const { text, evidence: renderEvidence } = await freshRenderText(tab.url, port, deadline);
    if (!text) continue;
    if (renderEvidence?.kind === 'throttle') tripThrottleEvidence(tab.url, renderEvidence, `fresh render ${tab.url}`);
    if (!foldedIncludes(text, marker)) {
      // Blacklist ONLY on positive evidence: the page carries someone
      // ELSE's run marker, proving it rendered a different review's
      // conversation. Shell/login/error pages and pre-hydration renders can
      // exceed any length heuristic without being the conversation at all;
      // blacklisting those could permanently hide the real review and let
      // --probe green-light a double-spending retry. Anything without a
      // foreign marker is treated as not-ready and retried within budget.
      if (FOREIGN_MARKER_RE.test(text)) {
        // If this IS the remembered conversation, the memo is provably stale. blacklist() alone
        // cannot record that: a remembered URL sits in ourUrls, so blacklist() deliberately
        // no-ops on it. And because the dead tab is still LISTED, the remembered-URL branch
        // below never runs for it — so without this the reservation would sit at "inconclusive"
        // forever instead of ever advancing toward release (gate P1).
        if (tab.url === knownUrl) memoStale = true;
        blacklist(tab.url);
      }
      continue;
    }
    const evidence = onOurConversation(tab.url, classifyEvidence(text));
    if (evidence.kind === 'cross-bound') {
      rejectCrossBound(tab.url, evidence.foreignMarker, 're-rendered');
      continue;
    }
    if (evidence.kind === 'terminal' || evidence.kind === 'terminal-infrastructure') emitEvidence(tab.url, evidence);
    if (evidence.kind !== 'owned-incomplete') continue;
    stillGeneratingUrl = tab.url;
    lastMatchWasSeeded = false;
    // A fresh render is a real page load against ChatGPT, so a match here is SERVER-SIDE
    // evidence just like the remembered-URL branch: keep it if this tab later disappears.
    seededLiveUrl = tab.url;
    if (probe) emitEvidence(tab.url, evidence);
    console.error(`conversation matches (via fresh render, ${tab.url}) but no VERDICT yet; waiting...`);
  }

  // v0.25: remembered-conversation recovery. Everything above can only see conversations that
  // are OPEN TABS. ChatGPT keeps conversations server-side, so a Chrome restart (routine when
  // the box is short on memory), a discarded renderer or a stray close leaves a finished review
  // perfectly intact and completely invisible here — which the engine then reports as
  // "conversation confirmed gone", telling a human a fresh Pro run is justified. If an earlier
  // invocation proved which conversation is ours, re-render THAT URL: it is a plain navigation
  // to server-side state and works with no tab at all.
  if (knownUrl && !stillGeneratingUrl && !tabs.some((t) => t.url === knownUrl)
      && Date.now() < deadline
      && seededRenders < MAX_SEEDED_RENDERS
      && Date.now() >= (nextRenderAt.get(knownUrl) ?? 0)) {
    const seedUrl = knownUrl;
    nextRenderAt.set(seedUrl, Date.now() + RENDER_INTERVAL_MS);
    seededRenders += 1;
    console.error(`no open tab carries "${marker}" — re-rendering the remembered conversation ${seedUrl} (${seededRenders}/${MAX_SEEDED_RENDERS})...`);
    // #215 gate r3 P2: this render's own generation snapshot, taken before it is opened.
    const renderGenerations = beginThrottleObservation();
    const { text, evidence: renderEvidence, reason: renderReason, retireSafe: renderRetireSafe } =
      await freshRenderText(seedUrl, port, deadline);
    if (text) {
      const evidence = renderEvidence ?? classifyEvidence(text);
      if (evidence.kind === 'throttle') tripThrottleEvidence(seedUrl, evidence, `remembered render ${seedUrl}`);
      // #215 skeptic r2 D3: the same rule as the organizer's memo render — this is the only
      // observation of a conversation that has no tab at all, so a decisive non-throttle render
      // retires that ONE URL's records. Reached only when the throttle trip above did NOT exit
      // (an already-charged repeat), and 'throttle' is not a decisive-healthy reason either way.
      // #215 skeptic r2c A: decisive AND readable-as-healthy — see freshRenderText's retireSafe.
      // #215 skeptic r3 D6: the throttledUrls/unknownUrls veto can never FIRE here. This seeded
      // render only runs when no listed tab carries seedUrl (the `!tabs.some(...)` guard above,
      // the same exact-string equality both sets are keyed by), so seedUrl is in neither set by
      // construction. They are passed anyway because the veto is a property of the function, not
      // of one call site, and because that guard is not this argument's to depend on: the veto
      // binds on the ORGANIZER path, where a listed tab at the remembered URL can exist and be
      // unreadable while the memo render of the same URL comes back healthy (the #215 gate r3 P2
      // (5) fixture is exactly that shape).
      retireThrottleSeenForHealthyRender(seedUrl,
        DECISIVE_HEALTHY_RENDER_REASONS.has(renderReason) && renderRetireSafe === true,
        scanHealth.throttledUrls, scanHealth.unknownUrls, renderGenerations);
      if (evidence.kind === 'cross-bound') {
        // The memo itself is cross-bound. Evict it with claim-and-verify, but preserve a
        // concurrently republished survivor as the only possible genuine recovery handle.
        rejectCrossBound(seedUrl, evidence.foreignMarker, 'remembered conversation');
      } else if (['terminal', 'terminal-infrastructure', 'owned-incomplete'].includes(evidence.kind)) {
        const owned = onOurConversation(seedUrl, evidence);
        if (owned.kind === 'terminal' || owned.kind === 'terminal-infrastructure') emitEvidence(seedUrl, owned);
        if (owned.kind === 'owned-incomplete') {
          stillGeneratingUrl = seedUrl;
          lastMatchWasSeeded = true;
          seededLiveUrl = seedUrl;   // survives later empty scans: this is server-side evidence
          if (probe) emitEvidence(seedUrl, owned);
          console.error(`remembered conversation recovered (${seedUrl}) but no VERDICT yet; waiting...`);
        }
      } else if (evidence.kind === 'foreign' || (evidence.kind === 'throttle' && evidence.foreign)) {
        // Decisive the other way: the memo points at ANOTHER run's conversation (stale or
        // corrupt) — proven either directly (kind: 'foreign') or, #208 gate r6 P1, by a
        // throttle modal painted over that other run's marker (kind: 'throttle', foreign:
        // true). tripThrottleEvidence above already decided whether this sighting re-arms
        // the cooldown (new) or was ignored as an already-charged repeat; either way it is
        // still positive proof the memo is stale, and a markerless repeat (foreign: false)
        // must NOT land here — that stays inconclusive below instead.
        memoStale = true;
        console.error(`remembered conversation ${seedUrl} carries a DIFFERENT run's marker — stale memo, ignoring it`);
      } else {
        // Not proof of loss: shell, login wall or incomplete hydration. Never blacklist it
        // (blacklist() also refuses, since a remembered URL is in ourUrls), and never let it
        // masquerade as a confirmed absence at the deadline.
        console.error(`remembered conversation ${seedUrl} did not render our marker this pass; will retry`);
      }
    }
  }
  // Honor short caller budgets precisely (important for probes and tests); never sleep 20s
  // past a 3s deadline.
  await sleep(Math.min(probe ? 5_000 : POLL_MS, Math.max(0, deadline - Date.now())));
}
if (!probe && stillGeneratingUrl && !lastMatchWasSeeded) {
  // Revalidate at the deadline: exit 3 means the marker-matched conversation exists NOW, not
  // merely that it was observed sometime earlier in the invocation.
  // Skipped when the last positive observation came from re-rendering the remembered URL: that
  // conversation has no tab BY DEFINITION, so a tab scan would "disprove" a sighting we just
  // made against server-side state and downgrade a live run to a miss.
  try {
    const tabs = (await (await fetch(`http://127.0.0.1:${port}/json`)).json())
      .filter((t) => t.type === 'page' && /chatgpt\.com\/c\//.test(t.url || ''));
    const reads = await Promise.all(tabs.map(async (tab) => ({ tab, text: await tabText(tab) })));
    const live = reads.find(({ text }) => text && foldedIncludes(text, marker));
    stillGeneratingUrl = live?.tab?.url ?? null;
  } catch {
    // CDP outage is inconclusive: retain the last positive signal, fail-closed against respending.
  }
}
// A conversation proven to exist SERVER-SIDE is still generating even with no tab anywhere.
// stillGeneratingUrl is a per-scan signal and is cleared every cycle; seededLiveUrl is not.
const liveUrl = stillGeneratingUrl || seededLiveUrl;
if (!probe && liveUrl) {
  // Budget exhausted while the model is still generating. The Pro slot is SPENT and the answer
  // may land any minute: exiting 4 here historically made the engine declare failure and CLOSE
  // the tab, destroying the review (65-minute Pro run lost on 2026-07-09). Distinct code + open
  // tab lets the caller harvest later instead of respending.
  console.error(`still-generating: ${liveUrl} matches "${marker}" but has no VERDICT after ${timeoutSecs}s`
    + `${stillGeneratingUrl ? ': tab left open' : ' (proven server-side; no tab needed)'}; harvest later (oracle-review.sh --harvest '${marker}')`);
  console.error('evidence-kind: owned-incomplete');
  process.exit(3);
}
if (!lastListOk) {
  // Never got a single successful tab list: the browser is down or restarting. That is absence
  // of EVIDENCE, not evidence of absence, and the engine's miss counter (3 strikes -> "review
  // lost, re-run justified") must not advance on it. Distinct code, so callers keep the
  // reservation and retry instead.
  console.error(`inconclusive: the last CDP tab list failed (${listFailures} consecutive) within ${timeoutSecs}s — browser down or restarting; NOT evidence the conversation is gone`);
  console.error('evidence-kind: browser-down');
  process.exit(7);
}
if (knownUrl && !memoStale) {
  // We hold a URL proven to be this run's conversation and could not decisively rule it out —
  // the renders were inconclusive (shell / login wall / never got a turn within budget). A
  // successful TAB listing is not evidence about SERVER-SIDE state, so it must not be laundered
  // into a confirmed absence: three of those releases a live reservation and permits a
  // double-spending resubmit (gate P1). Stay inconclusive; the reservation TTL bounds it.
  console.error(`inconclusive: remembered conversation ${knownUrl} re-rendered ${seededRenders}x without a decisive result in ${timeoutSecs}s — NOT evidence it is gone`);
  console.error('evidence-kind: inconclusive');
  process.exit(7);
}
if (inconclusiveThrottleSeen) {
  // #208 gate r2 P1: a throttle surface (modal or interstitial) was observed this invocation —
  // charged as a genuinely new sighting or ignored as an already-charged repeat, either way — and
  // never proven to belong to another run (no FOREIGN exact marker was readable in its text).
  // Cooldown dedup ("already charged, ignore it") is a RATE-LIMIT decision, not an OWNERSHIP one;
  // conflating them used to let a repeat sighting of the SAME markerless tab fall all the way
  // through to the confirmed-absent exit 4 below, silently spending a paid review's finite
  // recovery-miss budget on nothing but the account limiter. Only a POSITIVELY foreign sighting
  // may be disregarded when deciding absence — this one wasn't, so stay inconclusive and do NOT
  // rewrite the cooldown here (tripThrottleUnowned already decided charge vs. ignore).
  console.error(`inconclusive: an unowned throttle surface was observed this scan (${inconclusiveThrottleWhere}) `
    + `and not proven to belong to another run — NOT evidence "${marker}" is gone`);
  console.error('evidence-kind: inconclusive');
  process.exit(7);
}
console.error(`timeout: no ${probe ? 'conversation tab' : 'completed review'} matching "${marker}" after ${timeoutSecs}s`
  + (memoStale ? ' (the remembered conversation belongs to another run; memo was stale)' : ''));
// v0.42 (#109): one closed-vocabulary line naming what this pass concluded, printed at every exit
// (see the other `evidence-kind:` sites). The engine records it per marker so --status can name a
// stall instead of calling every unresolved attempt "generating". A conviction without a proven
// owner is cross-bound; every other timeout here is a confirmed absence for this marker.
console.error(`evidence-kind: ${crossBindHits.size > 0 && !ownershipProven ? 'cross-bound' : 'absent'}`);
process.exit(4);
