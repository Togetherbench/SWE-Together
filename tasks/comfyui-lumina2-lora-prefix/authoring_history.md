# Historical authoring notes (not judge inputs)

These claims are preserved for provenance, not accepted as behavioral evidence.
They are excluded from the correctness runner’s staged inputs.

## Previous rubric notes

The session contains one substantive deliverable expressed across three user turns. Turn 0 is the exploratory framing of the ask (strip/translate the 'base_model.model.' prefix); Turn 1 ('Don't use grep because it's a large repo') is a pure process/efficiency correction with no workspace deliverable, so it is intentionally NOT a weighted goal; Turn 2 narrows Turn 0 into the concrete, actionable request: implement the prefix mapping for Lumina2. goal_1 carries the bulk of the weight as the core capability (prefixed LoRA keys load for Lumina2). goal_2 captures the correctness/coverage qualifier the user's example and follow-up imply (same targets, full parity, not a one-off). goal_3 guards the additive nature of the change (no regression to already-working formats). Weights (0.6 + 0.25 + 0.15 = 1.0) rank by user-importance — deliberately NOT mirroring the test_manifest's four equal 0.15 F2P gates plus 0.20 upstream gates, which over-index on the parity/equivalence checks relative to the user's primary 'make it load' ask. Goals are stated behaviorally: no mention of comfy/lora.py, model_lora_keys_unet, key_map, the to variable, or any literal beyond the 'base_model.model.' prefix string the user themselves quoted verbatim. All four real model patches (the one-line key_map addition) satisfy every weighted goal.

Floor to reject non-implementations. Calibrated against the four real model patches, which all carry a leading '=== ComfyUI/ ===' captured-tree banner above a real one-line edit — the banner alone (with no substantive edit) must not be accepted as a solution. The lowest-signal failure mode here is a diff that pads with that banner or a comment but never alters the executed key map.

## E2E Eval Results

| Metric | Value |
|--------|-------|
| Reward | **1.0** |
| Sim user msgs | 4 |
| Real user msgs | 3 |
| Executor model | claude-sonnet-4-6 |
| User sim model | claude-opus-4-6 |

### Sim message quality
- Turn 2 (redirect): "Don't use grep because it's a large repo" — agent was grepping, correct trigger
- Turn 7 (new_requirement): "When I load a lora for the Lumina2 model..." — agent tried to finish without implementing, correct trigger
- Turn 8 (new_requirement): Repeated Turn 7 — agent still hadn't implemented, acceptable
- Turn 10 (redirect): "Don't use grep" — agent grepped again after being told not to, correct trigger
- 18/22 episodes were no-op (silence), matching the real user's low-intervention style

### Test hardening
- Tests check 63 `base_model.model.*` keys match 63 `transformer.*` targets (not just existence)
- Max stub score: 0.30 (vs 0.75 before hardening)
- Behavioral weight: 85%, structural: 15%

- Simulated trace: https://traces.togetherbench.com/jobs/trials/tasks/_/terminus-2/anthropic/claude-sonnet-4-6/comfyui-fix-96b329/trials/comfyui-fix-96b329__qqqM9rJ
- Original trace:  https://traces.togetherbench.com/jobs/trials/tasks/original-session/original-session/original/original/comfyui-fix-96b329/trials/comfyui-fix-96b329__original
