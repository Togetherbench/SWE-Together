"""Check Lumina2 prefix loading against real, small CPU model weights."""

import argparse
import json
from pathlib import Path
from types import SimpleNamespace

import torch
import yaml
import comfy.cli_args

# Model imports otherwise select CUDA even though no checkpoint is needed.
comfy.cli_args.args.cpu = True

import comfy.lora as lora
import comfy.model_base as model_base
import comfy.ops
import comfy.utils
from comfy.ldm.lumina.model import NextDiT


class _TinyLumina2(model_base.Lumina2):
    def __init__(self, config: dict) -> None:
        torch.nn.Module.__init__(self)
        self.model_config = SimpleNamespace(unet_config=config)
        self.diffusion_model = NextDiT(
            **config, operations=comfy.ops.disable_weight_init,
            device=torch.device("cpu"), dtype=torch.float32,
        )


def _loads(alias: str, target: str | tuple, state: dict, key_map: dict) -> bool:
    name = target[0] if isinstance(target, tuple) else target
    shape = list(state[name].shape)
    if isinstance(target, tuple):
        axis, start, length = target[1]
        assert start + length <= shape[axis]
        shape[axis] = length
    down = torch.arange(2 * shape[1], dtype=torch.float32).reshape(2, shape[1]) / 100
    up = torch.arange(shape[0] * 2, dtype=torch.float32).reshape(shape[0], 2) / 100
    payload = {alias + ".lora_A.weight": down, alias + ".lora_B.weight": up}
    patches = lora.load_lora(payload, key_map, log_missing=False)
    if set(patches) != {target}:
        return False
    actual = patches[target].calculate_weight(
        torch.zeros(shape), name, 1.0, 1.0, None, lambda value: value,
    )
    return torch.allclose(actual, up @ down)


def _check_model(config: dict) -> dict:
    model = _TinyLumina2(config)
    state = model.state_dict()
    key_map = lora.model_lora_keys_unet(model, key_map={})
    native = {}
    existing = {}
    for name, weight in state.items():
        if not name.endswith(".weight") or weight.ndim != 2:
            continue
        alias = name.removeprefix("diffusion_model.").removesuffix(".weight")
        native[alias] = _loads("base_model.model." + alias, name, state, key_map)
        existing[name] = _loads(name.removesuffix(".weight"), name, state, key_map)

    diffusers = {}
    absent_targets = []
    # The conversion map describes aliases; the actual model decides which targets exist.
    for key, target in comfy.utils.z_image_to_diffusers(
        config, output_prefix="diffusion_model.",
    ).items():
        name = target[0] if isinstance(target, tuple) else target
        if name not in state:
            absent_targets.append(key)
            continue
        if not key.endswith(".weight") or state[name].ndim != 2:
            continue
        alias = key.removesuffix(".weight")
        diffusers[alias] = _loads("base_model.model." + alias, target, state, key_map)
        existing["transformer." + alias] = _loads("transformer." + alias, target, state, key_map)
    assert native and diffusers and existing, "The verifier must exercise both real alias families"
    transformer = {k.removeprefix("transformer."): v for k, v in key_map.items() if k.startswith("transformer.")}
    prefixed = {k.removeprefix("base_model.model."): v for k, v in key_map.items() if k.startswith("base_model.model.")}
    common = transformer.keys() & prefixed.keys()
    return {
        "prefix_keys_present": len(prefixed) >= 5,
        "prefix_count_parity": bool(transformer) and len(prefixed) >= 0.9 * len(transformer),
        "complete_target_parity": len(common) >= 5 and sum(
            transformer[k] == prefixed[k] for k in common
        ) >= 0.9 * len(common),
        "config": config,
        "exact_user_example": native["layers.0.attention.out"],
        "native": native,
        "diffusers": diffusers,
        "existing": existing,
        "inherited_aliases_to_absent_weights": absent_targets,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--logs", required=True, type=Path)
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=True)
    # An interrupted or failed invocation must not leave a previous numeric reward.
    for name in ("reward.txt", "gates.json", "behavior.json"):
        (args.logs / name).unlink(missing_ok=True)
    torch.set_num_threads(2)
    cases = []
    for modulation in (False, True):
        for dim, layers, refiners in ((32, 1, 0), (64, 2, 1), (64, 5, 2)):
            config = {
                "patch_size": 2, "in_channels": 16, "dim": dim, "n_layers": layers,
                "n_refiner_layers": refiners, "n_heads": 2, "n_kv_heads": 2,
                "qk_norm": True, "cap_feat_dim": 32,
                "axes_dims": [dim // 8, 3 * dim // 16, 3 * dim // 16],
                "z_image_modulation": modulation,
            }
            cases.append(_check_model(config))
    gates = [
        {"id": "f2p_turn1_base_model_keys", "passed": all(c["prefix_keys_present"] for c in cases),
         "detail": "Prefixed aliases are produced for real model states"},
        {"id": "f2p_turn1_coverage_parity", "passed": all(c["prefix_count_parity"] for c in cases),
         "detail": "Prefixed alias count reaches 90% of existing transformer alias count"},
        {"id": "f2p_turn1_layers0_keys", "passed": all(c["exact_user_example"] for c in cases),
         "detail": "Load and apply the exact attention.out example, not merely any layers.0 key"},
        {"id": "f2p_turn1_target_match", "passed": all(c["complete_target_parity"] for c in cases),
         "detail": "Shared aliases retain complete targets, including tensor-slice offsets"},
        {"id": "f2p_upstream_lumina2_bm_keys", "passed": all(all(c["diffusers"].values()) for c in cases),
         "detail": "Prefixed Diffusers aliases load and apply to real 2D weights"},
        {"id": "f2p_native_weight_loading", "passed": all(all(c["native"].values()) for c in cases),
         "detail": "Prefixed native aliases load and apply to every real 2D weight"},
        {"id": "p2p_existing_lumina_formats", "passed": all(all(c["existing"].values()) for c in cases),
         "detail": "Previously supported native and transformer aliases still load and apply"},
    ]
    (args.logs / "behavior.json").write_text(json.dumps({"version": 2, "cases": cases}, indent=2) + "\n")
    (args.logs / "gates.json").write_text("".join(json.dumps(g) + "\n" for g in gates))
    # Preserve the existing manifest weights; this diagnostic is not the LLM rubric score.
    manifest = yaml.safe_load(Path(__file__).with_name("test_manifest.yaml").read_text())
    passed = {gate["id"]: gate["passed"] for gate in gates}
    assert set(passed) == {gate["id"] for gate in manifest["gates"]}
    score = sum(gate["weight"] for gate in manifest["gates"] if passed[gate["id"]])
    if not gates[-1]["passed"]:
        score = 0.0
    (args.logs / "reward.txt").write_text(f"{score:.4f}\n")
    print(json.dumps({"cases": len(cases), "gates": gates, "test_reward": score}))


if __name__ == "__main__":
    main()
