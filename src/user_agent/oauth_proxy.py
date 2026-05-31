"""ChatGPT OAuth → OpenAI Chat Completions proxy.

Translates incoming OpenAI **Chat Completions** requests into ChatGPT's
private **Responses API** backend at `https://chatgpt.com/backend-api/codex`,
using the host user's `~/.codex/auth.json` for OAuth credentials.

Why this exists
---------------
The codex CLI bills against the user's ChatGPT subscription (flat cost) by
calling a private Responses-API endpoint with an OAuth Bearer token. Standard
OpenAI Platform API endpoints (`api.openai.com/v1/chat/completions`,
`api.openai.com/v1/responses`) reject the same Bearer token with
`missing scope` errors — the ChatGPT subscription has no
`model.request` / `api.responses.write` scope.

mini-swe-agent (and anything else built on LiteLLM) hits Chat Completions by
default. This proxy lets those tools transparently use the ChatGPT
subscription billing by:

  client → POST http://localhost:4220/v1/chat/completions
         → [proxy: translate body Chat → Responses, attach OAuth headers]
         → POST https://chatgpt.com/backend-api/codex/responses
         → [proxy: SSE Responses → SSE Chat Completions deltas]
         → client

Coverage
--------
- ✅ Streaming text deltas (`response.output_text.delta`)
- ✅ Reasoning effort pass-through (`reasoning_effort` → `reasoning.effort`)
- ✅ Tools: function-call argument streaming
  (`response.output_item.added`/`function_call_arguments.delta`/
  `output_item.done`) → Chat Completions `tool_calls` deltas
- ✅ Token reload on 401 (re-reads ~/.codex/auth.json — another process or
  manual `codex login` will have refreshed it on disk)
- ⚠️  No automatic refresh-token rotation (would need to replicate codex
  CLI's refresh flow; for typical pilot runs the access_token TTL is
  multi-day so this isn't usually needed)

Usage
-----
Run as a subprocess from the trial wrapper, or standalone:

    .venv/bin/python -m user_agent.oauth_proxy --port 4220

Then point LiteLLM at it:

    OPENAI_BASE_URL=http://localhost:4220/v1
    OPENAI_API_KEY=placeholder           # required by LiteLLM but ignored
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import uuid
from pathlib import Path
from typing import Any

import aiohttp
from aiohttp import web

log = logging.getLogger(__name__)

DEFAULT_AUTH_JSON = Path.home() / ".codex" / "auth.json"
UPSTREAM_URL = "https://chatgpt.com/backend-api/codex/responses"


# ──────────────────────────────────────────────────────────────────────
# Auth: read access_token + account_id from ~/.codex/auth.json
# ──────────────────────────────────────────────────────────────────────

class AuthCache:
    """Lazy-reloadable wrapper over the host's codex OAuth credentials.

    Re-reads `auth.json` from disk on demand (e.g. after a 401), so a
    concurrent codex CLI invocation that rotated the refresh_token is
    automatically picked up.
    """

    def __init__(self, auth_path: Path):
        self.auth_path = Path(auth_path)
        self.access_token: str = ""
        self.account_id: str = ""
        self.reload()

    def reload(self) -> None:
        data = json.loads(self.auth_path.read_text())
        tokens = data.get("tokens") or {}
        self.access_token = tokens.get("access_token", "")
        self.account_id = tokens.get("account_id", "")
        if not self.access_token:
            raise RuntimeError(
                f"No access_token in {self.auth_path} — run `codex login` first"
            )


# ──────────────────────────────────────────────────────────────────────
# Chat Completions request → Responses API request
# ──────────────────────────────────────────────────────────────────────

def chat_to_responses_body(chat_body: dict) -> dict:
    """Convert Chat Completions body → Responses-API body.

    Key transforms:
    - first `role=system` message → top-level `instructions`
    - remaining messages → `input` array (same {role, content} shape)
    - `tools` (Chat Completions schema) → `tools` (Responses-style;
      ChatGPT backend accepts the same OpenAI function-tool schema)
    - `reasoning_effort` → `reasoning.effort`
    - force `store: false` (required by backend; reasoning-summary writes
      are disabled in this codex-bound mode)
    - force `stream: true` (required by backend)
    """
    messages = chat_body.get("messages") or []
    instructions = ""
    input_msgs: list[dict] = []
    for m in messages:
        role = m.get("role")
        if role == "system" and not instructions:
            instructions = _stringify_content(m.get("content"))
            continue
        # ChatGPT's Responses API rejects role="tool" in input items.
        # Tool results live in their own item type: function_call_output.
        if role == "tool":
            input_msgs.append({
                "type": "function_call_output",
                "call_id": m.get("tool_call_id", ""),
                "output": _stringify_content(m.get("content")),
            })
            continue
        # Assistant messages that issued tool calls split into:
        #   (optional) a regular message item carrying any prose
        #   one function_call item per call (call_id + name + arguments)
        if role == "assistant" and m.get("tool_calls"):
            content_str = _stringify_content(m.get("content"))
            if content_str:
                input_msgs.append({
                    "type": "message", "role": "assistant",
                    "content": content_str,
                })
            for tc in m.get("tool_calls") or []:
                fn = tc.get("function") or {}
                input_msgs.append({
                    "type": "function_call",
                    "call_id": tc.get("id", ""),
                    "name": fn.get("name", ""),
                    "arguments": fn.get("arguments", ""),
                })
            continue
        # Plain user / assistant / developer / second-system message.
        input_msgs.append({
            "type": "message", "role": role,
            "content": _normalize_content_for_responses(m.get("content")),
        })

    # LiteLLM passes through the prefixed model name (e.g. "openai/gpt-5.5");
    # ChatGPT's backend only accepts the bare leaf, so strip any provider/.
    raw_model = chat_body.get("model", "gpt-5.5")
    bare_model = raw_model.split("/", 1)[-1] if "/" in raw_model else raw_model
    body: dict[str, Any] = {
        "model": bare_model,
        "instructions": instructions or "You are a helpful assistant.",
        "input": input_msgs,
        "store": False,
        "stream": True,
    }
    if "tools" in chat_body and chat_body["tools"]:
        body["tools"] = [_tool_chat_to_responses(t) for t in chat_body["tools"]]
    if "tool_choice" in chat_body:
        body["tool_choice"] = chat_body["tool_choice"]
    if "parallel_tool_calls" in chat_body:
        body["parallel_tool_calls"] = chat_body["parallel_tool_calls"]
    # reasoning_effort can arrive as top-level (mini-swe-agent style) or
    # nested under extra_body. Either way, lift to reasoning.effort.
    effort = (
        chat_body.get("reasoning_effort")
        or (chat_body.get("extra_body") or {}).get("reasoning_effort")
    )
    if effort:
        # Without `summary` set, ChatGPT's Responses API does NOT emit
        # `response.reasoning_summary_text.delta` events even with effort
        # enabled. "auto" lets the backend choose granularity per request.
        # (codex CLI does the same — see ResponsesApiRequest in codex-rs.)
        body["reasoning"] = {"effort": effort, "summary": "auto"}
    if "temperature" in chat_body:
        body["temperature"] = chat_body["temperature"]
    if "top_p" in chat_body:
        body["top_p"] = chat_body["top_p"]
    return body


def _stringify_content(c: Any) -> str:
    if c is None:
        return ""
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        parts = []
        for part in c:
            if isinstance(part, dict):
                parts.append(part.get("text", ""))
            else:
                parts.append(str(part))
        return "\n".join(p for p in parts if p)
    return str(c)


def _tool_chat_to_responses(tool: dict) -> dict:
    """Convert one Chat Completions tool descriptor to Responses-API shape.

    Chat Completions: {type:"function", function:{name, description, parameters}}
    Responses API:    {type:"function", name, description, parameters}
    (flat — `function` envelope is gone)
    """
    if tool.get("type") != "function":
        # Pass through non-function tool types unchanged (e.g. web_search,
        # image_gen on the Responses side). They use the same flat shape.
        return tool
    fn = tool.get("function") or {}
    out = {"type": "function"}
    for key in ("name", "description", "parameters"):
        if key in fn:
            out[key] = fn[key]
    # Responses-API uses "strict" too, pass through if present
    if "strict" in fn:
        out["strict"] = fn["strict"]
    return out


def _normalize_content_for_responses(c: Any) -> Any:
    """ChatGPT Responses accepts content as string OR list of parts. We
    pass through unchanged when it's already a list of parts; if it's a
    bare string, leave it (backend tolerates both)."""
    if c is None:
        return ""
    return c


# ──────────────────────────────────────────────────────────────────────
# Responses SSE → Chat Completions SSE
# ──────────────────────────────────────────────────────────────────────

class StreamTranslator:
    """Stateful SSE event translator.

    ChatGPT Responses emits structured per-item events; Chat Completions
    is a flat delta stream. We track the per-call_id index so tool-call
    argument deltas accumulate into the right `tool_calls[i]` slot.
    """

    def __init__(self, chat_id: str, model: str):
        self.chat_id = chat_id
        self.model = model
        # item_id → (tool_call_index, function_name, call_id_string)
        self._tool_index: dict[str, tuple[int, str, str]] = {}
        self._next_tool_idx = 0
        self._finish_reason: str | None = None
        self._final_usage: dict | None = None

    def _envelope(self, delta: dict, finish_reason: str | None = None) -> dict:
        return {
            "id": self.chat_id,
            "object": "chat.completion.chunk",
            "model": self.model,
            "choices": [{
                "index": 0,
                "delta": delta,
                "finish_reason": finish_reason,
            }],
        }

    def translate(self, event_type: str, data: dict) -> list[dict]:
        """Return zero or more Chat Completions chunks for this event."""
        if event_type == "response.created":
            # Capture model name if backend echoed a more specific one
            m = (data.get("response") or {}).get("model")
            if m:
                self.model = m
            return [self._envelope({"role": "assistant"})]

        if event_type == "response.output_text.delta":
            delta_text = data.get("delta", "")
            if not delta_text:
                return []
            return [self._envelope({"content": delta_text})]

        # ChatGPT Responses emits reasoning over two parallel SSE streams:
        #   response.reasoning_text.delta          — raw chain-of-thought
        #   response.reasoning_summary_text.delta  — abridged summary
        # Surface both into Chat Completions deltas under `reasoning_content`,
        # the field LiteLLM (and DeepSeek / OpenAI o-series) puts native CoT
        # under. mini-swe-agent's v2 trajectory format preserves provider-
        # specific fields, so the merged reasoning ends up in
        # `provider_specific_fields.reasoning_content` for offline analysis.
        if event_type in (
            "response.reasoning_text.delta",
            "response.reasoning_summary_text.delta",
        ):
            delta_text = data.get("delta", "")
            if not delta_text:
                return []
            return [self._envelope({"reasoning_content": delta_text})]

        if event_type == "response.output_item.added":
            item = data.get("item") or {}
            if item.get("type") == "function_call":
                item_id = item.get("id") or data.get("item_id") or ""
                call_id = item.get("call_id") or item_id
                name = item.get("name", "")
                idx = self._next_tool_idx
                self._next_tool_idx += 1
                self._tool_index[item_id] = (idx, name, call_id)
                return [self._envelope({"tool_calls": [{
                    "index": idx,
                    "id": call_id,
                    "type": "function",
                    "function": {"name": name, "arguments": ""},
                }]})]
            return []

        if event_type == "response.function_call_arguments.delta":
            item_id = data.get("item_id") or ""
            entry = self._tool_index.get(item_id)
            if not entry:
                return []
            idx, _name, _call_id = entry
            return [self._envelope({"tool_calls": [{
                "index": idx,
                "function": {"arguments": data.get("delta", "")},
            }]})]

        if event_type == "response.output_item.done":
            item = data.get("item") or {}
            if item.get("type") == "function_call":
                # Tool call complete — Chat Completions doesn't need a
                # specific event here (the accumulated arguments are
                # already in place); we'll emit finish_reason="tool_calls"
                # on response.completed.
                self._finish_reason = "tool_calls"
            return []

        if event_type == "response.completed":
            # Default to "stop" unless a tool call ended the turn
            chunks = [self._envelope({}, finish_reason=self._finish_reason or "stop")]
            # ChatGPT Responses returns `usage` on response.completed; map to
            # Chat Completions shape so LiteLLM populates response.usage and
            # callers (mini-swe-agent → trajectory) see reasoning_tokens.
            # Without this, the trajectory shows usage all zeros for gpt-5.5
            # via Codex OAuth, making the cohort look like it never thought.
            resp_usage = ((data.get("response") or {}).get("usage")) or {}
            if resp_usage:
                prompt_tokens = resp_usage.get("input_tokens", 0) or 0
                completion_tokens = resp_usage.get("output_tokens", 0) or 0
                reasoning_tokens = (
                    (resp_usage.get("output_tokens_details") or {})
                    .get("reasoning_tokens", 0) or 0
                )
                usage_chunk = {
                    "id": self.chat_id,
                    "object": "chat.completion.chunk",
                    "model": self.model,
                    "choices": [],
                    "usage": {
                        "prompt_tokens": prompt_tokens,
                        "completion_tokens": completion_tokens,
                        "total_tokens": prompt_tokens + completion_tokens,
                        "completion_tokens_details": {
                            "reasoning_tokens": reasoning_tokens,
                        },
                    },
                }
                self._final_usage = usage_chunk["usage"]
                chunks.append(usage_chunk)
            return chunks

        if event_type == "response.failed":
            err = (data.get("response") or {}).get("error") or {}
            log.warning("upstream response.failed: %s", err)
            return [self._envelope(
                {"content": f"\n[proxy: upstream error: {err.get('message','unknown')}]"},
                finish_reason="stop",
            )]

        # Ignore other Responses-API events (in_progress, metadata,
        # reasoning_summary_part.added/done, output_text.done, …)
        return []


# ──────────────────────────────────────────────────────────────────────
# Request handler
# ──────────────────────────────────────────────────────────────────────

async def handle_chat_completions(request: web.Request) -> web.StreamResponse:
    auth: AuthCache = request.app["auth"]
    try:
        chat_body = await request.json()
    except Exception as e:
        return web.json_response({"error": f"bad json: {e}"}, status=400)

    streaming = bool(chat_body.get("stream"))
    upstream_body = chat_to_responses_body(chat_body)
    chat_id = f"chatcmpl-{uuid.uuid4().hex}"
    model = chat_body.get("model", "gpt-5.5")
    translator = StreamTranslator(chat_id, model)

    response = web.StreamResponse(
        headers={
            "Content-Type": "text/event-stream" if streaming else "application/json",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
        }
    )
    await response.prepare(request)

    async def stream_upstream(retry_on_401: bool = True) -> int:
        nonlocal_chunks: list[dict] = []
        headers = _build_headers(auth)
        # aiohttp's ClientTimeout: per-socket read budget covers long SSE streams.
        # We intentionally set total=None — ChatGPT streams can run for minutes.
        timeout = aiohttp.ClientTimeout(
            sock_connect=30, sock_read=600, connect=30, total=None,
        )
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.post(
                UPSTREAM_URL,
                headers=headers, json=upstream_body,
            ) as r:
                if r.status == 401 and retry_on_401:
                    log.warning("upstream 401 — reloading auth.json")
                    auth.reload()
                    return await stream_upstream(retry_on_401=False)
                if r.status >= 400:
                    body_bytes = await r.read()
                    log.error("upstream %d: %s", r.status, body_bytes[:500])
                    err_msg = f"upstream {r.status}: {body_bytes.decode(errors='replace')[:500]}"
                    if streaming:
                        chunk = translator._envelope(
                            {"content": f"[proxy: {err_msg}]"},
                            finish_reason="stop",
                        )
                        await _write_sse_chunk(response, chunk)
                        await response.write(b"data: [DONE]\n\n")
                    else:
                        await response.write(json.dumps({"error": err_msg}).encode())
                    return r.status

                current_event: str | None = None
                # aiohttp StreamReader doesn't have aiter_lines; readline()
                # returns until LF (handles LF/CRLF). Empty bytes ⇒ EOF.
                while True:
                    raw = await r.content.readline()
                    if not raw:
                        break
                    line = raw.rstrip(b"\r\n").decode("utf-8", errors="replace")
                    if not line:
                        current_event = None
                        continue
                    if line.startswith("event:"):
                        current_event = line[6:].strip()
                        continue
                    if line.startswith("data:"):
                        data_str = line[5:].strip()
                        if not data_str or data_str == "[DONE]":
                            continue
                        try:
                            data = json.loads(data_str)
                        except json.JSONDecodeError:
                            continue
                        chunks = translator.translate(current_event or "", data)
                        for ch in chunks:
                            if streaming:
                                await _write_sse_chunk(response, ch)
                            else:
                                nonlocal_chunks.append(ch)
        if streaming:
            await response.write(b"data: [DONE]\n\n")
        else:
            # Coalesce all deltas into one Chat Completions response object
            merged = _coalesce_chunks(nonlocal_chunks, chat_id, model)
            await response.write(json.dumps(merged).encode())
        return 200

    try:
        await stream_upstream()
    except Exception as e:
        log.exception("proxy error")
        if streaming:
            err_chunk = translator._envelope(
                {"content": f"[proxy: {e}]"}, finish_reason="stop",
            )
            await _write_sse_chunk(response, err_chunk)
            await response.write(b"data: [DONE]\n\n")
        else:
            await response.write(json.dumps({"error": str(e)}).encode())

    await response.write_eof()
    return response


def _build_headers(auth: AuthCache) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {auth.access_token}",
        "chatgpt-account-id": auth.account_id,
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        # Identify ourselves as something codex-like to avoid odd backend
        # gating; the backend doesn't enforce a specific UA but be polite.
        "User-Agent": "swe-together-oauth-proxy/0.1 (+codex-compat)",
    }


async def _write_sse_chunk(response: web.StreamResponse, chunk: dict) -> None:
    await response.write(f"data: {json.dumps(chunk)}\n\n".encode())


def _coalesce_chunks(chunks: list[dict], chat_id: str, model: str) -> dict:
    """For non-streaming clients: merge all delta chunks into a single
    Chat Completions response object."""
    content_parts: list[str] = []
    reasoning_parts: list[str] = []
    tool_calls_by_index: dict[int, dict] = {}
    finish_reason: str | None = None
    usage: dict | None = None
    for ch in chunks:
        if ch.get("usage"):
            usage = ch["usage"]
        choice = (ch.get("choices") or [{}])[0]
        delta = choice.get("delta") or {}
        if "content" in delta and delta["content"]:
            content_parts.append(delta["content"])
        if "reasoning_content" in delta and delta["reasoning_content"]:
            reasoning_parts.append(delta["reasoning_content"])
        for tc in delta.get("tool_calls") or []:
            idx = tc.get("index", 0)
            slot = tool_calls_by_index.setdefault(idx, {
                "id": "", "type": "function",
                "function": {"name": "", "arguments": ""},
            })
            if tc.get("id"):
                slot["id"] = tc["id"]
            fn = tc.get("function") or {}
            if fn.get("name"):
                slot["function"]["name"] = fn["name"]
            if fn.get("arguments"):
                slot["function"]["arguments"] += fn["arguments"]
        if choice.get("finish_reason"):
            finish_reason = choice["finish_reason"]
    message: dict[str, Any] = {
        "role": "assistant",
        "content": "".join(content_parts) if content_parts else None,
    }
    if reasoning_parts:
        # LiteLLM surfaces this as message.reasoning_content (DeepSeek /
        # OpenAI o-series compat). For the streaming path the deltas already
        # carry the field; this only matters for the non-streaming fallback.
        message["reasoning_content"] = "".join(reasoning_parts)
    if tool_calls_by_index:
        message["tool_calls"] = [tool_calls_by_index[i] for i in sorted(tool_calls_by_index)]
    return {
        "id": chat_id,
        "object": "chat.completion",
        "model": model,
        "choices": [{
            "index": 0,
            "message": message,
            "finish_reason": finish_reason or "stop",
        }],
        "usage": usage or {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


# ──────────────────────────────────────────────────────────────────────
# /v1/responses passthrough (for clients that already speak Responses API)
# ──────────────────────────────────────────────────────────────────────

def _truncate_responses_input(body: dict, max_bytes: int = 800_000) -> int:
    """In-place trim `body['input']` from the head until the serialized body
    is under `max_bytes`. Returns number of items dropped.

    Why: ChatGPT OAuth's codex/responses backend rejects bodies over ~1MB
    with `{"error":"bad json: Request Entity Too Large"}` (HTTP 400). Long
    multi-turn conversations + tool history serialize past that. OpenCode
    surfaces this as `ContextOverflowError` and tears the whole session
    down — even though the model's actual context window is fine.

    Strategy: keep `instructions` + `tools` + the last KEEP_TAIL `input`
    items (recent user/assistant + tool calls), drop older history first.
    Always preserves at least KEEP_TAIL items, even if that exceeds the
    budget (we'd rather forward and let upstream 413 than ship an empty
    conversation).
    """
    KEEP_TAIL = 8
    items = body.get("input")
    if not isinstance(items, list):
        return 0
    dropped = 0
    while len(items) > KEEP_TAIL:
        if len(json.dumps(body).encode()) < max_bytes:
            return dropped
        items.pop(0)
        dropped += 1
    return dropped


async def handle_responses(request: web.Request) -> web.StreamResponse:
    """Proxy `POST /v1/responses` straight to ChatGPT's codex backend.

    Some clients (e.g. OpenCode's openai provider via the Vercel ai-sdk's
    bun runtime) speak the OpenAI **Responses** API natively rather than
    Chat Completions. We don't need to translate anything — just inject the
    OAuth headers and pipe the SSE stream through.

    Adjustments to the body:
      - strip any `openai/` / `openrouter/` model prefix to the bare leaf
        (ChatGPT's backend only accepts e.g. `gpt-5.5`, not `openai/gpt-5.5`)
      - if `reasoning.effort` is present without `summary`, add `summary=auto`
        so reasoning_summary_text.delta events actually fire
      - inject a minimal `instructions` if missing (codex backend requires it)
      - truncate `input` history if the serialized body exceeds ~800KB
        (codex backend rejects bigger bodies with `Request Entity Too Large`)
    """
    auth: AuthCache = request.app["auth"]
    try:
        body = await request.json()
    except Exception as e:
        return web.json_response({"error": f"bad json: {e}"}, status=400)

    raw_model = body.get("model", "")
    if isinstance(raw_model, str) and "/" in raw_model:
        body["model"] = raw_model.split("/", 1)[-1]

    reasoning = body.get("reasoning")
    if isinstance(reasoning, dict) and reasoning.get("effort") and not reasoning.get("summary"):
        reasoning["summary"] = "auto"

    # ChatGPT's private /backend-api/codex/responses endpoint rejects the
    # request with `{"detail":"Instructions are required"}` if `instructions`
    # is missing or empty. The public OpenAI Responses API tolerates an
    # absent field (defaults to empty system prompt). OpenCode's openai
    # provider follows the public spec, so its turn-0 and resume bodies
    # both omit `instructions`. Inject a minimal default when missing so
    # we don't 400 every model call.
    if not body.get("instructions"):
        body["instructions"] = "You are a helpful assistant."

    # Trim oldest history if the body would 413 upstream (see helper docstring).
    dropped = _truncate_responses_input(body)
    if dropped:
        log.warning("responses: trimmed %d oldest input items to fit body size", dropped)

    streaming = bool(body.get("stream"))
    response = web.StreamResponse(
        headers={
            "Content-Type": "text/event-stream" if streaming else "application/json",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
        }
    )
    await response.prepare(request)

    async def proxy(retry_on_401: bool = True) -> int:
        headers = _build_headers(auth)
        timeout = aiohttp.ClientTimeout(
            sock_connect=30, sock_read=600, connect=30, total=None,
        )
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.post(
                UPSTREAM_URL, headers=headers, json=body,
            ) as r:
                if r.status == 401 and retry_on_401:
                    log.warning("upstream 401 — reloading auth.json")
                    auth.reload()
                    return await proxy(retry_on_401=False)
                if r.status >= 400:
                    body_bytes = await r.read()
                    log.error("upstream %d: %s", r.status, body_bytes[:500])
                    if streaming:
                        # Emit a properly-typed Responses-API event so the
                        # client's ai-sdk parser doesn't choke on schema
                        # validation. Without a `type` field, ai-sdk's
                        # zod-style validator throws
                        # "Type validation failed: Value: {error:...}" and
                        # the whole OpenCode session dies. `response.failed`
                        # is the documented terminal event for failed runs.
                        err_payload = body_bytes.decode(errors="replace")[:1000]
                        failed_event = {
                            "type": "response.failed",
                            "response": {
                                "id": "resp_proxy_error",
                                "object": "response",
                                "status": "failed",
                                "error": {
                                    "code": f"upstream_{r.status}",
                                    "message": err_payload,
                                },
                            },
                        }
                        await response.write(b"event: response.failed\n")
                        await response.write(
                            f"data: {json.dumps(failed_event)}\n\n".encode()
                        )
                        await response.write(b"data: [DONE]\n\n")
                    else:
                        await response.write(body_bytes)
                    return r.status
                # Pass through SSE bytes verbatim — OpenCode already parses
                # native Responses-API events, no translation needed.
                async for chunk in r.content.iter_any():
                    if chunk:
                        await response.write(chunk)
        return 200

    try:
        await proxy()
    except Exception as e:
        log.exception("responses-proxy error")
        if streaming:
            await response.write(f"data: {{\"error\":\"proxy {e}\"}}\n\n".encode())
            await response.write(b"data: [DONE]\n\n")
        else:
            await response.write(json.dumps({"error": str(e)}).encode())
    await response.write_eof()
    return response


# ──────────────────────────────────────────────────────────────────────
# Health + models endpoints (LiteLLM probes /models before /chat/completions)
# ──────────────────────────────────────────────────────────────────────

async def handle_models(request: web.Request) -> web.Response:
    """Minimal /v1/models response so LiteLLM's pre-flight probe passes."""
    return web.json_response({
        "object": "list",
        "data": [
            {"id": "gpt-5.5", "object": "model", "owned_by": "openai"},
            {"id": "gpt-5", "object": "model", "owned_by": "openai"},
            {"id": "gpt-4.1", "object": "model", "owned_by": "openai"},
        ],
    })


async def handle_health(request: web.Request) -> web.Response:
    auth: AuthCache = request.app["auth"]
    return web.json_response({
        "ok": True,
        "account_id": auth.account_id,
        "access_token_len": len(auth.access_token),
        "upstream": UPSTREAM_URL,
    })


# ──────────────────────────────────────────────────────────────────────
# Entry point
# ──────────────────────────────────────────────────────────────────────

async def run_proxy(host: str, port: int, auth_path: Path) -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s [oauth_proxy] %(message)s",
    )
    auth = AuthCache(auth_path)
    app = web.Application()
    app["auth"] = auth
    app.router.add_post("/v1/chat/completions", handle_chat_completions)
    app.router.add_post("/v1/responses", handle_responses)
    app.router.add_get("/v1/models", handle_models)
    app.router.add_get("/health", handle_health)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, host, port)
    await site.start()
    log.info("listening on http://%s:%d", host, port)
    log.info("upstream: %s", UPSTREAM_URL)
    log.info("auth: %s (account_id=%s)", auth_path, auth.account_id)
    log.info("client config:")
    log.info("  OPENAI_BASE_URL=http://%s:%d/v1", host, port)
    log.info("  OPENAI_API_KEY=placeholder")
    await asyncio.Event().wait()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=4220)
    parser.add_argument("--auth-json", default=str(DEFAULT_AUTH_JSON))
    args = parser.parse_args()
    asyncio.run(run_proxy(args.host, args.port, Path(args.auth_json)))


if __name__ == "__main__":
    main()
