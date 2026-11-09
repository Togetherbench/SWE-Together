# LoRA grading repair, task version 2.0

The initial instruction explicitly names `base_model.model.layers.0.attention.out.lora_A.weight`. The original verifier built a synthetic state dictionary from the Diffusers conversion map and checked alias-count parity. That did not exercise the native `attention.out` target. It also discarded tensor-slice offsets when comparing mappings. Patches that added only Diffusers aliases could therefore receive full rubric credit while missing the user's example.

Version 2.0 uses six small real NextDiT model configurations on CPU. It feeds A/B tensors through the submitted mapper, loader, and weight adapter; checks the exact example, both supported naming families, complete slice targets, and existing-format regressions. It does not download checkpoints or generate images. The launcher clears stale results and leaves no numeric reward after setup/import errors.

| Gate | Previous evidence | Version 2.0 evidence | Weight |
|---|---|---|---:|
| Prefix aliases | Synthetic-map aliases | Real-model aliases | 0.15 |
| Coverage parity | Synthetic alias counts | Real-model alias counts | 0.15 |
| Layer-zero key | Any `layers.0` alias | Exact user's `attention.out` load and tensor application | 0.15 |
| Target parity | Base target only | Full target, including slice offsets | 0.15 |
| Diffusers support | Synthetic map check | Actual valid Diffusers targets load/apply | 0.20 |
| Native support | Source assignment-pattern check | Actual native targets load/apply | 0.20 |
| Existing formats | Limited stub checks | Native and transformer aliases load/apply | Regression gate |

These manifest weights remain distinct from the LLM rubric's unchanged goal weights (0, 0.60, 0.25, 0.15). A diagnostic test reward is not a new LLM correctness grade.

The original `reference_patch.json` also misses the native example and is retained unchanged for provenance. `corrected_reference.patch` is a separate patch against the task's base commit, supporting both naming families. No automatic reference selector is changed.

Rubric decomposition notes asserted that all historical model patches satisfied every goal, and the README contained model identities and a historical 1.0 reward. Both files are provided to the correctness judge. Those authoring claims are preserved in `authoring_history.md`, which is not staged as judge input. The goal descriptions, tiers, IDs, and weights are unchanged; the README now includes the exact initial instruction. This cleanup is specific to this task.

Offline validation of the checker on three saved model patches, the baseline, original/corrected references, and three targeted mutants discriminates missing native coverage, single-example overfitting, lost slice offsets, and regressions. Full validation in the cached task image passed on 9 November 2026 without model-family stubs or network access: all nine variants completed, and the corrected reference passed every behavioral gate. ML4 and MM3.5 each missed all six exact-example checks; Opus passed all six. Their diagnostic rewards were 0.65, 0.65 and 1.0 respectively, while the frozen LLM scores remain 1.0 for all three. No fresh coding or judge call is included in this repair. Frozen scores must not be overwritten.
