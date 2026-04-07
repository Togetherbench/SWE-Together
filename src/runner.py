"""runner.py — run a harbor task with UserEnabledTerminus2.

Supports Gemini, OpenRouter, and Anthropic for both action agent and user agent.

Usage:
    # Gemini
    GEMINI_API_KEY=<key> python runner.py --model gemini/gemini-3.1-pro-preview

    # Anthropic
    ANTHROPIC_API_KEY=<key> python runner.py --model anthropic/claude-opus-4-6

    # OpenRouter
    OPENROUTER_API_KEY=<key> python runner.py --model openrouter/google/gemini-2.5-flash

    # Mixed: action=Gemini, user=Anthropic
    GEMINI_API_KEY=<k1> ANTHROPIC_API_KEY=<k2> python runner.py \\
        --model gemini/gemini-3.1-pro-preview --user-model anthropic/claude-haiku-4-5
"""

import argparse
import asyncio
import json
import logging
import os
import subprocess
import sys
import time
from pathlib import Path

import yaml
from dotenv import load_dotenv

# Auto-load .env from repo root (won't override existing env vars)
load_dotenv(Path(__file__).resolve().parent.parent / ".env")

# ── repo paths ────────────────────────────────────────────────────────────────
REPO_ROOT = Path(__file__).resolve().parent.parent
HARBOR_ROOT = REPO_ROOT / "external" / "harbor"
HARBOR_SRC = HARBOR_ROOT / "src"

sys.path.insert(0, str(HARBOR_SRC))
sys.path.insert(0, str(REPO_ROOT / "src"))

from harbor.models.environment_type import EnvironmentType
from harbor.models.trial.config import (
    AgentConfig,
    EnvironmentConfig,
    TaskConfig,
    TrialConfig,
)
from harbor.trial.trial import Trial

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
log = logging.getLogger("runner")

# ── agent type registry ───────────────────────────────────────────────────────
# Agent types with user simulation support (custom wrappers in src/user_agent/)
_USER_SIM_AGENT_TYPES = {
    "terminus":    "user_agent.user_enabled_agent:UserEnabledTerminus2",
    "claude-code": "user_agent.user_enabled_claude_code:UserEnabledClaudeCode",
    "codex":       "user_agent.user_enabled_codex:UserEnabledCodex",
}

# Agent types without user simulation (Harbor's installed CLI agents, single-shot)
_PASSTHROUGH_AGENT_TYPES = {
    "aider", "cline-cli", "cursor-cli", "gemini-cli", "goose",
    "swe-agent", "mini-swe-agent", "opencode", "openhands",
    "openhands-sdk", "kimi-cli", "qwen-coder",
}

VALID_AGENT_TYPES = set(_USER_SIM_AGENT_TYPES) | _PASSTHROUGH_AGENT_TYPES


# ── provider resolution ───────────────────────────────────────────────────────

# Maps LiteLLM provider prefix → (env var name, env var key passed to agent)
_PROVIDER_MAP = {
    "gemini":      ("GEMINI_API_KEY",      "GEMINI_API_KEY"),
    "anthropic":   ("ANTHROPIC_API_KEY",   "ANTHROPIC_API_KEY"),
    "openrouter":  ("OPENROUTER_API_KEY",  "OPENROUTER_API_KEY"),
    "openai":      ("OPENAI_API_KEY",      "OPENAI_API_KEY"),
    "chutes":      ("CHUTES_API_KEY",      "ANTHROPIC_API_KEY"),
    "fireworks":   ("FIREWORKS_API_KEY",   "ANTHROPIC_API_KEY"),
    "glm":         ("GLM_API_KEY",         "ANTHROPIC_API_KEY"),
}

# Proxy URLs for routing non-Anthropic models through Claude Code CLI.
# Both expose Anthropic Messages API-compatible endpoints.
#
# Chutes: --model chutes/moonshotai/Kimi-K2.5-TEE
# OpenRouter: --model openrouter/minimax/minimax-m2.7
_CHUTES_BASE_URL = "https://claude.chutes.ai"
_OPENROUTER_BASE_URL = "https://openrouter.ai/api"
_FIREWORKS_BASE_URL = "https://api.fireworks.ai/inference"
_GLM_BASE_URL = "https://api.z.ai/api/anthropic"


def resolve_model(model_arg: str) -> tuple[str, str, str]:
    """Return (litellm_model, api_key, env_var_name) for a model spec.

    model_arg may be:
      - "gemini/gemini-3.1-pro-preview"      → provider prefix explicit
      - "gemini-2.5-flash"             → inferred from available keys
      - "anthropic/claude-opus-4-6"
      - "openrouter/google/gemini-..."
    """
    # Split off provider prefix
    parts = model_arg.split("/", 1)
    if len(parts) == 2 and parts[0] in _PROVIDER_MAP:
        provider, _ = parts[0], parts[1]
        env_var, agent_env_var = _PROVIDER_MAP[provider]
        api_key = os.environ.get(env_var, "")
        if not api_key:
            log.error("Model %s requires %s to be set.", model_arg, env_var)
            sys.exit(1)
        return model_arg, api_key, agent_env_var

    # No explicit prefix — infer from whichever key is available
    for provider, (env_var, agent_env_var) in _PROVIDER_MAP.items():
        api_key = os.environ.get(env_var, "")
        if api_key:
            full_model = f"{provider}/{model_arg}"
            log.info("No provider prefix on %r — using %s (found %s)", model_arg, full_model, env_var)
            return full_model, api_key, agent_env_var

    log.error(
        "No API key found. Set one of: %s",
        ", ".join(v for v, _ in _PROVIDER_MAP.values()),
    )
    sys.exit(1)


# ── docker helpers ────────────────────────────────────────────────────────────

def load_docker_image(tar_path: Path) -> str:
    log.info("Loading docker image from %s ...", tar_path)
    result = subprocess.run(
        ["docker", "load", "--input", str(tar_path)],
        capture_output=True, text=True, check=True,
    )
    output = result.stdout.strip()
    log.info("docker load: %s", output)
    for line in output.splitlines():
        if line.startswith("Loaded image: "):
            return line.removeprefix("Loaded image: ").strip()
        if line.startswith("Loaded image ID: "):
            return line.removeprefix("Loaded image ID: ").strip()
    raise RuntimeError(f"Could not parse image name from docker load output:\n{output}")


def patch_task_toml(task_dir: Path, docker_image: str) -> None:
    toml_path = task_dir / "task.toml"
    text = toml_path.read_text()
    if "docker_image" not in text:
        text = text.replace(
            "[environment]",
            f'[environment]\ndocker_image = "{docker_image}"',
        )
        toml_path.write_text(text)
        log.info("Patched task.toml: docker_image = %s", docker_image)


def load_analysis(task_dir: Path) -> dict:
    analysis_path = task_dir / "analysis.json"
    if analysis_path.exists():
        return json.loads(analysis_path.read_text())
    return {}


def load_user_messages(task_dir: Path, analysis: dict) -> list[str]:
    """Load the recorded user messages from whichever artifact has them."""
    candidates = analysis.get("user_messages")
    if isinstance(candidates, list):
        return [
            msg for msg in candidates
            if isinstance(msg, str) and not msg.startswith("[Request interrupted")
        ]

    session_path = task_dir / "original_session.json"
    if not session_path.exists():
        return []

    # Prefixes that mark Claude Code system/tooling messages, not genuine user turns
    _SYSTEM_PREFIXES = (
        "[Request interrupted",
        "<local-command-caveat>",
        "<command-name>",
        "<command-message>",
        "<command-args>",
        "<local-command-stdout>",
        "<task-",
        "Base directory",
    )

    session = json.loads(session_path.read_text())
    return [
        msg.get("content", "")
        for msg in session.get("messages", [])
        if msg.get("role") == "user"
        and isinstance(msg.get("content"), str)
        and not msg["content"].startswith(_SYSTEM_PREFIXES)
    ]


def _compute_message_guidance(gt_count: int) -> tuple[int, int]:
    """Compute a suggested message range based on ground-truth count.

    Returns (low, high) — a guidance range of [GT*0.5, GT*1.5] that is
    injected into the user sim's system prompt as a soft target. No hard
    cap is enforced; the user sim decides based on the session context.
    """
    import math
    low = max(1, math.ceil(gt_count * 0.5))
    high = max(low + 1, math.ceil(gt_count * 1.5))
    return low, high


def _extract_gt_session_duration(task_dir: Path) -> float | None:
    """Extract the original session duration in seconds from original_session.json."""
    from datetime import datetime, timezone

    session_path = task_dir / "original_session.json"
    if not session_path.exists():
        return None

    try:
        session = json.loads(session_path.read_text())
        start = session.get("start_time")
        end = session.get("end_time")
        if start and end:
            t0 = datetime.fromisoformat(start)
            t1 = datetime.fromisoformat(end)
            return (t1 - t0).total_seconds()
    except Exception as exc:
        log.debug("Could not extract GT session duration: %s", exc)

    return None


def resolve_task_dir(task_name: str) -> Path | None:
    """Support both current and legacy harbor task layouts."""
    candidates = [
        REPO_ROOT / "harbor_tasks" / task_name,
        REPO_ROOT / "harbor_tasks" / "raw" / task_name,
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


# ── main ──────────────────────────────────────────────────────────────────────

async def run_single_task(task_name: str, tar_path: Path | None, args) -> None:
    """Run a single task by name."""
    # Resolve action agent model + key
    action_model, action_key, action_env_var = resolve_model(args.model)

    # Resolve user agent model + key (defaults to same as action)
    user_model_arg = args.user_model or args.model
    user_model, user_key, _user_env_var = resolve_model(user_model_arg)

    # Detect proxy provider for Claude Code CLI env setup
    action_provider = args.model.split("/", 1)[0] if "/" in args.model else None
    is_chutes = action_provider == "chutes"
    is_openrouter = action_provider == "openrouter"
    is_fireworks = action_provider == "fireworks"
    is_glm = action_provider == "glm"
    proxy_label = (
        " (via Chutes)" if is_chutes
        else " (via OpenRouter)" if is_openrouter
        else " (via Fireworks)" if is_fireworks
        else " (via Z.AI direct)" if is_glm
        else ""
    )

    log.info("Action agent : %s%s", action_model, proxy_label)
    log.info("User agent   : %s", user_model)

    trial_start = time.time()

    task_dir = resolve_task_dir(task_name)

    if task_dir is None:
        log.error("Task directory not found: %s", task_name)
        return

    if tar_path is None:
        tar_path = Path(args.env_path) / f"harbor-{task_name}.tar"

    if tar_path.exists():
        image_name = load_docker_image(tar_path)
        patch_task_toml(task_dir, image_name)
    else:
        log.warning("Tar not found at %s — assuming image already loaded.", tar_path)

    # Load ground-truth user messages from analysis.json or original_session.json
    analysis = load_analysis(task_dir)
    user_messages = load_user_messages(task_dir, analysis)
    log.info("Ground-truth user messages: %d", len(user_messages))

    # Load user_simulation_prompt.md for rich session context
    sim_prompt_path = task_dir / "user_simulation_prompt.md"
    session_analysis = sim_prompt_path.read_text() if sim_prompt_path.exists() else ""
    if session_analysis:
        log.info("Loaded user_simulation_prompt.md (%d chars)", len(session_analysis))

    # Compute GT-based message guidance range (soft target, no hard cap)
    gt_count = len(user_messages)
    msg_low, msg_high = _compute_message_guidance(gt_count)
    log.info("Message guidance: %d–%d (from GT=%d)", msg_low, msg_high, gt_count)

    # Inject guidance into session analysis so user sim sees it
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

    # Build AgentConfig based on agent type
    agent_type = args.agent_type

    # Determine the user sim's api_base. When a proxy (Chutes/Fireworks/OpenRouter)
    # sets ANTHROPIC_BASE_URL in os.environ, LiteLLM would route the user sim's
    # Anthropic calls through that proxy too. Fix: explicitly set user_api_base so
    # the user sim always hits the correct provider endpoint.
    user_provider = user_model_arg.split("/", 1)[0] if "/" in user_model_arg else None
    user_api_base = None  # default: let LiteLLM use the provider's default endpoint
    if user_provider == "anthropic":
        # Force the real Anthropic endpoint so proxy env vars don't interfere
        user_api_base = "https://api.anthropic.com"

    user_sim_kwargs = {
        "user_model_name": user_model,
        "user_api_key": user_key,
        "user_api_base": user_api_base,
        "original_user_messages": user_messages,
        "session_analysis": session_analysis_with_guidance,
        "max_messages": None,  # no hard cap — guidance is soft
        "user_context_chars": args.user_context_chars,
        "call_user_on_completion": args.call_user_on_completion,
    }

    setup_timeout = getattr(args, 'setup_timeout', None)

    # Build agent env: API key + optional proxy for non-Anthropic models.
    # When using a proxy (Chutes/OpenRouter), Claude Code CLI needs:
    #   ANTHROPIC_BASE_URL → proxy endpoint (Anthropic Messages API-compatible)
    #   ANTHROPIC_AUTH_TOKEN + ANTHROPIC_API_KEY → both set to the proxy's API key
    #   CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC → prevent calls to api.anthropic.com
    #   All model aliases → point to the selected model
    # Ref: /home/alex/agentsmd-rl/scripts/run_agentmd_overnight.sh (Z.AI pattern)
    agent_env = {action_env_var: action_key}

    def _configure_proxy(base_url: str, key: str, model: str, label: str):
        """Set Claude Code CLI env vars for an Anthropic API-compatible proxy.

        Sets vars in both agent_env (passed to sandbox) AND os.environ (read by
        Harbor's ClaudeCode.create_run_agent_commands() on the host side).
        """
        proxy_vars = {
            "ANTHROPIC_BASE_URL": base_url,
            "ANTHROPIC_AUTH_TOKEN": key,
            "ANTHROPIC_API_KEY": key,
            "ANTHROPIC_MODEL": model,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": model,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": model,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": model,
            "ANTHROPIC_SMALL_FAST_MODEL": model,
            "CLAUDE_CODE_SUBAGENT_MODEL": model,
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_ENABLE_TELEMETRY": "0",
            "CLAUDE_CODE_ATTRIBUTION_HEADER": "0",
            "CLAUDE_CODE_SIMPLE": "1",  # --bare mode: disables context management beta header
            "IS_SANDBOX": "1",
            "API_TIMEOUT_MS": "6000000",
        }
        agent_env.update(proxy_vars)
        # Also set on host so Harbor's ClaudeCode._setup_env() picks them up
        os.environ.update(proxy_vars)
        log.info("%s proxy: %s → model %s", label, base_url, model)

    if is_chutes:
        # Strip "chutes/" prefix — Claude Code sees just the model ID
        action_model = action_model.split("/", 1)[1]
        _configure_proxy(_CHUTES_BASE_URL, action_key, action_model, "Chutes")
    elif is_openrouter:
        # OpenRouter: use a local LiteLLM proxy inside the E2B sandbox.
        # Claude Code sends Anthropic beta headers that OpenRouter rejects for
        # non-Anthropic models. The proxy (with drop_params=true) strips them.
        # Ref: agentsmd-rl/scripts/eval_models_overnight.sh
        or_model = action_model.split("/", 1)[1]  # strip "openrouter/"
        proxy_port = "4210"
        # Tell Claude Code to connect to localhost proxy
        proxy_vars = {
            "ANTHROPIC_BASE_URL": f"http://localhost:{proxy_port}",
            "ANTHROPIC_API_KEY": "sk-litellm-local",
            "ANTHROPIC_AUTH_TOKEN": "sk-litellm-local",
            "ANTHROPIC_MODEL": "claude-sonnet-4-6",  # proxy remaps this
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_SMALL_FAST_MODEL": "claude-sonnet-4-6",
            "CLAUDE_CODE_SUBAGENT_MODEL": "claude-sonnet-4-6",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_ENABLE_TELEMETRY": "0",
            "API_TIMEOUT_MS": "6000000",
            # These are read by UserEnabledClaudeCode.setup() to start the proxy
            "LITELLM_PROXY_MODEL": or_model,
            "LITELLM_PROXY_PORT": proxy_port,
            "OPENROUTER_API_KEY": action_key,
        }
        agent_env.update(proxy_vars)
        os.environ.update(proxy_vars)
        # Keep action_model as a standard Claude name (proxy remaps it)
        action_model = "claude-sonnet-4-6"
        log.info("OpenRouter via LiteLLM proxy: localhost:%s → %s", proxy_port, or_model)
    elif is_fireworks:
        # Fireworks: use a local proxy inside the E2B sandbox (like OpenRouter).
        # Claude Code CLI rejects non-Claude model names client-side, so we give it
        # a standard Claude model name and have the proxy remap to the real Fireworks
        # model. Fireworks handles anthropic-beta headers natively, so the proxy only
        # needs to remap the model field — no header stripping required.
        # On 429, falls back to OpenRouter.
        fw_model = action_model.split("/", 1)[1]  # strip "fireworks/" prefix
        proxy_port = "4210"
        or_key = os.environ.get("OPENROUTER_API_KEY", "")
        # Map Fireworks model → OpenRouter fallback model
        _FW_TO_OR = {
            "accounts/fireworks/routers/kimi-k2p5-turbo": "moonshotai/kimi-k2.5",
            "accounts/fireworks/models/glm-5": "z-ai/glm-5",
        }
        or_fallback = _FW_TO_OR.get(fw_model, "")
        proxy_vars = {
            "ANTHROPIC_BASE_URL": f"http://localhost:{proxy_port}",
            "ANTHROPIC_API_KEY": "sk-proxy-local",
            "ANTHROPIC_AUTH_TOKEN": "sk-proxy-local",
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
            "LITELLM_PROXY_PORT": proxy_port,
            "PROXY_TARGET_URL": _FIREWORKS_BASE_URL,
            "PROXY_API_KEY": action_key,
            # Fallback to OpenRouter on 429
            "PROXY_FALLBACK_URL": _OPENROUTER_BASE_URL,
            "PROXY_FALLBACK_KEY": or_key,
            "PROXY_FALLBACK_MODEL": or_fallback,
        }
        agent_env.update(proxy_vars)
        os.environ.update(proxy_vars)
        action_model = "claude-sonnet-4-6"
        log.info("Fireworks via proxy: localhost:%s → %s (fallback: OpenRouter/%s)", proxy_port, fw_model, or_fallback)
    elif is_glm:
        # Z.AI GLM: speaks Anthropic Messages API natively, but we still use an
        # in-sandbox proxy so it can fall back to OpenRouter on 429 (rate limit).
        glm_model = action_model.split("/", 1)[1]  # strip "glm/" prefix
        proxy_port = "4210"
        or_key = os.environ.get("OPENROUTER_API_KEY", "")
        proxy_vars = {
            "ANTHROPIC_BASE_URL": f"http://localhost:{proxy_port}",
            "ANTHROPIC_API_KEY": "sk-proxy-local",
            "ANTHROPIC_AUTH_TOKEN": "sk-proxy-local",
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
            "LITELLM_PROXY_PORT": proxy_port,
            "PROXY_TARGET_URL": _GLM_BASE_URL,
            "PROXY_API_KEY": action_key,
            # Fallback to OpenRouter on 429
            "PROXY_FALLBACK_URL": _OPENROUTER_BASE_URL,
            "PROXY_FALLBACK_KEY": or_key,
            "PROXY_FALLBACK_MODEL": f"z-ai/{glm_model}",
        }
        agent_env.update(proxy_vars)
        os.environ.update(proxy_vars)
        action_model = "claude-sonnet-4-6"
        log.info("Z.AI GLM via proxy: localhost:%s → %s (fallback: OpenRouter)", proxy_port, glm_model)

    agent_timeout = getattr(args, 'agent_timeout', None)

    if agent_type in _USER_SIM_AGENT_TYPES:
        agent_config = AgentConfig(
            import_path=_USER_SIM_AGENT_TYPES[agent_type],
            model_name=action_model,
            override_setup_timeout_sec=setup_timeout,
            override_timeout_sec=agent_timeout,
            kwargs=user_sim_kwargs,
            env=agent_env,
        )
    else:
        log.info("Using installed agent type: %s (user simulation not supported)", agent_type)
        agent_config = AgentConfig(
            name=agent_type,
            model_name=action_model,
            override_setup_timeout_sec=setup_timeout,
            override_timeout_sec=agent_timeout,
            env=agent_env,
        )

    env_type = getattr(args, 'env_type', None)
    env_kwargs: dict = {"delete": not args.keep}
    if env_type:
        env_kwargs["type"] = EnvironmentType(env_type)

    trial_config = TrialConfig(
        task=TaskConfig(path=task_dir),
        trials_dir=Path(args.trials_dir),
        agent=agent_config,
        environment=EnvironmentConfig(**env_kwargs),
    )

    trial = Trial(config=trial_config)
    result = await trial.run()

    trial_elapsed = time.time() - trial_start
    gt_duration = _extract_gt_session_duration(task_dir)

    print("\n" + "=" * 60)
    print(f"  task   : {task_name}")
    rewards = result.verifier_result.rewards if result.verifier_result else None
    reward = rewards.get("reward") if rewards else None
    print(f"  reward : {reward}")
    print(f"  success: {result.exception_info is None}")
    if result.exception_info:
        print(f"  error  : {result.exception_info.exception_type}: {result.exception_info.exception_message}")
    print(f"  wall_clock : {trial_elapsed:.0f}s ({trial_elapsed/60:.1f}m)")
    if gt_duration:
        print(f"  gt_duration: {gt_duration:.0f}s ({gt_duration/60:.1f}m)")
        print(f"  speedup    : {gt_duration/trial_elapsed:.2f}x" if trial_elapsed > 0 else "")
    print("=" * 60)

    # Write timing.json into each trial directory for this task
    _write_timing(task_dir, Path(args.trials_dir), task_name, trial_elapsed, gt_duration)

    # Copy user_simulation_prompt.md into trial dirs so it gets uploaded with traces
    _copy_sim_prompts_to_trials(task_dir, Path(args.trials_dir))

    # Pre-build enriched trajectory.json from episode files (avoids viewer reconstruction)
    _build_trajectories(task_dir, Path(args.trials_dir))

    # Auto-upload traces to Railway S3 if credentials available
    _auto_upload_traces()


def _write_timing(
    task_dir: Path, trials_dir: Path, task_name: str,
    trial_elapsed: float, gt_duration: float | None,
):
    """Write timing.json into each trial directory for the task."""
    timing = {
        "trial_wall_clock_sec": round(trial_elapsed, 1),
        "gt_session_duration_sec": round(gt_duration, 1) if gt_duration else None,
        "speedup": round(gt_duration / trial_elapsed, 2) if gt_duration and trial_elapsed > 0 else None,
    }
    for trial in trials_dir.iterdir():
        if trial.is_dir() and trial.name.startswith(task_name):
            path = trial / "timing.json"
            if not path.exists():
                path.write_text(json.dumps(timing, indent=2))
                log.info("Wrote timing.json → %s", path)


def _copy_sim_prompts_to_trials(task_dir: Path, trials_dir: Path):
    """Copy user_simulation_prompt.md into each trial directory for the task.

    The viewer expects this file alongside the trajectory — bake it in so
    we never have to remember to upload it separately.
    """
    import shutil
    src = task_dir / "user_simulation_prompt.md"
    if not src.exists():
        return
    task_name = task_dir.name
    for trial in trials_dir.iterdir():
        if trial.is_dir() and trial.name.startswith(task_name):
            dst = trial / "user_simulation_prompt.md"
            if not dst.exists():
                shutil.copy2(src, dst)
                log.info("Copied user_simulation_prompt.md → %s", dst)


def _build_trajectories(task_dir: Path, trials_dir: Path):
    """Pre-build enriched trajectory.json from episode files.

    Converts per-episode files into a single ATIF-compatible trajectory.json
    so the viewer serves it directly instead of reconstructing on every request.
    """
    build_script = REPO_ROOT / "scripts" / "build_trajectory.py"
    if not build_script.exists():
        return
    task_name = task_dir.name
    for trial in trials_dir.iterdir():
        if trial.is_dir() and trial.name.startswith(task_name):
            agent_dir = trial / "agent"
            episodes = [d for d in agent_dir.iterdir() if d.is_dir() and d.name.startswith("episode-")] if agent_dir.exists() else []
            if episodes:
                subprocess.run(
                    [sys.executable, str(build_script), str(trial)],
                    cwd=str(REPO_ROOT), timeout=60, check=False,
                )


def _auto_upload_traces():
    """Sanitize and upload traces to Railway S3 if bucket credentials are set."""
    bucket = os.environ.get("BUCKET_NAME", "")
    endpoint = os.environ.get("BUCKET_ENDPOINT", "")
    access_key = os.environ.get("BUCKET_ACCESS_KEY", "")
    secret_key = os.environ.get("BUCKET_SECRET_KEY", "")

    if not all([bucket, endpoint, access_key, secret_key]):
        log.info("Skipping auto-upload: BUCKET_* env vars not set")
        return

    scripts_dir = REPO_ROOT / "scripts"
    sanitize_script = scripts_dir / "sanitize_traces.py"
    upload_script = scripts_dir / "upload_traces.py"

    if not sanitize_script.exists() or not upload_script.exists():
        log.info("Skipping auto-upload: sanitize/upload scripts not found")
        return

    log.info("Auto-uploading traces to Railway S3...")
    try:
        subprocess.run(
            [sys.executable, str(sanitize_script)],
            cwd=str(REPO_ROOT), timeout=60, check=False,
        )
        subprocess.run(
            [sys.executable, str(upload_script)],
            cwd=str(REPO_ROOT), timeout=300, check=False,
        )
        log.info("Traces uploaded successfully")
    except Exception as e:
        log.warning("Auto-upload failed (non-fatal): %s", e)


def discover_tasks_from_env_path(env_path: str) -> list[tuple[str, Path]]:
    """Discover all tasks from docker tar files in env_path.

    Returns list of (task_name, tar_path) tuples.
    """
    env_dir = Path(env_path)
    if not env_dir.is_dir():
        log.error("env_path directory not found: %s", env_dir)
        return []
    tasks = []
    for tar_file in sorted(env_dir.glob("harbor-*.tar")):
        # Extract task name: harbor-<task_name>.tar -> task_name
        task_name = tar_file.stem.removeprefix("harbor-")
        tasks.append((task_name, tar_file))
    return tasks


async def run(args) -> None:
    if args.task:
        await run_single_task(args.task, None, args)
    else:
        # No task specified — run all docker images in env_path
        tasks = discover_tasks_from_env_path(args.env_path)
        if not tasks:
            log.error("No tasks found. Specify --task or add docker tars to env_path: %s", args.env_path)
            sys.exit(1)
        log.info("No task specified — running all %d tasks from %s", len(tasks), args.env_path)
        for task_name, tar_path in tasks:
            log.info("=" * 60)
            log.info("Running task: %s", task_name)
            log.info("=" * 60)
            await run_single_task(task_name, tar_path, args)


def load_config(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f) or {}


def main():
    parser = argparse.ArgumentParser(
        description="Run a harbor task with UserEnabledTerminus2",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--config",     default=None,
                        help="Path to YAML config file (e.g. config.yaml)")
    parser.add_argument("--task",       default=None,
                        help="Task name under harbor_tasks/ or harbor_tasks/raw/")
    parser.add_argument("--model",      default=None,
                        help="Action agent model, e.g. gemini/gemini-3.1-pro-preview")
    parser.add_argument("--user-model", default=None,
                        help="User agent model (defaults to --model)")
    parser.add_argument("--agent-type", default=None,
                        choices=sorted(VALID_AGENT_TYPES),
                        help="Coding agent type (default: terminus). "
                             "'terminus' uses UserEnabledTerminus2 with in-process user sim. "
                             "'claude-code' uses Claude Code CLI with user sim via --resume. "
                             "'codex' uses Codex CLI with user sim via sequential re-runs. "
                             "Others use Harbor's installed CLI agents (no user sim).")
    parser.add_argument("--env-type",   default=None,
                        choices=["docker", "e2b", "daytona", "modal", "gke"],
                        help="Environment type (default: docker). Use 'e2b' for cloud sandbox.")
    parser.add_argument("--setup-timeout", default=None, type=float,
                        help="Agent setup timeout in seconds (default: 360). Increase for slow E2B installs.")
    parser.add_argument("--agent-timeout", default=None, type=float,
                        help="Agent execution timeout in seconds (default: from task.toml, usually 1800). "
                             "Increase for slower open-source models.")
    parser.add_argument("--trials-dir", default=None,
                        help="Directory for trial results")
    parser.add_argument("--keep",       action="store_true", default=None,
                        help="Keep container after run")
    cli = parser.parse_args()

    # Load config file first, then overlay CLI args (CLI wins)
    cfg: dict = {}
    if cli.config:
        cfg = load_config(cli.config)
        log.info("Loaded config from %s", cli.config)

    # Merge: CLI args override config values; fall back to hardcoded defaults
    class Args:
        task                  = cli.task       or cfg.get("task")  # None = run all from env_path
        env_path              = cfg.get("env_path", str(REPO_ROOT / "harbor_tasks" / "docker_images"))
        model                 = cli.model      or cfg.get("model",      "gemini/gemini-3.1-pro-preview")
        user_model            = cli.user_model or cfg.get("user_model") or cfg.get("model") or "gemini/gemini-3.1-pro-preview"
        agent_type            = cli.agent_type or cfg.get("agent_type", "terminus")
        env_type              = cli.env_type   or cfg.get("env_type")  # None = docker (default)
        setup_timeout         = cli.setup_timeout or cfg.get("setup_timeout")  # None = default (360s)
        agent_timeout         = cli.agent_timeout or cfg.get("agent_timeout")  # None = from task.toml
        trials_dir            = cli.trials_dir or cfg.get("trials_dir", "trials")
        keep                  = cli.keep       or cfg.get("keep_container", False)
        user_context_chars    = cfg.get("user_context_chars",    3000)
        call_user_on_completion = cfg.get("call_user_on_completion", True)

    asyncio.run(run(Args()))


if __name__ == "__main__":
    main()
