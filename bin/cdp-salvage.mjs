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
//
// Usage: cdp-salvage.mjs [--probe] <pr-marker> [timeout-secs] [cdp-port]
//   pr-marker    substring identifying the right conversation (e.g. the PR
//                URL or the engine's pg-run marker); required because several
//                review slots may have concurrent conversation tabs open.
//   --probe      liveness check only: exit 0 as soon as a conversation tab
//                matching the marker EXISTS (no VERDICT wait). Used by the
//                engine's no-think watchdog to distinguish "dead submission,
//                safe to retry" from "live run, retry would double-spend".
//                Also prints `probe-state: complete|generating` on stderr so the
//                reservation reconciler can release the account slot of a review
//                that has finished but has not been collected yet (#82). This is
//                an additive LINE, never a new exit code: callers above key on
//                rc 0 meaning "live", and a new code would fall through them.
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
//           evidence that the remembered conversation is another run's does that.
// Requires Node >= 21 (global WebSocket); the box runs Node 24.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  buildArchiveConversationExpression,
  buildCancelOrganizerMutationExpression,
  buildRenameConversationExpression,
  ORGANIZER_MUTATION_LEASE_MS,
} from './cdp-organizer-expressions.mjs';

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
const POLL_MS = 20_000;

const PG_HOME = process.env.PRO_GATE_HOME ?? path.join(os.homedir(), '.pro-review-daemon');
const BLACKLIST_FILE = path.join(PG_HOME, 'salvage-nonmatching.txt');
// honor the same override pg_health_gate reads, or a detected throttle would never defer runs
const COOLDOWN_FILE = process.env.PRO_GATE_COOLDOWN_FILE ?? path.join(PG_HOME, 'throttle.cooldown');

// --- conversation-URL memory (v0.25) -------------------------------------------------
// One file per run marker holding the conversation URL we PROVED carries it. This is the
// engine's only handle on a conversation whose tab is gone, so it is written on every positive
// match (probe included) and read before we ever conclude "not found".
const URL_MEMO_DIR = path.join(PG_HOME, 'conversation-urls');
const TITLE_MEMO_DIR = path.join(PG_HOME, 'conversation-titles');
const COMPLETED_DIR = process.env.PRO_GATE_COMPLETED_DIR ?? path.join(PG_HOME, 'completed');
const PENDING_DIR = path.join(PG_HOME, 'pending');
const MEMO_KEEP = 200;                  // newest N memos retained; older ones are pruned on write
const MARKER_SAFE_RE = /^pg-run-[A-Za-z0-9.-]+$/;
const memoPath = (m) => (MARKER_SAFE_RE.test(m) ? path.join(URL_MEMO_DIR, m) : null);
const titleMemoPath = (m) => (MARKER_SAFE_RE.test(m) ? path.join(TITLE_MEMO_DIR, m) : null);

function recallUrl(m) {
  const f = memoPath(m);
  if (!f) return null;
  try {
    const url = fs.readFileSync(f, 'utf8').trim();
    return /^https:\/\/chatgpt\.com\/c\//.test(url) ? url : null;
  } catch { return null; }
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

// Persist terminal cross-bound state ONLY when the completed scan found no candidate we could
// prove is ours. Order-independent by construction: every candidate has been classified by the
// time this runs.
function flushCrossBind(m) {
  const dir = path.join(PG_HOME, 'crossbound');
  const f = path.join(dir, m);
  if (ownershipProven || crossBindHits.size === 0) {
    try { fs.unlinkSync(f); } catch {}
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
// conviction an earlier salvage recorded. probe stays excluded exactly as before.
process.on('exit', () => { if (!probe && !organize) flushCrossBind(marker); });

function rememberUrl(m, url) {
  const f = memoPath(m);
  if (!f || !/^https:\/\/chatgpt\.com\/c\//.test(url || '')) return;
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
// The interstitial's two distinctive sentences. Deliberately NOT a generic
// /rate.?limit/ — review findings routinely discuss rate limits.
const THROTTLE_RE = /making requests too quickly|temporarily limited access to your conversations/i;
// Any pro-gate run marker. On a page that does NOT carry our own marker, a hit here is positive
// evidence the page rendered a DIFFERENT run's conversation (vs. merely not having loaded yet).
const FOREIGN_MARKER_RE = /pg-run-[A-Za-z0-9.-]+/;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A page is the throttle interstitial only if it carries the phrase, no run
// marker at all (ours or foreign — real conversations can QUOTE the phrase,
// e.g. a review of this very engine), and is short like an error page.
function isThrottlePage(text) {
  return !!text && text.length < 5000 && !/pg-run-[A-Za-z0-9.-]+/.test(text) && THROTTLE_RE.test(text);
}
function recordThrottle(where) {
  try {
    fs.mkdirSync(PG_HOME, { recursive: true });
    fs.writeFileSync(COOLDOWN_FILE, `${new Date().toISOString()} ${where}\n`);
  } catch {}
  console.error(`ChatGPT throttle interstitial detected (${where}) — cooldown written to ${COOLDOWN_FILE}. Back off; do NOT resubmit.`);
}
function tripThrottle(where) {
  recordThrottle(where);
  process.exit(5);
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

async function tabText(tab) {
  const result = await evaluateTab(tab, 'document.body.innerText');
  return result.ok ? result.value ?? null : null;
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
if (close) {
  let tabs = [];
  try {
    tabs = (await (await fetch(`http://127.0.0.1:${port}/json`)).json())
      .filter((t) => t.type === 'page' && /chatgpt\.com\/c\//.test(t.url || ''));
  } catch { process.exit(0); }
  let closed = 0;
  for (const tab of tabs) {
    const text = await tabText(tab);
    if (text && text.includes(marker)) { await closeTab(tab.id); closed += 1; }
  }
  console.error(`cdp-salvage --close: closed ${closed} conversation tab(s) matching "${marker}"`);
  process.exit(0);
}

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

async function freshRenderText(url, port, outerDeadline, waitForDecisiveEvidence = false) {
  let target = null;
  try {
    let res = await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`, { method: 'PUT' });
    if (!res.ok) res = await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`); // pre-v111 Chrome used GET
    if (!res.ok) return { text: null, reason: 'scratch-open-failed' };
    target = await res.json();
    // never grant more than the caller's remaining budget (a 30s probe must
    // not stall watchdog/retry decisions by overrunning its own window)
    const renderDeadline = Math.min(Date.now() + 25_000, outerDeadline);
    let text = null;
    let evidence = null;
    while (Date.now() + 2_500 < renderDeadline) {
      await sleep(2_500);
      let tabs;
      try { tabs = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); } catch { return { text: null, reason: 'cdp-list-failed' }; }
      const live = tabs.find((t) => t.id === target.id);
      if (!live) return { text: null, reason: 'target-disappeared' };
      // A scratch target may redirect, be reused, or be replaced underneath us. Its DOM is
      // evidence only for the canonical URL requested above, never merely for a matching target id.
      if (live.url !== url) return { text: null, reason: 'target-url-drift' };
      const sample = await tabText(live);
      if (!sample) continue;
      text = sample;
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
        evidence = classifyEvidence(sample);
        if (['terminal', 'foreign', 'cross-bound', 'throttle'].includes(evidence.kind)) {
          return { text, reason: `${evidence.kind}-evidence`, evidence };
        }
      } else {
        if (hasExactMarker(sample, marker)) return { text, reason: 'marker-found' }; // ours — done
        if (FOREIGN_MARKER_RE.test(sample)) return { text, reason: 'foreign-marker' }; // provably another run's — done
        if (isThrottlePage(sample)) return { text, reason: 'throttle' }; // interstitial — done
      }
      // Anything else (shell, pre-hydration, login wall, or a marker-only stale-source render)
      // is NOT an answer: keep sampling and return the last text at the render deadline.
    }
    return { text, reason: text ? 'not-hydrated' : 'read-failed', evidence };
  } catch {
    return { text: null, reason: 'scratch-cdp-failed' };
  } finally {
    if (target?.id) {
      try { await fetch(`http://127.0.0.1:${port}/json/close/${target.id}`); } catch {}
    }
  }
}

// VERDICT / Pn matchers tolerate GPT-5.6 formatting drift: leading bold/bullet/quote markers and
// whitespace, and markers/space between the label and its colon (e.g. `**VERDICT:**`, `- P0 :`).
const VERDICT_RE = /^\s*[*_>#-]*\s*VERDICT[*_\s]*:/i;
const PBLOCK_START_RE = /^\s*[*_>#-]*\s*(P0\s*[:\-]|P0\b|\[P[0-3]\])/i;
function extractReview(text) {
  const lines = text.split('\n');
  let verdictIdx = -1;
  for (let i = lines.length - 1; i >= 0; i--) if (VERDICT_RE.test(lines[i])) { verdictIdx = i; break; }
  if (verdictIdx < 0) return null;
  let start = -1;
  for (let i = verdictIdx; i >= 0; i--) if (PBLOCK_START_RE.test(lines[i].trim())) start = i;
  if (start < 0) start = Math.max(0, verdictIdx - 120);
  return lines.slice(start, verdictIdx + 1).join('\n').trim();
}

// #67: a page carrying a COMPLETED answer whose verdict echoes a DIFFERENT run's marker is
// that run's conversation, full stop — even though our own marker also appears on the page,
// because the marker rides the submitted PROMPT and a mis-navigated render can show ours
// above someone else's answer. Two live incidents (pro-gate#66 <- pushbot#1336,
// pushbot#1334 <- pushbot#1323) memoized exactly such a page as "ours" and, because a
// remembered URL is exempt from blacklisting, poisoned that marker's memo permanently.
// Returns the foreign marker when the ANSWER is provably another run's, else null.
function foreignAnswerMarker(text) {
  const review = extractReview(text);
  if (!review) return null;                       // no completed answer here: decides nothing
  // ONLY the terminal VERDICT line carries ownership (#68 gate r2 P1). Scanning the last six
  // lines convicts a genuine nonce-less answer whose FINDINGS merely mention another marker —
  // routine in this repo, whose reviews quote incident markers verbatim. A verdict line with
  // no marker at all is ambiguous, not foreign: return null and let the engine's nonce check
  // file it as retryable.
  const lines = review.split('\n');
  let verdictLine = '';
  for (let i = lines.length - 1; i >= 0; i--) if (VERDICT_RE.test(lines[i])) { verdictLine = lines[i]; break; }
  if (!verdictLine) return null;
  if (verdictLine.includes(`(run marker: ${marker})`)) return null;   // ours, positively
  const m = verdictLine.match(/\(run marker:\s*(pg-run-[A-Za-z0-9.-]+)\s*\)/);
  if (!m || m[1] === marker) return null;
  // POSITION MATTERS (#68 gate P1). A reused conversation can hold an OLDER nonce-bearing
  // verdict ABOVE our freshly-submitted prompt while our answer is still generating.
  // extractReview() takes the LAST verdict in the page, which in that layout is the old one —
  // convicting on it would blacklist and forget the genuine LIVE conversation and let a probe
  // count misses toward a duplicate spend. Only convict when the foreign verdict comes AFTER
  // the last occurrence of our marker, i.e. it is the answer to our prompt rather than
  // scrollback above it.
  const lastMarkerAt = lastExactMarkerAt(text, marker);
  const foreignAt = text.lastIndexOf(m[0]);
  if (lastMarkerAt >= 0 && foreignAt >= 0 && foreignAt < lastMarkerAt) return null;
  return m[1];
}

const organizerToken = (value, fallback = 'unknown') => {
  const token = String(value ?? fallback).toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '');
  return (token || fallback).slice(0, 64);
};
function emitOrganizerResult({ source = 'none', renameStatus = 'skipped', archiveStatus = 'disabled', closeStatus = 'skipped', reason = 'ok' }) {
  process.stdout.write(`organizer source=${organizerToken(source)} rename=${organizerToken(renameStatus)} archive=${organizerToken(archiveStatus)} close=${organizerToken(closeStatus)} reason=${organizerToken(reason)}\n`);
}

const isRunMarkerChar = (char) => /[A-Za-z0-9.-]/.test(char ?? '');
function lastExactMarkerAt(text, wanted) {
  let found = -1;
  let from = 0;
  while (from <= text.length - wanted.length) {
    const at = text.indexOf(wanted, from);
    if (at < 0) break;
    const before = at > 0 ? text[at - 1] : '';
    const after = text[at + wanted.length] ?? '';
    if (!isRunMarkerChar(before) && !isRunMarkerChar(after)) found = at;
    from = at + 1;
  }
  return found;
}
const hasExactMarker = (text, wanted) => !!text && lastExactMarkerAt(text, wanted) >= 0;
function lastExactRunMarkerAt(text) {
  let found = -1;
  for (const match of text.matchAll(/pg-run-[A-Za-z0-9.-]+/g)) {
    const at = match.index;
    const before = at > 0 ? text[at - 1] : '';
    const after = text[at + match[0].length] ?? '';
    if (!isRunMarkerChar(before) && !isRunMarkerChar(after)) found = at;
  }
  return found;
}

function terminalVerdict(text) {
  const lines = text.split('\n');
  let at = 0;
  let terminal = null;
  for (const line of lines) {
    if (VERDICT_RE.test(line)) terminal = { line, at };
    at += line.length + 1;
  }
  return terminal;
}

// Mutation authority is intentionally stricter than salvage extraction. The engine may capture a
// nonce-less completed answer and adjudicate it as retryable, but the organizer must not mutate that
// page: once a verdict follows this run's prompt, only an exact marker echo proves it is our answer.
function organizerOwnership(text) {
  if (!hasExactMarker(text, marker)) return { owned: false, reason: 'marker-missing' };
  const verdict = terminalVerdict(text);
  if (!verdict) return { owned: true, reason: 'live' };
  const answerMarker = verdict.line.match(/\(run marker:\s*(pg-run-[A-Za-z0-9.-]+)\s*\)/i)?.[1] ?? null;
  if (answerMarker === marker) return { owned: true, reason: 'completed' };
  if (verdict.at < lastExactMarkerAt(text, marker)) return { owned: true, reason: 'old-verdict' };
  return answerMarker
    ? { owned: false, reason: 'cross-bound', foreignMarker: answerMarker }
    : { owned: false, reason: 'answer-marker-missing' };
}

function normalizeReviewBytes(value) {
  return String(value ?? '').replace(/\r\n?/g, '\n').replace(/\n$/, '');
}

function stripMarkerEcho(value) {
  const token = `(run marker: ${marker})`;
  return String(value ?? '').split('\n').map((line) => {
    const at = line.indexOf(token);
    if (at < 0) return line;
    return `${line.slice(0, at)}${line.slice(at + token.length)}`.replace(/[ \t]+$/, '');
  }).join('\n');
}

let acceptedReview = null;
function finalizerOwnership(text) {
  if (acceptedReview === null) return { owned: false, reason: 'result-file-missing' };
  const verdict = terminalVerdict(text);
  if (!verdict) return { owned: false, reason: 'answer-incomplete' };
  const promptMarkerAt = lastExactMarkerAt(text.slice(0, verdict.at), marker);
  if (promptMarkerAt < 0) return { owned: false, reason: 'answer-incomplete' };
  if (lastExactRunMarkerAt(text.slice(verdict.at + verdict.line.length)) >= 0) {
    return { owned: false, reason: 'newer-run-marker' };
  }
  const answerMarker = verdict.line.match(/\(run marker:\s*(pg-run-[A-Za-z0-9.-]+)\s*\)/i)?.[1] ?? null;
  if (!answerMarker) return { owned: false, reason: 'answer-marker-missing' };
  if (answerMarker !== marker) {
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
    let response = await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`, { method: 'PUT' });
    if (!response.ok) response = await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`);
    if (!response.ok) return { target: null, reason: 'memo-open-failed' };
    target = await response.json();
    const renderDeadline = Math.min(deadline, Date.now() + 25_000);
    let sawLogin = false;
    while (Date.now() < renderDeadline) {
      await sleep(Math.min(250, Math.max(0, renderDeadline - Date.now())));
      let live = target;
      try {
        const tabs = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
        live = tabs.find((tab) => tab.id === target.id) ?? null;
      } catch { return { target, reason: 'cdp-list-failed' }; }
      if (!live) return { target, reason: 'memo-tab-disappeared' };
      if (live.url !== url) return { target: live, reason: 'memo-url-drift' };
      const text = await tabText(live);
      if (!text) continue;
      if (isThrottlePage(text)) return { target: live, reason: 'throttle' };
      if (hasExactMarker(text, marker)) {
        const ownership = mutationOwnership(text);
        return ownership.owned
          ? { target: live, text, reason: 'ok' }
          : { target: live, reason: ownership.reason };
      }
      if (FOREIGN_MARKER_RE.test(text)) return { target: live, reason: 'stale-memo' };
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

  const reads = await Promise.all(tabs.map(async (tab) => ({ tab, text: await tabText(tab) })));
  if (reads.some(({ text }) => isThrottlePage(text))) {
    recordThrottle('organizer scan');
    return { ...result, reason: 'throttle' };
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
    if (!recoveryUrl) return { ...result, reason: rejectionReason };
    if (nonMatching.has(recoveryUrl)) return { ...result, reason: 'provenance-rejected' };
    const scratch = await openOrganizerScratch(recoveryUrl);
    if (!scratch.text || !scratch.target) {
      if (scratch.reason === 'throttle') recordThrottle('organizer scratch');
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
function classifyEvidence(text) {
  if (!text || !text.trim()) return { kind: 'inconclusive', reason: 'empty-text' };
  if (isThrottlePage(text)) return { kind: 'throttle' };
  if (!hasExactMarker(text, marker)) {
    return FOREIGN_MARKER_RE.test(text)
      ? { kind: 'foreign' }
      : { kind: 'inconclusive', reason: 'marker-not-hydrated' };
  }
  const foreignMarker = foreignAnswerMarker(text);
  if (foreignMarker) return { kind: 'cross-bound', foreignMarker };
  const review = extractReview(text);
  if (!review) return { kind: 'owned-incomplete' };
  const verdict = terminalVerdict(text);
  const promptMarkerAt = verdict ? lastExactMarkerAt(text.slice(0, verdict.at), marker) : -1;
  const answerMarker = verdict?.line.match(/\(run marker:\s*(pg-run-[A-Za-z0-9.-]+)\s*\)/i)?.[1] ?? null;
  // The marker echoed in the terminal line is not a later prompt. A separate exact marker after
  // that line is, and proves this otherwise-owned verdict belongs to an older turn in the same chat.
  const newerPromptMarker = verdict && hasExactMarker(text.slice(verdict.at + verdict.line.length), marker);
  return {
    kind: 'terminal',
    review,
    probeComplete: promptMarkerAt >= 0 && answerMarker === marker && !newerPromptMarker,
  };
}

// Positive evidence mutates URL ownership only after the shared classifier has excluded a
// cross-bound answer. It deliberately does not exit; the readable-source path gets exactly one
// canonical scratch revalidation before the caller decides whether an owned incomplete page is
// still generating.
function onOurConversation(url, text) {
  const evidence = classifyEvidence(text);
  if (evidence.kind === 'cross-bound') return evidence;
  if (!['owned-incomplete', 'terminal'].includes(evidence.kind)) return evidence;
  ourUrls.add(url);
  // Positive ownership: the run is demonstrably NOT terminally cross-bound, whatever other
  // candidates this scan rejected (#68 gate r2/r3 P2). Decided at exit, so tab order is
  // irrelevant.
  ownershipProven = true;
  rememberUrl(marker, url);
  knownUrl = url;                // usable by the recovery branch from the very next cycle
  return evidence;
}

function emitEvidence(url, evidence) {
  if (probe) {
    console.error(`live conversation: ${url}`);
    // rc 0 proves the conversation exists. Completeness is intentionally stricter than harvest
    // extraction: the terminal verdict must answer the latest exact prompt and echo this marker.
    console.error(`probe-state: ${evidence.kind === 'terminal' && evidence.probeComplete ? 'complete' : 'generating'}`);
    process.exit(0);
  }
  if (evidence.kind === 'terminal') {
    // v0.28 (gate #54 r5): name the EXACT source of this capture so the engine can blacklist
    // precisely on a provenance rejection — reading the shared memo afterwards races probes.
    console.error(`matched-url ${url}`);
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
  const reads = await Promise.all(tabs.map(async (tab) => ({ tab, text: await tabText(tab) })));
  for (const { tab, text } of reads) {
    if (text === null || text.trim() === '') { deadTabs.push(tab); continue; }
    if (isThrottlePage(text)) tripThrottle(`tab ${tab.url}`);
    // v0.28 (gate #54 r2): honor the per-marker blacklist for OPEN tabs too, not only
    // re-renders. The engine appends here when a capture from this URL failed the provenance
    // check — even a marker-bearing tab must be skipped then, or every later harvest replays
    // the same rejected conversation and starves the real one.
    if (nonMatching.has(tab.url)) continue;
    if (!text.includes(marker)) {
      // The remembered URL is open and rendered ANOTHER run's conversation: the memo is stale
      // (recycled URL, or it was never ours). This is the second way to prove staleness — the
      // first is a seeded render below — and without it an open-but-foreign remembered URL is
      // never re-rendered (it is already a tab), so nothing could ever decide it.
      if (tab.url === knownUrl && FOREIGN_MARKER_RE.test(text)) memoStale = true;
      continue;
    }
    let evidence = onOurConversation(tab.url, text);
    if (evidence.kind === 'cross-bound') {
      rejectCrossBound(tab.url, evidence.foreignMarker, 'tab');
      continue;
    }
    if (evidence.kind === 'terminal') emitEvidence(tab.url, evidence);
    if (evidence.kind !== 'owned-incomplete') continue;
    stillGeneratingUrl = tab.url;
    lastMatchWasSeeded = false;
    // A readable DOM can be stale while its server-side conversation is complete. The source
    // remains untouched; one same-profile scratch navigation is the only fresh evidence pass.
    const fresh = await revalidateReadableStaleSource(tab.url);
    if (fresh?.kind === 'throttle') tripThrottle(`canonical scratch ${tab.url}`);
    if (fresh?.kind === 'cross-bound') {
      rejectCrossBound(tab.url, fresh.foreignMarker, 'canonical scratch');
      stillGeneratingUrl = null;
      continue;
    }
    if (fresh?.kind === 'foreign') {
      rejectForeign(tab.url, 'canonical scratch');
      stillGeneratingUrl = null;
      continue;
    }
    if (fresh?.kind === 'terminal') emitEvidence(tab.url, fresh);
    // Inconclusive scratch evidence deliberately leaves the proven source live and makes no
    // memo/blacklist mutation. Probe still returns rc 0, but only after this bounded pass.
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
    const { text } = await freshRenderText(tab.url, port, deadline);
    if (!text) continue;
    if (isThrottlePage(text)) tripThrottle(`fresh render ${tab.url}`);
    if (!text.includes(marker)) {
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
    const evidence = onOurConversation(tab.url, text);
    if (evidence.kind === 'cross-bound') {
      rejectCrossBound(tab.url, evidence.foreignMarker, 're-rendered');
      continue;
    }
    if (evidence.kind === 'terminal') emitEvidence(tab.url, evidence);
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
    const { text } = await freshRenderText(seedUrl, port, deadline);
    if (text) {
      const evidence = classifyEvidence(text);
      if (evidence.kind === 'throttle') tripThrottle(`remembered render ${seedUrl}`);
      if (evidence.kind === 'cross-bound') {
        // The memo itself is cross-bound. Evict it with claim-and-verify, but preserve a
        // concurrently republished survivor as the only possible genuine recovery handle.
        rejectCrossBound(seedUrl, evidence.foreignMarker, 'remembered conversation');
      } else if (evidence.kind === 'terminal' || evidence.kind === 'owned-incomplete') {
        const owned = onOurConversation(seedUrl, text);
        if (owned.kind === 'terminal') emitEvidence(seedUrl, owned);
        if (owned.kind === 'owned-incomplete') {
          stillGeneratingUrl = seedUrl;
          lastMatchWasSeeded = true;
          seededLiveUrl = seedUrl;   // survives later empty scans: this is server-side evidence
          if (probe) emitEvidence(seedUrl, owned);
          console.error(`remembered conversation recovered (${seedUrl}) but no VERDICT yet; waiting...`);
        }
      } else if (evidence.kind === 'foreign') {
        // Decisive the other way: the memo points at ANOTHER run's conversation (stale or
        // corrupt). Only this justifies treating the remembered handle as worthless.
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
    const live = reads.find(({ text }) => text && text.includes(marker));
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
  process.exit(3);
}
if (!lastListOk) {
  // Never got a single successful tab list: the browser is down or restarting. That is absence
  // of EVIDENCE, not evidence of absence, and the engine's miss counter (3 strikes -> "review
  // lost, re-run justified") must not advance on it. Distinct code, so callers keep the
  // reservation and retry instead.
  console.error(`inconclusive: the last CDP tab list failed (${listFailures} consecutive) within ${timeoutSecs}s — browser down or restarting; NOT evidence the conversation is gone`);
  process.exit(7);
}
if (knownUrl && !memoStale) {
  // We hold a URL proven to be this run's conversation and could not decisively rule it out —
  // the renders were inconclusive (shell / login wall / never got a turn within budget). A
  // successful TAB listing is not evidence about SERVER-SIDE state, so it must not be laundered
  // into a confirmed absence: three of those releases a live reservation and permits a
  // double-spending resubmit (gate P1). Stay inconclusive; the reservation TTL bounds it.
  console.error(`inconclusive: remembered conversation ${knownUrl} re-rendered ${seededRenders}x without a decisive result in ${timeoutSecs}s — NOT evidence it is gone`);
  process.exit(7);
}
console.error(`timeout: no ${probe ? 'conversation tab' : 'completed review'} matching "${marker}" after ${timeoutSecs}s`
  + (memoStale ? ' (the remembered conversation belongs to another run; memo was stale)' : ''));
process.exit(4);
