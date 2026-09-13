"""Sandbox wrapper for the agentic judge.

Spins up a sandbox from the task's image (E2B template, or an enroot container
of the same image when ``JUDGE_SANDBOX=enroot`` — see ``judge_sandbox.py``),
applies the agent's patch to /workspace, drops the four input files plus the
judge system prompt into /tmp/judge_inputs/, runs `claude --print` headlessly
with a turn / wall-clock budget, and pulls back the verdict.json.

Auth: ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN (subscription), or
JUDGE_VIA_OR=1 (OpenRouter's Anthropic-compatible endpoint).
"""
from __future__ import annotations

import json
import re
import logging
import os
import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from dirhash import dirhash

from eval.correctness.judge_sandbox import CmdResult, open_judge_sandbox
import llm_config  # noqa: E402  (src/ is on sys.path via judge_sandbox)
from patch_normalize import apply_candidates as _patch_apply_candidates, main_repo_path as _patch_main_repo  # noqa: E402

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


JUDGE_MODEL_CLAUDE = llm_config.LEGACY_JUDGE_NATIVE_MODEL.split("/", 1)[1]  # "claude-opus-4-6"
JUDGE_MODEL_CODEX_DEFAULT = llm_config.LEGACY_JUDGE_CODEX_MODEL


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
    # Where that model was served (native | openrouter | bedrock | codex).
    judge_backend: str = ""


async def run_judge(
    task_name: str,
    trial_id: str,
    inputs: JudgeInputs,
    oauth_token: str,
    *,
    timeout_sec: int = JUDGE_TIMEOUT_SEC,
    max_turns: int = JUDGE_MAX_TURNS,
    api_key: str | None = None,
) -> JudgeRunResult:
    """Run the agentic judge in a fresh sandbox (E2B or enroot, per JUDGE_SANDBOX).

    Auth: prefer `api_key` (sk-ant-api03-…, pay-per-token) when supplied,
    otherwise fall back to `oauth_token` (sk-ant-oat01-…, subscription).
    Passing both lets Claude Code in the sandbox pick api_key automatically
    via its standard ANTHROPIC_API_KEY env var.
    """
    alias = template_alias(task_name)
    # Judge seat: which Claude and where it is served (docs/llm_backends.md).
    # Honours the legacy JUDGE_VIA_OR / JUDGE_VIA_CODEX switches; an explicit
    # SWT_JUDGE_BACKEND wins. Re-resolved per trial so refreshed Bedrock
    # credentials in os.environ reach every new sandbox.
    judge = llm_config.judge_model()
    judge_via_codex = judge.backend == "codex"
    codex_auth_path = Path.home() / ".codex" / "auth.json"
    codex_auth_blob: str | None = None
    if judge_via_codex and codex_auth_path.exists():
        # [judge-via-codex] Swap `claude` for `codex` as the agentic judge. Auth
        # via host's ~/.codex/auth.json (ChatGPT OAuth — same mechanism Harbor
        # uses with CODEX_USE_HOST_AUTH=1 for agent runs).
        codex_auth_blob = codex_auth_path.read_text()
        log.info("judge auth: codex via host ~/.codex/auth.json (ChatGPT OAuth)")
    if judge.backend == "bedrock":
        import bedrock_creds
        bedrock_creds.ensure_fresh()
    env_view = dict(os.environ)
    if api_key:
        env_view["ANTHROPIC_API_KEY"] = api_key
    if oauth_token:
        env_view.setdefault("CLAUDE_CODE_OAUTH_TOKEN", oauth_token)
    auth_envs: dict[str, str] = llm_config.judge_auth_envs(judge, env_view)
    if judge.backend == "openrouter":
        # [judge-via-or] `claude --print` through OpenRouter's Anthropic-compat
        # endpoint: pay-per-token OR credit instead of the host's Anthropic OAuth
        # subscription, which avoids the rate-limit ceiling hit at workers>10 on
        # opus-4-7 and gives reproducible cost per judge run.
        log.info("judge auth: claude --print → OpenRouter direct (model=%s)", judge.model)
    elif judge.backend == "bedrock":
        log.info("judge auth: claude --print → AWS Bedrock (model=%s, region=%s)",
                 judge.model, auth_envs.get("AWS_REGION"))
    judge_model_label = llm_config.judge_model_label(judge)
    claude_model = llm_config.to_claude_code_model(judge.model)

    # Sandbox spawn. The E2B backend retries its flaky HTTP/2 ProtocolError
    # internally; enroot creates a container from the task's .sqsh. Both need
    # internet: (1) claude-code installer when the task image doesn't bake it
    # in, (2) `go mod download` / `pip install` triggered by test.sh on
    # package-touching trials, (3) judge-driven web lookups.
    log.info("spawning judge sandbox: task=%s trial=%s", task_name, trial_id)
    sb = await open_judge_sandbox(
        task_name=task_name, e2b_template=alias, envs=auth_envs,
        timeout_sec=timeout_sec, buffer_sec=SANDBOX_BUFFER_SEC,
    )
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
        # `git apply` rejects two artefacts of the harness's own diff capture:
        # the `=== <repo> (cumulative vs harbor-base) ===` banner line, and a
        # last hunk whose trailing blank context line was lost (patches recorded
        # before repo_diff._trim_diff). patch_normalize yields one or two
        # reconstructions (they differ only in that unknowable whitespace line);
        # the first that `git apply --check` accepts is applied. Candidate 0 is
        # written first so the judge's /tmp/agent.patch is always populated.
        candidates = _patch_apply_candidates(patch_to_apply) or [""]
        for i, cand in enumerate(candidates):
            await sb.write(f"/tmp/agent.patch.{i}", cand)
        await sb.write("/tmp/agent.patch", candidates[0])
        n_candidates = len(candidates)
        # The recorder names the task repo in its first banner; prefer it over
        # filesystem discovery, whose `find | head -1` can land on a nested
        # submodule (nunchaku: /workspace/nunchaku before /workspace) or a
        # scratch clone the agent made under /tmp.
        hinted_repo = _patch_main_repo(patch_to_apply) or ""
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
        apply = await sb.run(
            "set -e; "
            f'HINT={shlex.quote(hinted_repo)}; '
            'ROOTS="/workspace /opt /home /app /repo /tmp /entire-cli /entireio-cli /no-magic"; '
            'if [ -n "${HARBOR_REPO_PATHS:-}" ]; then '
            '  ROOTS="$ROOTS $(echo "$HARBOR_REPO_PATHS" | tr ":" " ")"; '
            'fi; '
            'EXISTING=""; '
            'for r in $ROOTS; do [ -e "$r" ] && EXISTING="$EXISTING $r"; done; '
            'if [ -z "$EXISTING" ]; then echo "NO_REPO_ROOTS_EXIST" >&2; exit 1; fi; '
            # Prefer the repo the recorder named; otherwise the shallowest .git
            # (shortest path), so a nested submodule never shadows its parent.
            'REPO=""; '
            'if [ -n "$HINT" ] && [ -e "$HINT/.git" ]; then REPO="$HINT"; fi; '
            'if [ -z "$REPO" ]; then '
            '  REPO=$(find $EXISTING -maxdepth 3 -name .git \\( -type d -o -type f \\) 2>/dev/null '
            '         | while IFS= read -r g; do printf "%d %s\\n" "${#g}" "$g"; done | sort -n | head -1 | cut -d" " -f2- | xargs -I{} dirname {}); '
            'fi; '
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
                # The chmod is best-effort; the apply is not. Keep `|| true`
                # scoped to the chmod so a rejected patch surfaces as
                # patch_apply_failed instead of the judge scoring an unmodified
                # workspace as "incorrect". Try each candidate with --check and
                # apply the first that fits; publish it as /tmp/agent.patch so
                # the judge reads exactly what was applied.
                'APPLIED=""; for i in $(seq 0 %d); do '
                '  if git -c safe.directory="*" apply --check --whitespace=nowarn "/tmp/agent.patch.$i" 2>/dev/null; then '
                '    git -c safe.directory="*" apply --whitespace=nowarn "/tmp/agent.patch.$i" && cp "/tmp/agent.patch.$i" /tmp/agent.patch && APPLIED=$i; break; '
                '  fi; '
                'done; '
                'if [ -z "$APPLIED" ]; then git -c safe.directory="*" apply --check --whitespace=nowarn /tmp/agent.patch.0; exit 1; fi; '
                'echo "applied candidate $APPLIED"; '
                '{ chmod -R a+rwX "$REPO" 2>/dev/null || true; }' % (n_candidates - 1)
            ),
            timeout=120, user="root",
        )
        if apply.exit_code != 0:
            return JudgeRunResult(
                verdict={"error": "patch_apply_failed",
                         "stdout": apply.stdout[-2000:],
                         "stderr": apply.stderr[-2000:]},
                stdout=apply.stdout, stderr=apply.stderr,
                exit_code=apply.exit_code, sandbox_id=sandbox_id,
                judge_model=judge_model_label, judge_backend=judge.backend,
            )

        # 2. Ensure claude-code CLI is present. Production task images
        # FROM one of base_images/* which bake in v2.1.108; standalone
        # Dockerfiles (like cli-task-2c3e30 → ubuntu:24.04 and the personA
        # cohort task images) don't, so we install on demand. The official
        # installer is idempotent — `claude` already in PATH is a no-op.
        #
        # PATH gotcha: `claude.ai/install.sh` drops the binary in
        # `$HOME/.local/bin/` and only updates ~/.bashrc to add that to PATH.
        # `sb.run` does NOT source ~/.bashrc, so a subsequent
        # `command -v claude` returns empty even though the binary exists.
        # We explicitly prepend `~/.local/bin` everywhere we look for or run
        # claude (also covers `/root/.local/bin` for tasks that run as root).
        _PATH_PREFIX = "export PATH=\"$HOME/.local/bin:/root/.local/bin:$PATH\"; "
        check_claude = await sb.run(
            _PATH_PREFIX + "command -v claude || true", timeout=10
        )
        if not check_claude.stdout.strip():
            log.info("claude-code not in PATH; installing v2.1.108")
            install = await sb.run(
                "curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.108",
                timeout=180,
            )
            if install.exit_code != 0:
                return JudgeRunResult(
                    verdict={"error": "claude_install_failed",
                             "stderr": install.stderr[-2000:]},
                    stdout=install.stdout, stderr=install.stderr,
                    exit_code=install.exit_code, sandbox_id=sandbox_id,
                    judge_model=judge_model_label, judge_backend=judge.backend,
                )
            # Re-verify claude is now resolvable with the PATH prefix.
            # If the installer wrote to a non-standard location we want to
            # fail fast here rather than blow up later inside judge_cmd.
            recheck = await sb.run(
                _PATH_PREFIX + "command -v claude || true", timeout=10
            )
            if not recheck.stdout.strip():
                return JudgeRunResult(
                    verdict={"error": "claude_install_post_check_failed",
                             "install_stdout_tail": install.stdout[-1000:],
                             "install_stderr_tail": install.stderr[-1000:]},
                    stdout=install.stdout, stderr=install.stderr,
                    exit_code=1, sandbox_id=sandbox_id,
                    judge_model=judge_model_label, judge_backend=judge.backend,
                )
            log.info("claude-code resolved at: %s", recheck.stdout.strip())

        # 2b. Legacy in-sandbox OR proxy — superseded by direct routing per
        # OR's claude-code cookbook. Kept guarded by a deprecated flag for
        # backwards-compat with any one-off experiments that still set it.
        or_api_key = auth_envs.get("ANTHROPIC_AUTH_TOKEN", "")
        if judge.backend == "openrouter" and or_api_key and os.environ.get("JUDGE_OR_USE_LEGACY_PROXY") == "1":
            or_target_model = claude_model
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
            await sb.write("/tmp/or_proxy.py", proxy_script)
            await sb.run(
                "nohup python3 /tmp/or_proxy.py > /tmp/or_proxy.log 2>&1 &",
                timeout=10,
            )
            # Wait for port to bind (poll up to ~5s). Capture proxy log + GET
            # probe output so we can diagnose if it didn't come up.
            probe = await sb.run(
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
        await sb.run(f"mkdir -p {inputs_dir} {tests_dir} {logs_dir}", timeout=10)
        await sb.write(f"{inputs_dir}/README.md", inputs.readme)
        await sb.write(f"{inputs_dir}/user_simulation_prompt.md", inputs.user_sim_prompt)
        await sb.write(f"{inputs_dir}/oracle.patch", inputs.oracle_patch)
        # Phase-1 fallback file: present only for tasks without an oracle patch.
        # When non-empty, the Phase 1 first_message redirects the judge to read
        # this instead of /tmp/judge_inputs/oracle.patch.
        if inputs.user_dialogue:
            await sb.write(f"{inputs_dir}/user_dialogue.md", inputs.user_dialogue)
        # In phase=2 we do NOT need agent.patch as an input (it's already on disk
        # under /workspace), but we DO need the FROZEN rubric. In phase=1 we
        # need oracle.patch as reference reading material (it's also already
        # applied). Keep both files written for legacy compatibility.
        await sb.write(f"{inputs_dir}/agent.patch", inputs.agent_patch)
        await sb.write(f"{inputs_dir}/test.sh", inputs.test_sh)
        await sb.write(f"{inputs_dir}/judge_system.md", inputs.system_prompt)
        # Phase 2 only: upload the frozen rubric from the host so the judge
        # reads it instead of re-deriving goals.
        if inputs.phase == 2 and inputs.canonical_goals_json:
            await sb.write(f"{inputs_dir}/canonical_goals.json", inputs.canonical_goals_json)

        # Mount the task's full tests/ dir so the judge can run the canonical
        # test.sh, not just read it. Mirrors Harbor's verifier mount path.
        for filename, content in (inputs.tests_files or {}).items():
            await sb.write(f"{tests_dir}/{filename}", content)
        # test.sh needs to be executable.
        await sb.run(f"chmod +x {tests_dir}/test.sh 2>/dev/null || true", timeout=10)

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
            _, codex_model = llm_config.split_model(judge.model)
            # Upload host OAuth credentials to sandbox CODEX_HOME (default /root/.codex).
            # chmod 600 to keep codex happy about file permissions.
            heredoc_marker = "CODEX_AUTH_EOF"
            await sb.run(
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
            # `claude_model` is the backend's spelling: OR's dotted slug
            # (anthropic/claude-opus-4.6), a Bedrock inference-profile id, or
            # the native name. Resolved once above from llm_config.judge_model().
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
        # A non-zero exit is returned (not raised) by the sandbox layer — claude
        # may have written verdict.json successfully BEFORE a hook failed, so we
        # always attempt the verdict read.
        # codex needs root for apt-get install + npm -g; harmless for claude path.
        judge_user = "root" if (judge_via_codex and codex_auth_blob) else None
        result: CmdResult = await sb.run(
            judge_cmd, timeout=timeout_sec + 60, cwd="/tmp", user=judge_user,
        )
        if result.exit_code != 0:
            log.warning("judge exited non-zero (%s); attempting verdict read anyway", result.exit_code)
        log.info("judge exit=%s stdout_len=%d stdout_tail=%r stderr_tail=%r",
                 result.exit_code, len(result.stdout),
                 result.stdout[-400:], (result.stderr or "")[-300:])

        # 4. Pull output file. Phase 1 writes canonical_goals.json; phase 2 +
        # legacy single-pass mode both write verdict.json.
        output_filename = "canonical_goals.json" if inputs.phase == 1 else "verdict.json"
        verdict: dict
        try:
            raw = await sb.read(f"{inputs_dir}/{output_filename}")
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
        # Provenance: which normalised candidate was applied (repair tooling
        # distinguishes verdicts on the normalised patch from pre-fix ones).
        m_applied = re.search(r"applied candidate (\d+)", apply.stdout or "")
        verdict["patch_applied_candidate"] = int(m_applied.group(1)) if m_applied else None
        verdict["patch_applied_repo"] = repo_hint

        return JudgeRunResult(
            verdict=verdict,
            stdout=result.stdout,
            stderr=result.stderr,
            exit_code=result.exit_code,
            sandbox_id=sandbox_id,
            judge_model=judge_model_label,
            judge_backend=judge.backend,
        )
    finally:
        try:
            await sb.kill()
        except Exception as e:
            log.warning("sandbox kill failed for %s: %s", sandbox_id, e)


# Backwards-compatible name used by run_batch.py and generate_task_goals.py.
run_judge_in_e2b = run_judge
