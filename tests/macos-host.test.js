'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { createInterface } = require('node:readline');
const { once } = require('node:events');

test('macOS host: separate data directory, authenticated API, EOF shutdown and persistence', { timeout: 30000 }, async t => {
  const root = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'whale-mac-'));
  const payload = process.env.WHALE_MAC_TEST_PAYLOAD || path.resolve(__dirname, '..');
  const node = process.env.WHALE_MAC_TEST_NODE || process.execPath;
  let child;
  t.after(() => { child?.kill(); fs.rmSync(root, { recursive: true, force: true }); });
  const start = async () => {
    child = spawn(node, [path.join(payload, 'macos/host.js'), root], { stdio: ['pipe', 'pipe', 'pipe'] });
    const exited = once(child, 'exit');
    const lines = createInterface({ input: child.stdout });
    const url = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', code => reject(new Error('host exited before ready: ' + code)));
      lines.on('line', line => {
        if (!line.startsWith('WHALE_MAC ')) return;
        const event = JSON.parse(line.slice(10));
        if (event.event === 'ready') resolve(event.detail);
      });
    });
    return { url, exited };
  };
  const first = await start();
  assert.equal((await fetch(first.url + '/api/status')).status, 200);
  const config = JSON.parse(fs.readFileSync(path.join(root, 'config.json')));
  const token = config.gateway.wechat.inboundToken;
  assert.match(token, /^[a-f0-9]{64}$/);
  assert.equal((await fetch(first.url + '/api/bridge/heartbeat', {
    method: 'POST', body: '{}', headers: { 'content-type': 'application/json' },
  })).status, 403);
  assert.equal((await fetch(first.url + '/api/bridge/heartbeat', {
    method: 'POST', body: '{}', headers: { 'content-type': 'application/json', 'x-bot-token': token },
  })).status, 200);
  child.stdin.end();
  assert.equal((await first.exited)[0], 0);
  const second = await start();
  assert.equal(JSON.parse(fs.readFileSync(path.join(root, 'config.json'))).gateway.wechat.inboundToken, token);
  child.stdin.write(JSON.stringify({ action: 'shutdown' }) + '\n');
  assert.equal((await second.exited)[0], 0);
  assert.ok(fs.existsSync(path.join(root, 'assets/personas')));
});
