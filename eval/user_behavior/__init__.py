"""eval/user_behavior — per-trial panel of user-simulator behavior metrics.

Companion to `eval/correctness/` (judge_score) and `eval/intent_coverage/`
(overall_score, effort_cost). This package does NOT call any LLM — it reads
existing per-trial artefacts on disk and computes a panel of behavioral metrics
that sit alongside the correctness number per §"Three-step protocol" step 3 of
`eval/eval_design.md`.

Public API:
    from eval.user_behavior.behavior_one import measure_one_trial
"""
