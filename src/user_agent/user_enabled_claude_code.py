"""Claude Code agent wrapper with simulated user injection via --resume.

Multi-turn flow:
  1. Run `claude --print <instruction>` → agent completes first turn
  2. Parse session ID from JSONL logs
  3. Consult UserAgent — if it wants to intervene, run
     `claude --resume <session_id> --print <user_message>`
  4. Repeat until user sim is silent or max turns reached
"""

import json
import logging
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from harbor.agents.installed.base import ExecInput
from harbor.agents.installed.claude_code import ClaudeCode
from harbor.agents.base import BaseAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.llms.lite_llm import LiteLLM

from .repo_config import discover_repo_config_files
from .user_agent import UserAgent, UserDecision

log = logging.getLogger(__name__)

_MAX_RESUME_TURNS = 15
_MAX_CONSECUTIVE_NOOPS = 4  # allow agent to continue N times without user input before stopping


class UserEnabledClaudeCode(BaseAgent):
    """Claude Code + simulated user via sequential --resume invocations."""

    SUPPORTS_ATIF: bool = True

    def __init__(
        self,
        logs_dir: Path,
        model_name: str | None = None,
        *,
        user_model_name: str = "anthropic/claude-opus-4-6",
        user_api_base: str | None = None,
        user_api_key: str | None = None,
        user_temperature: float = 0.5,
        user_context_chars: int = 3000,
        original_user_messages: list[str] | None = None,
        session_analysis: str = "",
        max_messages: int | None = None,
        call_user_on_completion: bool = True,
        **kwargs,
    ):
        super().__init__(logs_dir=logs_dir, model_name=model_name, **kwargs)

        # Compose the real ClaudeCode agent for setup/commands
        self._inner = ClaudeCode(logs_dir=logs_dir, model_name=model_name, **kwargs)

        self._sim_user = UserAgent(
            llm=LiteLLM(
                model_name=user_model_name,
                api_base=user_api_base,
                api_key=user_api_key,
                temperature=user_temperature,
            ),
            original_user_messages=original_user_messages,
            session_analysis=session_analysis,
            max_messages=max_messages,
        )
        self._ctx_budget = max(500, user_context_chars)
        self._check_on_completion = call_user_on_completion
        self._task_instruction = ""
        self._cumulative_output: list[str] = []
        # Timing: wall-clock tracking for turn summaries
        self._start_time: float = 0.0  # set when run() begins
        self._turn_start_time: float = 0.0  # set before each agent turn
        # Global step counter so step IDs don't restart across turns
        self._global_step_id: int = 0

    @staticmethod
    def name() -> str:
        return "user-enabled-claude-code"

    def version(self) -> str | None:
        return self._inner.version()

    async def setup(self, environment: BaseEnvironment) -> None:
        await self._inner.setup(environment)

        # If using a non-Anthropic model via OpenRouter/Fireworks, start a minimal
        # reverse proxy inside the sandbox. Claude Code CLI rejects non-Claude model
        # names, so this proxy remaps the model field. For OpenRouter it also strips
        # the anthropic-beta header (which OpenRouter rejects for non-Anthropic models).
        # For Fireworks, headers pass through as-is (Fireworks handles them natively).
        # No dependencies needed — uses stdlib only.
        proxy_model = os.environ.get("LITELLM_PROXY_MODEL")
        if proxy_model:
            proxy_port = os.environ.get("LITELLM_PROXY_PORT", "4210")
            target_url = os.environ.get("PROXY_TARGET_URL", "https://openrouter.ai/api")
            proxy_api_key = os.environ.get("PROXY_API_KEY") or os.environ.get("OPENROUTER_API_KEY", "")
            is_openrouter_target = "openrouter" in target_url
            # Fallback config (OpenRouter) for 429 rate limits
            fallback_url = os.environ.get("PROXY_FALLBACK_URL", "")
            fallback_key = os.environ.get("PROXY_FALLBACK_KEY", "")
            fallback_model = os.environ.get("PROXY_FALLBACK_MODEL", "")
            log.info("Starting proxy in sandbox: model=%s port=%s target=%s fallback=%s",
                     proxy_model, proxy_port, target_url, fallback_url or "none")

            # Upload a minimal proxy script and start it
            proxy_script = f'''#!/usr/bin/env python3
"""Reverse proxy: remaps model, forwards to target API, falls back to OpenRouter on 429."""
import http.server, urllib.request, ssl, json, sys, threading, time

TARGET = "{target_url}"
PORT = {proxy_port}
API_KEY = "{proxy_api_key}"
REMAP_MODEL = "{proxy_model}"
IS_OPENROUTER = {is_openrouter_target}

# Fallback to OpenRouter on 429 rate limit
FALLBACK_URL = "{fallback_url}"
FALLBACK_KEY = "{fallback_key}"
FALLBACK_MODEL = "{fallback_model}"
MAX_RETRIES = 2
RETRY_DELAY = 5  # seconds
# Cap upstream wait so a stuck OR upstream can't wedge the whole proxy.
# Anthropic Messages API calls in Harbor evals normally finish in <2 min;
# 10 min covers worst-case slow-provider draws on OR (DeepInfra/SiliconFlow).
UPSTREAM_TIMEOUT = 600

class Proxy(http.server.BaseHTTPRequestHandler):
    # [v042-fix-streaming] HTTP/1.1 enables chunked transfer-encoding for
    # streamed SSE pass-through. Without this, BaseHTTPRequestHandler defaults
    # to HTTP/1.0 (no chunking) and we'd have to buffer-then-set-Content-Length,
    # which is the bug we're fixing.
    protocol_version = "HTTP/1.1"

    def _build_request(self, url, body, is_or):
        """Build a request for either primary or OpenRouter fallback."""
        # [v042-fix] Only strip anthropic-beta for NON-Anthropic OR routes.
        # OR rejects anthropic-beta for kimi/minimax/glm/qwen, but Anthropic
        # routed through OR Bedrock honors it — and CC needs it to enable
        # prompt caching (anthropic-beta: prompt-caching-2024-07-31). Without
        # this header, every turn re-sends the full system+tools+history and
        # Opus 4.7 trials cost ~10-20x more than they should.
        # [v043-zai-cache] Also keep beta for z-ai/* routes — z.ai's GLM
        # endpoint supports cache_control: ephemeral when surfaced through
        # OR's Anthropic-compat layer, IF we pin upstream to z-ai (see
        # provider injection in do_POST).
        is_anthropic_route = REMAP_MODEL.startswith("anthropic/")
        is_zai_route = REMAP_MODEL.startswith("z-ai/")
        strip_beta = is_or and not is_anthropic_route and not is_zai_route
        # [v043-ark] ARK Coding Plan (volces.com) requires Bearer auth on the
        # primary path, NOT x-api-key. Anthropic-compat probe confirmed
        # `Authorization: Bearer <key>` returns 200 while `x-api-key` returns 401.
        is_ark = "volces.com" in TARGET
        headers = {{}}
        for k, v in self.headers.items():
            k_lower = k.lower()
            if k_lower in ("host", "content-length"):
                continue
            if strip_beta and k_lower == "anthropic-beta":
                continue
            headers[k] = v
        if is_or:
            headers["Authorization"] = f"Bearer {{FALLBACK_KEY}}"
            headers["HTTP-Referer"] = "https://togetherbench.com"
            headers["X-Title"] = "togetherbench-eval"
            for h in ("x-api-key", "X-Api-Key"):
                headers.pop(h, None)
        elif is_ark:
            headers["Authorization"] = f"Bearer {{API_KEY}}"
            for h in ("x-api-key", "X-Api-Key"):
                headers.pop(h, None)
        else:
            headers["x-api-key"] = API_KEY
        return urllib.request.Request(url, data=body, headers=headers, method="POST")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(length)

        # Rewrite model for primary target
        body_primary = raw_body
        if REMAP_MODEL:
            try:
                data = json.loads(raw_body)
                data["model"] = REMAP_MODEL
                # [v043-zai-cache] Pin OR routing to z-ai upstream when the
                # remapped model is z-ai/*, so the Anthropic-compat call hits
                # z.ai's GLM endpoint (which supports prompt caching) instead
                # of a load-balanced third-party serving glm-5.1.
                if IS_OPENROUTER and REMAP_MODEL.startswith("z-ai/"):
                    data["provider"] = {{"only": ["z-ai"]}}
                body_primary = json.dumps(data).encode()
            except (json.JSONDecodeError, KeyError):
                pass

        url = TARGET + self.path
        ctx = ssl.create_default_context()

        # Try primary
        for attempt in range(MAX_RETRIES + 1):
            req = self._build_request(url, body_primary, IS_OPENROUTER)
            try:
                with urllib.request.urlopen(req, context=ctx, timeout=UPSTREAM_TIMEOUT) as resp:
                    # [v042-fix-streaming] Stream chunks instead of buffering.
                    # CC sends `stream:true`; upstream returns SSE with chunked
                    # transfer-encoding. Old code did `resp.read()` (full
                    # buffer) + Content-Length, making CC's parser see SSE
                    # bytes as a fixed-length JSON body → "Failed to parse JSON".
                    # Now: re-encode chunks as Transfer-Encoding: chunked so CC
                    # sees a real streamed response.
                    self.send_response(resp.status)
                    for k, v in resp.getheaders():
                        if k.lower() in ("content-encoding", "content-length", "transfer-encoding"):
                            continue
                        self.send_header(k, v)
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    while True:
                        chunk = resp.read1(8192)  # read1 = per upstream chunk, doesn't block to fill buffer
                        if not chunk:
                            self.wfile.write(b"0\\r\\n\\r\\n")
                            break
                        self.wfile.write(f"{{len(chunk):x}}\\r\\n".encode() + chunk + b"\\r\\n")
                        self.wfile.flush()
                    return
            except urllib.error.HTTPError as e:
                if e.code == 429 and attempt < MAX_RETRIES:
                    print(f"[proxy] 429 from primary (attempt {{attempt+1}}), retrying in {{RETRY_DELAY}}s...", flush=True)
                    e.read()  # drain
                    time.sleep(RETRY_DELAY)
                    continue
                elif e.code == 429 and FALLBACK_URL and FALLBACK_MODEL:
                    print(f"[proxy] 429 from primary, falling back to OpenRouter/{{FALLBACK_MODEL}}", flush=True)
                    e.read()
                    break  # fall through to fallback
                else:
                    resp_body = e.read()
                    self.send_response(e.code)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(resp_body)))
                    self.end_headers()
                    self.wfile.write(resp_body)
                    return
            except Exception as e:
                err = json.dumps({{"error": {{"message": str(e), "type": "proxy_error"}}}}).encode()
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(err)))
                self.end_headers()
                self.wfile.write(err)
                return

        # Fallback to OpenRouter
        if FALLBACK_URL and FALLBACK_MODEL:
            try:
                data = json.loads(raw_body)
                data["model"] = FALLBACK_MODEL
                body_fb = json.dumps(data).encode()
            except:
                body_fb = raw_body
            fb_url = FALLBACK_URL + self.path
            req = self._build_request(fb_url, body_fb, True)
            try:
                with urllib.request.urlopen(req, context=ctx, timeout=UPSTREAM_TIMEOUT) as resp:
                    # [v042-fix-streaming] Same chunked-streaming pattern as primary path.
                    self.send_response(resp.status)
                    for k, v in resp.getheaders():
                        if k.lower() in ("content-encoding", "content-length", "transfer-encoding"):
                            continue
                        self.send_header(k, v)
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    while True:
                        chunk = resp.read1(8192)
                        if not chunk:
                            self.wfile.write(b"0\\r\\n\\r\\n")
                            break
                        self.wfile.write(f"{{len(chunk):x}}\\r\\n".encode() + chunk + b"\\r\\n")
                        self.wfile.flush()
                    return
            except urllib.error.HTTPError as e:
                resp_body = e.read()
                self.send_response(e.code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(resp_body)))
                self.end_headers()
                self.wfile.write(resp_body)
            except Exception as e:
                err = json.dumps({{"error": {{"message": str(e), "type": "fallback_error"}}}}).encode()
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(err)))
                self.end_headers()
                self.wfile.write(err)
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            body = b'{{"status":"ok"}}'
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, format, *args):
        pass  # suppress logs

server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Proxy)
# Don't keep daemon threads waiting at shutdown — let in-flight requests die
# cleanly instead of pinning the process if a CC call gets cancelled.
server.daemon_threads = True
print(f"Proxy listening on port {{PORT}}")
server.serve_forever()
'''
            from pathlib import Path
            proxy_path = self.logs_dir / "model_proxy.py"
            proxy_path.write_text(proxy_script)

            await environment.upload_file(
                source_path=proxy_path,
                target_path="/tmp/model_proxy.py",
            )

            # Start proxy in background and wait for health
            setup_cmd = (
                f"nohup python3 /tmp/model_proxy.py > /tmp/proxy.log 2>&1 & "
                f"for i in $(seq 1 15); do "
                f"  sleep 1; "
                f"  curl -s http://localhost:{proxy_port}/health > /dev/null 2>&1 && "
                f"  echo 'Proxy ready on port {proxy_port}' && exit 0; "
                f"done; "
                f"echo 'WARNING: proxy not healthy after 15s' >&2; "
                f"cat /tmp/proxy.log >&2; exit 1"
            )
            result = await environment.exec(command=setup_cmd)
            if result.return_code != 0:
                log.warning("Proxy start failed: %s", result.stderr or result.stdout)
            else:
                log.info("Header-strip proxy started successfully")

        # Tag every git repo under /workspace as `harbor-base` so per-turn
        # `git diff` can compare against the pre-agent state even after the
        # agent runs `git commit` mid-trial.  Without this, `git diff HEAD`
        # returns empty after the first commit, silently black-holing all
        # subsequent agent work from our patch capture.
        #
        # v0.4.3 audit refinement: snapshot the WORKING TREE state before
        # tagging.  ~10-20% of task Dockerfiles do post-checkout mutations
        # (`rm -f AGENTS.md CLAUDE.md`, `sed -i`, etc.) without a follow-up
        # `git commit`.  Without the pre-tag snapshot, those Dockerfile
        # mutations show up as phantom "agent edits" in every per-turn diff.
        tag_cmd = (
            'set +e\n'
            'cd /workspace 2>/dev/null || exit 0\n'
            'for d in */; do\n'
            '  if [ -d "$d/.git" ] || [ -f "$d/.git" ]; then\n'
            '    (cd "$d" && \\\n'
            '       git add -A 2>/dev/null && \\\n'
            '       git -c user.email=harbor@base -c user.name=harbor \\\n'
            '         commit --allow-empty -m "harbor-base" --quiet 2>/dev/null && \\\n'
            '       git tag -f harbor-base HEAD 2>/dev/null) || true\n'
            '  fi\n'
            'done\n'
        )
        try:
            await environment.exec(command=tag_cmd, cwd="/workspace",
                                   env={}, timeout_sec=30)
            log.debug("harbor-base tagged in /workspace git repos")
        except Exception as e:
            log.debug("harbor-base tagging failed (best-effort): %s", e)

    # ── session ID extraction ────────────────────────────────────────

    def _find_session_id(self) -> str | None:
        """Parse session ID from Claude Code output.

        Tries three sources in order:
        1. The stream-json stdout captured in _cumulative_output (most reliable —
           the init event always contains session_id)
        2. JSONL session logs on disk via _get_session_dir()
        3. Fallback to directory name

        Source 1 avoids the "Multiple session directories" bug in Harbor's
        _get_session_dir() which returns None when multiple project dirs exist.
        """
        # Source 1: parse from captured stdout (stream-json init event)
        for raw in self._cumulative_output:
            for line in raw.split("\n"):
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                    # The init event has {"type": "system", "subtype": "init", "session_id": "..."}
                    sid = event.get("session_id") or event.get("sessionId")
                    if isinstance(sid, str) and sid:
                        return sid
                except (json.JSONDecodeError, ValueError):
                    continue

        # Source 2: JSONL files on disk
        session_dir = self._inner._get_session_dir()
        if session_dir:
            for jsonl_file in session_dir.glob("*.jsonl"):
                with open(jsonl_file) as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            event = json.loads(line)
                            sid = event.get("sessionId")
                            if isinstance(sid, str) and sid:
                                return sid
                        except json.JSONDecodeError:
                            continue
            # Source 3: directory name
            return session_dir.name

        return None

    # ── resume command builder ───────────────────────────────────────

    def _build_resume_command(self, session_id: str, user_message: str) -> list[ExecInput]:
        """Build claude --resume command to continue with a user message."""
        import shlex
        escaped_message = shlex.quote(user_message)

        # Reuse the inner agent's env setup
        initial_commands = self._inner.create_run_agent_commands("")
        if not initial_commands:
            return []

        # Use the env from the main run command (last one)
        run_env = initial_commands[-1].env or {}

        cli_flags = self._inner.build_cli_flags()
        extra_flags = (cli_flags + " ") if cli_flags else ""

        return [
            ExecInput(
                command=(
                    'export PATH="$HOME/.local/bin:$PATH"; '
                    f"claude --verbose --output-format=stream-json "
                    f"--permission-mode=bypassPermissions "
                    f"--resume {session_id} "
                    f"{extra_flags}"
                    f"--print -- {escaped_message} 2>&1 </dev/null | tee -a "
                    f"/logs/agent/claude-code.txt"
                ),
                env=run_env,
            ),
        ]

    # ── trajectory snapshot for user sim ─────────────────────────────

    def _parse_stream_json(self, raw: str) -> list[str]:
        """Parse Claude Code stream-json output into structured step summaries.

        Converts raw JSONL (thinking, tool_use, text, result) into a format
        similar to Terminus 2's trajectory steps, so the user simulator sees
        structured information instead of raw JSON noise.

        Uses self._global_step_id so step numbers are continuous across turns.
        """
        steps: list[str] = []
        for line in raw.split("\n"):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue

            t = obj.get("type")

            if t == "assistant":
                for block in obj.get("message", {}).get("content", []):
                    bt = block.get("type")
                    if bt == "thinking":
                        self._global_step_id += 1
                        text = block.get("thinking", "")[:300]
                        steps.append(f"[{self._global_step_id}] thinking: {text}")
                    elif bt == "tool_use":
                        self._global_step_id += 1
                        name = block.get("name", "?")
                        inp = block.get("input", {})
                        # Show the most useful part of each tool call
                        if name in ("Bash", "bash"):
                            detail = inp.get("command", "")[:200]
                        elif name in ("Read", "read"):
                            detail = inp.get("file_path", "")
                        elif name in ("Edit", "edit"):
                            detail = inp.get("file_path", "")
                        elif name in ("Write", "write"):
                            detail = inp.get("file_path", "")
                        elif name in ("Grep", "grep"):
                            detail = f'pattern={inp.get("pattern", "")} path={inp.get("path", "")}'
                        elif name in ("Glob", "glob"):
                            detail = inp.get("pattern", "")
                        else:
                            detail = json.dumps(inp)[:200]
                        steps.append(f"[{self._global_step_id}] tool_call({name}): {detail}")
                    elif bt == "text":
                        self._global_step_id += 1
                        text = block.get("text", "")[:300]
                        steps.append(f"[{self._global_step_id}] agent: {text}")

            elif t == "result":
                self._global_step_id += 1
                result = obj.get("result", "")
                if isinstance(result, str):
                    steps.append(f"[{self._global_step_id}] result: {result[:300]}")
                else:
                    steps.append(f"[{self._global_step_id}] result: {json.dumps(result)[:300]}")

        return steps

    def _snapshot_latest_turn(self) -> tuple[str, str]:
        """Return structured steps and raw observation for the LATEST turn only.

        Returns (trajectory, observation) where:
        - trajectory: structured step summary of the latest turn's agent activity
        - observation: the last result/agent text from the latest turn (what the
          agent actually produced, not the full tool-call log)

        Prior turns are already in the user sim's conversation history, so
        re-sending them would cause O(N²) growth and confuse the LLM.
        """
        if not self._cumulative_output:
            return "(nothing yet)", "(nothing yet)"

        # Parse only the latest turn's raw output
        latest_raw = self._cumulative_output[-1]
        steps = self._parse_stream_json(latest_raw)

        if not steps:
            trajectory = latest_raw[:self._ctx_budget] if latest_raw else "(no structured output)"
        else:
            trajectory = "\n".join(steps)

        # Observation: extract the last result/agent text as what the agent
        # actually produced (the user cares about the outcome, not every tool call)
        observation_lines = [s for s in steps if any(
            s.split("] ", 1)[-1].startswith(prefix)
            for prefix in ("result:", "agent:")
        )]
        if observation_lines:
            # Show last few result/agent lines (the actual output)
            observation = "\n".join(observation_lines[-5:])
        else:
            observation = trajectory[-self._ctx_budget:] if trajectory else "(no output)"

        return trajectory, observation

    # ── user simulation ──────────────────────────────────────────────

    async def _consult_user(
        self, trajectory: str, observation: str, turn: int, completing: bool,
        logging_dir: Path | None = None,
    ) -> UserDecision:
        # Compute timing for this turn
        now = time.monotonic()
        elapsed_sec = now - self._start_time if self._start_time else 0
        turn_duration_sec = now - self._turn_start_time if self._turn_start_time else 0

        decision = await self._sim_user.process(
            task_description=self._task_instruction,
            recent_trajectory=trajectory,
            latest_observation=observation,
            latest_analysis=None,
            step_count=turn,
            is_completion_attempt=completing,
            total_steps_so_far=turn,
            elapsed_sec=elapsed_sec,
            turn_duration_sec=turn_duration_sec,
        )
        if decision.has_message:
            self._sim_user.advance_original_index(1)
            log.info("User sim intervenes at turn %d: %s", turn, decision.action)
        else:
            log.debug("User sim waits at turn %d", turn)

        self._log_user_decision(logging_dir, turn, decision, completing)
        return decision

    async def _capture_git_diff(self, environment, turn: int) -> None:
        """Snapshot `git diff HEAD` for every git repo under /workspace.

        Writes to <logs_dir>/patches/turn-<N>.patch. The final turn's patch is
        also copied to <logs_dir>/final.patch for easy access. Best-effort —
        silently no-ops if /workspace has no git repos or exec fails.

        Failure mode this guards against: in v0.4.3 ~65% of trials silently
        wrote git's "Not a git repository" warning + `git diff -h` usage text
        to the patch file because the original cmd used `2>&1` (mixed
        stderr in) and didn't check the exit code.  Downstream replay then
        treated the help text as the agent's diff and applied a "garbage"
        patch.  Fix: capture stdout separately, check exit code, mark
        capture failures explicitly.
        """
        # v0.4.3 fix E: prefer `git diff harbor-base` over `git diff HEAD`.
        # The `harbor-base` tag is set in `setup` to point at the pre-agent
        # commit; using it means we capture cumulative agent work even after
        # `git commit` (under HEAD this would have returned empty post-commit
        # and silently lost the rest of the trial's edits).  Falls back to
        # `git diff HEAD` if the tag doesn't exist (older trials, third-party
        # workspace setups).
        cmd = (
            'set +e\n'
            'cd /workspace 2>/dev/null || exit 0\n'
            'for d in */; do\n'
            '  if [ -d "$d/.git" ] || [ -f "$d/.git" ]; then\n'
            '    BASE_REF=HEAD\n'
            '    if (cd "$d" && git rev-parse --verify harbor-base >/dev/null 2>&1); then\n'
            '      BASE_REF=harbor-base\n'
            '    fi\n'
            '    DIFF_OUT=$(cd "$d" && git --no-pager diff $BASE_REF 2>/dev/null)\n'
            '    DIFF_RC=$?\n'
            '    echo "=== $d ==="\n'
            '    if [ $DIFF_RC -eq 0 ]; then\n'
            '      printf %s "$DIFF_OUT"\n'
            '      echo ""\n'
            '    else\n'
            '      echo "# capture-failed: git diff $BASE_REF exit=$DIFF_RC"\n'
            '    fi\n'
            '  fi\n'
            'done\n'
        )
        try:
            result = await environment.exec(
                command=cmd,
                cwd="/workspace",
                env={},
                timeout_sec=60,
            )
        except Exception as e:
            log.debug("git diff capture failed at turn %d: %s", turn, e)
            return

        if not result.stdout:
            return

        patches_dir = self.logs_dir / "patches"
        patches_dir.mkdir(parents=True, exist_ok=True)
        patch_path = patches_dir / f"turn-{turn}.patch"
        patch_path.write_text(result.stdout)
        # Mirror to final.patch — overwritten each turn so it always reflects
        # the most recent state (== the agent's final candidate at trial end).
        (self.logs_dir / "final.patch").write_text(result.stdout)

    def _log_user_decision(
        self, logging_dir: Path | None, turn: int,
        decision: UserDecision, completing: bool,
    ):
        if logging_dir is None:
            return
        episode_dir = logging_dir / f"episode-{turn}"
        episode_dir.mkdir(parents=True, exist_ok=True)
        record = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "turn": turn,
            "is_completion_attempt": completing,
            "action": decision.action,
            "has_message": decision.has_message,
            "content": decision.content,
            "raw_response": decision.raw_response[:500] if decision.raw_response else "",
            "cursor": self._sim_user._cursor,
            "ground_truth_remaining": len(self._sim_user._ground_truth) - self._sim_user._cursor,
            "stats": self._sim_user.get_stats(),
        }
        path = episode_dir / "user_decision.json"
        path.write_text(json.dumps(record, indent=2, ensure_ascii=False))

    # ── main run ─────────────────────────────────────────────────────

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        # Inject repo config files into the instruction
        config_content = await discover_repo_config_files(environment)
        if config_content:
            instruction = f"{instruction}\n\n{config_content}"

        # Inject incremental-work instruction so CC stops after each sub-task
        # instead of completing everything in one autonomous run. This gives the
        # user sim more opportunities to intervene with corrections/feedback.
        _INCREMENTAL_NOTICE = (
            "\n\nIMPORTANT: Work incrementally. After completing each distinct "
            "sub-task (e.g., implementing one feature, fixing one bug, making one "
            "significant change), STOP and report what you did and what you plan "
            "to do next. Wait for user feedback before proceeding to the next "
            "sub-task. Do NOT implement everything in one go."
        )
        instruction = instruction + _INCREMENTAL_NOTICE

        self._task_instruction = instruction
        self._start_time = time.monotonic()
        self._turn_start_time = self._start_time

        # Turn 0: initial run via inner agent's commands
        commands = self._inner.create_run_agent_commands(instruction)
        try:
            for i, exec_input in enumerate(commands):
                env = exec_input.env
                result = await environment.exec(
                    command=f"set -o pipefail; {exec_input.command}",
                    cwd=exec_input.cwd,
                    env=env,
                    timeout_sec=exec_input.timeout_sec,
                )
                if result.stdout:
                    self._cumulative_output.append(result.stdout)

                command_dir = self.logs_dir / f"command-0-{i}"
                command_dir.mkdir(parents=True, exist_ok=True)
                (command_dir / "command.txt").write_text(exec_input.command)
                (command_dir / "return-code.txt").write_text(str(result.return_code))
                if result.stdout:
                    (command_dir / "stdout.txt").write_text(result.stdout)
                if result.stderr:
                    (command_dir / "stderr.txt").write_text(result.stderr)
        finally:
            # Always capture turn-0 patch — even if the agent's exec crashed
            # mid-stream, the partial workspace state matters.
            await self._capture_git_diff(environment, turn=0)

        # Multi-turn: resume loop
        session_id = self._find_session_id()
        if not session_id:
            log.warning("Could not find Claude Code session ID — skipping user sim turns")
            self._inner.populate_context_post_run(context)
            return

        log.info("Claude Code session ID: %s", session_id)

        consecutive_noops = 0
        for turn in range(1, _MAX_RESUME_TURNS + 1):
            trajectory, observation = self._snapshot_latest_turn()

            # Consult user sim (treat every completed claude run as a "completion")
            decision = await self._consult_user(
                trajectory, observation, turn, completing=True,
                logging_dir=self.logs_dir,
            )

            if not decision.has_message:
                consecutive_noops += 1
                if consecutive_noops >= _MAX_CONSECUTIVE_NOOPS:
                    log.info("User sim silent %d consecutive times at turn %d — ending",
                             consecutive_noops, turn)
                    break
                # No-op means "let the agent keep working" — resume without
                # user input so the agent can continue where it left off.
                log.info("User sim no-op at turn %d (streak %d/%d) — resuming agent",
                         turn, consecutive_noops, _MAX_CONSECUTIVE_NOOPS)
                user_msg = "continue"
            else:
                consecutive_noops = 0
                user_msg = decision.format_for_injection()

            log.info("Resuming claude-code session with user message (turn %d)", turn)
            self._turn_start_time = time.monotonic()

            resume_commands = self._build_resume_command(session_id, user_msg)
            try:
                for j, exec_input in enumerate(resume_commands):
                    result = await environment.exec(
                        command=f"set -o pipefail; {exec_input.command}",
                        cwd=exec_input.cwd,
                        env=exec_input.env,
                        timeout_sec=exec_input.timeout_sec,
                    )
                    if result.stdout:
                        self._cumulative_output.append(result.stdout)

                    command_dir = self.logs_dir / f"command-{turn}-{j}"
                    command_dir.mkdir(parents=True, exist_ok=True)
                    (command_dir / "command.txt").write_text(exec_input.command)
                    (command_dir / "return-code.txt").write_text(str(result.return_code))
                    if result.stdout:
                        (command_dir / "stdout.txt").write_text(result.stdout)
                    if result.stderr:
                        (command_dir / "stderr.txt").write_text(result.stderr)
            finally:
                # Always capture this turn's patch — survives mid-turn exec failures.
                await self._capture_git_diff(environment, turn=turn)

        # Final safety net — re-snapshot at run-end so even if all per-turn
        # captures somehow fail, final.patch reflects the very last state.
        try:
            await self._capture_git_diff(environment, turn=999)
        except Exception as e:
            log.debug("end-of-run patch capture failed: %s", e)

        # Post-run: build trajectory from session logs
        try:
            self._inner.populate_context_post_run(context)
        except Exception as e:
            log.warning("Failed to populate context post-run: %s", e)
