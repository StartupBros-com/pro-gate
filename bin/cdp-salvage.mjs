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
// Usage: cdp-salvage.mjs [--probe] <pr-marker> [timeout-secs] [cdp-port]
//   pr-marker    substring identifying the right conversation (e.g. the PR
//                URL or "pull/863"); required because up to 3 review slots
//                may have concurrent conversation tabs open.
//   --probe      liveness check only: exit 0 as soon as a conversation tab
//                matching the marker EXISTS (no VERDICT wait). Used by the
//                engine's no-think watchdog to distinguish "dead submission,
//                safe to retry" from "live run, retry would double-spend".
// Exit: 0 = review printed (probe: tab found); 4 = timeout; 2 = usage/CDP error.
// Requires Node >= 21 (global WebSocket); the box runs Node 24.

const argv = process.argv.slice(2);
const probe = argv[0] === '--probe' && argv.shift();
const [marker, timeoutSecs = probe ? '30' : '600', port = process.env.ORACLE_CDP_PORT ?? '9222'] = argv;
if (!marker) { console.error('usage: cdp-salvage.mjs [--probe] <pr-marker> [timeout-secs] [cdp-port]'); process.exit(2); }
const deadline = Date.now() + Number(timeoutSecs) * 1000;
const POLL_MS = 20_000;

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

// v0.17: renderer-dead-tab fallback. Under Xvfb a background conversation
// tab's renderer can suspend or crash: Runtime.evaluate then returns nothing
// (and /json/activate does NOT revive it) even though the finished review
// exists in ChatGPT server state. Re-render the SAME conversation URL in a
// fresh scratch tab (non-destructive; uses the signed-in profile), read the
// text there, and close the scratch tab. Conversations whose fresh render
// loads fully but shows no marker belong to another review and are
// blacklisted for the rest of this invocation.
const FRESH_RENDERS_PER_CYCLE = 3;
const nonMatching = new Set();

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
      await new Promise((r) => setTimeout(r, 2_500));
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

while (Date.now() < deadline) {
  let tabs = [];
  try {
    tabs = (await (await fetch(`http://127.0.0.1:${port}/json`)).json())
      .filter((t) => t.type === 'page' && /chatgpt\.com\/c\//.test(t.url || ''));
  } catch (e) { console.error(`CDP list failed: ${e.message}`); process.exit(2); }
  const deadTabs = [];
  const reads = await Promise.all(tabs.map(async (tab) => ({ tab, text: await tabText(tab) })));
  for (const { tab, text } of reads) {
    if (text === null || text.trim() === '') { deadTabs.push(tab); continue; }
    if (!text.includes(marker)) continue;
    if (probe) { console.error(`live conversation tab: ${tab.url}`); process.exit(0); }
    const review = extractReview(text);
    if (review) { console.log(review); process.exit(0); }
    console.error(`conversation found (${tab.url}) but no VERDICT yet; waiting...`);
  }
  // v0.17 fallback: unreadable tabs get their URL re-rendered in a scratch tab
  let renders = 0;
  for (const tab of deadTabs) {
    if (Date.now() >= deadline) break;
    if (renders >= FRESH_RENDERS_PER_CYCLE) break;
    if (nonMatching.has(tab.url)) continue;
    renders += 1;
    console.error(`tab unreadable (renderer dead?): ${tab.url} — re-rendering in a scratch tab...`);
    const { text } = await freshRenderText(tab.url, port, deadline);
    if (!text) continue;
    if (!text.includes(marker)) {
      // Blacklist ONLY on positive evidence: the page carries someone
      // ELSE's run marker, proving it rendered a different review's
      // conversation. Shell/login/error pages and pre-hydration renders can
      // exceed any length heuristic without being the conversation at all;
      // blacklisting those could permanently hide the real review and let
      // --probe green-light a double-spending retry. Anything without a
      // foreign marker is treated as not-ready and retried next cycle.
      if (/pg-run-[A-Za-z0-9.-]+/.test(text)) nonMatching.add(tab.url);
      continue;
    }
    if (probe) { console.error(`live conversation (via fresh render): ${tab.url}`); process.exit(0); }
    const review = extractReview(text);
    if (review) { console.log(review); process.exit(0); }
    console.error(`conversation matches (via fresh render, ${tab.url}) but no VERDICT yet; waiting...`);
  }
  await new Promise((r) => setTimeout(r, probe ? 5_000 : POLL_MS));
}
console.error(`timeout: no ${probe ? 'conversation tab' : 'completed review'} matching "${marker}" after ${timeoutSecs}s`);
process.exit(4);
