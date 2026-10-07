"""Serving recipes for self-hosted models: how to launch each one with vLLM and
what opencode must be told about it (models.dev never lists a private server, so
context limits and reasoning variants cannot be auto-discovered).

Keyed by the registry's canonical name; ``served_model_name`` must equal the
registry's ``ModelSpec.vllm`` id — that is the name the relay pins and opencode
requests.
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class ServingSpec:
    canonical: str
    #: Hugging Face repo the weights come from (also the default local dir layout).
    hf_repo: str
    served_model_name: str
    #: Prompt window to serve. Agentic trials run to hundreds of thousands of
    #: tokens; the cap must fit the node's KV budget at the run's concurrency.
    context: int
    #: Max completion tokens opencode may request per turn.
    output: int
    #: ``reasoning_effort`` values the model's chat template distinguishes. The
    #: benchmark default is ``high``; a value outside this set is an error, not a
    #: silent fallback.
    efforts: tuple[str, ...]
    #: Extra ``vllm serve`` arguments from the model's published recipe.
    vllm_args: tuple[str, ...] = ()
    tensor_parallel: int = 8
    #: Pipeline stages when the weights leave too little KV room on one node; the
    #: ``tensor_parallel * pipeline_parallel`` GPUs span several nodes
    #: (``launch.py serve --nodes N``).
    pipeline_parallel: int = 1
    #: The window the model itself supports (``max_position_embeddings``). API-served
    #: rows run at it, so a self-hosted row should too, even if that takes more nodes.
    native_context: int | None = None
    #: Model-specific chat-template switches sent with every request.
    chat_template_kwargs: dict = field(default_factory=dict)


SERVING: dict[str, ServingSpec] = {
    s.canonical: s
    for s in (
        # recipes.vllm.ai/zai-org/GLM-5.3 — FP8 weights, 8×H200-class node. GLM-5.3's
        # template honours reasoning_effort low|high and treats anything else as max.
        # `context` is what one node holds (weights leave ~28 GiB/GPU of KV, ~544K tokens);
        # the native 1M window needs two nodes (TP 8 × PP 2): `launch.py serve --nodes 2`.
        ServingSpec(
            canonical="glm-5.3",
            hf_repo="zai-org/GLM-5.3",
            served_model_name="glm-5.3",
            context=262_144,
            output=65_536,
            efforts=("low", "high", "max"),
            vllm_args=(
                "--kv-cache-dtype", "fp8",
                "--speculative-config.method", "mtp",
                "--speculative-config.num_speculative_tokens", "5",
                "--tool-call-parser", "glm47",
                "--reasoning-parser", "glm47",
                "--enable-auto-tool-choice",
            ),
            tensor_parallel=8,
            pipeline_parallel=2,
            native_context=1_048_576,
        ),
    )
}


def serving_spec(name: str) -> ServingSpec:
    try:
        return SERVING[name]
    except KeyError:
        raise SystemExit(f"no serving recipe for {name!r}; known: {', '.join(sorted(SERVING)) or 'none'}") from None


def spec_for_served_name(served: str) -> ServingSpec | None:
    return next((s for s in SERVING.values() if s.served_model_name == served), None)
