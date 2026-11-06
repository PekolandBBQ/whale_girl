'use strict';

const { spawn } = require('node:child_process');
const { createInterface } = require('node:readline');
const { randomUUID } = require('node:crypto');

// AX 没有稳定消息 ID；只接受与上一帧尾部重合的新增部分，失去锚点时停止。
const identity = (row) => JSON.stringify([row.kind, row.sender, row.media, row.text]);
function newMessages(previous, current) {
  if (!Array.isArray(current) || current.some(r => !r || typeof r.text !== 'string')) {
    throw new Error('invalid_snapshot');
  }
  if (previous === null) return [];
  const a = previous.map(identity), b = current.map(identity);
  if (JSON.stringify(a) === JSON.stringify(b)) return [];
  for (let n = Math.min(a.length, b.length); n > 0; n--) {
    if (a.slice(-n).every((key, i) => key === b[i])) return current.slice(n);
  }
  // 空会话的第一条消息可以处理；其它无重合情况不能分辨翻页和新消息。
  if (!a.length) return current;
  throw new Error('snapshot_lost_anchor');
}

class Adapter {
  constructor(python, script, root) {
    this.pending = new Map();
    this.nextId = 0;
    this.child = spawn(python, ['-u', script], {
      cwd: root, stdio: ['pipe', 'pipe', 'ignore'],
      env: { ...process.env, PYTHONUTF8: '1', WECHAT_MCP_LOG_DIR: root + '/data/mac-bridge' },
    });
    this.lines = createInterface({ input: this.child.stdout });
    this.lines.on('line', line => {
      let reply;
      try { reply = JSON.parse(line); } catch { return this.close('adapter_protocol'); }
      const request = this.pending.get(reply.id);
      if (!request) return;
      clearTimeout(request.timer);
      this.pending.delete(reply.id);
      if (reply.error) request.reject(new Error(reply.error));
      else request.resolve(reply.result);
    });
    this.child.on('error', () => this.close('adapter_start_failed'));
    this.child.on('exit', () => this.close('adapter_exited'));
    this.child.stdin.on('error', () => this.close('adapter_pipe_closed'));
  }
  call(method, params) {
    if (this.closed) return Promise.reject(new Error('adapter_closed'));
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.close('adapter_timeout'), 15000);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
    });
  }
  close(reason = 'bridge_stopped') {
    if (this.closed) return;
    this.closed = true;
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.reject(new Error(reason));
    }
    this.pending.clear();
    this.lines.close();
    this.child.stdin.end();
    this.child.kill('SIGTERM');
  }
}

class Bridge {
  constructor({ adapter, chat, inbound, heartbeat, report = () => {} }) {
    this.adapter = adapter;
    this.chat = chat;
    this.inbound = inbound;
    this.heartbeat = heartbeat;
    this.report = report;
    this.previous = null;
    this.stopped = false;
  }
  async tick() {
    if (this.stopped) return;
    const current = await this.adapter.call('read', { chat: this.chat });
    const added = newMessages(this.previous, current);
    // 先消耗消息，生成/发送异常不能触发重放。
    this.previous = current;
    if (added.some(r => r.kind === 'message' && r.sender === 'UNKNOWN')) {
      throw new Error('sender_unknown');
    }
    await this.heartbeat();
    for (const row of added) {
      if (this.stopped) return;
      if (row.kind !== 'message' || row.sender !== 'OTHER' || row.media || !row.text.trim()) continue;
      const result = await this.inbound({
        chat_id: 'mac-' + this.chat, chat_type: 'private', sender_id: 'mac-' + this.chat,
        sender_name: this.chat, text: row.text, msg_id: randomUUID(), local: true,
      });
      if (this.stopped) return;
      if (!result.ok) throw new Error('kernel_rejected');
      if (result.action !== 'reply' || !result.reply || result.stickerOnly) continue;
      const sent = await this.adapter.call('send', { chat: this.chat, text: result.reply });
      if (sent?.confirmed !== true) throw new Error('send_unconfirmed');
      this.report('已确认一条文字回复');
    }
  }
  stop() {
    this.stopped = true;
    this.adapter.close();
  }
}

module.exports = { Adapter, Bridge, newMessages };
