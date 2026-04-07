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


def get_all_tasks() -> list[str]:
    tasks_dir = REPO_ROOT / "harbor_tasks"
    return sorted(
        d.name for d in tasks_dir.iterdir()
        if d.is_dir() and (d / "task.toml").exists() and (d / "instruction.md").exists()
    )


def is_task_completed(task_name: str, trials_dir: Path) -> bool:
    """Check if a task has a successful trial (result.json with a real reward)."""
    if not trials_dir.exists():
        return False
    for d in trials_dir.iterdir():
        if d.is_dir() and d.name.startswith(task_name + "__"):
            result_path = d / "result.json"
            if result_path.exists():
                try:
                    result = json.loads(result_path.read_text())
                    vr = result.get("verifier_result")
                    if vr and vr.get("rewards"):
                        return True
                except (json.JSONDecodeError, KeyError):
                    pass
    return False


def build_agent_env(model_arg: str, action_model: str, action_key: str) -> dict[str, str]:
    """Build the agent environment variables for proxy/provider routing.

    Returns a dict that goes into AgentConfig.env → agent's extra_env →
    sandbox exec env. Does NOT touch os.environ.
    """
    provider = model_arg.split("/", 1)[0] if "/" in model_arg else None
    env: dict[str, str] = {}

    if provider == "anthropic":
        env["ANTHROPIC_API_KEY"] = action_key
        return env

    if provider == "openrouter":
        or_model = model_arg.split("/", 1)[1]
        or_key = action_key
        env.update({
            "ANTHROPIC_API_KEY": "sk-litellm-local",
            "ANTHROPIC_AUTH_TOKEN": "sk-litellm-local",
            "ANTHROPIC_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_SMALL_FAST_MODEL": "claude-sonnet-4-6",
            "CLAUDE_CODE_SUBAGENT_MODEL": "claude-sonnet-4-6",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_ENABLE_TELEMETRY": "0",
            "API_TIMEOUT_MS": "6000000",
            "LITELLM_PROXY_MODEL": or_model,
            "LITELLM_PROXY_PORT": "4210",
            "OPENROUTER_API_KEY": or_key,
        })
        return env

    if provider == "fireworks":
        fw_model = model_arg.split("/", 1)[1]
        or_key = os.environ.get("OPENROUTER_API_KEY", "")
        _FW_TO_OR = {
            "accounts/fireworks/routers/kimi-k2p5-turbo": "moonshotai/kimi-k2.5",
            "accounts/fireworks/models/glm-5": "z-ai/glm-5",
        }
        env.update({
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
            "LITELLM_PROXY_PORT": "4210",
            "PROXY_TARGET_URL": _FIREWORKS_BASE_URL,
            "PROXY_API_KEY": action_key,
            "PROXY_FALLBACK_URL": _OPENROUTER_BASE_URL,
            "PROXY_FALLBACK_KEY": or_key,
            "PROXY_FALLBACK_MODEL": _FW_TO_OR.get(fw_model, ""),
        })
        return env

    if provider == "glm":
        glm_model = model_arg.split("/", 1)[1]
        or_key = os.environ.get("OPENROUTER_API_KEY", "")
        env.update({
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
            "LITELLM_PROXY_PORT": "4210",
            "PROXY_TARGET_URL": _GLM_BASE_URL,
            "PROXY_API_KEY": action_key,
            "PROXY_FALLBACK_URL": _OPENROUTER_BASE_URL,
            "PROXY_FALLBACK_KEY": or_key,
            "PROXY_FALLBACK_MODEL": f"z-ai/{glm_model}",
        })
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
    }

    # For proxy providers, the model name sent to Harbor must be a Claude name
    # (the proxy remaps it). For direct Anthropic, use the real model name.
    harbor_model = action_model
    if agent_env.get("LITELLM_PROXY_MODEL"):
        harbor_model = "claude-sonnet-4-6"

    agent_config = AgentConfig(
        import_path=AGENT_IMPORT_PATH,
        model_name=harbor_model,
        override_timeout_sec=agent_timeout,
        kwargs=user_sim_kwargs,
        env=agent_env,
    )

    env_config = EnvironmentConfig(delete=True)
    if env_type:
        env_config.type = EnvironmentType(env_type)

    return TrialConfig(
        task=TaskConfig(path=task_dir),
        trials_dir=trials_dir,
        agent=agent_config,
        environment=env_config,
    )


async def main():
    parser = argparse.ArgumentParser(
        description="In-process batch eval using Harbor's LocalOrchestrator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--model", required=True, help="Action agent model (e.g., anthropic/claude-opus-4-6)")
    parser.add_argument("--user-model", default="anthropic/claude-opus-4-6", help="User sim model")
    parser.add_argument("--tag", required=True, help="Short tag for this run")
    parser.add_argument("--workers", type=int, default=25, help="Max concurrent trials (default: 25)")
    parser.add_argument("--env-type", default=None, help="Environment: docker, e2b, etc.")
    parser.add_argument("--agent-timeout", type=int, default=None, help="Agent timeout in seconds")
    parser.add_argument("--trials-dir", default=None, help="Trials directory (default: trials/)")
    parser.add_argument("--tasks", default=None, help="Comma-separated task names or globs")
    parser.add_argument("--skip-existing", action="store_true", help="Skip tasks with existing results")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--user-context-chars", type=int, default=3000)
    parser.add_argument("--call-user-on-completion", type=bool, default=True)
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

    print(f"\n{'='*70}")
    print(f"In-Process Eval (Harbor LocalOrchestrator)")
    print(f"{'='*70}")
    print(f"Model:     {args.model}")
    print(f"User sim:  {args.user_model}")
    print(f"Env:       {args.env_type or 'docker (default)'}")
    print(f"Timeout:   {args.agent_timeout or 'default'}s")
    print(f"Tag:       {args.tag}")
    print(f"Workers:   {args.workers}")
    print(f"Trials:    {trials_dir}")
    print(f"Tasks:     {len(task_names)}")
    print(f"{'='*70}\n")

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
        )
        trial_configs.append(tc)

    log.info("Built %d trial configs", len(trial_configs))

    # Run via Harbor's LocalOrchestrator
    start = time.time()
    # Retry on E2B sandbox rate limits (429) with exponential backoff.
    # Retries happen INSIDE the semaphore — a retrying trial holds its
    # concurrency slot, so total E2B pressure stays ≤ n_concurrent_trials.
    # Backoff: 30s → 60s → 120s → 240s → 300s (capped) ≈ 12 min total window.
    retry_config = RetryConfig(
        max_retries=5,
        include_exceptions=["SandboxException"],
        min_wait_sec=30.0,
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

    print(f"\n{'Task':<45} {'Reward':>7} {'Status':<10}")
    print("-" * 70)
    def _extract_reward(r):
        if r.verifier_result and r.verifier_result.rewards is not None:
            rv = r.verifier_result.rewards
            return rv.get("reward", 0.0) if isinstance(rv, dict) else float(rv)
        return None

    for r in sorted(results, key=lambda x: x.task_name):
        rv = _extract_reward(r)
        reward = f"{rv:.2f}" if rv is not None else "?"
        status = "error" if r.exception_info else "done"
        print(f"{r.task_name:<45} {reward:>7} {status:<10}")

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
        "results": [
            {
                "task": r.task_name,
                "reward": _extract_reward(r),
                "error": r.exception_info.exception_type if r.exception_info else None,
            }
            for r in results
        ],
    }
    summary_path.write_text(json.dumps(summary_data, indent=2))
    log.info("Summary written to %s", summary_path)


if __name__ == "__main__":
    asyncio.run(main())
