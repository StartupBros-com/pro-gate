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
    const bail = setTimeout(() => { try { ws.close(); } catch {} resolve(null); }, 15_000);
    ws.onerror = () => { clearTimeout(bail); resolve(null); };
    ws.onopen = () => ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression: 'document.body.innerText', returnByValue: true } }));
    ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id === 1) { clearTimeout(bail); try { ws.close(); } catch {} resolve(m.result?.result?.value ?? null); }
    };
  });
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
  for (const tab of tabs) {
    const text = await tabText(tab);
    if (!text || !text.includes(marker)) continue;
    if (probe) { console.error(`live conversation tab: ${tab.url}`); process.exit(0); }
    const review = extractReview(text);
    if (review) { console.log(review); process.exit(0); }
    console.error(`conversation found (${tab.url}) but no VERDICT yet; waiting...`);
  }
  await new Promise((r) => setTimeout(r, probe ? 5_000 : POLL_MS));
}
console.error(`timeout: no ${probe ? 'conversation tab' : 'completed review'} matching "${marker}" after ${timeoutSecs}s`);
process.exit(4);
