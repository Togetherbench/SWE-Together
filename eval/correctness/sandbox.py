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
TASKS_DIR = REPO_ROOT / "tasks"

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
    # Read the team prefix from env (default "tb") so the judge reuses the SAME
    # templates Step-0 built. Critical when the prefix was changed (e.g. to
    # "tbalx7") to dodge the shichaopei alias collision — otherwise the judge
    # looks up tb-<task>__<hash>, which resolves to shichaopei's broken template
    # and 404s. Mirrors external/harbor/.../e2b.py prefix logic.
    prefix = os.environ.get("HARBOR_TEAM_PREFIX", "tb").strip()
    p = f"{prefix}-" if prefix else ""
    return f"{p}{task_name}__{h}".replace(".", "-")


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
    # Phase 1/2 split (see eval/correctness/prompts/judge_phase{1,2}_system.md):
    #   phase=1  → DECOMPOSE-ONLY (apply oracle.patch; produce canonical_goals.json)
    #   phase=2  → SCORE-ONLY (apply agent.patch + use frozen rubric from
    #             canonical_goals_json; produce verdict.json with met-per-goal)
    # (Legacy phase=0 single-pass mode removed together with judge_one.py.)
    phase: int = 2
    # Phase-2 only: the FROZEN rubric JSON content (Phase 1's output, read from
    # tasks/<task>/canonical_goals.json on the host and passed in here).
    canonical_goals_json: str = ""
    # Phase-1 fallback only: condensed user dialogue (oracle_intents.json +
    # verbatim user turns from oracle_session.jsonl). Used when `oracle_patch`
    # is empty — some tasks have `_status: no_canonical` with stripped tool_use
    # inputs, so we have the conversation but no reconstructable diff. Phase 1
    # then derives goals from the user's stated intent + test.sh + the
    # buggy-state workspace, instead of from an oracle solution.
    user_dialogue: str = ""


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
    # [judge-via-or] If JUDGE_VIA_OR=1, route `claude --print` through OpenRouter's
    # Anthropic-compat endpoint (https://openrouter.ai/api/v1/messages). Uses
    # pay-per-token OR credit instead of the host's Anthropic OAuth subscription,
    # which avoids the rate-limit ceiling we hit at workers>10 on opus-4-7
    # and gives reproducible cost per judge run.
    judge_via_or = os.environ.get("JUDGE_VIA_OR") == "1"
    or_api_key = os.environ.get("OPENROUTER_API_KEY", "")
    if judge_via_codex and codex_auth_path.exists():
        codex_auth_blob = codex_auth_path.read_text()
        log.info("judge auth: codex via host ~/.codex/auth.json (ChatGPT OAuth)")
    elif judge_via_or and or_api_key:
        # Direct OR routing per
        # https://openrouter.ai/docs/cookbook/coding-agents/claude-code-integration
        # CC accepts ANTHROPIC_AUTH_TOKEN (vs ANTHROPIC_API_KEY) without doing the
        # strict /v1/models/<name> pre-flight that blocked the legacy proxy-stub
        # approach. Required env tuple:
        #   ANTHROPIC_BASE_URL = https://openrouter.ai/api
        #   ANTHROPIC_AUTH_TOKEN = <OR-key>
        #   ANTHROPIC_API_KEY   = "" (MUST be empty — non-empty here breaks auth)
        # Model names use OR's dot notation (anthropic/claude-opus-4.6 NOT -4-6).
        auth_envs["ANTHROPIC_BASE_URL"] = "https://openrouter.ai/api"
        auth_envs["ANTHROPIC_AUTH_TOKEN"] = or_api_key
        auth_envs["ANTHROPIC_API_KEY"] = ""
        or_target = os.environ.get("JUDGE_OR_MODEL", "anthropic/claude-opus-4.6")
        # CC resolves per-tier model from these env vars; pin all three to the
        # same OR slug so any model-tier dispatch routes correctly.
        auth_envs["ANTHROPIC_DEFAULT_OPUS_MODEL"] = or_target
        auth_envs["ANTHROPIC_DEFAULT_SONNET_MODEL"] = or_target
        auth_envs["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = or_target
        log.info("judge auth: claude --print → OpenRouter direct (model=%s)", or_target)
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
        # 1. Apply the right patch to /workspace AS ROOT, depending on phase:
        #   phase=1 (decompose-only)      → oracle.patch (we judge the reference state)
        #   phase=2 (score-only)          → agent.patch (judge what the agent did)
        # Some Dockerfiles never chown the repo to `agent` (e.g.
        # agent-swarm-implement-e71acf doesn't even create an `agent` user;
        # cli-task-7e3475 only chowns /installed-agent). Applying the patch as
        # root sidesteps every permission-denied class. After the apply we
        # chmod world-rwX so the judge agent can still read/run tests against
        # the patched workspace.
        patch_to_apply = inputs.oracle_patch if inputs.phase == 1 else inputs.agent_patch
        await sb.files.write("/tmp/agent.patch", patch_to_apply)
        # Phase-1 with no oracle patch still needs the repo discovery (the
        # judge's first_message references {repo_hint}), but the apply step
        # should be a no-op — the workspace stays in the buggy state and the
        # judge derives goals from user_dialogue.md + test.sh expectations.
        skip_apply = inputs.phase == 1 and not patch_to_apply.strip()
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
            + (
                # No-apply branch: just discover the repo, chmod for judge read
                # access. Used for Phase-1 tasks with no canonical oracle patch.
                'chmod -R a+rwX "$REPO" 2>/dev/null || true'
                if skip_apply
                else
                'git -c safe.directory="*" apply --whitespace=nowarn /tmp/agent.patch && '
                'chmod -R a+rwX "$REPO" 2>/dev/null || true'
            ),
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

        # 2b. Legacy in-sandbox OR proxy — superseded by direct routing per
        # OR's claude-code cookbook. Kept guarded by a deprecated flag for
        # backwards-compat with any one-off experiments that still set it.
        if judge_via_or and or_api_key and os.environ.get("JUDGE_OR_USE_LEGACY_PROXY") == "1":
            or_target_model = os.environ.get("JUDGE_OR_MODEL", "anthropic/claude-opus-4.6")
            proxy_script = '''#!/usr/bin/env python3
"""Minimal OR proxy: GET /v1/models/<*> → 200, POST /v1/messages → rewrite model + forward."""
import http.server, urllib.request, json, sys

TARGET_URL = "https://openrouter.ai/api/v1/messages"
OR_API_KEY = "''' + or_api_key + '''"
REMAP_MODEL = "''' + or_target_model + '''"
PORT = 4210

class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a, **kw): pass  # quiet

    def do_GET(self):
        # Claude CLI probes GET /v1/models/<name> before sending messages.
        # OR returns 404 — we synthesize a 200 with a stub model object.
        if self.path.startswith("/v1/models"):
            body = json.dumps({
                "id": self.path.split("/v1/models/")[-1] or REMAP_MODEL,
                "type": "model",
                "display_name": REMAP_MODEL,
                "created_at": "2024-01-01T00:00:00Z",
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path != "/v1/messages":
            self.send_error(404); return
        n = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(n)
        try:
            body = json.loads(raw)
            body["model"] = REMAP_MODEL
            data = json.dumps(body).encode()
        except Exception as e:
            self.send_error(400, str(e)); return
        # Build forward request — Anthropic format → OR's anthropic-compat endpoint.
        headers = {
            "Content-Type": "application/json",
            "Authorization": "Bearer " + OR_API_KEY,
            "anthropic-version": self.headers.get("anthropic-version", "2023-06-01"),
        }
        # Pass through anthropic-beta (caching hints etc.) only for anthropic/ routes.
        beta = self.headers.get("anthropic-beta", "")
        if beta and REMAP_MODEL.startswith("anthropic/"):
            headers["anthropic-beta"] = beta
        req = urllib.request.Request(TARGET_URL, data=data, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                status = resp.status
                resp_headers = dict(resp.headers)
                resp_body = resp.read()
        except urllib.error.HTTPError as e:
            status = e.code
            resp_body = e.read() if e.fp else b""
            resp_headers = dict(e.headers) if e.headers else {}
        except Exception as e:
            self.send_error(502, str(e)); return
        self.send_response(status)
        for k, v in resp_headers.items():
            kl = k.lower()
            if kl in ("transfer-encoding", "content-length", "connection"): continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(resp_body)))
        self.end_headers()
        self.wfile.write(resp_body)

if __name__ == "__main__":
    print(f"OR-proxy: localhost:{PORT} → {TARGET_URL} model={REMAP_MODEL}", flush=True)
    http.server.HTTPServer(("127.0.0.1", PORT), Proxy).serve_forever()
'''
            await sb.files.write("/tmp/or_proxy.py", proxy_script)
            await sb.commands.run(
                "nohup python3 /tmp/or_proxy.py > /tmp/or_proxy.log 2>&1 &",
                timeout=10,
            )
            # Wait for port to bind (poll up to ~5s). Capture proxy log + GET
            # probe output so we can diagnose if it didn't come up.
            probe = await sb.commands.run(
                "for i in 1 2 3 4 5 6 7 8 9 10; do "
                "  if curl -sf http://localhost:4210/v1/models/probe; then "
                "    echo OR_PROXY_UP; exit 0; "
                "  fi; sleep 0.5; done; "
                "echo OR_PROXY_NOT_UP; cat /tmp/or_proxy.log 2>&1; exit 1",
                timeout=15,
            )
            if probe.exit_code != 0 or "OR_PROXY_UP" not in probe.stdout:
                log.warning("OR-proxy DID NOT start: %s", (probe.stdout + probe.stderr)[:500])
            else:
                log.info("OR-proxy started in sandbox: localhost:4210 → %s", or_target_model)

        # 3. Drop input files under the agent user's home — `USER agent` in the
        # task Dockerfile means /judge_inputs/ at root is not writable.
        inputs_dir = "/tmp/judge_inputs"
        tests_dir = f"{inputs_dir}/tests"
        logs_dir = f"{inputs_dir}/logs"
        await sb.commands.run(f"mkdir -p {inputs_dir} {tests_dir} {logs_dir}", timeout=10)
        await sb.files.write(f"{inputs_dir}/README.md", inputs.readme)
        await sb.files.write(f"{inputs_dir}/user_simulation_prompt.md", inputs.user_sim_prompt)
        await sb.files.write(f"{inputs_dir}/oracle.patch", inputs.oracle_patch)
        # Phase-1 fallback file: present only for tasks without an oracle patch.
        # When non-empty, the Phase 1 first_message redirects the judge to read
        # this instead of /tmp/judge_inputs/oracle.patch.
        if inputs.user_dialogue:
            await sb.files.write(f"{inputs_dir}/user_dialogue.md", inputs.user_dialogue)
        # In phase=2 we do NOT need agent.patch as an input (it's already on disk
        # under /workspace), but we DO need the FROZEN rubric. In phase=1 we
        # need oracle.patch as reference reading material (it's also already
        # applied). Keep both files written for legacy compatibility.
        await sb.files.write(f"{inputs_dir}/agent.patch", inputs.agent_patch)
        await sb.files.write(f"{inputs_dir}/test.sh", inputs.test_sh)
        await sb.files.write(f"{inputs_dir}/judge_system.md", inputs.system_prompt)
        # Phase 2 only: upload the frozen rubric from the host so the judge
        # reads it instead of re-deriving goals.
        if inputs.phase == 2 and inputs.canonical_goals_json:
            await sb.files.write(f"{inputs_dir}/canonical_goals.json", inputs.canonical_goals_json)

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
        # First message varies by phase. In phase=1 we instruct the judge to
        # decompose into a rubric; in phase=2 we point it at the frozen rubric.
        if inputs.phase == 1:
            if inputs.oracle_patch.strip():
                first_message = (
                    f"Begin by reading {inputs_dir}/README.md and "
                    f"{inputs_dir}/user_simulation_prompt.md to understand the task. "
                    f"Then read {inputs_dir}/oracle.patch (the reference solution, "
                    f"already applied to {repo_hint}) and explore the workspace. "
                    f"You may run the canonical test.sh to see which F2P tests the "
                    f"oracle satisfies. Decompose the task into completeness goals "
                    f"and write the FROZEN rubric to {inputs_dir}/canonical_goals.json."
                )
            else:
                # No diffable oracle patch — fall back to user-intent dialogue.
                # The workspace is in the BUGGY state (no oracle applied), so
                # the judge derives goals from what the user asked across turns
                # + test.sh's F2P expectations, not from any concrete solution.
                first_message = (
                    f"Begin by reading {inputs_dir}/README.md and "
                    f"{inputs_dir}/user_simulation_prompt.md to understand the task. "
                    f"This task has NO canonical oracle patch (the original session's "
                    f"tool_use inputs were stripped of diffable content). Instead, "
                    f"read {inputs_dir}/user_dialogue.md which contains: (a) the "
                    f"per-turn user intents extracted from the original session, and "
                    f"(b) the verbatim user messages. Derive goals from what the user "
                    f"explicitly asked for + corrections they made + tests in "
                    f"{inputs_dir}/test.sh — those F2P tests are the empirical "
                    f"definition of 'completed'. The workspace at {repo_hint} is in "
                    f"the BUGGY pre-fix state (no oracle applied), so use it for "
                    f"context on the codebase shape but not as evidence of the "
                    f"correct fix. Decompose into completeness goals and write the "
                    f"FROZEN rubric to {inputs_dir}/canonical_goals.json."
                )
        elif inputs.phase == 2:
            first_message = (
                f"Begin by reading {inputs_dir}/canonical_goals.json — this is "
                f"the FROZEN rubric. DO NOT re-derive goals; for each goal in "
                f"the rubric, mark met:true/false with concrete evidence. Then "
                f"read {inputs_dir}/README.md and {inputs_dir}/user_simulation_prompt.md "
                f"for context, inspect the agent's patch at {inputs_dir}/agent.patch "
                f"(already applied to {repo_hint}), explore the workspace, and "
                f"optionally run tests. Write your verdict to "
                f"{inputs_dir}/verdict.json."
            )
        else:
            raise ValueError(
                f"unsupported judge phase={inputs.phase!r}: the legacy single-pass "
                f"mode (phase 0) was removed — use phase 1 (decompose) or 2 (score)."
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
            # When routing through OR, pass the OR-formatted slug directly.
            # CC honors ANTHROPIC_AUTH_TOKEN auth with no /v1/models pre-flight,
            # so the model name is forwarded as-is to OR (no rewriting needed).
            if judge_via_or:
                or_target = os.environ.get("JUDGE_OR_MODEL", "anthropic/claude-opus-4.6")
                judge_model_label = f"or:{or_target}"
                claude_model = or_target  # OR's dot notation, e.g. anthropic/claude-opus-4.6
            else:
                judge_model_label = JUDGE_MODEL_CLAUDE
                claude_model = JUDGE_MODEL_CLAUDE
            # PATH prefix mirrors the install/check step above — required when
            # the binary was on-demand-installed to ~/.local/bin and the
            # shell doesn't source ~/.bashrc.
            judge_cmd = (
                _PATH_PREFIX
                + f"timeout {timeout_sec} claude --print --max-turns {max_turns} "
                f"--model {claude_model} "
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
        log.info("judge exit=%s stdout_len=%d stdout_tail=%r stderr_tail=%r",
                 result.exit_code, len(result.stdout),
                 result.stdout[-400:], (result.stderr or "")[-300:])

        # 4. Pull output file. Phase 1 writes canonical_goals.json; phase 2 +
        # legacy single-pass mode both write verdict.json.
        output_filename = "canonical_goals.json" if inputs.phase == 1 else "verdict.json"
        verdict: dict
        try:
            raw = await sb.files.read(f"{inputs_dir}/{output_filename}")
            verdict = json.loads(raw)
        except Exception as e:
            verdict = {
                "error": "verdict_read_failed",
                "exception": str(e),
                "expected_filename": output_filename,
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
