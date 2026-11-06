'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const readline = require('node:readline');
const { startServer } = require('../server');
const { Adapter, Bridge } = require('./bridge');
const { describeError } = require('../src/infra/errors');

const BRIDGE_ERRORS = {
  accessibility_permission: '请授予鲸鲸辅助功能权限，然后重开应用',
  screen_recording_permission: '请授予鲸鲸屏幕录制权限，然后重开应用',
  wechat_not_foreground: '请打开并登录微信，保持目标私聊在前台后重新启用',
  chat_changed: '当前会话与指定私聊不一致，请确认后重新启用',
  draft_present: '微信输入框已有内容；草稿已保留，请处理后重新启用',
  input_changed: '输入框发生变化，请检查微信草稿后重新启用',
  input_focus_failed: '无法定位微信输入框，请检查会话和辅助功能权限',
  input_not_focused: '微信输入框没有焦点，已取消发送',
  input_write_failed: '无法写入微信输入框，请检查辅助功能权限',
  snapshot_lost_anchor: '可见消息发生较大变化，已停止以免重放历史消息',
  sender_unknown: '无法确认消息来自谁，请检查屏幕录制权限和微信窗口',
  send_unconfirmed: '未确认发送结果，不会重试；请检查微信消息和残留草稿',
  adapter_start_failed: '桥接 Python 启动失败，请检查路径或重新安装桥接环境',
  adapter_exited: '桥接环境未能运行，请重新安装桥接环境并确认权限',
  adapter_timeout: '微信界面操作超时，请检查微信消息和草稿后重新启用',
  accessibility_failed: '微信界面读取失败，请检查权限、窗口和微信版本',
};

async function main() {
  const root = process.argv[2];
  if (!root || !path.isAbsolute(root)) throw new Error('absolute_data_directory_required');
  fs.mkdirSync(root, { recursive: true, mode: 0o700 });
  // 配置、记忆放 Application Support；应用资源只读，更新 .app 不覆盖个人数据。
  const configFile = path.join(root, 'config.json');
  if (!fs.existsSync(configFile)) {
    fs.writeFileSync(configFile, JSON.stringify({
      server: { host: '127.0.0.1', port: 0 },
      gateway: { wechat: { enabled: true, inboundToken: crypto.randomBytes(32).toString('hex') } },
      env: { autoDetect: false }, log: { traceRaw: false },
      sticker: { enabled: false },
    }, null, 2), { mode: 0o600 });
  }
  if (!fs.existsSync(path.join(root, 'assets'))) {
    fs.cpSync(path.join(__dirname, '..', 'assets'), path.join(root, 'assets'), { recursive: true });
  }
  const instance = await startServer({ root, host: '127.0.0.1', port: 0 });
  const emit = (event, detail = '') => console.log('WHALE_MAC ' + JSON.stringify({ event, detail }));
  const reportError = err => {
    instance.runtime.logger.warn('[mac-bridge] ' + describeError(err));
    emit('bridge-error', BRIDGE_ERRORS[err.message] || '桥接发生错误，已停止；请查看数据目录中的日志');
  };
  emit('ready', instance.url);
  let bridge = null, stopping = false;
  const post = async (route, body) => {
    const response = await fetch(instance.url + route, {
      method: 'POST', headers: { 'content-type': 'application/json',
        'x-bot-token': instance.runtime.config.gateway.wechat.inboundToken, 'x-whale-bridge': '1' },
      body: JSON.stringify(body), signal: AbortSignal.timeout(60000),
    });
    if (!response.ok) throw Object.assign(new Error('kernel_http'), { status: response.status });
    return response.json();
  };
  const stopBridge = () => {
    bridge?.stop();
    bridge = null;
    emit('bridge-stopped');
  };
  const runBridge = async ({ python, chat }) => {
    if (bridge || stopping) return;
    if (typeof python !== 'string' || !path.isAbsolute(python) || typeof chat !== 'string' || !chat.trim()) {
      emit('bridge-error', '请填写桥接 Python 的绝对路径和私聊名称'); return;
    }
    const session = new Bridge({
      adapter: new Adapter(python, path.join(__dirname, 'wechat_adapter.py'), root), chat: chat.trim(),
      inbound: body => post('/webhook/wechat', body),
      heartbeat: () => post('/api/bridge/heartbeat', { platform: 'wechat', uia: true, ffmpeg: false }),
      report: message => emit('bridge-status', message),
    });
    bridge = session;
    emit('bridge-status', '请在 5 秒内切到微信目标私聊，并保持前台');
    await new Promise(resolve => setTimeout(resolve, 5000));
    try {
      while (!session.stopped) {
        await session.tick();
        if (!session.stopped) emit('bridge-status', '正在监听当前私聊的新文字消息');
        await new Promise(resolve => setTimeout(resolve, 2000));
      }
    } catch (err) {
      if (!session.stopped) reportError(err);
    } finally {
      session.stop();
      if (bridge === session) {
        bridge = null;
        emit('bridge-stopped');
      }
    }
  };
  const shutdown = async () => {
    if (stopping) return;
    stopping = true;
    stopBridge();
    instance.runtime.stopLocationProbe?.();
    await instance.close();
    process.exit(0);
  };
  const controls = readline.createInterface({ input: process.stdin });
  controls.on('line', line => {
    let command;
    try { command = JSON.parse(line); } catch { return; }
    if (command.action === 'shutdown') void shutdown();
    if (command.action === 'bridge-stop') stopBridge();
    if (command.action === 'bridge-start') void runBridge(command).catch(reportError);
  });
  controls.on('close', () => void shutdown());
  process.on('SIGINT', () => void shutdown());
  process.on('SIGTERM', () => void shutdown());
}

main().catch(err => { console.error(describeError(err)); process.exitCode = 1; });
