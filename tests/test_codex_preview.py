"""Codex preview reads evidence, never reasoning or tool arguments."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'lib'))
spec = importlib.util.spec_from_file_location('codex_preview', ROOT/'lib/codex-preview.py')
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)


def event(kind, **values):
    return {'type':'event_msg', 'payload':dict(type=kind, **values)}


def item(kind, **values):
    return event('item_completed', item=dict(type=kind, **values))


class CodexPreviewTest(unittest.TestCase):
    def test_current_format_and_new_turn_does_not_show_old_response(self):
        rows = [item('UserMessage', content=[{'type':'text','text':'Fix login'}]),
                item('AgentMessage', content=[{'type':'text','text':'Investigating'}]),
                item('CommandExecution', status='completed', exit_code=1, command='secret args'),
                item('Reasoning', raw_content='private thought')]
        result = preview.pick(rows)
        self.assertEqual(result['request'], 'Fix login')
        self.assertEqual(result['response'], 'Investigating')
        self.assertIn('종료 코드 1', result['activity'])
        self.assertNotIn('secret', json.dumps(result))
        self.assertNotIn('private thought', json.dumps(result))
        rows += [event('task_started'), item('UserMessage', content=[{'type':'text','text':'다른 작업'}])]
        result = preview.pick(rows)
        self.assertEqual(result['request'], '다른 작업')
        self.assertEqual(result['response'], '')
        self.assertEqual(result['activity'], '')

    def test_legacy_formats_and_non_user_messages(self):
        rows = [event('user_message', message='실제 요청'),
                {'type':'response_item','payload':{'type':'message','role':'developer',
                    'content':[{'type':'input_text','text':'private instructions'}]}},
                {'type':'response_item','payload':{'type':'message','role':'assistant','channel':'analysis',
                    'content':[{'type':'output_text','text':'private reasoning'}]}},
                event('agent_message', message='진행 응답'),
                event('task_complete', last_agent_message='테스트는 아직 실행하지 않았습니다.')]
        result = preview.pick(rows)
        self.assertEqual(result['request'], '실제 요청')
        self.assertEqual(result['response'], '테스트는 아직 실행하지 않았습니다.')
        self.assertEqual(result['turn'], '턴 응답 종료')
        self.assertNotIn('private', json.dumps(result))

    def test_large_record_partial_tail_fallback_and_redaction(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'rollout.jsonl'
            rows = [event('user_message', message='api_key=secret_value123'),
                    {'type':'world_state','payload':{'data':'x'*1100000}},
                    event('agent_message', message='완료')]
            path.write_text(''.join(json.dumps(r)+'\n' for r in rows)+'{"partial":')
            result = preview.read(path)
            self.assertIn('REDACTED', result['request'])
            self.assertEqual(result['response'], '완료')
            with contextlib.redirect_stdout(io.StringIO()) as output:
                preview.display(path)
            self.assertIn('마지막 요청', output.getvalue())
            self.assertIn('최근 응답', output.getvalue())
            self.assertNotIn('secret_value123', output.getvalue())

    def test_daemon_terminal_fallback_ignores_placeholder_and_commands(self):
        text = """@@TTY:/dev/ttys001
› 리뷰어는?
• Ran gh secret-command
  └ secret-output
• 리뷰 요청이 등록되어 있습니다.
  새 리뷰는 아직 없습니다.
  Worked for 9s
› Ask Codex to do anything
GPT-6-Astra medium · Context 11% used · 828K window
← for agents · ? for shortcuts
"""
        result = preview.screen_fields(text)
        self.assertEqual(result['request'], '리뷰어는?')
        self.assertIn('새 리뷰는 아직 없습니다.', result['response'])
        self.assertNotIn('secret', json.dumps(result))
        self.assertIn('11%', result['footer'])

    def test_missing_record_explained(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            preview.display('/nonexistent/rollout.jsonl')
        self.assertIn('확인할 수 없습니다', output.getvalue())


if __name__ == '__main__':
    unittest.main()
