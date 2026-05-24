"""E2B sandbox wrapper for the agentic judge.

Spins up the task's existing E2B template (built during the original eval run),
applies the agent's patch to /workspace, drops the four input files plus the
judge system prompt into /judge_inputs/, runs `claude --print` headlessly with
a 20-turn / 10-min budget, and pulls back the verdict.json.

The judge uses CLAUDE_CODE_OAUTH_TOKEN (subscription auth, flat cost) — same
mechanism as the existing Opus subscription cohort.
"""
from __future__ import annotations

import json
import logging
import os
import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from dirhash import dirhash
from e2b import AsyncSandbox

log = logging.getLogger(__name__)

REPO_ROOT = Path(__file__).resolve().parents[2]
TASKS_DIR = REPO_ROOT / "harbor_tasks"

JUDGE_TIMEOUT_SEC = 600  # 10 min wall clock for the judge agent itself
JUDGE_TIMEOUT_SEC_HEAVY = 1200  # 20 min for tasks with build_timeout_sec >= 600
                                # (e.g. cc-backend-implement-50b2b1, where the agentic
                                # judge has to wait for `go build` + `go test` on a
                                # ~30k-LOC Go web app — too slow to fit in 600s).
JUDGE_MAX_TURNS = 50  # bumped from 40 — complex tasks (e.g. cli-task-ea3f8f,
                       # sd-scripts-reg-image-dedup) hit "Error: Reached max turns"
                       # before writing verdict.json.
SANDBOX_BUFFER_SEC = 180  # extra time on the sandbox for setup + teardown


def judge_timeout_for_task(task_name: str) -> int:
    """Return the judge sandbox wall-clock budget for this task.

    Heavy-build tasks (those whose task.toml declares `[agent].build_timeout_sec
    >= 600`) need a longer judge window: the agentic judge runs the canonical
    `test.sh`, which can itself spend most of the budget compiling/running the
    upstream project before the judge has any time to think.
    """
    task_toml = TASKS_DIR / task_name / "task.toml"
    if not task_toml.exists():
        return JUDGE_TIMEOUT_SEC
    try:
        # Lightweight regex scan — avoid importing toml just for one field.
        text = task_toml.read_text()
        import re
        m = re.search(r"build_timeout_sec\s*=\s*([0-9.]+)", text)
        if m and float(m.group(1)) >= 600:
            return JUDGE_TIMEOUT_SEC_HEAVY
    except Exception:
        pass
    return JUDGE_TIMEOUT_SEC


def template_alias(task_name: str) -> str:
    """Compute the E2B template alias used by the production eval runs.

    Matches `scripts/build_e2b_templates.py:get_template_alias` and Harbor's
    `external/harbor/src/harbor/environments/e2b.py:_template_name` with
    HARBOR_TEAM_PREFIX="tb".
    """
    env_dir = TASKS_DIR / task_name / "environment"
    h = dirhash(str(env_dir), "sha256")[:8]
    return f"tb-{task_name}__{h}".replace(".", "-")


@dataclass
class JudgeInputs:
    readme: str
    user_sim_prompt: str
    oracle_patch: str
    agent_patch: str
    test_sh: str
    system_prompt: str
    # Full task/tests/ dir as {filename: bytes}. Includes test.sh + install_config.json
    # + log_parsers.py + swe_constants.py + test_manifest.yaml. Mounted into the
    # sandbox so the judge can run the canonical test.sh exactly as Harbor would,
    # not just read it.
    tests_files: dict[str, bytes] = None  # type: ignore[assignment]


JUDGE_MODEL_CLAUDE = "claude-opus-4-6"
JUDGE_MODEL_CODEX_DEFAULT = "gpt-5.5"


@dataclass
class JudgeRunResult:
    verdict: dict  # parsed verdict.json, or {"error": ...} on failure
    stdout: str
    stderr: str
    exit_code: int
    sandbox_id: str
    # Which judge model produced this verdict. Surfaced into the on-disk
    # verdict JSON so post-hoc analyses can tell 4-6 vs 4-7 runs apart, and
    # which trials used the codex-as-judge cross-family calibration.
    judge_model: str = ""


async def run_judge_in_e2b(
    task_name: str,
    trial_id: str,
    inputs: JudgeInputs,
    oauth_token: str,
    *,
    timeout_sec: int = JUDGE_TIMEOUT_SEC,
    max_turns: int = JUDGE_MAX_TURNS,
    api_key: str | None = None,
) -> JudgeRunResult:
    """Run the agentic judge in a fresh E2B sandbox.

    Auth: prefer `api_key` (sk-ant-api03-…, pay-per-token) when supplied,
    otherwise fall back to `oauth_token` (sk-ant-oat01-…, subscription).
    Passing both lets Claude Code in the sandbox pick api_key automatically
    via its standard ANTHROPIC_API_KEY env var.
    """
    alias = template_alias(task_name)
    auth_envs: dict[str, str] = {}
    # [judge-via-codex] If JUDGE_VIA_CODEX=1, swap `claude` for `codex` as the
    # agentic judge. Auth via host's ~/.codex/auth.json (ChatGPT OAuth — same
    # mechanism Harbor uses with CODEX_USE_HOST_AUTH=1 for agent runs).
    judge_via_codex = os.environ.get("JUDGE_VIA_CODEX") == "1"
    codex_auth_path = Path.home() / ".codex" / "auth.json"
    codex_auth_blob: str | None = None
    if judge_via_codex and codex_auth_path.exists():
        codex_auth_blob = codex_auth_path.read_text()
        log.info("judge auth: codex via host ~/.codex/auth.json (ChatGPT OAuth)")
    elif api_key:
        auth_envs["ANTHROPIC_API_KEY"] = api_key
    else:
        auth_envs["CLAUDE_CODE_OAUTH_TOKEN"] = oauth_token or ""

    # Retry sandbox spawn on E2B's flaky HTTP/2 ProtocolError ("Invalid input
    # ConnectionInputs.SEND_SETTINGS in state ConnectionState.CLOSED") — pure
    # infra-side hiccup, common at high concurrency. Up to 3 attempts with
    # exponential backoff. Permanent errors (404 missing template, auth) fail fast.
    import asyncio as _asyncio
    last_err: Exception | None = None
    sb = None
    for attempt in range(3):
        try:
            log.info("spawning E2B sandbox: template=%s trial=%s (attempt %d)", alias, trial_id, attempt + 1)
            sb = await AsyncSandbox.create(
                template=alias,
                envs=auth_envs,
                timeout=timeout_sec + SANDBOX_BUFFER_SEC,
                # Judge needs internet for: (1) claude-code installer when the task
                # image doesn't bake it in, (2) `go mod download` / `pip install`
                # triggered by test.sh on package-touching trials, (3) judge-driven
                # web lookups when it wants to cross-reference upstream. E2B default
                # is True; we pin it so a future SDK default flip doesn't silently
                # break us.
                allow_internet_access=True,
            )
            break
        except Exception as e:
            msg = str(e)
            if "ProtocolError" in type(e).__name__ or "SEND_SETTINGS" in msg or "ConnectionState.CLOSED" in msg:
                last_err = e
                wait = 2 ** attempt  # 1s, 2s, 4s
                log.warning("sandbox spawn ProtocolError attempt %d, retrying in %ds: %s", attempt + 1, wait, msg[:120])
                await _asyncio.sleep(wait)
                continue
            raise
    if sb is None:
        raise last_err or RuntimeError("sandbox spawn failed after retries")
    sandbox_id = sb.sandbox_id

    try:
        # 1. Apply agent patch to /workspace AS ROOT. Some Dockerfiles never
        # chown the repo to `agent` (e.g. agent-swarm-implement-e71acf doesn't
        # even create an `agent` user; cli-task-7e3475 only chowns
        # /installed-agent). Applying the patch as root sidesteps every
        # permission-denied class. After the apply we chmod world-rwX so the
        # judge agent can still read/run tests against the patched workspace.
        await sb.files.write("/tmp/agent.patch", inputs.agent_patch)
        # Repo discovery (mirrors PR #170 in src/user_agent/user_enabled_claude_code.py):
        # the original `cd /workspace; find . -maxdepth 3 -name .git` missed 29
        # tasks whose Dockerfiles clone outside /workspace (/opt/<name>,
        # /home/{agent,user}/..., /app, /repo, /tmp/repo, or filesystem-root
        # oddballs like /entire-cli, /no-magic). For those tasks the judge
        # failed with NO_GIT_REPO_FOUND. Now `find` over the same allowlist
        # of well-known roots (maxdepth 3) so every task layout is covered.
        # HARBOR_REPO_PATHS env var (colon-separated) is the escape hatch
        # for future nonstandard layouts.
        apply = await sb.commands.run(
            "set -e; "
            'ROOTS="/workspace /opt /home /app /repo /tmp /entire-cli /entireio-cli /no-magic"; '
            'if [ -n "${HARBOR_REPO_PATHS:-}" ]; then '
            '  ROOTS="$ROOTS $(echo "$HARBOR_REPO_PATHS" | tr ":" " ")"; '
            'fi; '
            'EXISTING=""; '
            'for r in $ROOTS; do [ -e "$r" ] && EXISTING="$EXISTING $r"; done; '
            'if [ -z "$EXISTING" ]; then echo "NO_REPO_ROOTS_EXIST" >&2; exit 1; fi; '
            'REPO=$(find $EXISTING -maxdepth 3 -name .git \\( -type d -o -type f \\) 2>/dev/null | head -1 | xargs -I{} dirname {}); '
            'if [ -z "$REPO" ]; then echo "NO_GIT_REPO_FOUND" >&2; exit 1; fi; '
            'cd "$REPO" && echo "applying to $(pwd)" && '
            # safe.directory='*' lets root run git on repos owned by `agent`
            # (uid 1001) without "dubious ownership" errors. Common for tasks
            # at /home/agent/<repo> or /workspace/<sub>/ chowned to agent.
            'git -c safe.directory="*" apply --whitespace=nowarn /tmp/agent.patch && '
            'chmod -R a+rwX "$REPO" 2>/dev/null || true',
            timeout=120, user="root",
        )
        if apply.exit_code != 0:
            # Intended judge model (the run errored before we picked which branch);
            # default to the claude path since judge_via_codex requires an explicit opt-in env.
            intended_model = f"codex:{os.environ.get('CODEX_JUDGE_MODEL', JUDGE_MODEL_CODEX_DEFAULT)}" if judge_via_codex else JUDGE_MODEL_CLAUDE
            return JudgeRunResult(
                verdict={"error": "patch_apply_failed",
                         "stdout": apply.stdout[-2000:],
                         "stderr": apply.stderr[-2000:]},
                stdout=apply.stdout, stderr=apply.stderr,
                exit_code=apply.exit_code, sandbox_id=sandbox_id,
                judge_model=intended_model,
            )

        # 2. Ensure claude-code CLI is present. Production task images
        # FROM one of base_images/* which bake in v2.1.108; standalone
        # Dockerfiles (like cli-task-2c3e30 → ubuntu:24.04 and the personA
        # cohort task images) don't, so we install on demand. The official
        # installer is idempotent — `claude` already in PATH is a no-op.
        #
        # PATH gotcha: `claude.ai/install.sh` drops the binary in
        # `$HOME/.local/bin/` and only updates ~/.bashrc to add that to PATH.
        # `sb.commands.run` does NOT source ~/.bashrc, so a subsequent
        # `command -v claude` returns empty even though the binary exists.
        # We explicitly prepend `~/.local/bin` everywhere we look for or run
        # claude (also covers `/root/.local/bin` for tasks that run as root).
        _PATH_PREFIX = "export PATH=\"$HOME/.local/bin:/root/.local/bin:$PATH\"; "
        check_claude = await sb.commands.run(
            _PATH_PREFIX + "command -v claude || true", timeout=10
        )
        if not check_claude.stdout.strip():
            log.info("claude-code not in PATH; installing v2.1.108")
            install = await sb.commands.run(
                "curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.108",
                timeout=180,
            )
            if install.exit_code != 0:
                return JudgeRunResult(
                    verdict={"error": "claude_install_failed",
                             "stderr": install.stderr[-2000:]},
                    stdout=install.stdout, stderr=install.stderr,
                    exit_code=install.exit_code, sandbox_id=sandbox_id,
                    judge_model=JUDGE_MODEL_CLAUDE,
                )
            # Re-verify claude is now resolvable with the PATH prefix.
            # If the installer wrote to a non-standard location we want to
            # fail fast here rather than blow up later inside judge_cmd.
            recheck = await sb.commands.run(
                _PATH_PREFIX + "command -v claude || true", timeout=10
            )
            if not recheck.stdout.strip():
                return JudgeRunResult(
                    verdict={"error": "claude_install_post_check_failed",
                             "install_stdout_tail": install.stdout[-1000:],
                             "install_stderr_tail": install.stderr[-1000:]},
                    stdout=install.stdout, stderr=install.stderr,
                    exit_code=1, sandbox_id=sandbox_id,
                    judge_model=JUDGE_MODEL_CLAUDE,
                )
            log.info("claude-code resolved at: %s", recheck.stdout.strip())

        # 3. Drop input files under the agent user's home — `USER agent` in the
        # task Dockerfile means /judge_inputs/ at root is not writable.
        inputs_dir = "/tmp/judge_inputs"
        tests_dir = f"{inputs_dir}/tests"
        logs_dir = f"{inputs_dir}/logs"
        await sb.commands.run(f"mkdir -p {inputs_dir} {tests_dir} {logs_dir}", timeout=10)
        await sb.files.write(f"{inputs_dir}/README.md", inputs.readme)
        await sb.files.write(f"{inputs_dir}/user_simulation_prompt.md", inputs.user_sim_prompt)
        await sb.files.write(f"{inputs_dir}/oracle.patch", inputs.oracle_patch)
        await sb.files.write(f"{inputs_dir}/agent.patch", inputs.agent_patch)
        await sb.files.write(f"{inputs_dir}/test.sh", inputs.test_sh)
        await sb.files.write(f"{inputs_dir}/judge_system.md", inputs.system_prompt)

        # Mount the task's full tests/ dir so the judge can run the canonical
        # test.sh, not just read it. Mirrors Harbor's verifier mount path.
        for filename, content in (inputs.tests_files or {}).items():
            await sb.files.write(f"{tests_dir}/{filename}", content)
        # test.sh needs to be executable.
        await sb.commands.run(f"chmod +x {tests_dir}/test.sh 2>/dev/null || true", timeout=10)

        # 3. Run judge agent headlessly. `claude --print` runs to completion;
        # --max-turns caps the agentic loop; `timeout` is the hard wall-clock kill.
        # Capture the repo path the patch was applied to (set by the apply step
        # — `echo "applying to $(pwd)"` writes it to stdout). Most tasks clone
        # to /workspace/<sub>/ but ~29 use /opt, /home, /app, /repo, /tmp, or
        # filesystem-root dirs; we surface the discovered path so the judge
        # doesn't waste turns hunting in /workspace when it's empty.
        repo_hint = "/workspace"  # safe default
        for line in apply.stdout.splitlines():
            if line.startswith("applying to "):
                repo_hint = line.removeprefix("applying to ").strip()
                break
        first_message = (
            f"Begin by reading {inputs_dir}/README.md and "
            f"{inputs_dir}/user_simulation_prompt.md. Then evaluate the agent "
            f"solution and write your verdict to {inputs_dir}/verdict.json. "
            f"Use Bash freely to explore the project repo at {repo_hint} "
            f"(the agent's patch has already been applied there) and run tests."
        )
        # `--setting-sources user` skips loading the workspace's .claude/settings.json,
        # which often defines SessionStart/SessionEnd hooks pointing at binaries not in
        # the sandbox PATH (e.g. cli-task-* repos hook to `go run cmd/entire/main.go
        # hooks claude-code session-{start,end}`). Without this, claude exits non-zero
        # at boot before our verdict.json is ever written. cwd=/tmp alone isn't enough
        # because claude code's project-settings loader finds the workspace .claude/
        # via auto-detection independent of cwd.
        if judge_via_codex and codex_auth_blob:
            codex_model = os.environ.get("CODEX_JUDGE_MODEL", JUDGE_MODEL_CODEX_DEFAULT)
            judge_model_label = f"codex:{codex_model}"
            # Upload host OAuth credentials to sandbox CODEX_HOME (default /root/.codex).
            # chmod 600 to keep codex happy about file permissions.
            heredoc_marker = "CODEX_AUTH_EOF"
            await sb.commands.run(
                f"mkdir -p /root/.codex && "
                f"cat > /root/.codex/auth.json <<'{heredoc_marker}'\n"
                f"{codex_auth_blob}\n"
                f"{heredoc_marker}\n"
                f"chmod 600 /root/.codex/auth.json",
                timeout=30, user="root",
            )
            # Codex doesn't have a separate system-prompt flag; concat system + first message.
            # Inline the system-prompt content directly (don't try to shell-expand $(cat ...)
            # — we shlex.quote the final string for safe arg passing, which would prevent
            # expansion anyway).
            full_instruction = (
                f"{inputs.system_prompt}"
                f"\n\n---\n\n"
                f"{first_message}"
            )
            codex_version = os.environ.get("CODEX_CLI_VERSION", "0.133.0")
            # Install codex CLI if not pre-baked, then exec. (~60s install when fresh.)
            judge_cmd = (
                "if ! command -v codex >/dev/null 2>&1; then "
                "  if command -v apk >/dev/null 2>&1; then "
                "    apk add --no-cache nodejs npm >/dev/null 2>&1; "
                "  elif command -v apt-get >/dev/null 2>&1; then "
                "    apt-get update -qq && apt-get install -y -qq nodejs npm >/dev/null 2>&1; "
                "  fi && "
                f"  npm install -g @openai/codex@{codex_version} >/dev/null 2>&1; "
                "fi && "
                f"CODEX_HOME=/root/.codex timeout {timeout_sec} codex exec "
                "--dangerously-bypass-approvals-and-sandbox "
                "--skip-git-repo-check "
                f"--model {codex_model} "
                f"-- {shlex.quote(full_instruction)}"
            )
        else:
            judge_model_label = JUDGE_MODEL_CLAUDE
            # PATH prefix mirrors the install/check step above — required when
            # the binary was on-demand-installed to ~/.local/bin and the
            # shell doesn't source ~/.bashrc.
            judge_cmd = (
                _PATH_PREFIX
                + f"timeout {timeout_sec} claude --print --max-turns {max_turns} "
                f"--model {JUDGE_MODEL_CLAUDE} "
                f"--dangerously-skip-permissions "
                f"--setting-sources user "
                f"--append-system-prompt \"$(cat {inputs_dir}/judge_system.md)\" "
                f"{shlex.quote(first_message)}"
            )
        # Run from /tmp so claude doesn't pick up the repo's
        # .claude/settings.json (which often defines SessionEnd hooks pointing
        # at binaries that don't exist in our sandbox, e.g. cli-task-2c3e30's
        # `go run cmd/entire/main.go hooks claude-code session-end`).
        # /tmp is always writable and exists everywhere, including images
        # where the `agent` user is missing (e.g. agent-swarm-implement-e71acf).
        # Also catch the CommandExitException raised on non-zero exit — claude
        # may have written verdict.json successfully BEFORE the hook failed.
        from e2b.sandbox.commands.command_handle import CommandExitException
        try:
            # codex needs root for apt-get install + npm -g; harmless for claude path.
            judge_user = "root" if (judge_via_codex and codex_auth_blob) else None
            result = await sb.commands.run(
                judge_cmd, timeout=timeout_sec + 60, cwd="/tmp",
                **({"user": judge_user} if judge_user else {}),
            )
            exit_code = result.exit_code
            stdout, stderr = result.stdout, result.stderr
        except CommandExitException as e:
            exit_code = getattr(e, "exit_code", 1)
            stdout = getattr(e, "stdout", "") or ""
            stderr = getattr(e, "stderr", "") or str(e)
            log.warning("judge exited non-zero (%s); attempting verdict read anyway", exit_code)

        class _R:
            pass
        result = _R()
        result.exit_code = exit_code
        result.stdout = stdout
        result.stderr = stderr
        log.info("judge exit=%s stdout_len=%d", result.exit_code, len(result.stdout))

        # 4. Pull verdict
        verdict: dict
        try:
            raw = await sb.files.read(f"{inputs_dir}/verdict.json")
            verdict = json.loads(raw)
        except Exception as e:
            verdict = {
                "error": "verdict_read_failed",
                "exception": str(e),
                "judge_exit_code": result.exit_code,
                "judge_stdout_tail": result.stdout[-2000:],
                "judge_stderr_tail": result.stderr[-2000:],
            }

        return JudgeRunResult(
            verdict=verdict,
            stdout=result.stdout,
            stderr=result.stderr,
            exit_code=result.exit_code,
            sandbox_id=sandbox_id,
            judge_model=judge_model_label,
        )
    finally:
        try:
            await sb.kill()
        except Exception as e:
            log.warning("sandbox kill failed for %s: %s", sandbox_id, e)
