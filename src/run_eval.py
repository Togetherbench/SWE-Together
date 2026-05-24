#!/usr/bin/env python3
"""In-process batch evaluation using Harbor's LocalOrchestrator.

Replaces run_full_eval.py (which spawned ~300MB subprocesses per task).
Uses Harbor's async orchestrator: single process, ~18MB per trial,
supports 100+ concurrent E2B sandboxes on a 15GB machine.

Usage:
    # Opus 4.6 on E2B with 25 concurrent trials
    python src/run_eval.py \
        --model anthropic/claude-opus-4-6 \
        --tag opus46 --env-type e2b --agent-timeout 1800 --workers 25

    # Kimi K2.5 via Fireworks (proxy + OpenRouter fallback)
    python src/run_eval.py \
        --model fireworks/accounts/fireworks/routers/kimi-k2p5-turbo \
        --tag kimi25 --env-type e2b --agent-timeout 3600 --workers 25

    # GLM-5 via Z.AI direct (fallback to OpenRouter)
    python src/run_eval.py \
        --model glm/glm-5 --tag glm5 --env-type e2b --workers 25

    # Options
    --workers 25         # Concurrent E2B sandboxes (default: 25)
    --skip-existing      # Skip tasks with existing results
    --tasks t1,t2        # Filter specific tasks
    --dry-run            # List tasks without running
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
import time
from pathlib import Path

# Ensure src/ and harbor/ are importable
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "src"))
sys.path.insert(0, str(REPO_ROOT / "external" / "harbor" / "src"))

from harbor.environments.base import EnvironmentType
from harbor.models.job.config import EnvironmentConfig
from harbor.models.trial.config import AgentConfig, TaskConfig, TrialConfig
from harbor.orchestrators.local import LocalOrchestrator, RetryConfig

from eval_infra_sentinel import (
    classify_or_load,
    classify_trial,
    write_sidecar,
)

# Import shared utilities from runner.py
from runner import (
    resolve_model,
    load_analysis,
    load_user_messages,
    _compute_message_guidance,
    resolve_task_dir,
    REPO_ROOT as RUNNER_REPO_ROOT,
    _CHUTES_BASE_URL,
    _OPENROUTER_BASE_URL,
    _FIREWORKS_BASE_URL,
    _GLM_BASE_URL,
    _MINIMAX_BASE_URL,
    _ARK_BASE_URL,
    _GLMD_BASE_URL,
    _DEEPSEEK_BASE_URL,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("run_eval")

# Load .env
_env_path = REPO_ROOT / ".env"
if _env_path.exists():
    for line in _env_path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip())


AGENT_IMPORT_PATH = "user_agent.user_enabled_claude_code:UserEnabledClaudeCode"
CODEX_AGENT_IMPORT_PATH = "user_agent.user_enabled_codex:UserEnabledCodex"

# Env vars the codex wrapper inspects on the host — forwarded into the trial's
# agent_env so the in-sandbox wrapper sees them (CODEX_USE_HOST_AUTH triggers
# the ChatGPT-OAuth auth.json overlay; CODEX_VERSION upgrades the in-sandbox
# codex CLI past the pinned 0.117.0; CODEX_USE_RESUME opts INTO the resume path).
_CODEX_FORWARDED_HOST_ENV = (
    "CODEX_USE_HOST_AUTH", "CODEX_HOST_AUTH_JSON", "CODEX_VERSION",
    "CODEX_USE_RESUME", "OPENAI_BASE_URL",
)


def get_all_tasks() -> list[str]:
    tasks_dir = REPO_ROOT / "harbor_tasks"
    candidates = sorted(
        d for d in tasks_dir.iterdir()
        if d.is_dir() and (d / "task.toml").exists() and (d / "instruction.md").exists()
    )
    runnable = []
    skipped = []
    for d in candidates:
        if (d / "tests" / "test.sh").exists():
            runnable.append(d.name)
        else:
            skipped.append(d.name)
    if skipped:
        log.warning("Skipping %d tasks missing tests/test.sh: %s",
                    len(skipped),
                    ", ".join(skipped[:5]) + (" ..." if len(skipped) > 5 else ""))
    return runnable


def is_task_completed(task_name: str, trials_dir: Path) -> bool:
    """Check if a task has a successful trial.

    A trial counts as completed only if (a) Harbor recorded a verifier
    result AND (b) the infra sentinel says the agent actually ran. Trials
    that scored 0.0 because the provider returned 402/429/HTML inside the
    sandbox are excluded, so ``--skip-existing`` reruns them instead of
    silently inheriting the bad data point.
    """
    if not trials_dir.exists():
        return False
    for d in trials_dir.iterdir():
        if not (d.is_dir() and d.name.startswith(task_name + "__")):
            continue
        result_path = d / "result.json"
        if not result_path.exists():
            continue
        try:
            result = json.loads(result_path.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        vr = result.get("verifier_result")
        if not (vr and vr.get("rewards")):
            continue
        verdict = classify_or_load(d)
        if verdict.status == "infra_failed":
            log.info(
                "Re-running %s: trial %s flagged infra_failed (%s)",
                task_name, d.name, verdict.reason,
            )
            continue
        return True
    return False


def build_agent_env(model_arg: str, action_model: str, action_key: str) -> dict[str, str]:
    """Build the agent environment variables for proxy/provider routing.

    Returns a dict that goes into AgentConfig.env → agent's extra_env →
    sandbox exec env. Does NOT touch os.environ.
    """
    provider = model_arg.split("/", 1)[0] if "/" in model_arg else None
    env: dict[str, str] = {}

    if provider == "anthropic":
        # OAuth tokens (sk-ant-oat01-... from `claude setup-token`, subscription
        # billing) MUST go via CLAUDE_CODE_OAUTH_TOKEN — the Anthropic API rejects
        # OAuth tokens sent via x-api-key. CC in the sandbox auto-detects this
        # env var and routes via Authorization: Bearer + the oauth beta header.
        # Same auth path as eval/correctness/sandbox.py uses for the judge.
        oauth_token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
        if action_key.startswith("sk-ant-oat01-") or oauth_token.startswith("sk-ant-oat01-"):
            env["CLAUDE_CODE_OAUTH_TOKEN"] = oauth_token or action_key
        else:
            env["ANTHROPIC_API_KEY"] = action_key
        # Forward CLAUDE_CODE_EFFORT_LEVEL (low/medium/high/xhigh/max) for
        # Claude Opus 4.7. xhigh is the recommended default for coding/agentic
        # use; controls adaptive-thinking depth via Anthropic's effort param.
        # For Opus 4.6 the valid levels are low/medium/high/max ('xhigh' falls
        # back to high silently); recommended default for coding is 'high'.
        effort = os.environ.get("CLAUDE_CODE_EFFORT_LEVEL")
        if effort:
            env["CLAUDE_CODE_EFFORT_LEVEL"] = effort
        return env

    if provider == "openrouter":
        or_model = model_arg.split("/", 1)[1]
        or_key = action_key
        env.update({
            "ANTHROPIC_API_KEY": "sk-litellm-local",
            "ANTHROPIC_AUTH_TOKEN": "sk-litellm-local",
            "ANTHROPIC_BASE_URL": "http://localhost:4210",
            "ANTHROPIC_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_SMALL_FAST_MODEL": "claude-sonnet-4-6",
            "CLAUDE_CODE_SUBAGENT_MODEL": "claude-sonnet-4-6",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_ENABLE_TELEMETRY": "0",
            "API_TIMEOUT_MS": "6000000",
            # [v042] Cap output tokens. Some OR upstreams (DeepInfra, Mara,
            # Inceptron) report context_length=204800 with max_tokens=128000
            # reserved for output → only 76800 left for input + tool defs +
            # context. Capping output to 32000 leaves ~170k for input, which
            # fits Claude Code's typical prompt for these tasks.
            "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "32000",
            "LITELLM_PROXY_MODEL": or_model,
            "LITELLM_PROXY_PORT": "4210",
            "OPENROUTER_API_KEY": or_key,
            # Proxy's _build_request uses FALLBACK_KEY for OR Bearer auth on
            # the is_or=True branch — that branch fires for OR-as-primary too,
            # not just OR-as-fallback. Without this, OR-primary requests ship
            # `Authorization: Bearer ` (empty) and get 401'd.
            "PROXY_FALLBACK_KEY": or_key,
        })
        return env

    if provider == "fireworks":
        fw_model = model_arg.split("/", 1)[1]
        # Fireworks-only — NO OpenRouter fallback. We measure firepass-served
        # kimi-k2.5-turbo specifically, not what OR happens to route us to.
        env.update({
            "ANTHROPIC_API_KEY": "sk-proxy-local",
            "ANTHROPIC_AUTH_TOKEN": "sk-proxy-local",
            "ANTHROPIC_BASE_URL": "http://localhost:4210",
            "ANTHROPIC_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_SMALL_FAST_MODEL": "claude-sonnet-4-6",
            "CLAUDE_CODE_SUBAGENT_MODEL": "claude-sonnet-4-6",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_ENABLE_TELEMETRY": "0",
            "API_TIMEOUT_MS": "6000000",
            "LITELLM_PROXY_MODEL": fw_model,
            "LITELLM_PROXY_PORT": "4210",
            "PROXY_TARGET_URL": _FIREWORKS_BASE_URL,
            "PROXY_API_KEY": action_key,
            # No fallback. If Fireworks 429s, the trial fails — we'd rather
            # have a clean fireworks-only signal than mixed data with OR.
        })
        return env

    if provider == "glm":
        glm_model = model_arg.split("/", 1)[1]
        or_key = os.environ.get("OPENROUTER_API_KEY", "")
        env.update({
            "ANTHROPIC_API_KEY": "sk-proxy-local",
            "ANTHROPIC_AUTH_TOKEN": "sk-proxy-local",
            "ANTHROPIC_BASE_URL": "http://localhost:4210",
            "ANTHROPIC_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_SMALL_FAST_MODEL": "claude-sonnet-4-6",
            "CLAUDE_CODE_SUBAGENT_MODEL": "claude-sonnet-4-6",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_ENABLE_TELEMETRY": "0",
            "API_TIMEOUT_MS": "6000000",
            "LITELLM_PROXY_MODEL": glm_model,
            "LITELLM_PROXY_PORT": "4210",
            "PROXY_TARGET_URL": _GLM_BASE_URL,
            "PROXY_API_KEY": action_key,
            "PROXY_FALLBACK_URL": _OPENROUTER_BASE_URL,
            "PROXY_FALLBACK_KEY": or_key,
            "PROXY_FALLBACK_MODEL": f"z-ai/{glm_model}",
        })
        return env

    # Direct-provider proxy template. All three (ark, glmd, minimaxd) route via
    # the in-sandbox LiteLLM-style proxy that user_enabled_claude_code.py
    # launches on port 4210. CC sees `claude-sonnet-4-6` (passes client-side
    # model-name validator). Proxy rewrites `model` in the POST body to the
    # real target (e.g. `kimi-k2.6`, `glm-5.1`, `MiniMax-M2.5`) and forwards
    # to the provider's Anthropic-compatible endpoint. No CC changes to auth
    # flow needed — proxy injects `x-api-key: <provider-key>`.
    def _proxy_env(target_url: str, real_model: str, api_key: str) -> dict[str, str]:
        return {
            "ANTHROPIC_API_KEY": "sk-proxy-local",
            "ANTHROPIC_AUTH_TOKEN": "sk-proxy-local",
            "ANTHROPIC_BASE_URL": "http://localhost:4210",
            "ANTHROPIC_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_SMALL_FAST_MODEL": "claude-sonnet-4-6",
            "CLAUDE_CODE_SUBAGENT_MODEL": "claude-sonnet-4-6",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_ENABLE_TELEMETRY": "0",
            "API_TIMEOUT_MS": "6000000",
            "LITELLM_PROXY_MODEL": real_model,
            "LITELLM_PROXY_PORT": "4210",
            "PROXY_TARGET_URL": target_url,
            "PROXY_API_KEY": api_key,
        }

    if provider == "minimaxd":
        # MiniMax direct — explicit model selection via proxy.
        # Supported: MiniMax-M2, MiniMax-M2.5, MiniMax-M2.7.
        mm_model = model_arg.split("/", 1)[1]
        env.update(_proxy_env(_MINIMAX_BASE_URL, mm_model, action_key))
        return env

    if provider == "glmd":
        # GLM direct via z.ai — explicit model selection via proxy.
        # Supported: glm-4.5, glm-4.6, glm-4.7, glm-5, glm-5.1.
        glm_model = model_arg.split("/", 1)[1]
        env.update(_proxy_env(_GLMD_BASE_URL, glm_model, action_key))
        return env

    if provider == "ark":
        # ARK (Volcengine) — explicit model selection via proxy.
        # Supported: kimi-k2.5, kimi-k2.6, minimax-m2.5, minimax-m2.7,
        # glm-4.7, glm-5.1, deepseek-v3.2, doubao-seed-code, doubao-seed-2.0-code, etc.
        ark_model = model_arg.split("/", 1)[1]
        env.update(_proxy_env(_ARK_BASE_URL, ark_model, action_key))
        return env

    if provider == "deepseek":
        # DeepSeek direct — Anthropic-compat at api.deepseek.com/anthropic.
        # /v1/models/<name> returns 404 (per ARK/MMD/GLMD known-broken pattern)
        # so MUST route through proxy. x-api-key auth (proxy default).
        # Supported: deepseek-v4-pro, deepseek-v4-flash. (`[1m]` suffix accepted
        # but not canonical; bare IDs match `/v1/models` listing.)
        ds_model = model_arg.split("/", 1)[1]
        env.update(_proxy_env(_DEEPSEEK_BASE_URL, ds_model, action_key))
        return env

    # Unknown provider — pass key directly
    env["ANTHROPIC_API_KEY"] = action_key
    return env


def build_trial_config(
    task_dir: Path,
    action_model: str,
    user_model: str,
    user_key: str,
    user_api_base: str | None,
    agent_env: dict[str, str],
    trials_dir: Path,
    env_type: str | None,
    agent_timeout: float | None,
    user_context_chars: int,
    call_user_on_completion: bool,
    force_build: bool = False,
    agent_type: str = "claude-code",
) -> TrialConfig:
    """Build a TrialConfig with per-task user sim kwargs."""
    # Load per-task data
    analysis = load_analysis(task_dir)
    user_messages = load_user_messages(task_dir, analysis)
    gt_count = len(user_messages)

    # Load and augment session analysis
    sim_prompt_path = task_dir / "user_simulation_prompt.md"
    session_analysis = sim_prompt_path.read_text() if sim_prompt_path.exists() else ""

    msg_low, msg_high = _compute_message_guidance(gt_count)
    guidance_note = (
        f"\n\n## Message Guidance (auto-generated)\n"
        f"The real user sent {gt_count} messages in the original session. "
        f"Aim for **{msg_low}–{msg_high} messages** total. "
        f"This is a soft target — send fewer if the agent handles everything "
        f"well, send more if it needs correction. Do NOT treat any cap in "
        f"the session analysis above as a hard limit; use this range instead.\n\n"
        f"## Trigger Interpretation (auto-generated)\n"
        f"The agent works incrementally and reports after each sub-task. "
        f"When evaluating trigger conditions from the session analysis above, "
        f"apply them broadly:\n"
        f"- If a trigger says 'ONLY if agent has X but not Y', also fire "
        f"if the agent has completed both X and Y but Y has issues.\n"
        f"- If the agent reports completing a sub-task, check whether the "
        f"next ground-truth message in sequence is relevant and send it.\n"
        f"- Do NOT skip a turn just because the agent already moved past "
        f"the exact intermediate state described in the trigger. The agent "
        f"may have done it incorrectly.\n"
        f"- Prioritize sending ground-truth messages in order. If the agent's "
        f"progress maps to turn N in the session analysis, send turn N's "
        f"message even if the trigger condition is not a perfect match."
    )
    session_analysis_with_guidance = session_analysis + guidance_note

    user_sim_kwargs = {
        "user_model_name": user_model,
        "user_api_key": user_key,
        "user_api_base": user_api_base,
        "original_user_messages": user_messages,
        "session_analysis": session_analysis_with_guidance,
        "max_messages": None,
        "user_context_chars": user_context_chars,
        "call_user_on_completion": call_user_on_completion,
        # Pin Claude Code version at agent-setup time (flows through
        # UserEnabledClaudeCode **kwargs to inner ClaudeCode, then into Harbor's
        # install-claude-code.sh.j2 {% if version %} branch which hardcodes
        # `curl install.sh | bash -s -- <version>`). Otherwise Harbor's runtime
        # install pulls LATEST (currently 2.1.119), which has a client-side
        # model-name validator that rejects non-Anthropic names like kimi-k2.6
        # before any API call is made.
        "version": "2.1.108",
    }

    # Model name sent to Harbor.self.model_name governs BOTH the ANTHROPIC_MODEL
    # env var AND all the ANTHROPIC_DEFAULT_*_MODEL aliases Harbor sets when
    # ANTHROPIC_BASE_URL is custom. If this is a real model name like kimi-k2.6,
    # Claude Code's client-side validator rejects it before any API call.
    # So: for every provider where we route through a non-Anthropic backend
    # (LiteLLM proxy OR direct Anthropic-compatible endpoint), lie to Harbor
    # and say "claude-sonnet-4-6" — the backend maps it to the real model.
    harbor_model = action_model
    if agent_env.get("LITELLM_PROXY_MODEL"):
        harbor_model = "claude-sonnet-4-6"
    elif agent_env.get("ANTHROPIC_BASE_URL") in (_ARK_BASE_URL, _MINIMAX_BASE_URL, _GLMD_BASE_URL):
        harbor_model = "claude-sonnet-4-6"

    if agent_type == "codex":
        # Codex wrapper handles its own auth (CODEX_USE_HOST_AUTH overlay or
        # OPENAI_API_KEY), its own protocol (OpenAI Responses API), and its
        # own model-name passing — none of the claude_code Harbor-model
        # remapping or ANTHROPIC_*_MODEL aliases apply. Drop them all so the
        # in-sandbox codex sees a clean env.
        import_path = CODEX_AGENT_IMPORT_PATH
        harbor_model = action_model  # pass model as-is, codex wrapper strips provider prefix
        # `version: "2.1.108"` in user_sim_kwargs is meant for ClaudeCode (pins
        # the in-sandbox CC harness). When codex agent_type uses the same
        # user_sim_kwargs, that version gets passed into install-codex.sh.j2 as
        # `npm install -g @openai/codex@2.1.108` which doesn't exist (npm
        # ETARGET). Drop it for codex so the template falls back to its
        # hardcoded 0.117.0 default (then CODEX_VERSION env may upgrade in-sandbox).
        user_sim_kwargs.pop("version", None)
        # Strip claude_code-only env vars but KEEP codex-relevant ones
        codex_env = {
            k: v for k, v in agent_env.items()
            if not k.startswith("ANTHROPIC_") and not k.startswith("CLAUDE_CODE_")
               and not k.startswith("LITELLM_") and not k.startswith("PROXY_")
        }
        # Forward host-side CODEX_* env vars (wrapper reads them at trial start)
        for var in _CODEX_FORWARDED_HOST_ENV:
            if v := os.environ.get(var):
                codex_env[var] = v
        # Codex needs OPENAI_API_KEY env var even if empty (auth.json overlay
        # provides real creds via CODEX_USE_HOST_AUTH path)
        codex_env.setdefault("OPENAI_API_KEY", os.environ.get("OPENAI_API_KEY", ""))
        agent_env_final = codex_env
    else:
        import_path = AGENT_IMPORT_PATH
        agent_env_final = agent_env

    agent_config = AgentConfig(
        import_path=import_path,
        model_name=harbor_model,
        override_timeout_sec=agent_timeout,
        kwargs=user_sim_kwargs,
        env=agent_env_final,
    )

    env_config = EnvironmentConfig(delete=True, force_build=force_build)
    if env_type:
        env_config.type = EnvironmentType(env_type)

    return TrialConfig(
        task=TaskConfig(path=task_dir),
        trials_dir=trials_dir,
        agent=agent_config,
        environment=env_config,
    )


def _copy_sim_prompts(task_names: list[str], trials_dir: Path):
    """Copy user_simulation_prompt.md into each trial dir for the viewer."""
    import shutil
    copied = 0
    for task_name in task_names:
        task_dir = resolve_task_dir(task_name)
        if task_dir is None:
            continue
        sim_prompt = task_dir / "user_simulation_prompt.md"
        if not sim_prompt.exists():
            continue
        for trial_dir in trials_dir.iterdir():
            if trial_dir.is_dir() and trial_dir.name.startswith(task_name + "__"):
                dest = trial_dir / "user_simulation_prompt.md"
                if not dest.exists():
                    shutil.copy2(sim_prompt, dest)
                    copied += 1
    if copied:
        log.info("Copied user_simulation_prompt.md to %d trials", copied)


def _build_trajectories(trials_dir: Path):
    """Build trajectory.json for all trials that need it (viewer compatibility)."""
    import subprocess as _sp

    build_script = REPO_ROOT / "scripts" / "build_trajectory.py"
    if not build_script.exists():
        log.warning("build_trajectory.py not found — skipping")
        return

    log.info("Building trajectory.json files...")
    result = _sp.run(
        [sys.executable, str(build_script), "--all", "--trials-dir", str(trials_dir)],
        cwd=str(REPO_ROOT), timeout=120, capture_output=True, text=True,
    )
    if result.stdout:
        for line in result.stdout.strip().split("\n"):
            log.info("  %s", line)
    if result.returncode != 0 and result.stderr:
        log.warning("build_trajectory errors: %s", result.stderr[:500])


def _emit_infra_sidecars(trials_dir: Path) -> dict[str, int]:
    """Classify every trial in ``trials_dir`` and write ``trial_infra.json``
    next to its ``result.json``.

    Returns a Counter-like dict ``{"ok": N, "infra_failed": M, "<reason>": K, ...}``
    that the post-run summary prints. Idempotent: re-running re-classifies
    fresh (cheap — bounded by claude-code.txt size) and overwrites the
    sidecar.

    Why this lives in the runner rather than only in the audit CLI: writing
    the sidecar at trial-completion time means the next ``--skip-existing``
    invocation pays only a single JSON read per trial, never re-parses the
    multi-MB transcript.
    """
    if not trials_dir.exists():
        return {}
    counts: dict[str, int] = {"ok": 0, "infra_failed": 0}
    for trial_dir in sorted(trials_dir.iterdir()):
        if not (trial_dir.is_dir() and "__" in trial_dir.name):
            continue
        # Only sidecar trials that actually completed — pre-result.json dirs
        # are partial and would always classify as no_agent_progress.
        if not (trial_dir / "result.json").exists():
            continue
        verdict = classify_trial(trial_dir)
        write_sidecar(trial_dir, verdict)
        counts[verdict.status] = counts.get(verdict.status, 0) + 1
        if verdict.status == "infra_failed":
            counts[verdict.reason] = counts.get(verdict.reason, 0) + 1
    return counts


def _sanitize_and_upload(trials_dir: Path):
    """Sanitize traces (strip API keys) and upload to Railway S3."""
    import subprocess as _sp

    scripts_dir = REPO_ROOT / "scripts"
    sanitize_script = scripts_dir / "sanitize_traces.py"
    upload_script = scripts_dir / "upload_traces.py"
    # Resolve a usable python3: prefer the same interpreter we're already running
    # (works whether we were invoked from the main repo or a worktree without its
    # own .venv); fall back to REPO_ROOT/.venv for backward compat with hosts that
    # pinned that path explicitly.
    venv_python = REPO_ROOT / ".venv" / "bin" / "python3"
    python_bin = sys.executable if Path(sys.executable).exists() else str(venv_python)

    # Check for bucket credentials
    bucket = os.environ.get("BUCKET_NAME", "")
    if not bucket:
        log.info("Skipping trace upload: BUCKET_NAME not set")
        return

    # Sanitize — pass --trials-dir so non-default paths (trials_<model>_v0XX/)
    # are scrubbed. Without this arg, sanitize_traces.py defaults to ./trials
    # and silently skips our actual run output. Was a critical bug pre-v0.4.2:
    # OR API keys + ANTHROPIC_AUTH_TOKEN leaked unredacted into 1755 files.
    if sanitize_script.exists():
        log.info("Sanitizing traces in %s ...", trials_dir)
        _sp.run([python_bin, str(sanitize_script), "--trials-dir", str(trials_dir)],
                cwd=str(REPO_ROOT), timeout=600, check=False)

    # Upload — the existing script only checks trials/, so we upload manually
    endpoint = os.environ.get("BUCKET_ENDPOINT", "")
    access_key = os.environ.get("BUCKET_ACCESS_KEY", "")
    secret_key = os.environ.get("BUCKET_SECRET_KEY", "")
    if not all([endpoint, access_key, secret_key]):
        log.info("Skipping trace upload: missing BUCKET_* env vars")
        return

    log.info("Uploading traces from %s to S3...", trials_dir)
    try:
        import boto3
        s3 = boto3.client("s3", endpoint_url=endpoint,
                          aws_access_key_id=access_key, aws_secret_access_key=secret_key)
        uploaded = 0
        skipped = 0
        for path in sorted(trials_dir.rglob("*")):
            if path.is_dir():
                continue
            # Always upload under trials/ prefix so the viewer can find them
            relative = path.relative_to(trials_dir)
            key = f"trials/{relative}"
            try:
                head = s3.head_object(Bucket=bucket, Key=key)
                if head["ContentLength"] == path.stat().st_size:
                    skipped += 1
                    continue
            except Exception:
                pass
            s3.upload_file(str(path), bucket, key)
            uploaded += 1
        log.info("Traces uploaded: %d new, %d skipped", uploaded, skipped)
    except Exception as e:
        log.warning("Trace upload failed (non-fatal): %s", e)


async def main():
    parser = argparse.ArgumentParser(
        description="In-process batch eval using Harbor's LocalOrchestrator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--model", required=True, help="Action agent model (e.g., anthropic/claude-opus-4-6)")
    # Default to direct Gemini (matches config.yaml + runner.py + the v0.4.4
    # DS-Flash / DS-Pro production manifests). The OpenRouter route works too,
    # pass --user-model openrouter/google/gemini-3.1-pro-preview if needed,
    # but the default OR token has been flaky (401 "User not found").
    parser.add_argument("--user-model", default="gemini/gemini-3.1-pro-preview", help="User sim model")
    parser.add_argument("--tag", required=True, help="Short tag for this run")
    parser.add_argument("--workers", type=int, default=20, help="Max concurrent trials (default: 20)")
    parser.add_argument("--env-type", default=None, help="Environment: docker, e2b, etc.")
    parser.add_argument("--agent-type", default="claude-code",
                        choices=["claude-code", "codex"],
                        help="Coding agent type. Default claude-code. Use 'codex' for "
                             "user_enabled_codex (gpt-5.x via OAuth/OpenAI direct or OR).")
    parser.add_argument("--agent-timeout", type=int, default=None, help="Agent timeout in seconds")
    parser.add_argument("--trials-dir", default=None, help="Trials directory (default: trials/)")
    parser.add_argument("--tasks", default=None, help="Comma-separated task names or globs")
    parser.add_argument("--skip-existing", action="store_true", help="Skip tasks with existing results")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--user-context-chars", type=int, default=3000)
    parser.add_argument("--call-user-on-completion", type=bool, default=True)
    parser.add_argument("--force-build", action="store_true", help="Force E2B template rebuild (recovers from corrupted template aliases)")
    args = parser.parse_args()

    # Resolve model + key
    action_model, action_key, _env_var = resolve_model(args.model)
    user_model, user_key, _ = resolve_model(args.user_model or args.model)

    # User sim api_base — force real Anthropic endpoint when proxy is active
    user_provider = (args.user_model or args.model).split("/", 1)[0]
    user_api_base = "https://api.anthropic.com" if user_provider == "anthropic" else None

    # Build shared agent env (proxy config — same for all tasks)
    agent_env = build_agent_env(args.model, action_model, action_key)
    log.info("Provider: %s → agent_env keys: %s", args.model.split("/")[0], list(agent_env.keys())[:5])

    # CRITICAL: copy ALL agent_env keys into os.environ.
    #
    # Two host-side consumers read these via os.environ.get():
    # 1. user_enabled_claude_code.py:setup() — checks LITELLM_PROXY_MODEL to
    #    decide whether to upload + start the in-sandbox proxy.
    # 2. external/harbor/src/harbor/agents/installed/claude_code.py:874-880 —
    #    reads ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_BASE_URL
    #    from os.environ to build the env passed to `claude --print` inside
    #    the sandbox.
    #
    # If we only put the proxy config in agent_env (= AgentConfig.env, sandbox-
    # only), Harbor's installed-agent layer falls back to the host's real
    # ANTHROPIC_API_KEY (loaded from .env) and ignores ANTHROPIC_BASE_URL —
    # CC inside the sandbox then talks straight to api.anthropic.com with the
    # real key and the lying `claude-sonnet-4-6` name → silently runs as real
    # Anthropic Sonnet for all non-Anthropic models. This is the long-standing
    # recurring bug (see memory feedback_run_eval_proxy_bug_recurrence).
    #
    # Each run_eval.py invocation handles ONE model, so no race condition.
    for k, v in agent_env.items():
        os.environ[k] = v
    log.info("  host-env override applied (%d keys)", len(agent_env))

    # When using OAuth (subscription billing), explicitly POP any stale
    # ANTHROPIC_API_KEY / ANTHROPIC_BASE_URL from os.environ. Harbor's
    # claude_code adapter reads these from the host env and would prefer
    # ANTHROPIC_API_KEY (x-api-key auth) over CLAUDE_CODE_OAUTH_TOKEN
    # (Bearer auth), causing CC inside the sandbox to send the stale API
    # key to api.anthropic.com → 401. Matches the README's documented
    # OAuth flow.
    if agent_env.get("CLAUDE_CODE_OAUTH_TOKEN"):
        for k in ("ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL"):
            os.environ.pop(k, None)
        log.info("  OAuth mode: popped ANTHROPIC_API_KEY + ANTHROPIC_BASE_URL from host env")

    # Permanent fix for the shichaopei alias collision: prefix every E2B
    # template alias with our team identifier so we live in a private
    # namespace no other E2B team can squat on. Patched into Harbor's
    # e2b.py — see external/harbor/src/harbor/environments/e2b.py.
    os.environ.setdefault("HARBOR_TEAM_PREFIX", "tb")
    log.info("  HARBOR_TEAM_PREFIX=%s (E2B alias prefix)", os.environ["HARBOR_TEAM_PREFIX"])

    # Determine tasks
    if args.tasks:
        task_names = [t.strip() for t in args.tasks.split(",")]
    else:
        task_names = get_all_tasks()

    # Resolve task dirs
    trials_dir = Path(args.trials_dir) if args.trials_dir else REPO_ROOT / "trials"
    trials_dir.mkdir(parents=True, exist_ok=True)

    # Filter completed
    if args.skip_existing:
        before = len(task_names)
        task_names = [t for t in task_names if not is_task_completed(t, trials_dir)]
        log.info("Skip existing: %d → %d tasks", before, len(task_names))

    # Reproducibility metadata
    import subprocess as _sp
    git_sha = _sp.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, cwd=str(REPO_ROOT)).stdout.strip()
    git_tag = _sp.run(["git", "describe", "--tags", "--exact-match"], capture_output=True, text=True, cwd=str(REPO_ROOT)).stdout.strip() or "untagged"
    git_dirty = "clean" if _sp.run(["git", "diff", "--quiet"], cwd=str(REPO_ROOT)).returncode == 0 else "dirty"
    from datetime import datetime
    started_at = datetime.now().isoformat()

    print(f"\n{'='*70}")
    print(f"In-Process Eval (Harbor LocalOrchestrator)")
    print(f"{'='*70}")
    print(f"Git:       {git_sha[:12]} ({git_tag}) tree={git_dirty}")
    print(f"Started:   {started_at}")
    print(f"Model:     {args.model}")
    print(f"User sim:  {args.user_model}")
    print(f"Env:       {args.env_type or 'docker (default)'}")
    print(f"Timeout:   {args.agent_timeout or 'default'}s")
    print(f"Tag:       {args.tag}")
    print(f"Workers:   {args.workers}")
    print(f"Trials:    {trials_dir}")
    print(f"Tasks:     {len(task_names)}")
    print(f"{'='*70}\n")

    # Save manifest
    manifest = {
        "git_sha": git_sha,
        "git_tag": git_tag,
        "git_dirty": git_dirty,
        "started_at": started_at,
        "model": args.model,
        "user_model": args.user_model,
        "agent_type": args.agent_type,
        "env_type": args.env_type,
        "agent_timeout": args.agent_timeout,
        "tag": args.tag,
        "workers": args.workers,
        "trials_dir": str(trials_dir),
        "task_count": len(task_names),
        "tasks": task_names,
    }
    manifest_dir = REPO_ROOT / "pipeline_logs"
    manifest_dir.mkdir(exist_ok=True)
    manifest_path = manifest_dir / f"eval-{args.tag}-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2))
    log.info("Manifest: %s", manifest_path)

    if args.dry_run:
        for t in task_names:
            print(f"  {t}")
        return

    # Build per-task TrialConfigs
    trial_configs = []
    for task_name in task_names:
        task_dir = resolve_task_dir(task_name)
        if task_dir is None:
            log.warning("Task dir not found: %s — skipping", task_name)
            continue
        tc = build_trial_config(
            task_dir=task_dir,
            action_model=action_model,
            user_model=user_model,
            user_key=user_key,
            user_api_base=user_api_base,
            agent_env=agent_env,
            trials_dir=trials_dir,
            env_type=args.env_type,
            agent_timeout=args.agent_timeout,
            user_context_chars=args.user_context_chars,
            call_user_on_completion=args.call_user_on_completion,
            force_build=args.force_build,
            agent_type=args.agent_type,
        )
        trial_configs.append(tc)

    log.info("Built %d trial configs", len(trial_configs))

    # Run via Harbor's LocalOrchestrator
    start = time.time()
    # Retry on transient E2B infra failures with exponential backoff.
    # Retries happen INSIDE the semaphore — a retrying trial holds its
    # concurrency slot, so total E2B pressure stays ≤ n_concurrent_trials.
    # Backoff: 60s → 120s → 240s → 300s → 300s ≈ 17 min total window.
    #
    # IMPORTANT: include_exceptions is matched against type(e).__name__ (string
    # equality, not isinstance). So we list the *concrete* subclasses we want to
    # retry, not "SandboxException" (which would only match the literal alias-404
    # case where retry can never succeed).
    retry_config = RetryConfig(
        max_retries=5,
        include_exceptions=[
            "RateLimitException",  # E2B 429 — sandbox cap or template-build cap
            "TimeoutException",    # sandbox lost mid-run (gRPC unavailable)
            "ConnectTimeout",      # httpcore network blip during sandbox create
            "AddTestsDirError",    # transient docker upload_dir failure
        ],
        min_wait_sec=60.0,
        max_wait_sec=300.0,
        wait_multiplier=2.0,
    )
    orchestrator = LocalOrchestrator(
        trial_configs=trial_configs,
        n_concurrent_trials=args.workers,
        metrics={},
        quiet=True,
        retry_config=retry_config,
    )
    results = await orchestrator.run()
    elapsed = time.time() - start

    # Summary — rewards is a dict like {'reward': 0.1}
    rewards = []
    for r in results:
        if r.verifier_result and r.verifier_result.rewards is not None:
            rv = r.verifier_result.rewards
            if isinstance(rv, dict):
                rewards.append(rv.get("reward", 0.0))
            else:
                rewards.append(float(rv))

    print(f"\n{'='*70}")
    print(f"Eval Summary: {args.tag} ({elapsed/60:.0f} min)")
    print(f"{'='*70}")
    print(f"Total:   {len(results)}")
    print(f"Scored:  {len(rewards)}")
    if rewards:
        print(f"Avg reward: {sum(rewards)/len(rewards):.3f}")
        print(f"Min/Max:    {min(rewards):.3f} / {max(rewards):.3f}")

    def _extract_reward(r):
        if r.verifier_result and r.verifier_result.rewards is not None:
            rv = r.verifier_result.rewards
            return rv.get("reward", 0.0) if isinstance(rv, dict) else float(rv)
        return None

    def _count_user_interventions(trial_name: str) -> tuple[int, list[str]]:
        """Count user interventions from episode user_decision.json files."""
        trial_dir = trials_dir / trial_name / "agent"
        if not trial_dir.exists():
            return 0, []
        actions = []
        for ep_dir in sorted(trial_dir.iterdir()):
            decision_file = ep_dir / "user_decision.json"
            if decision_file.exists():
                try:
                    d = json.loads(decision_file.read_text())
                    if d.get("has_message"):
                        actions.append(d.get("action", "message"))
                except (json.JSONDecodeError, KeyError):
                    pass
        return len(actions), actions

    # Build per-result stats
    result_stats = []
    for r in sorted(results, key=lambda x: x.task_name):
        rv = _extract_reward(r)
        interventions, actions = _count_user_interventions(r.trial_name)
        result_stats.append({
            "task": r.task_name,
            "trial": r.trial_name,
            "reward": rv,
            "interventions": interventions,
            "actions": actions,
            "error": r.exception_info.exception_type if r.exception_info else None,
        })

    print(f"\n{'Task':<40} {'Reward':>7} {'Turns':>5} {'Actions':<20} {'Status':<8}")
    print("-" * 85)
    for s in result_stats:
        reward = f"{s['reward']:.2f}" if s['reward'] is not None else "?"
        actions_str = ", ".join(s["actions"]) if s["actions"] else "-"
        status = "error" if s["error"] else "done"
        print(f"{s['task']:<40} {reward:>7} {s['interventions']:>5} {actions_str:<20} {status:<8}")

    # Write summary JSON
    summary_dir = REPO_ROOT / "pipeline_logs"
    summary_dir.mkdir(exist_ok=True)
    summary_path = summary_dir / f"eval-{args.tag}-summary.json"
    summary_data = {
        "tag": args.tag,
        "model": args.model,
        "user_model": args.user_model,
        "env_type": args.env_type,
        "wall_time_sec": elapsed,
        "total": len(results),
        "scored": len(rewards),
        "avg_reward": sum(rewards) / len(rewards) if rewards else None,
        "results": result_stats,
    }
    summary_path.write_text(json.dumps(summary_data, indent=2))
    log.info("Summary written to %s", summary_path)

    # Post-run: copy sim prompts, build trajectories, classify infra
    # health, sanitize and upload. Order matters — sidecars must be written
    # before the optional S3 upload so they're included.
    _copy_sim_prompts(task_names, trials_dir)
    _build_trajectories(trials_dir)
    infra_counts = _emit_infra_sidecars(trials_dir)
    if infra_counts:
        print(f"\nInfra audit: {infra_counts.get('ok', 0)} ok, "
              f"{infra_counts.get('infra_failed', 0)} infra_failed "
              f"({', '.join(f'{k}={v}' for k, v in infra_counts.items() if k not in ('ok', 'infra_failed'))})")
    _sanitize_and_upload(trials_dir)


if __name__ == "__main__":
    asyncio.run(main())
