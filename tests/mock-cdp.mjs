#!/usr/bin/env node
// Standalone mock CDP browser for engine-level tests: serves /json/version (preflight),
// /json (one chatgpt.com/c/ tab whose innerText is the contents of the file in argv[1]),
// the tab's debugger WebSocket, and /json/close. Prints the chosen port on stdout.
// Usage: node tests/mock-cdp.mjs <tab-text-file>
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import fs from 'node:fs';

const textFile = process.argv[2];
if (!textFile) { console.error('usage: mock-cdp.mjs <tab-text-file>'); process.exit(2); }
const WS_MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function wsTextFrame(payload) {
  const data = Buffer.from(payload, 'utf8');
  if (data.length < 126) return Buffer.concat([Buffer.from([0x81, data.length]), data]);
  const head = Buffer.alloc(4);
  head[0] = 0x81; head[1] = 126; head.writeUInt16BE(data.length, 2);
  return Buffer.concat([head, data]);
}

const server = createServer((req, res) => {
  if (req.url === '/json/version') { res.end(JSON.stringify({ Browser: 'MockChrome/1.0' })); return; }
  if (req.url === '/json') {
    const port = server.address().port;
    const current = fs.readFileSync(textFile, 'utf8');
    res.setHeader('content-type', 'application/json');
    if (current === '__NO_TABS__') { res.end('[]'); return; }
    res.end(JSON.stringify([{
      id: 'tab1', type: 'page', url: 'https://chatgpt.com/c/mock-conversation',
      webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/tab1`,
    }]));
    return;
  }
  if (req.url?.startsWith('/json/close/')) { console.error(`closed ${req.url.split('/').pop()}`); res.end('ok'); return; }
  res.statusCode = 404; res.end();
});
server.on('upgrade', (req, socket) => {
  const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + WS_MAGIC).digest('base64');
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
    + `Sec-WebSocket-Accept: ${accept}\r\n\r\n`);
  socket.on('data', () => {
    const text = fs.readFileSync(textFile, 'utf8');
    socket.write(wsTextFrame(JSON.stringify({ id: 1, result: { result: { value: text } } })));
  });
  socket.on('error', () => {});
});
server.listen(0, '127.0.0.1', () => process.stdout.write(`${server.address().port}\n`));
