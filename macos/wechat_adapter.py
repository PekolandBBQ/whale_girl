"""Only the already-open, foreground conversation; no injection or database access."""
import json
import logging
import sys
import time

# 上游调试日志含会话名；此适配器只返回固定错误码，不落聊天正文或截图。
logging.disable(logging.CRITICAL)


class BridgeError(Exception):
    pass


class WeChatUI:
    def __init__(self):
        import AppKit
        import ApplicationServices as AX
        import Quartz
        from wechat_mcp import wechat_accessibility as accessibility
        from wechat_mcp import fetch_messages_by_chat_utils as messages
        from wechat_mcp.reply_to_messages_by_chat_utils import find_input_field
        self.AppKit, self.AX, self.Quartz = AppKit, AX, Quartz
        self.accessibility, self.messages = accessibility, messages
        self.find_input_field = find_input_field

    def context(self, chat):
        if not self.AX.AXIsProcessTrusted():
            # 由实际执行 UI 操作的解释器发起请求，让系统列出正确的授权对象。
            self.AX.AXIsProcessTrustedWithOptions({self.AX.kAXTrustedCheckOptionPrompt: True})
            raise BridgeError('accessibility_permission')
        if not self.Quartz.CGPreflightScreenCaptureAccess():
            self.Quartz.CGRequestScreenCaptureAccess()
            raise BridgeError('screen_recording_permission')
        apps = self.AppKit.NSRunningApplication.runningApplicationsWithBundleIdentifier_('com.tencent.xinWeChat')
        if len(apps) != 1 or not apps[0].isActive():
            raise BridgeError('wechat_not_foreground')
        pid = apps[0].processIdentifier()
        app = self.AX.AXUIElementCreateApplication(pid)
        if self.accessibility.current_chat_name(app) != chat:
            raise BridgeError('chat_changed')
        return app, pid

    def read(self, chat):
        app, _ = self.context(chat)
        m, a, ax = self.messages, self.accessibility, self.AX
        message_list = m.get_messages_list(app)
        origin = a.axvalue_to_point(a.ax_get(message_list, ax.kAXPositionAttribute))
        size = a.axvalue_to_size(a.ax_get(message_list, ax.kAXSizeAttribute))
        if not origin or not size or size[0] <= 0:
            raise BridgeError('message_geometry')
        # 不调用 fetch_recent_messages：它会主动激活/滚动微信；这里只读可见区域。
        image, rows = m._capture_aligned(message_list, origin, size)
        if image is None:
            raise BridgeError('screen_capture_failed')
        result = []
        for row in rows:
            sender, _ = m.classify_row_sender(image, origin, image.width / size[0], row)
            result.append(dict(text=row.text, kind=row.kind, media=row.media,
                               sender=sender if row.kind == 'message' else 'UNKNOWN'))
        self.context(chat)
        return result

    def send(self, chat, text):
        if not isinstance(text, str) or not text.strip() or len(text) > 4000:
            raise BridgeError('invalid_reply')
        before = self.read(chat)
        app, pid = self.context(chat)
        field = self.find_input_field(app)
        ax, a = self.AX, self.accessibility
        draft = a.ax_get(field, ax.kAXValueAttribute)
        if draft != '':
            raise BridgeError('draft_present')
        if ax.AXUIElementSetAttributeValue(field, ax.kAXFocusedAttribute, True) != 0:
            raise BridgeError('input_focus_failed')
        if a.ax_get(field, ax.kAXFocusedAttribute) != True:
            raise BridgeError('input_not_focused')
        self.context(chat)
        if a.ax_get(field, ax.kAXValueAttribute) != '':
            raise BridgeError('draft_present')
        if ax.AXUIElementSetAttributeValue(field, ax.kAXValueAttribute, text) != 0:
            raise BridgeError('input_write_failed')
        self.context(chat)
        if a.ax_get(field, ax.kAXValueAttribute) != text or a.ax_get(field, ax.kAXFocusedAttribute) != True:
            raise BridgeError('input_changed')
        # 定向到已检查的微信 PID，不向系统当前焦点广播按键。
        for down in (True, False):
            event = self.Quartz.CGEventCreateKeyboardEvent(None, 36, down)
            self.Quartz.CGEventSetFlags(event, 0)
            self.Quartz.CGEventPostToPid(pid, event)
        def count(rows):
            return sum(r['kind'] == 'message' and r['sender'] == 'ME' and r['text'] == text for r in rows)
        for _ in range(6):
            time.sleep(0.3)
            after = self.read(chat)
            if count(after) > count(before):
                return {'confirmed': True}
        # 不重试、不删除残留草稿；回读不能证明发送就交给用户处理。
        raise BridgeError('send_unconfirmed')


def serve(ui, input_stream=sys.stdin, output_stream=sys.stdout):
    for line in input_stream:
        request = {}
        try:
            request = json.loads(line)
            params = request.get('params', {})
            chat = params.get('chat', '')
            if not isinstance(chat, str) or not chat.strip():
                raise BridgeError('chat_required')
            method = request.get('method')
            if method == 'read':
                result = ui.read(chat)
            elif method == 'send':
                result = ui.send(chat, params.get('text'))
            else:
                raise BridgeError('unknown_method')
            reply = {'id': request.get('id'), 'result': result}
        except Exception as error:
            code = str(error) if isinstance(error, BridgeError) else 'accessibility_failed'
            reply = {'id': request.get('id') if isinstance(request, dict) else None, 'error': code}
        output_stream.write(json.dumps(reply, ensure_ascii=False) + '\n')
        output_stream.flush()


if __name__ == '__main__':
    try:
        serve(WeChatUI())
    except Exception:
        sys.exit(1)
