"""Offline policy regression tests. Never read real keys or call the API."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("agentop_ai", Path(__file__).resolve().parents[1] / "lib/ai.py")
ai = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ai)


class AITest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.paths = patch.multiple(ai, CONFIG=root / "config", STATE=root / "state")
        self.paths.start()
        with contextlib.redirect_stdout(io.StringIO()):
            ai.init()
        (ai.CONFIG / "anthropic_api_key").write_text("sk-ant-fixture-only-not-a-key")
        self.db = ai.database()
        self.tx = root / "session.jsonl"
        self.write("로그인 만료 처리 수정", "구현 완료, 테스트는 아직 실행하지 않았습니다")
        self.calls = []

    def tearDown(self):
        self.db.close()
        self.paths.stop()
        self.temp.cleanup()

    def write(self, user, assistant):
        self.tx.write_text("\n".join(json.dumps({"type": role, "message": {"content": text}}, ensure_ascii=False)
                                     for role, text in (("user", user), ("assistant", assistant))) + "\n")

    def configure(self, **overrides):
        cfg = dict(ai.DEFAULTS, **overrides)
        (ai.CONFIG / "ai.json").write_text(json.dumps(cfg))
        return ai.config()

    def transport(self, endpoint, payload, key):
        self.calls.append((endpoint, payload))
        if endpoint == "messages/count_tokens":
            return {"input_tokens": 1000}
        return {"stop_reason": "end_turn", "usage": {"input_tokens": 1000, "output_tokens": 120},
                "content": [{"type": "text", "text": json.dumps(dict(zip(ai.FIELDS,
                    ("로그인 수정", "구현 완료 · 테스트 미실행", "확인되지 않음", "E1, E2"))))}]}

    def test_setup_preserves_key_and_permissions(self):
        with contextlib.redirect_stdout(io.StringIO()):
            ai.init()
        self.assertEqual(ai.api_key(), "sk-ant-fixture-only-not-a-key")
        self.assertEqual((ai.CONFIG / "anthropic_api_key").stat().st_mode & 0o777, 0o600)
        self.assertEqual(ai.CONFIG.stat().st_mode & 0o777, 0o700)
        (ai.CONFIG / "anthropic_api_key").chmod(0o644)
        with self.assertRaises(ai.PolicyError):
            ai.api_key()

    def test_workspace_config_and_headers(self):
        self.configure(workspace_id="wrkspc_example123")
        with patch.object(ai.urllib.request, "build_opener") as factory:
            response = factory.return_value.open.return_value.__enter__.return_value
            response.read.return_value = b'{"input_tokens":100}'
            for endpoint in ("messages/count_tokens", "messages"):
                ai.post(endpoint, {}, "fixture-key", ai.config()["workspace_id"])
                request = factory.return_value.open.call_args.args[0]
                self.assertEqual(request.get_header("Anthropic-workspace-id"), "wrkspc_example123")
            ai.post("messages", {}, "fixture-key")
            self.assertIsNone(factory.return_value.open.call_args.args[0].get_header("Anthropic-workspace-id"))
        legacy = dict(ai.DEFAULTS)
        legacy.pop("workspace_id")
        (ai.CONFIG / "ai.json").write_text(json.dumps(legacy))
        self.assertEqual(ai.config()["workspace_id"], "")
        with self.assertRaises(ai.PolicyError):
            self.configure(workspace_id="invalid\r\nheader")

    def test_workspace_passed_to_both_api_calls(self):
        self.configure(workspace_id="wrkspc_example123")
        def fake_post(endpoint, payload, key, workspace_id):
            self.assertEqual(workspace_id, "wrkspc_example123")
            return self.transport(endpoint, payload, key)
        with patch.object(ai, "post", side_effect=fake_post):
            ai.analyze(self.db, "s1", self.tx)
        self.assertEqual(len(self.calls), 2)

    def test_cache_ignores_metadata_and_display_does_not_send(self):
        ai.analyze(self.db, "s1", self.tx, self.transport)
        with self.tx.open("a") as f:
            f.write('{"type":"progress","timestamp":"new"}\n')
        ai.analyze(self.db, "s1", self.tx, self.transport)
        with contextlib.redirect_stdout(io.StringIO()) as output:
            ai.display(self.db, "s1")
        self.assertIn("로그인 수정", output.getvalue())
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(ai.totals(self.db)[-1], 1)
        self.assertEqual(ai.totals(self.db)[2], 160000)

    def test_changed_content_sends_but_does_not_mutate_observed_status(self):
        ai.analyze(self.db, "s1", self.tx, self.transport)
        self.write("로그인 만료 처리 수정", "회귀 테스트 2건 실패")
        ai.analyze(self.db, "s1", self.tx, self.transport)
        self.assertEqual(len(self.calls), 4)
        self.assertIn("previous_summary", self.calls[-1][1]["messages"][0]["content"])

    def test_daily_budget_blocks_before_network(self):
        self.configure(daily_budget_usd=0.0006)
        with self.assertRaises(ai.PolicyError):
            ai.analyze(self.db, "s1", self.tx, self.transport)
        self.assertEqual(self.calls, [])
        self.assertEqual(ai.totals(self.db)[-1], 0)

    def test_monthly_budget_and_count_across_connections(self):
        cfg = self.configure(monthly_budget_usd=0.001)
        ai.reserve(self.db, cfg, "s1")
        other = ai.database()
        try:
            with self.assertRaises(ai.PolicyError):
                ai.reserve(other, cfg, "s2")
        finally:
            other.close()
        self.configure(manual_daily_limit=1)
        with self.assertRaises(ai.PolicyError):
            ai.analyze(self.db, "s2", self.tx, self.transport)
        self.assertEqual(self.calls, [])

    def test_timeout_retains_reservation_and_old_summary(self):
        ai.analyze(self.db, "s1", self.tx, self.transport)
        old = self.db.execute("SELECT result FROM summaries").fetchone()[0]
        self.write("新しい作業", "실패 원인 조사 중")
        def timeout(endpoint, payload, key):
            if endpoint == "messages":
                raise TimeoutError("must never be displayed: " + key)
            return self.transport(endpoint, payload, key)
        with self.assertRaises(TimeoutError):
            ai.analyze(self.db, "s1", self.tx, timeout)
        row = self.db.execute("SELECT cost,state FROM requests ORDER BY id DESC").fetchone()
        self.assertEqual(tuple(row), (700000, "uncertain"))
        self.assertEqual(self.db.execute("SELECT result FROM summaries").fetchone()[0], old)
        self.assertNotIn("secret", ai.safe_error(TimeoutError("secret")))

    def test_count_failure_releases_money_but_consumes_attempt(self):
        def broken(*args):
            raise TimeoutError()
        with self.assertRaises(TimeoutError):
            ai.analyze(self.db, "s1", self.tx, broken)
        self.assertEqual(ai.totals(self.db)[2:], (0, 0, 1))

    def test_oversized_input_counts_at_most_three_times_no_generation(self):
        def large(endpoint, payload, key):
            self.calls.append(endpoint)
            return {"input_tokens": 99999}
        with self.assertRaises(ai.PolicyError):
            ai.analyze(self.db, "s1", self.tx, large)
        self.assertEqual(self.calls, ["messages/count_tokens"] * 3)
        self.assertEqual(ai.totals(self.db)[2], 0)

    def test_output_validation_failure_still_charged_no_retry(self):
        def invalid(endpoint, payload, key):
            response = self.transport(endpoint, payload, key)
            if endpoint == "messages":
                response["content"][0]["text"] = '{"goal":"wrong shape"}'
            return response
        with self.assertRaises(ai.PolicyError):
            ai.analyze(self.db, "s1", self.tx, invalid)
        self.assertEqual(len(self.calls), 2)
        self.assertGreater(ai.totals(self.db)[2], 0)
        self.assertIsNone(self.db.execute("SELECT * FROM summaries").fetchone())

    def test_disabled_unknown_model_and_invalid_budgets_fail_closed(self):
        self.configure(enabled=False)
        with self.assertRaises(ai.PolicyError):
            ai.analyze(self.db, "s1", self.tx, self.transport)
        for budget in (-1, float("nan"), float("inf"), "invalid"):
            with self.assertRaises(ai.PolicyError):
                self.configure(monthly_budget_usd=budget)
        with self.assertRaises(ai.PolicyError):
            self.configure(model="claude-opus-expensive")
        self.assertEqual(self.calls, [])

    def test_lock_shared_and_released_on_close(self):
        fd = ai.lock_worker()
        try:
            self.assertIsNone(ai.lock_worker())
        finally:
            os.close(fd)
        fd = ai.lock_worker()
        self.assertIsNotNone(fd)
        os.close(fd)

    def test_redaction_excludes_tool_inputs_and_thinking(self):
        self.write("api_key=sk-ant-sensitive-value123", "Bearer very-secret-token")
        with self.tx.open("a") as f:
            f.write(json.dumps({"type": "assistant", "message": {"content": [
                {"type": "thinking", "thinking": "private-reasoning"},
                {"type": "tool_use", "name": "Bash", "input": {"command": "secret-command"}}]}}) + "\n")
        items, _ = ai.snapshot(self.tx)
        text = json.dumps(items)
        for secret in ("sensitive-value", "very-secret-token", "private-reasoning", "secret-command"):
            self.assertNotIn(secret, text)
        self.assertIn("REDACTED", text)

    def test_partial_tail_and_malformed_lines(self):
        with self.tx.open("ab") as f:
            f.write(b'{"type":"progress","blob":"' + b"x" * 300000 + b'"}\n')
            f.write(b'{"type":"assistant","message":{"content":"latest evidence"}}\n')
            f.write(b'{"incomplete":')
        items, _ = ai.snapshot(self.tx)
        self.assertIn("latest evidence", json.dumps(items))
        self.assertEqual(items[0]["role"], "user")

    def test_unexpected_usage_stops_future_calls(self):
        def excessive(endpoint, payload, key):
            response = self.transport(endpoint, payload, key)
            if endpoint == "messages":
                response["usage"]["input_tokens"] = 10000
            return response
        with self.assertRaises(ai.PolicyError):
            ai.analyze(self.db, "s1", self.tx, excessive)
        self.assertEqual(self.db.execute("SELECT state FROM requests").fetchone()[0], "overrun")
        with self.assertRaises(ai.PolicyError):
            ai.analyze(self.db, "s2", self.tx, self.transport)
        self.assertEqual(len(self.calls), 2)

    def test_day_and_month_rollover_keeps_history(self):
        ai.reserve(self.db, ai.config(), "s1")
        self.db.execute("UPDATE requests SET day='2026-01-31',month='2026-01'")
        february = ai.dt.datetime(2026, 2, 1)
        self.assertEqual(ai.totals(self.db, february)[2:], (0, 0, 0))
        self.assertEqual(ai.totals(self.db, ai.dt.datetime(2026, 1, 31))[2:], (700000, 700000, 1))

    def test_real_background_worker_missing_key_is_offline_and_unlocks(self):
        root = Path(self.temp.name)
        repo = Path(__file__).resolve().parents[1]
        env = dict(os.environ, XDG_CONFIG_HOME=str(root / "xdg-config"),
                   XDG_STATE_HOME=str(root / "xdg-state"), TEST_TX=str(self.tx),
                   TEST_LIB=str(repo / "lib"))
        setup = subprocess.run([str(repo / "agentop"), "--ai-init"], env=env,
                               capture_output=True, text=True, timeout=5)
        self.assertEqual(setup.returncode, 0, setup.stderr)
        launch = subprocess.run(["bash", "-c",
            'LIB="$TEST_LIB"; source "$LIB/ai.sh"; '
            'tx_of() { printf "%s" "$TEST_TX"; }; ai_analyze s1 /fixture'],
            env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(launch.returncode, 0, launch.stderr)
        state = root / "xdg-state/agentop/ai"
        with sqlite3.connect(state / "usage.sqlite3") as db:
            message = ""
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                row = db.execute("SELECT message FROM notices WHERE sid='s1'").fetchone()
                message = row[0] if row else ""
                if "API 키만 한 줄" in message:
                    break
                time.sleep(0.02)
            self.assertIn("API 키만 한 줄", message)
            self.assertEqual(db.execute("SELECT count(*) FROM requests").fetchone()[0], 0)
        # Process releases its inherited lock after recording the error.
        with patch.object(ai, "STATE", state):
            fd = None
            while fd is None and time.monotonic() < deadline:
                fd = ai.lock_worker()
                if fd is None:
                    time.sleep(0.02)
            self.assertIsNotNone(fd)
            os.close(fd)


if __name__ == "__main__":
    unittest.main()
