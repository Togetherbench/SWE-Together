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

from harbor.models.trial.config import (
    AgentConfig,
    EnvironmentConfig,
    TaskConfig,
    TrialConfig,
)
from harbor.trial.trial import Trial

from user_agent.user_agent import UserPersona, build_persona_from_analysis

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
log = logging.getLogger("runner")


# ── provider resolution ───────────────────────────────────────────────────────

# Maps LiteLLM provider prefix → (env var name, env var key passed to agent)
_PROVIDER_MAP = {
    "gemini":      ("GEMINI_API_KEY",      "GEMINI_API_KEY"),
    "anthropic":   ("ANTHROPIC_API_KEY",   "ANTHROPIC_API_KEY"),
    "openrouter":  ("OPENROUTER_API_KEY",  "OPENROUTER_API_KEY"),
}


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

    session = json.loads(session_path.read_text())
    return [
        msg.get("content", "")
        for msg in session.get("messages", [])
        if msg.get("role") == "user"
        and isinstance(msg.get("content"), str)
        and not msg["content"].startswith("[Request interrupted")
    ]


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

    log.info("Action agent : %s", action_model)
    log.info("User agent   : %s", user_model)

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

    # Load ground-truth user messages + persona from analysis.json
    analysis = load_analysis(task_dir)
    user_messages = load_user_messages(task_dir, analysis)
    persona: UserPersona = build_persona_from_analysis(analysis)
    log.info("Ground-truth user messages: %d", len(user_messages))

    # Load analysis.md for rich session context (state graph, friction triggers)
    analysis_md_path = task_dir / "analysis.md"
    session_analysis = analysis_md_path.read_text() if analysis_md_path.exists() else ""
    if session_analysis:
        log.info("Loaded analysis.md (%d chars)", len(session_analysis))

    trial_config = TrialConfig(
        task=TaskConfig(path=task_dir),
        trials_dir=Path(args.trials_dir),
        agent=AgentConfig(
            import_path="user_agent.user_enabled_agent:UserEnabledTerminus2",
            model_name=action_model,
            kwargs={
                "user_model_name": user_model,
                "user_api_key": user_key,
                "original_user_messages": user_messages,
                "user_persona": persona,
                "session_analysis": session_analysis,
                "user_context_chars": args.user_context_chars,
                "call_user_on_completion": args.call_user_on_completion,
            },
            env={action_env_var: action_key},
        ),
        environment=EnvironmentConfig(
            delete=not args.keep,
        ),
    )

    trial = Trial(config=trial_config)
    result = await trial.run()

    print("\n" + "=" * 60)
    print(f"  task   : {task_name}")
    rewards = result.verifier_result.rewards if result.verifier_result else None
    reward = rewards.get("reward") if rewards else None
    print(f"  reward : {reward}")
    print(f"  success: {result.exception_info is None}")
    if result.exception_info:
        print(f"  error  : {result.exception_info.exception_type}: {result.exception_info.exception_message}")
    print("=" * 60)

    # Auto-upload traces to Railway S3 if credentials available
    _auto_upload_traces()


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
    parser.add_argument("--trials-dir", default=None,
                        help="Directory for trial results")
    parser.add_argument("--keep",       action="store_true", default=None,
                        help="Keep docker container after run")
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
        trials_dir            = cli.trials_dir or cfg.get("trials_dir", "trials")
        keep                  = cli.keep       or cfg.get("keep_container", False)
        user_context_chars    = cfg.get("user_context_chars",    3000)
        call_user_on_completion = cfg.get("call_user_on_completion", True)

    asyncio.run(run(Args()))


if __name__ == "__main__":
    main()
