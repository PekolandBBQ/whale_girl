'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Bridge, newMessages } = require('../macos/bridge');
const incoming = text => ({ kind: 'message', sender: 'OTHER', text, media: null });
const own = text => ({ ...incoming(text), sender: 'ME' });

test('macOS: baseline, overlap, duplicate text and self messages', () => {
  const old = [incoming('old'), own('answer')];
  assert.deepEqual(newMessages(null, old), []);
  assert.deepEqual(newMessages(old, old), []);
  assert.deepEqual(newMessages(old, [own('answer'), incoming('new')]), [incoming('new')]);
  assert.deepEqual(newMessages([incoming('hi')], [incoming('hi'), incoming('hi')]), [incoming('hi')]);
  assert.throws(() => newMessages(old, [incoming('unrelated')]), /lost_anchor/);
});

function harness(frames, send = { confirmed: true }) {
  const calls = [], received = [];
  const adapter = {
    async call(method, params) {
      calls.push({ method, params });
      return method === 'read' ? frames.shift() : send;
    }, close() {},
  };
  const bridge = new Bridge({ adapter, chat: 'test-friend', heartbeat: async () => {},
    inbound: async msg => { received.push(msg); return { ok: true, action: 'reply', reply: 'reply' }; } });
  return { bridge, calls, received };
}

test('macOS: forwards only new incoming text, never baseline, own or media', async () => {
  const baseline = [incoming('old')];
  const newer = [...baseline, own('mine'), { ...incoming('Image'), media: 'image' }, incoming('new')];
  const { bridge, calls, received } = harness([baseline, newer, newer]);
  await bridge.tick(); await bridge.tick(); await bridge.tick();
  assert.equal(received.length, 1);
  assert.equal(received[0].text, 'new');
  assert.equal(received[0].chat_type, 'private');
  assert.equal(calls.filter(x => x.method === 'send').length, 1);
});

test('macOS: unknown sender stops before calling the model', async () => {
  const { bridge, received } = harness([[], [{ ...incoming('new'), sender: 'UNKNOWN' }]]);
  await bridge.tick();
  await assert.rejects(bridge.tick(), /sender_unknown/);
  assert.equal(received.length, 0);
});

test('macOS: uncertain send is consumed and never automatically retried', async () => {
  const frame = [incoming('new')];
  const { bridge, calls } = harness([[], frame, frame], { confirmed: false });
  await bridge.tick();
  await assert.rejects(bridge.tick(), /send_unconfirmed/);
  await bridge.tick();
  assert.equal(calls.filter(x => x.method === 'send').length, 1);
});

test('macOS: stopping during model generation prevents sending', async () => {
  let resolve;
  const { bridge, calls } = harness([[], [incoming('new')]]);
  bridge.inbound = () => new Promise(r => { resolve = r; });
  await bridge.tick();
  const running = bridge.tick();
  await new Promise(r => setImmediate(r));
  bridge.stop();
  resolve({ ok: true, action: 'reply', reply: 'reply' });
  await running;
  assert.equal(calls.filter(x => x.method === 'send').length, 0);
});
