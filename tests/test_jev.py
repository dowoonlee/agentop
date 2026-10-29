"""Offline input/diff/billing tests; these do not measure Jev's model accuracy."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
import jev
ai = jev.ai


class JevTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.paths = patch.multiple(ai, CONFIG=root/'config', STATE=root/'state')
        self.paths.start()
        with contextlib.redirect_stdout(io.StringIO()):
            jev.init()
        (ai.CONFIG/'typesafe_api_key').write_text('fixture-only-key')
        self.db = jev.database()
        self.path = root/'session.jsonl'
        self.path.touch()
        self.append('user', 'Fix login / 로그인 수정')
        self.append('assistant', '인증 실패 원인을 조사하겠습니다.')
        self.calls = []

    def tearDown(self):
        self.db.close()
        self.paths.stop()
        self.temp.cleanup()

    def append(self, role, text, **extra):
        with self.path.open('a') as f:
            f.write(json.dumps(dict(type=role, message={'content': text}, **extra), ensure_ascii=False)+'\n')

    def transport(self, payload, key):
        self.calls.append(payload)
        return {'model': jev.MODEL, 'usage': {'input_tokens': 1000, 'output_tokens': 30},
                'answers': {'intervention': {'type': 'choice', 'choice': 'unknown',
                    'probabilities': {k: int(k == 'unknown') for k in jev.LABELS}, 'confidence': 1}}}

    def preview(self):
        return subprocess.check_output(['bash', '-c',
            'source "$1/lib/preview.sh"; preview_last "$2"', 'bash', str(ROOT), str(self.path)], text=True).strip()

    def test_generated_records_filtered_in_preview_and_ai(self):
        for prefix in ai.GENERATED_PREFIXES:
            self.append('user', '  '+prefix+' generated content')
        self.append('user', 'metadata', isMeta=True)
        self.assertEqual(self.preview(), 'Fix login / 로그인 수정')
        items, _ = ai.snapshot(self.path, semantic=True)
        self.assertEqual(len(items), 2)
        with self.path.open('a') as f:
            f.write('{"incomplete":')
        self.assertEqual(self.preview(), 'Fix login / 로그인 수정')

    def test_preserves_real_request_with_quoted_system_text(self):
        request = 'Explain this: This session is being continued from a previous conversation'
        self.append('user', [{'type': 'text', 'text': request}])
        self.assertEqual(self.preview(), request)
        self.assertIn(request, json.dumps(ai.snapshot(self.path)[0]))

    def test_diff_accumulates_until_success_and_ignores_noise(self):
        first = jev.analyze(self.db, 's', self.path, self.transport)
        self.assertTrue(first['called'])
        self.append('progress', 'cpu 10 age 50 token count 3000')
        self.append('assistant', [{'type': 'tool_use', 'name': 'Bash', 'input': {'command': 'secret'}},
                                  {'type': 'thinking', 'thinking': 'secret'}])
        self.append('user', '<local-command-stdout>ignored')
        self.assertFalse(jev.analyze(self.db, 's', self.path, self.transport)['called'])
        self.append('assistant', 'Tests failed. 테스트 실패')
        self.assertEqual(len(jev.prepare(self.db, 's', self.path)[1]), 1)
        self.append('assistant', 'Fixed and tests passed. 오류 해결 후 테스트 통과')
        self.assertEqual(len(jev.prepare(self.db, 's', self.path)[1]), 2)
        result = jev.analyze(self.db, 's', self.path, self.transport)
        self.assertEqual(result['changed_excerpts'], 2)
        self.assertEqual(len(self.calls), 2)
        self.assertFalse(jev.prepare(self.db, 's', self.path)[1])
        self.assertEqual(ai.totals(self.db)[2], 84000)

    def test_timeout_preserves_baseline_and_budget_reservation(self):
        jev.analyze(self.db, 's', self.path, self.transport)
        self.append('assistant', 'Should I proceed? 진행할까요?')
        def timeout(*args):
            raise TimeoutError('secret')
        with self.assertRaises(TimeoutError):
            jev.analyze(self.db, 's', self.path, timeout)
        self.assertEqual(len(jev.prepare(self.db, 's', self.path)[1]), 1)
        self.assertEqual(tuple(self.db.execute('SELECT cost,state FROM requests ORDER BY id DESC').fetchone()),
                         (jev.RESERVED_TOKENS*jev.RATE, 'uncertain'))

    def test_invalid_response_charged_without_advancing_baseline(self):
        def invalid(payload, key):
            response = self.transport(payload, key)
            response['answers']['intervention']['confidence'] = float('nan')
            return response
        with self.assertRaises(ai.PolicyError):
            jev.analyze(self.db, 's', self.path, invalid)
        self.assertIsNone(self.db.execute('SELECT * FROM decisions').fetchone())
        self.assertEqual(ai.totals(self.db)[2], 42000)

    def test_budget_and_input_cap_prevent_network(self):
        cfg = dict(jev.DEFAULTS, daily_budget_usd=0.0001)
        (ai.CONFIG/'jev.json').write_text(json.dumps(cfg))
        with self.assertRaises(ai.PolicyError):
            jev.analyze(self.db, 's', self.path, self.transport)
        (ai.CONFIG/'jev.json').write_text(json.dumps(jev.DEFAULTS))
        for _ in range(12):
            self.append('assistant', '가'*900)
        with self.assertRaises(ai.PolicyError):
            jev.analyze(self.db, 's', self.path, self.transport)
        self.assertEqual(self.calls, [])
        self.assertEqual(ai.totals(self.db)[-1], 0)

    def test_usage_overrun_blocks_followup(self):
        def excessive(payload, key):
            response = self.transport(payload, key)
            response['usage']['input_tokens'] = jev.RESERVED_TOKENS+1
            return response
        with self.assertRaises(ai.PolicyError):
            jev.analyze(self.db, 's', self.path, excessive)
        with self.assertRaises(ai.PolicyError):
            jev.analyze(self.db, 's', self.path, self.transport)
        self.assertEqual(len(self.calls), 1)

    def test_sliding_window_and_repeated_event(self):
        a, b, c = ({'role': 'assistant', 'text': text} for text in ('A', 'B', 'C'))
        self.assertEqual(jev.changes([a,b], [b,c]), [c])
        self.assertEqual(jev.changes([a,b], [b]), [])
        self.assertEqual(jev.changes([a,b], [a,b,b]), [b])

    def test_tool_results_only_include_diagnostic_lines(self):
        self.append('user', [{'type':'tool_result','content':'secret source\nTests passed: 4\n'}])
        items, _, _ = jev.prepare(self.db, 's', self.path)
        self.assertEqual(items[-1]['text'], 'Tests passed: 4')

    def test_repeated_identical_events_keep_uuid(self):
        for index in range(12):
            self.append('assistant', 'Tests failed', uuid=str(index))
        jev.analyze(self.db, 's', self.path, self.transport)
        self.append('assistant', 'Tests failed', uuid='new-event')
        self.assertEqual(jev.prepare(self.db, 's', self.path)[1][-1]['event_id'], 'new-event')

    def test_http_provider_and_shared_attempt_limit(self):
        with patch.object(ai.urllib.request, 'build_opener') as factory:
            response = factory.return_value.open.return_value.__enter__.return_value
            response.read.return_value = b'{}'
            jev.post({'model': jev.MODEL}, 'fixture-key')
            request = factory.return_value.open.call_args.args[0]
            self.assertEqual(request.full_url, 'https://api.typesafe.ai/v1/systemone')
            self.assertEqual(request.get_header('Authorization'), 'Bearer fixture-key')
            self.assertEqual(factory.return_value.open.call_args.kwargs['timeout'], 30)
        cfg = dict(jev.DEFAULTS, manual_daily_limit=1)
        (ai.CONFIG/'jev.json').write_text(json.dumps(cfg))
        ai.reserve(self.db, dict(ai.DEFAULTS, day_cap=200000000, month_cap=5000000000), 'summary')
        with self.assertRaises(ai.PolicyError):
            jev.analyze(self.db, 's', self.path, self.transport)
        self.assertEqual(self.calls, [])

    def enable_auto(self, **extra):
        cfg = dict(jev.DEFAULTS, automatic=True, **extra)
        (ai.CONFIG/'jev.json').write_text(json.dumps(cfg))

    def test_automatic_debounce_noise_cooldown_and_resolution(self):
        self.enable_auto()
        sessions = [('s', self.path)]
        jev.tick(self.db, sessions, now=100, transport=self.transport)
        jev.tick(self.db, sessions, now=104, transport=self.transport)
        self.assertEqual(len(self.calls), 0)
        self.append('progress', 'tokens changed')
        jev.tick(self.db, sessions, now=105, transport=self.transport)
        self.assertEqual(len(self.calls), 1)
        self.append('assistant', '오류가 해결되었습니다. Tests passed.')
        jev.tick(self.db, sessions, now=106, transport=self.transport)
        jev.tick(self.db, sessions, now=150, transport=self.transport)
        self.assertEqual(len(self.calls), 1)
        jev.tick(self.db, sessions, now=165, transport=self.transport)
        self.assertEqual(len(self.calls), 2)
        jev.tick(self.db, sessions, now=300, transport=self.transport)
        self.assertEqual(len(self.calls), 2)

    def test_automatic_max_wait_and_no_retry_of_failed_input(self):
        self.enable_auto()
        sessions = [('s', self.path)]
        def failure(payload, key):
            self.calls.append(payload)
            raise TimeoutError()
        for now in range(100, 133, 4):
            self.append('assistant', f'작업 진행 {now}')
            jev.tick(self.db, sessions, now=now, transport=failure)
        self.assertEqual(len(self.calls), 1)
        jev.tick(self.db, sessions, now=500, transport=failure)
        self.assertEqual(len(self.calls), 1)
        self.assertIsNone(self.db.execute('SELECT * FROM decisions').fetchone())
        self.assertTrue(self.db.execute('SELECT error FROM jev_pending').fetchone()[0])

    def test_automatic_off_and_legacy_config(self):
        sessions = [('s', self.path)]
        jev.tick(self.db, sessions, now=100, transport=self.transport)
        jev.tick(self.db, sessions, now=200, transport=self.transport)
        self.assertEqual(self.calls, [])
        legacy = {k:v for k,v in jev.DEFAULTS.items() if k not in
                  ('automatic','debounce_seconds','max_wait_seconds','cooldown_seconds')}
        (ai.CONFIG/'jev.json').write_text(json.dumps(legacy))
        self.assertFalse(jev.config()['automatic'])

    def test_diff_cli_is_offline_and_does_not_advance_baseline(self):
        env = dict(os.environ, XDG_CONFIG_HOME=str(Path(self.temp.name)/'empty-config'),
                   XDG_STATE_HOME=str(Path(self.temp.name)/'empty-state'))
        for _ in range(2):
            result = subprocess.run([sys.executable, str(ROOT/'lib/jev.py'), 'diff', 's', str(self.path)],
                                    env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = json.loads(result.stdout)
            self.assertTrue(result['would_call'])
            self.assertFalse(result['baseline_exists'])


if __name__ == '__main__':
    unittest.main()
