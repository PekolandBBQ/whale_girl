import importlib.util
import io
import json
import pathlib
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('mac_adapter', pathlib.Path(__file__).resolve().parents[2] / 'macos/wechat_adapter.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class AdapterTests(unittest.TestCase):
    def ui(self, draft=''):
        ui = adapter.WeChatUI.__new__(adapter.WeChatUI)
        values = {'value': draft, 'focused': True}
        calls = []
        def write(field, key, value):
            calls.append(('write', key, value))
            values[key] = value
            return 0
        ui.AX = types.SimpleNamespace(kAXValueAttribute='value', kAXFocusedAttribute='focused', AXUIElementSetAttributeValue=write)
        ui.accessibility = types.SimpleNamespace(ax_get=lambda field, key: values[key])
        ui.find_input_field = lambda app: 'field'
        ui.context = lambda chat: ('app', 123)
        ui.Quartz = types.SimpleNamespace(
            CGEventCreateKeyboardEvent=lambda source, key, down: down,
            CGEventSetFlags=lambda *args: None,
            CGEventPostToPid=lambda pid, event: calls.append(('key', pid, event)))
        snapshots = [[], [{'kind': 'message', 'sender': 'ME', 'text': 'reply'}]]
        ui.read = lambda chat: snapshots.pop(0) if snapshots else []
        return ui, values, calls

    def test_draft_is_never_overwritten(self):
        ui, values, calls = self.ui('unfinished draft')
        with self.assertRaisesRegex(adapter.BridgeError, 'draft_present'):
            ui.send('test-friend', 'reply')
        self.assertEqual(values['value'], 'unfinished draft')
        self.assertEqual(calls, [])

    @patch.object(adapter.time, 'sleep')
    def test_send_targets_checked_pid_and_requires_outgoing_readback(self, sleep):
        ui, _, calls = self.ui()
        self.assertEqual(ui.send('test-friend', 'reply'), {'confirmed': True})
        self.assertEqual([c for c in calls if c[0] == 'key'], [('key', 123, True), ('key', 123, False)])

    @patch.object(adapter.time, 'sleep')
    def test_unconfirmed_send_does_not_retry_or_clear_draft(self, sleep):
        ui, values, calls = self.ui()
        ui.read = lambda chat: []
        with self.assertRaisesRegex(adapter.BridgeError, 'send_unconfirmed'):
            ui.send('test-friend', 'reply')
        self.assertEqual(len([c for c in calls if c[0] == 'key']), 2)
        self.assertEqual(values['value'], 'reply')

    def test_chat_switch_before_typing_stops(self):
        ui, _, calls = self.ui()
        def changed(chat):
            raise adapter.BridgeError('chat_changed')
        ui.context = changed
        with self.assertRaisesRegex(adapter.BridgeError, 'chat_changed'):
            ui.send('test-friend', 'reply')
        self.assertEqual(calls, [])

    def test_focus_failure_does_not_type(self):
        ui, _, calls = self.ui()
        ui.AX.AXUIElementSetAttributeValue = lambda *args: 1
        with self.assertRaisesRegex(adapter.BridgeError, 'input_focus_failed'):
            ui.send('test-friend', 'reply')
        self.assertEqual(calls, [])

    def test_chat_switch_after_typing_leaves_draft_without_pressing_return(self):
        ui, values, calls = self.ui()
        checks = []
        def context(chat):
            checks.append(chat)
            if len(checks) == 3:
                raise adapter.BridgeError('chat_changed')
            return 'app', 123
        ui.context = context
        with self.assertRaisesRegex(adapter.BridgeError, 'chat_changed'):
            ui.send('test-friend', 'reply')
        self.assertEqual(values['value'], 'reply')
        self.assertFalse(any(c[0] == 'key' for c in calls))

    def test_context_requires_permissions_foreground_and_exact_title(self):
        ui = adapter.WeChatUI.__new__(adapter.WeChatUI)
        state = dict(access=True, screen=True, active=True, title='test-friend')
        app = types.SimpleNamespace(isActive=lambda: state['active'], processIdentifier=lambda: 123)
        prompts = []
        ui.AX = types.SimpleNamespace(AXIsProcessTrusted=lambda: state['access'], AXUIElementCreateApplication=lambda pid: 'ax-app',
            kAXTrustedCheckOptionPrompt='prompt', AXIsProcessTrustedWithOptions=lambda options: prompts.append(('access', options)))
        ui.Quartz = types.SimpleNamespace(CGPreflightScreenCaptureAccess=lambda: state['screen'],
            CGRequestScreenCaptureAccess=lambda: prompts.append(('screen', True)))
        ui.AppKit = types.SimpleNamespace(NSRunningApplication=types.SimpleNamespace(
            runningApplicationsWithBundleIdentifier_=lambda bundle: [app]))
        ui.accessibility = types.SimpleNamespace(current_chat_name=lambda app: state['title'])
        self.assertEqual(ui.context('test-friend'), ('ax-app', 123))
        for key, value, reason in [('access', False, 'accessibility_permission'), ('screen', False, 'screen_recording_permission'),
                                   ('active', False, 'wechat_not_foreground'), ('title', 'other', 'chat_changed')]:
            original = state[key]
            state[key] = value
            with self.assertRaisesRegex(adapter.BridgeError, reason):
                ui.context('test-friend')
            state[key] = original
        self.assertEqual(prompts, [('access', {'prompt': True}), ('screen', True)])

    def test_protocol_does_not_expose_exception_content(self):
        class FailingUI:
            def read(self, chat):
                raise RuntimeError('private conversation contents')
        output = io.StringIO()
        adapter.serve(FailingUI(), io.StringIO('{"id":1,"method":"read","params":{"chat":"test-friend"}}\n'), output)
        self.assertEqual(json.loads(output.getvalue()), {'id': 1, 'error': 'accessibility_failed'})

    def test_protocol_rejects_unimplemented_actions(self):
        output = io.StringIO()
        adapter.serve(object(), io.StringIO('{"id":2,"method":"switch","params":{"chat":"test-friend"}}\n'), output)
        self.assertEqual(json.loads(output.getvalue())['error'], 'unknown_method')


if __name__ == '__main__':
    unittest.main()
