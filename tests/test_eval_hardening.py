from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path

from eval_infra_sentinel import SIDECAR_VERSION, classify_or_load, classify_trial
from harbor.models.trial.config import AgentConfig, TaskConfig, TrialConfig
from harbor.environments.modal import ModalEnvironment, _MAX_INLINE_COMMAND_BYTES
from run_eval import _build_retry_config, build_trial_config


def _write_modal_failure(trial: Path, exception_type: str, message: str) -> None:
    (trial / "agent").mkdir(parents=True)
    (trial / "agent" / "final.patch").write_text("diff --git a/a b/a\n" + "x" * 300)
    (trial / "result.json").write_text(
        json.dumps(
            {
                "exception_info": {
                    "exception_type": exception_type,
                    "exception_message": message,
                }
            }
        )
    )


def test_trial_config_redacts_secrets_only_when_serialized(tmp_path: Path) -> None:
    agent = AgentConfig(
        kwargs={"user_api_key": "gemini-secret", "max_output_tokens": 8192},
        env={
            "ANTHROPIC_API_KEY": "anthropic-secret",
            "ANTHROPIC_CUSTOM_HEADERS": "X-Weave-Router-Key: router-secret",
            "CLAUDE_CODE_EFFORT_LEVEL": "high",
        },
    )
    config = TrialConfig(task=TaskConfig(path=tmp_path), agent=agent)

    assert config.agent.env["ANTHROPIC_API_KEY"] == "anthropic-secret"
    serialized = json.loads(config.model_dump_json())
    assert serialized["agent"]["kwargs"]["user_api_key"] == "[REDACTED]"
    assert serialized["agent"]["kwargs"]["max_output_tokens"] == 8192
    assert serialized["agent"]["env"]["ANTHROPIC_API_KEY"] == "[REDACTED]"
    assert serialized["agent"]["env"]["ANTHROPIC_CUSTOM_HEADERS"] == "[REDACTED]"
    assert serialized["agent"]["env"]["CLAUDE_CODE_EFFORT_LEVEL"] == "high"
    assert "anthropic-secret" not in config.model_dump_json()
    assert "gemini-secret" not in config.model_dump_json()
    assert "router-secret" not in config.model_dump_json()


def test_modal_dns_failure_is_infra_even_with_real_patch(tmp_path: Path) -> None:
    _write_modal_failure(
        tmp_path,
        "ConnectionError",
        "[Errno 8] nodename nor servname provided, or not known",
    )
    verdict = classify_trial(tmp_path)
    assert verdict.status == "infra_failed"
    assert verdict.reason == "modal_control_plane"
    assert verdict.evidence["failure_kind"] == "dns"


def test_modal_exec_stream_failure_invalidates_old_cached_sidecar(
    tmp_path: Path,
) -> None:
    _write_modal_failure(
        tmp_path,
        "InternalError",
        "Failed to read exec stdio stream: please contact support@modal.com",
    )
    (tmp_path / "trial_infra.json").write_text(
        json.dumps(
            {
                "status": "ok",
                "reason": "",
                "version": SIDECAR_VERSION - 1,
            }
        )
    )
    verdict = classify_or_load(tmp_path)
    assert verdict.status == "infra_failed"
    assert verdict.evidence["failure_kind"] == "exec_stream"


def test_retry_policy_includes_observed_modal_failures() -> None:
    included = _build_retry_config().include_exceptions
    assert included is not None
    assert {"ConnectionError", "InternalError", "NotFoundError"} <= included


def test_modal_sandbox_disappearance_is_infra(tmp_path: Path) -> None:
    _write_modal_failure(
        tmp_path,
        "NotFoundError",
        "Modal Sandbox with container ID ta-123 not found. "
        "This means this Sandbox has already shut down.",
    )
    verdict = classify_trial(tmp_path)
    assert verdict.status == "infra_failed"
    assert verdict.reason == "modal_control_plane"
    assert verdict.evidence["failure_kind"] == "sandbox_not_found"


def test_modal_command_arg_limit_is_infra(tmp_path: Path) -> None:
    _write_modal_failure(
        tmp_path,
        "InvalidError",
        "Total length of CMD arguments cannot exceed 65536 bytes (ARG_MAX). "
        "Got 79461 bytes.",
    )
    verdict = classify_trial(tmp_path)
    assert verdict.status == "infra_failed"
    assert verdict.reason == "harness_command_arg_limit"
    assert verdict.evidence["failure_kind"] == "command_arg_limit"


def test_modal_large_command_is_staged_outside_exec_argv() -> None:
    class AsyncMethod:
        def __init__(self, function):
            self.aio = function

    class FileHandle:
        def __init__(self):
            self.data = b""
            self.write = AsyncMethod(self._write)

        async def _write(self, data: bytes) -> None:
            self.data += data

        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return None

    class Process:
        def __init__(self):
            async def read_stdout():
                return "ok"

            async def read_stderr():
                return ""

            async def wait():
                return 0

            self.stdout = type("Stream", (), {"read": AsyncMethod(read_stdout)})()
            self.stderr = type("Stream", (), {"read": AsyncMethod(read_stderr)})()
            self.wait = AsyncMethod(wait)

    class Sandbox:
        def __init__(self):
            self.open = AsyncMethod(self._open)
            self.exec = AsyncMethod(self._exec)
            self.opened: list[tuple[str, str, FileHandle]] = []
            self.exec_calls: list[tuple[tuple[str, ...], dict]] = []

        async def _open(self, path: str, mode: str) -> FileHandle:
            handle = FileHandle()
            self.opened.append((path, mode, handle))
            return handle

        async def _exec(self, *args: str, **kwargs) -> Process:
            self.exec_calls.append((args, kwargs))
            return Process()

    sandbox = Sandbox()
    environment = object.__new__(ModalEnvironment)
    environment._sandbox = sandbox
    environment._persistent_env = {}
    environment.logger = logging.getLogger("test-modal-large-command")

    command = "x" * (_MAX_INLINE_COMMAND_BYTES + 1)
    result = asyncio.run(environment.exec(command))

    assert result.return_code == 0
    assert len(sandbox.opened) == 1
    staged_path, mode, handle = sandbox.opened[0]
    assert staged_path.startswith("/tmp/harbor-exec-")
    assert mode == "wb"
    assert handle.data == command.encode()
    assert sandbox.exec_calls[0][0] == ("bash", staged_path)


def test_modal_trials_have_bounded_lifetime(tmp_path: Path) -> None:
    task = tmp_path / "task"
    task.mkdir()
    config = build_trial_config(
        task_dir=task,
        action_model="anthropic/claude-opus-4-8",
        user_model="gemini/gemini-3.1-pro-preview",
        user_key="user-secret",
        user_api_base=None,
        agent_env={"ANTHROPIC_API_KEY": "agent-secret"},
        trials_dir=tmp_path / "trials",
        env_type="modal",
        agent_timeout=4800,
        user_context_chars=3000,
        call_user_on_completion=True,
    )
    assert config.environment.kwargs["sandbox_timeout_secs"] == 7200
    assert config.environment.kwargs["sandbox_idle_timeout_secs"] == 900
