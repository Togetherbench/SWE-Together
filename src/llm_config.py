"""Per-seat LLM backend selection and model-name resolution.

The benchmark has four LLM *seats*::

    agent      the coding agent under evaluation (opencode inside the sandbox)
    user_sim   the simulated user (LiteLLM, host process)
    judge      the agentic correctness judge (`claude --print` in a sandbox)
    tagger     message tagging / intent coverage / intent extraction (LiteLLM, host)

Each seat picks a *backend* — where the model is served::

    bedrock      AWS Bedrock (short-lived AWS credentials, see bedrock_creds.py)
    openrouter   OpenRouter (OPENROUTER_API_KEY)
    native       the vendor's own API: GEMINI_API_KEY / ANTHROPIC_API_KEY / OPENAI_API_KEY

Selection, highest precedence first: CLI flag (``--agent-backend`` …) > the
cohort's ``agent_backend`` in a plan file (agent seat only) > ``SWT_<SEAT>_BACKEND``
> ``SWT_LLM_BACKEND`` > ``native``. ``native`` reproduces the upstream defaults,
so an unset configuration behaves exactly as before.

Models are named by a short *canonical* name (``gpt-5.6-sol``, ``claude-opus-4.6``,
``gemini-3.1-pro``) and :data:`MODEL_REGISTRY` maps it to the id each backend
expects. A name that already carries a provider prefix (``openrouter/meta/…``,
``bedrock/global.openai.…``, ``gemini/…``) is taken verbatim, so every existing
plan file and command line keeps working; the backend is then implied by the prefix.

Resolution produces one *fully-qualified* string in the repo's existing grammar
(``openrouter/<id>``, ``bedrock/<id>``, ``gemini/<id>``, ``anthropic/<id>``, …);
the ``to_*_model`` helpers translate it for each consumer (opencode, LiteLLM,
Claude Code), which is the only place the three tools' spellings differ.
"""
from __future__ import annotations

import json
import logging
import os
import urllib.request
from dataclasses import dataclass, field
from typing import Mapping

log = logging.getLogger(__name__)

SEATS: tuple[str, ...] = ("agent", "user_sim", "judge", "tagger")
BACKENDS: tuple[str, ...] = ("bedrock", "openrouter", "native")
#: Extra backend accepted for the judge only (legacy ``JUDGE_VIA_CODEX=1`` path).
JUDGE_BACKENDS: tuple[str, ...] = BACKENDS + ("codex",)
DEFAULT_BACKEND = "native"

SEAT_BACKEND_VARS = {
    "agent": "SWT_AGENT_BACKEND",
    "user_sim": "SWT_USER_SIM_BACKEND",
    "judge": "SWT_JUDGE_BACKEND",
    "tagger": "SWT_TAGGER_BACKEND",
}
GLOBAL_BACKEND_VAR = "SWT_LLM_BACKEND"

#: Provider prefixes of fully-qualified model strings, by backend.
BEDROCK_PREFIX = "bedrock"
OPENROUTER_PREFIX = "openrouter"
NATIVE_PREFIXES: tuple[str, ...] = ("gemini", "anthropic", "openai")
#: Reasoning-effort values Bedrock accepts (union over model families; each
#: family supports a subset — GPT-5.6 all six, Claude low/high/max).
BEDROCK_EFFORTS: tuple[str, ...] = ("none", "low", "medium", "high", "xhigh", "max")

DEFAULT_AWS_REGION = "us-west-2"
#: Claude Code's background/"small fast" model when the judge runs on Bedrock.
DEFAULT_BEDROCK_SMALL_FAST_MODEL = "global.anthropic.claude-haiku-4-5-20251001-v1:0"


@dataclass(frozen=True)
class ModelSpec:
    canonical: str
    openrouter: str | None = None
    bedrock: str | None = None
    #: Native id plus the provider prefix the repo already uses for it.
    native: str | None = None
    native_provider: str | None = None
    supports_temperature: bool = True
    aliases: tuple[str, ...] = field(default_factory=tuple)

    def id_for(self, backend: str) -> str | None:
        return {
            "openrouter": self.openrouter,
            "bedrock": self.bedrock,
            "native": self.native,
        }.get(backend)

    def backends(self) -> tuple[str, ...]:
        return tuple(b for b in BACKENDS if self.id_for(b))


# Bedrock ids are the ``global.`` inference profiles: they are what the models.dev
# ``amazon-bedrock`` catalog lists, and opencode only generates reasoning
# variants for ids that match that catalog exactly (a miss silently disables
# reasoning). OpenRouter ids use OpenRouter's dotted versions for the same reason.
MODEL_REGISTRY: dict[str, ModelSpec] = {
    s.canonical: s
    for s in (
        ModelSpec("gpt-5.6-sol", openrouter="openai/gpt-5.6-sol",
                  bedrock="global.openai.gpt-5.6-sol", supports_temperature=False,
                  aliases=("gpt-5.6",)),
        ModelSpec("gpt-5.6-luna", openrouter="openai/gpt-5.6-luna",
                  bedrock="global.openai.gpt-5.6-luna", supports_temperature=False),
        ModelSpec("gpt-5.6-terra", openrouter="openai/gpt-5.6-terra",
                  bedrock="global.openai.gpt-5.6-terra", supports_temperature=False),
        ModelSpec("gpt-6-astra", openrouter="openai/gpt-6-astra",
                  bedrock="global.openai.gpt-6-astra", supports_temperature=False,
                  aliases=("gpt-6",)),
        ModelSpec("grok-4.6", openrouter="x-ai/grok-4.6",
                  bedrock="global.xai.grok-4.6", supports_temperature=False,
                  aliases=("grok-4-6",)),
        ModelSpec("claude-opus-4.6", openrouter="anthropic/claude-opus-4.6",
                  bedrock="global.anthropic.claude-opus-4-6-v1",
                  native="claude-opus-4-6", native_provider="anthropic",
                  aliases=("claude-opus-4-6",)),
        ModelSpec("claude-opus-4.7", openrouter="anthropic/claude-opus-4.7",
                  bedrock="global.anthropic.claude-opus-4-7",
                  native="claude-opus-4-7", native_provider="anthropic",
                  aliases=("claude-opus-4-7",)),
        ModelSpec("claude-opus-4.8", openrouter="anthropic/claude-opus-4.8",
                  bedrock="global.anthropic.claude-opus-4-8",
                  native="claude-opus-4-8", native_provider="anthropic",
                  aliases=("claude-opus-4-8",)),
        ModelSpec("claude-opus-5", openrouter="anthropic/claude-opus-5",
                  bedrock="global.anthropic.claude-opus-5",
                  native="claude-opus-5", native_provider="anthropic"),
        ModelSpec("claude-fable-5", openrouter="anthropic/claude-fable-5",
                  bedrock="global.anthropic.claude-fable-5",
                  native="claude-fable-5", native_provider="anthropic",
                  supports_temperature=False),
        ModelSpec("claude-fable-5.1", openrouter="anthropic/claude-fable-5.1",
                  bedrock="global.anthropic.claude-fable-5-1",
                  native="claude-fable-5-1", native_provider="anthropic",
                  supports_temperature=False, aliases=("claude-fable-5-1",)),
        ModelSpec("claude-haiku-4.5", openrouter="anthropic/claude-haiku-4.5",
                  bedrock=DEFAULT_BEDROCK_SMALL_FAST_MODEL,
                  native="claude-haiku-4-5", native_provider="anthropic",
                  aliases=("claude-haiku-4-5",)),
        ModelSpec("gemini-3.1-pro", openrouter="google/gemini-3.1-pro-preview",
                  native="gemini-3.1-pro-preview", native_provider="gemini",
                  aliases=("gemini-3.1-pro-preview",)),
        ModelSpec("gemini-3.8-flash", openrouter="google/gemini-3.8-flash",
                  native="gemini-3.8-flash", native_provider="gemini"),
        ModelSpec("muse-spark-1.3", openrouter="meta/muse-spark-1.3"),
    )
}
_ALIASES: dict[str, str] = {
    alias: spec.canonical for spec in MODEL_REGISTRY.values() for alias in spec.aliases
}


@dataclass(frozen=True)
class ResolvedModel:
    seat: str
    backend: str
    #: Fully-qualified string in the repo grammar, e.g. ``bedrock/global.openai.gpt-5.6-sol``.
    model: str
    spec: ModelSpec | None = None

    @property
    def supports_temperature(self) -> bool:
        return self.spec.supports_temperature if self.spec else True


# ── backend selection ────────────────────────────────────────────────────────

def _validate_backend(value: str, allowed: tuple[str, ...], var: str) -> str:
    v = value.strip().lower()
    if v not in allowed:
        raise SystemExit(f"{var}={value!r}; expected one of {', '.join(allowed)}")
    return v


def seat_backend(seat: str, cli_value: str | None = None, plan_value: str | None = None) -> str:
    """Backend for ``seat``: CLI > plan file > SWT_<SEAT>_BACKEND > SWT_LLM_BACKEND > native."""
    if seat not in SEATS:
        raise ValueError(f"unknown seat {seat!r}; expected one of {SEATS}")
    allowed = JUDGE_BACKENDS if seat == "judge" else BACKENDS
    if cli_value:
        return _validate_backend(cli_value, allowed, f"--{seat.replace('_', '-')}-backend")
    if plan_value:
        return _validate_backend(plan_value, allowed, f"plan {seat}_backend")
    var = SEAT_BACKEND_VARS[seat]
    if os.environ.get(var):
        return _validate_backend(os.environ[var], allowed, var)
    if os.environ.get(GLOBAL_BACKEND_VAR):
        return _validate_backend(os.environ[GLOBAL_BACKEND_VAR], BACKENDS, GLOBAL_BACKEND_VAR)
    return DEFAULT_BACKEND


def split_model(model: str) -> tuple[str | None, str]:
    """``'openrouter/meta/x'`` → ``('openrouter', 'meta/x')``; bare names → ``(None, name)``."""
    if "/" in model:
        provider, rest = model.split("/", 1)
        return provider, rest
    return None, model


def backend_of(model: str) -> str:
    """Backend implied by a fully-qualified model string's prefix."""
    provider, _ = split_model(model)
    if provider == BEDROCK_PREFIX:
        return "bedrock"
    if provider == OPENROUTER_PREFIX:
        return "openrouter"
    if provider == "codex":
        return "codex"
    return "native"


def is_bedrock(model: str) -> bool:
    return backend_of(model) == "bedrock"


def lookup(name: str) -> ModelSpec | None:
    return MODEL_REGISTRY.get(_ALIASES.get(name, name))


def resolve_seat_model(seat: str, raw: str, backend: str) -> ResolvedModel:
    """Turn a canonical name (or a legacy fully-qualified string) into a fully-qualified model.

    A ``raw`` with a provider prefix passes through unchanged and overrides
    ``backend`` (the prefix *is* the backend). A bare name is looked up in the
    registry for ``backend``; an unsupported combination fails with the backends
    that do offer the model. Unknown bare names pass through so the caller's
    existing key-inference behaviour still applies.
    """
    provider, _ = split_model(raw)
    if provider is not None:
        spec = None
        for s in MODEL_REGISTRY.values():
            if raw in (s.openrouter and f"{OPENROUTER_PREFIX}/{s.openrouter}",
                       s.bedrock and f"{BEDROCK_PREFIX}/{s.bedrock}",
                       s.native and f"{s.native_provider}/{s.native}"):
                spec = s
                break
        implied = backend_of(raw)
        if implied != backend and (os.environ.get(SEAT_BACKEND_VARS[seat]) or os.environ.get(GLOBAL_BACKEND_VAR)):
            log.info("%s: model %r carries its own provider prefix; using backend %s", seat, raw, implied)
        return ResolvedModel(seat=seat, backend=implied, model=raw, spec=spec)

    spec = lookup(raw)
    if spec is None:
        log.warning("%s: %r is not in the model registry; passing it through unchanged", seat, raw)
        return ResolvedModel(seat=seat, backend=backend, model=raw, spec=None)
    model_id = spec.id_for(backend)
    if model_id is None:
        offered = ", ".join(spec.backends()) or "none"
        raise SystemExit(
            f"{seat}: model {spec.canonical!r} is not available on backend {backend!r} "
            f"(available: {offered}). Set {SEAT_BACKEND_VARS[seat]} or the --{seat.replace('_', '-')}-backend flag."
        )
    if backend == "bedrock":
        full = f"{BEDROCK_PREFIX}/{model_id}"
    elif backend == "openrouter":
        full = f"{OPENROUTER_PREFIX}/{model_id}"
    else:
        full = f"{spec.native_provider}/{model_id}"
    return ResolvedModel(seat=seat, backend=backend, model=full, spec=spec)


# ── per-consumer translation ─────────────────────────────────────────────────

def to_opencode_model(model: str) -> str:
    """opencode names the Bedrock provider ``amazon-bedrock``."""
    provider, rest = split_model(model)
    if provider == BEDROCK_PREFIX:
        return f"amazon-bedrock/{rest}"
    return model


def to_litellm_model(model: str) -> str:
    """LiteLLM's Bedrock route: force the Converse API for ids its catalog lacks."""
    provider, rest = split_model(model)
    if provider == BEDROCK_PREFIX and not rest.startswith(("converse/", "invoke/", "converse_like/")):
        return f"bedrock/converse/{rest}"
    return model


def to_claude_code_model(model: str) -> str:
    """The ``--model`` value for ``claude --print``: bare id on Bedrock/native, OR id on OpenRouter."""
    provider, rest = split_model(model)
    if provider in (BEDROCK_PREFIX, "anthropic", "codex"):
        return rest
    if provider == OPENROUTER_PREFIX:
        return rest
    return model


def aws_region() -> str:
    return os.environ.get("SWT_AWS_REGION") or os.environ.get("AWS_REGION") or DEFAULT_AWS_REGION


def bedrock_small_fast_model() -> str:
    return os.environ.get("SWT_BEDROCK_SMALL_FAST_MODEL") or DEFAULT_BEDROCK_SMALL_FAST_MODEL


# ── judge ────────────────────────────────────────────────────────────────────

LEGACY_JUDGE_OR_MODEL = "anthropic/claude-opus-4.6"
LEGACY_JUDGE_NATIVE_MODEL = "anthropic/claude-opus-4-6"
LEGACY_JUDGE_CODEX_MODEL = "gpt-5.5"


def judge_model(cli_backend: str | None = None, cli_model: str | None = None) -> ResolvedModel:
    """Resolve the judge seat, honouring the maintainers' ``JUDGE_VIA_OR`` / ``JUDGE_VIA_CODEX`` switches.

    Precedence: explicit backend (flag / ``SWT_JUDGE_BACKEND`` / ``SWT_LLM_BACKEND``) >
    ``JUDGE_VIA_CODEX=1`` > ``JUDGE_VIA_OR=1`` (with ``JUDGE_OR_MODEL``) > native Opus 4.6.
    """
    explicit = bool(cli_backend or os.environ.get(SEAT_BACKEND_VARS["judge"]) or os.environ.get(GLOBAL_BACKEND_VAR))
    via_codex = os.environ.get("JUDGE_VIA_CODEX") == "1"
    via_or = os.environ.get("JUDGE_VIA_OR") == "1"
    if explicit:
        backend = seat_backend("judge", cli_backend)
        if via_codex or via_or:
            log.warning("judge: JUDGE_VIA_%s is set but the explicit backend %r wins",
                        "CODEX" if via_codex else "OR", backend)
    elif via_codex:
        backend = "codex"
    elif via_or:
        backend = "openrouter"
    else:
        backend = "native"

    raw = cli_model or os.environ.get("SWT_JUDGE_MODEL")
    if backend == "codex":
        model = raw or f"codex/{os.environ.get('CODEX_JUDGE_MODEL', LEGACY_JUDGE_CODEX_MODEL)}"
        if not model.startswith("codex/"):
            model = f"codex/{model}"
        return ResolvedModel(seat="judge", backend="codex", model=model)
    if raw is None:
        if backend == "openrouter":
            raw = f"{OPENROUTER_PREFIX}/{os.environ.get('JUDGE_OR_MODEL', LEGACY_JUDGE_OR_MODEL)}"
        elif backend == "native":
            raw = LEGACY_JUDGE_NATIVE_MODEL
        else:
            raw = "claude-opus-4.6"
    resolved = resolve_seat_model("judge", raw, backend)
    _, rest = split_model(resolved.model)
    if "claude" not in rest.lower() and "anthropic" not in rest.lower():
        raise SystemExit(f"judge: {resolved.model!r} is not a Claude model; the judge runs on Claude Code")
    return resolved


OPENROUTER_ANTHROPIC_BASE_URL = "https://openrouter.ai/api"


def judge_auth_envs(judge: ResolvedModel, env: Mapping[str, str] | None = None) -> dict[str, str]:
    """Environment for ``claude --print`` in the judge sandbox, per backend.

    Pure function of the resolved judge model and ``env`` (defaults to
    ``os.environ``) so it can be unit-tested. The ``codex`` backend needs no
    Claude env (it uploads an auth blob instead) and returns ``{}``.

    ``openrouter``: Claude Code accepts ``ANTHROPIC_AUTH_TOKEN`` against
    OpenRouter's Anthropic-compatible endpoint without the strict
    ``/v1/models`` pre-flight; ``ANTHROPIC_API_KEY`` must be *empty*. The three
    per-tier model vars are pinned to the same slug so any tier dispatch routes
    to the chosen model.

    ``bedrock``: Claude Code's native Bedrock mode. ``ANTHROPIC_MODEL`` is the
    Bedrock id; the small/fast model must also be a Bedrock id or background
    calls hit an unavailable default.
    """
    e = os.environ if env is None else env
    out: dict[str, str] = {}
    _, model_id = split_model(judge.model)
    if judge.backend == "codex":
        return out
    if judge.backend == "openrouter":
        out["ANTHROPIC_BASE_URL"] = OPENROUTER_ANTHROPIC_BASE_URL
        out["ANTHROPIC_AUTH_TOKEN"] = e.get("OPENROUTER_API_KEY", "")
        out["ANTHROPIC_API_KEY"] = ""
        for tier in ("OPUS", "SONNET", "HAIKU"):
            out[f"ANTHROPIC_DEFAULT_{tier}_MODEL"] = model_id
        return out
    if judge.backend == "bedrock":
        out["CLAUDE_CODE_USE_BEDROCK"] = "1"
        for var in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"):
            if e.get(var):
                out[var] = e[var]
        out["AWS_REGION"] = e.get("AWS_REGION") or aws_region()
        out["ANTHROPIC_MODEL"] = model_id
        out["ANTHROPIC_SMALL_FAST_MODEL"] = bedrock_small_fast_model()
        out["ANTHROPIC_API_KEY"] = ""
        return out
    # native: API key preferred, OAuth token otherwise (Claude Code picks the key
    # automatically when both are present).
    api_key = e.get("ANTHROPIC_API_KEY") or ""
    if api_key:
        out["ANTHROPIC_API_KEY"] = api_key
    else:
        out["CLAUDE_CODE_OAUTH_TOKEN"] = e.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    return out


def check_judge_auth(judge: ResolvedModel) -> str | None:
    """Return a problem description if the judge backend cannot authenticate, else None."""
    if judge.backend == "openrouter":
        return None if os.environ.get("OPENROUTER_API_KEY") else "judge backend openrouter needs OPENROUTER_API_KEY"
    if judge.backend == "bedrock":
        import bedrock_creds
        try:
            bedrock_creds.ensure_fresh(strict=True)
        except bedrock_creds.CredentialError as exc:
            return f"judge backend bedrock: {exc}"
        return None
    if judge.backend == "codex":
        from pathlib import Path
        return None if (Path.home() / ".codex" / "auth.json").exists() else "judge backend codex needs ~/.codex/auth.json"
    if os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"):
        return None
    return "judge backend native needs ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN"


def judge_model_label(judge: ResolvedModel) -> str:
    """Label recorded in verdicts. Existing backends keep their historical spelling."""
    _, model_id = split_model(judge.model)
    if judge.backend == "openrouter":
        return f"or:{model_id}"
    if judge.backend == "codex":
        return f"codex:{model_id}"
    if judge.backend == "bedrock":
        return f"bedrock:{model_id}"
    return model_id


# ── catalog check ────────────────────────────────────────────────────────────

MODELS_DEV_URL = "https://models.dev/api.json"


def check_models_dev(provider: str, model_id: str, timeout: float = 5.0) -> str:
    """``'ok'`` if ``provider/model_id`` is in the models.dev catalog, ``'missing'`` if not, ``'offline'`` on error.

    opencode derives reasoning variants and pricing from this catalog; a miss
    means ``--variant`` silently does nothing for that id.
    """
    try:
        # models.dev returns 403 to urllib's default User-Agent.
        req = urllib.request.Request(MODELS_DEV_URL, headers={"User-Agent": "swe-together/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            catalog = json.load(resp)
    except Exception as exc:  # noqa: BLE001 - network is optional here
        log.debug("models.dev unavailable: %s", exc)
        return "offline"
    models = (catalog.get(provider) or {}).get("models") or {}
    return "ok" if model_id in models else "missing"


def warn_if_uncatalogued(model: str) -> None:
    """Log a warning when a Bedrock agent model is not in opencode's catalog."""
    if not is_bedrock(model):
        return
    _, model_id = split_model(model)
    status = check_models_dev("amazon-bedrock", model_id)
    if status == "missing":
        log.warning(
            "%s is not in the models.dev amazon-bedrock catalog; opencode will not "
            "auto-generate reasoning variants or pricing for it. Prefer the ids in "
            "llm_config.MODEL_REGISTRY (global.* inference profiles).", model_id,
        )
    elif status == "offline":
        log.info("models.dev unreachable; skipped catalog check for %s", model_id)
