"""Provider-backpressure handling in the opencode wrapper: throttled turns are
detected from the JSON event stream and re-run with backoff instead of being
recorded as silent no-ops.
"""
from __future__ import annotations

import asyncio
import json
import sys
import time
from pathlib import Path
from types import SimpleNamespace


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))
sys.path.insert(0, str(REPO_ROOT / "external" / "harbor" / "src"))

from user_agent.agents import user_enabled_opencode as ueo  # noqa: E402
from harbor.agents.installed.base import ExecInput  # noqa: E402


def _ev(**kw):
    return json.dumps(kw)


THROTTLE = _ev(type="error", error={"name": "ContextOverflowError",
                                    "data": {"message": "undefined: Too many tokens, please wait before trying again.",
                                             "responseBody": '{"message":"Too many tokens, please wait before trying again."}'}})
REAL_OVERFLOW = _ev(type="error", error={"name": "ContextOverflowError",
                                         "data": {"message": "prompt is too long: 210000 tokens > 200000 maximum"}})
STEP = _ev(type="step_finish", part={"tokens": {"input": 10, "output": 5}, "cost": 0.0})
TOOL = _ev(type="tool_use", part={"tool": "bash"})


def test_classify_turn_events_counts():
    out = "\n".join([THROTTLE, THROTTLE, STEP, TOOL, "not json", ""])
    assert ueo.classify_turn_events(out) == {"steps": 1, "errors": 2, "throttle_errors": 2, "tool_calls": 1, "ended_on_throttle": 0}


def test_turn_was_throttled_only_when_no_step_completed():
    assert ueo.turn_was_throttled("\n".join([THROTTLE, THROTTLE]))
    assert not ueo.turn_was_throttled("\n".join([THROTTLE, STEP]))   # partial progress → keep the turn
    assert not ueo.turn_was_throttled("\n".join([REAL_OVERFLOW]))     # a genuine context overflow is not backpressure
    assert not ueo.turn_was_throttled("")
    assert ueo.turn_was_throttled(_ev(type="error", error={"name": "APIError", "data": {"message": "ThrottlingException: Rate exceeded"}}))


class _FakeEnv:
    """Returns scripted stdouts for successive exec calls."""

    def __init__(self, outputs):
        self.outputs = list(outputs)
        self.calls = 0

    async def exec(self, command, cwd=None, env=None, timeout=None, user=None, **kwargs):
        self.calls += 1
        out = self.outputs.pop(0) if self.outputs else STEP
        return SimpleNamespace(stdout=out, stderr="", return_code=0)


def _wrapper(tmp_path, throttle_backoff=(0, 0, 0)):
    w = object.__new__(ueo.UserEnabledOpenCode)
    w._inner = SimpleNamespace(model_name="amazon-bedrock/global.openai.gpt-5.6-sol")
    w._start_time = time.monotonic()
    w._throttle_retries = 0
    w.logs_dir = tmp_path
    return w


def test_retry_loop_reruns_throttled_turn_until_progress(tmp_path, monkeypatch):
    monkeypatch.setattr(ueo, "_THROTTLE_BACKOFF_SEC", (0, 0, 0, 0))
    monkeypatch.setattr(ueo, "_refresh_agent_env_marker", None, raising=False)
    w = _wrapper(tmp_path)
    monkeypatch.setattr(w, "_refresh_agent_env", lambda env: env)
    env = _FakeEnv([THROTTLE, "\n".join([THROTTLE, THROTTLE]), "\n".join([STEP, TOOL])])
    cmd = ExecInput(command="opencode --model=amazon-bedrock/x run --format=json -- hi", env={})

    result, timed_out, attempts = asyncio.run(w._exec_turn_with_throttle_retry(env, cmd, turn=3))
    assert attempts == 3 and env.calls == 3 and not timed_out
    assert ueo.classify_turn_events(result.stdout)["steps"] == 1
    assert w._throttle_retries == 2
    # discarded attempts are archived for forensics, under a distinct name
    assert (tmp_path / "opencode.txt.turn-3-throttled-1").exists()
    assert (tmp_path / "opencode.txt.turn-3-throttled-2").exists()


def test_retry_loop_gives_up_after_max_retries(tmp_path, monkeypatch):
    monkeypatch.setattr(ueo, "_THROTTLE_BACKOFF_SEC", (0,))
    monkeypatch.setattr(ueo, "_THROTTLE_MAX_RETRIES", 2)
    w = _wrapper(tmp_path)
    monkeypatch.setattr(w, "_refresh_agent_env", lambda env: env)
    env = _FakeEnv([THROTTLE] * 10)
    cmd = ExecInput(command="opencode --model=amazon-bedrock/x run --format=json -- hi", env={})
    result, _, attempts = asyncio.run(w._exec_turn_with_throttle_retry(env, cmd, turn=1))
    assert attempts == 3 and env.calls == 3          # 1 initial + 2 retries
    assert result.stdout == ""                       # every attempt was throttle-only → nothing kept (caller sees a no-op)
    assert len(list(tmp_path.glob("opencode.txt.turn-1-throttled-*"))) == 3


def test_retry_loop_respects_trial_budget(tmp_path, monkeypatch):
    monkeypatch.setattr(ueo, "_THROTTLE_BACKOFF_SEC", (60,))
    w = _wrapper(tmp_path)
    monkeypatch.setattr(w, "_refresh_agent_env", lambda env: env)
    w._start_time = time.monotonic() - (ueo.TRIAL_BUDGET_SEC - 100)   # only 100 s left
    env = _FakeEnv([THROTTLE, STEP])
    cmd = ExecInput(command="opencode --model=amazon-bedrock/x run --format=json -- hi", env={})
    _, _, attempts = asyncio.run(w._exec_turn_with_throttle_retry(env, cmd, turn=2))
    assert attempts == 1 and env.calls == 1           # no retry when the budget can't cover the backoff


def test_non_throttled_turn_runs_once(tmp_path, monkeypatch):
    w = _wrapper(tmp_path)
    monkeypatch.setattr(w, "_refresh_agent_env", lambda env: env)
    env = _FakeEnv(["\n".join([STEP, STEP])])
    cmd = ExecInput(command="opencode --model=openrouter/meta/muse-spark-1.3 run --format=json -- hi", env={})
    _, _, attempts = asyncio.run(w._exec_turn_with_throttle_retry(env, cmd, turn=0))
    assert attempts == 1 and env.calls == 1 and w._throttle_retries == 0


# ── interrupted turns (progress, then a throttle ended the turn) ──────────

SID = "ses_test123"
STEP_SID = _ev(type="step_finish", sessionID=SID, part={"tokens": {"input": 10, "output": 5}, "cost": 0.0})


def test_turn_ended_on_throttle_detection():
    assert ueo.turn_ended_on_throttle("\n".join([STEP, STEP, THROTTLE, THROTTLE]))
    assert not ueo.turn_ended_on_throttle("\n".join([THROTTLE, STEP]))       # recovered on its own → fine
    assert not ueo.turn_ended_on_throttle("\n".join([THROTTLE, THROTTLE]))   # that's the 'no progress' case
    assert not ueo.turn_ended_on_throttle("\n".join([STEP, REAL_OVERFLOW]))  # genuine overflow, don't poke it
    c = ueo.classify_turn_events("\n".join([STEP, THROTTLE, STEP]))
    assert c["ended_on_throttle"] == 0 and c["throttle_errors"] == 1 and c["steps"] == 2


# Gemini 3.x through OpenRouter: the exact event opencode 1.18.29 emits when Google
# rejects a replayed reasoning signature. Note the message is a JSON string nested
# inside data.message (no responseBody).
GEMINI_SIGNATURE = _ev(type="error", error={
    "name": "UnknownError",
    "data": {"message": '{"code":400,"message":"Corrupted thought signature.",'
                        '"metadata":{"error_type":"invalid_request","provider_code":"400"}}'}})


def test_gemini_corrupted_signature_is_a_retryable_interruption():
    # observed shape: several completed steps, then the 400 ends the turn
    assert ueo.turn_ended_on_throttle("\n".join([STEP, STEP, STEP, GEMINI_SIGNATURE]))
    # and, if it fires before any step completes, the turn is re-run
    assert ueo.turn_was_throttled(GEMINI_SIGNATURE)
    # opencode recovered by itself → nothing to do
    assert not ueo.turn_ended_on_throttle("\n".join([STEP, GEMINI_SIGNATURE, STEP, STEP]))
    # an unrelated 400 is still not treated as backpressure
    other = _ev(type="error", error={"name": "UnknownError",
                                     "data": {"message": '{"code":400,"message":"Invalid tool schema."}'}})
    assert not ueo.turn_ended_on_throttle("\n".join([STEP, other]))


def test_interrupted_turn_is_resumed_with_continue(tmp_path, monkeypatch):
    monkeypatch.setattr(ueo, "_THROTTLE_BACKOFF_SEC", (0,))
    w = _wrapper(tmp_path)
    monkeypatch.setattr(w, "_refresh_agent_env", lambda env: env)
    built = []

    def fake_resume(session_id, msg):
        built.append((session_id, msg))
        return ExecInput(command=f"opencode --model=amazon-bedrock/x run --session={session_id} --format=json -- {msg!r}", env={})

    monkeypatch.setattr(w, "_build_resume_command", fake_resume)
    # attempt 1: 3 steps then throttled; attempt 2 (synthetic continue): finishes cleanly
    env = _FakeEnv(["\n".join([STEP_SID, STEP_SID, STEP_SID, THROTTLE]), "\n".join([STEP, TOOL, STEP])])
    cmd = ExecInput(command="opencode --model=amazon-bedrock/x run --format=json -- hi", env={})
    result, timed_out, attempts = asyncio.run(w._exec_turn_with_throttle_retry(env, cmd, turn=0))
    assert attempts == 2 and env.calls == 2 and not timed_out
    assert built == [(SID, ueo._THROTTLE_CONTINUE_MESSAGE)]          # session id discovered from turn-0 output
    c = ueo.classify_turn_events(result.stdout)
    assert c["steps"] == 5                                            # both attempts' progress is kept
    assert w._throttle_retries == 1
    assert not list(tmp_path.glob("*throttled*"))                     # nothing discarded


def test_interrupted_resume_turn_uses_known_session(tmp_path, monkeypatch):
    monkeypatch.setattr(ueo, "_THROTTLE_BACKOFF_SEC", (0,))
    w = _wrapper(tmp_path)
    monkeypatch.setattr(w, "_refresh_agent_env", lambda env: env)
    built = []
    monkeypatch.setattr(w, "_build_resume_command",
                        lambda sid, msg: built.append((sid, msg)) or ExecInput(command=f"opencode --model=amazon-bedrock/x run --session={sid} --format=json -- x", env={}))
    env = _FakeEnv(["\n".join([STEP, THROTTLE]), STEP])
    cmd = ExecInput(command="opencode --model=amazon-bedrock/x run --session=ses_known --format=json -- msg", env={})
    _, _, attempts = asyncio.run(w._exec_turn_with_throttle_retry(env, cmd, turn=4, session_id="ses_known"))
    assert attempts == 2 and built[0][0] == "ses_known"


def test_interrupted_turn_without_session_id_keeps_progress(tmp_path, monkeypatch):
    monkeypatch.setattr(ueo, "_THROTTLE_BACKOFF_SEC", (0,))
    w = _wrapper(tmp_path)
    monkeypatch.setattr(w, "_refresh_agent_env", lambda env: env)
    env = _FakeEnv(["\n".join([STEP, THROTTLE])])   # STEP carries no sessionID → cannot resume
    cmd = ExecInput(command="opencode --model=amazon-bedrock/x run --format=json -- hi", env={})
    result, _, attempts = asyncio.run(w._exec_turn_with_throttle_retry(env, cmd, turn=0))
    assert attempts == 1 and ueo.classify_turn_events(result.stdout)["steps"] == 1
