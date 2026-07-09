#!/usr/bin/env node
// Last-resort review salvage: read the finished GPT-5.5 Pro Extended review
// straight off the ChatGPT conversation tab's DOM via CDP.
//
// Why this exists: oracle (<=0.15.0) can fail to DETECT the thinking state
// after a ChatGPT UI change even though the submission landed. The engine's
// no-think watchdog then kills a LIVE run, and `oracle session --harvest`
// reattaches to a stale tab target ("Assistant turns: 0") while the real
// conversation keeps generating in another tab. This helper finds the
// conversation tab by PR marker, waits for the VERDICT line, and prints the
// review block. First seen: pushbot PR #863, 2026-07-02.
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
// Usage: cdp-salvage.mjs [--probe] <pr-marker> [timeout-secs] [cdp-port]
//   pr-marker    substring identifying the right conversation (e.g. the PR
//                URL or the engine's pg-run marker); required because several
//                review slots may have concurrent conversation tabs open.
//   --probe      liveness check only: exit 0 as soon as a conversation tab
//                matching the marker EXISTS (no VERDICT wait). Used by the
//                engine's no-think watchdog to distinguish "dead submission,
//                safe to retry" from "live run, retry would double-spend".
// Exit: 0 = review printed (probe: tab found); 4 = timeout; 2 = usage error;
//       5 = ChatGPT throttle detected (cooldown written — do NOT resubmit).
// Requires Node >= 21 (global WebSocket); the box runs Node 24.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const argv = process.argv.slice(2);
const probe = argv[0] === '--probe' && argv.shift();
const close = argv[0] === '--close' && argv.shift();
const [marker, timeoutSecs = probe ? '30' : '600', port = process.env.ORACLE_CDP_PORT ?? '9222'] = argv;
if (!marker) { console.error('usage: cdp-salvage.mjs [--probe|--close] <pr-marker> [timeout-secs] [cdp-port]'); process.exit(2); }
const deadline = Date.now() + Number(timeoutSecs) * 1000;
const POLL_MS = 20_000;

const PG_HOME = process.env.PRO_GATE_HOME ?? path.join(os.homedir(), '.pro-review-daemon');
const BLACKLIST_FILE = path.join(PG_HOME, 'salvage-nonmatching.txt');
// honor the same override pg_health_gate reads, or a detected throttle would never defer runs
const COOLDOWN_FILE = process.env.PRO_GATE_COOLDOWN_FILE ?? path.join(PG_HOME, 'throttle.cooldown');
// The interstitial's two distinctive sentences. Deliberately NOT a generic
// /rate.?limit/ — review findings routinely discuss rate limits.
const THROTTLE_RE = /making requests too quickly|temporarily limited access to your conversations/i;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A page is the throttle interstitial only if it carries the phrase, no run
// marker at all (ours or foreign — real conversations can QUOTE the phrase,
// e.g. a review of this very engine), and is short like an error page.
function isThrottlePage(text) {
  return !!text && text.length < 5000 && !/pg-run-[A-Za-z0-9.-]+/.test(text) && THROTTLE_RE.test(text);
}
function tripThrottle(where) {
  try {
    fs.mkdirSync(PG_HOME, { recursive: true });
    fs.writeFileSync(COOLDOWN_FILE, `${new Date().toISOString()} ${where}\n`);
  } catch {}
  console.error(`ChatGPT throttle interstitial detected (${where}) — cooldown written to ${COOLDOWN_FILE}. Back off; do NOT resubmit.`);
  process.exit(5);
}

async function tabText(tab) {
  return await new Promise((resolve) => {
    const ws = new WebSocket(tab.webSocketDebuggerUrl);
    // 5s bail: a healthy renderer answers in well under a second; suspended
    // renderers never answer, and orphaned conversation tabs accumulate on
    // the persistent Chrome, so a long bail makes every poll cycle crawl.
    const bail = setTimeout(() => { try { ws.close(); } catch {} resolve(null); }, 5_000);
    ws.onerror = () => { clearTimeout(bail); resolve(null); };
    ws.onopen = () => ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression: 'document.body.innerText', returnByValue: true } }));
    ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id === 1) { clearTimeout(bail); try { ws.close(); } catch {} resolve(m.result?.result?.value ?? null); }
    };
  });
}

async function closeTab(id) {
  try { await fetch(`http://127.0.0.1:${port}/json/close/${id}`); } catch {}
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

// Persistent blacklist: conversations proven (by a foreign run marker) to
// belong to another review. That fact never changes, so remember it across
// invocations instead of re-rendering the same dead tabs every salvage.
const nonMatching = new Set();
try {
  for (const u of fs.readFileSync(BLACKLIST_FILE, 'utf8').split('\n')) if (u.trim()) nonMatching.add(u.trim());
} catch {}
function blacklist(url) {
  if (nonMatching.has(url)) return;
  nonMatching.add(url);
  try {
    fs.mkdirSync(PG_HOME, { recursive: true });
    // rewrite (bounded) rather than append forever
    fs.writeFileSync(BLACKLIST_FILE, [...nonMatching].slice(-500).join('\n') + '\n');
  } catch {}
}

async function freshRenderText(url, port, outerDeadline) {
  let target = null;
  try {
    let res = await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`, { method: 'PUT' });
    if (!res.ok) res = await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`); // pre-v111 Chrome used GET
    if (!res.ok) return { text: null };
    target = await res.json();
    // never grant more than the caller's remaining budget (a 30s probe must
    // not stall watchdog/retry decisions by overrunning its own window)
    const renderDeadline = Math.min(Date.now() + 25_000, outerDeadline);
    let text = null;
    while (Date.now() + 2_500 < renderDeadline) {
      await sleep(2_500);
      const tabs = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
      const live = tabs.find((t) => t.id === target.id);
      if (!live) break;
      text = await tabText(live);
      if (text && text.trim().length > 200) return { text };
    }
    return { text };
  } catch {
    return { text: null };
  } finally {
    if (target?.id) {
      try { await fetch(`http://127.0.0.1:${port}/json/close/${target.id}`); } catch {}
    }
  }
}

function extractReview(text) {
  const lines = text.split('\n');
  let verdictIdx = -1;
  for (let i = lines.length - 1; i >= 0; i--) if (/^VERDICT:/.test(lines[i])) { verdictIdx = i; break; }
  if (verdictIdx < 0) return null;
  let start = -1;
  for (let i = verdictIdx; i >= 0; i--) if (/^(P0\s*[:\-]|P0$|\[P[0-3]\])/.test(lines[i].trim())) start = i;
  if (start < 0) start = Math.max(0, verdictIdx - 120);
  return lines.slice(start, verdictIdx + 1).join('\n').trim();
}

let listFailures = 0;
while (Date.now() < deadline) {
  let tabs = [];
  try {
    tabs = (await (await fetch(`http://127.0.0.1:${port}/json`)).json())
      .filter((t) => t.type === 'page' && /chatgpt\.com\/c\//.test(t.url || ''));
    listFailures = 0;
  } catch (e) {
    // v0.18: transient — Chrome restarts and CDP hiccups happen mid-salvage.
    // Aborting here made the engine's pre-retry probe read "dead submission"
    // and green-light a double-spending retry. Back off, retry until deadline.
    listFailures += 1;
    console.error(`CDP list failed (${listFailures}x): ${e.message} — retrying until deadline`);
    await sleep(Math.min(5_000 * listFailures, 30_000));
    continue;
  }
  const deadTabs = [];
  const reads = await Promise.all(tabs.map(async (tab) => ({ tab, text: await tabText(tab) })));
  for (const { tab, text } of reads) {
    if (text === null || text.trim() === '') { deadTabs.push(tab); continue; }
    if (isThrottlePage(text)) tripThrottle(`tab ${tab.url}`);
    if (!text.includes(marker)) continue;
    ourUrls.add(tab.url);
    if (probe) { console.error(`live conversation tab: ${tab.url}`); process.exit(0); }
    const review = extractReview(text);
    if (review) { await closeTab(tab.id); console.log(review); process.exit(0); }
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
      if (/pg-run-[A-Za-z0-9.-]+/.test(text)) blacklist(tab.url);
      continue;
    }
    ourUrls.add(tab.url);
    if (probe) { console.error(`live conversation (via fresh render): ${tab.url}`); process.exit(0); }
    const review = extractReview(text);
    if (review) { await closeTab(tab.id); console.log(review); process.exit(0); }
    console.error(`conversation matches (via fresh render, ${tab.url}) but no VERDICT yet; waiting...`);
  }
  await sleep(probe ? 5_000 : POLL_MS);
}
console.error(`timeout: no ${probe ? 'conversation tab' : 'completed review'} matching "${marker}" after ${timeoutSecs}s`);
process.exit(4);
