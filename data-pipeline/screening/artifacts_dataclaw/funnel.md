# DataClaw Test Construction Audit

Snapshot of test-construction quality across the 45 published DataClaw
Harbor tasks as of 2026-03-29 (verified against actual implementations in
SWE-bench, SWE-ABS, UTBoost, PatchDiff, ImpossibleBench; cross-referenced
with `harbor_tasks/*/tests/test.sh` plus the `/write-tests` and
`/review-task` slash commands).

## Headline numbers

```
45 published tasks
   ├─ Tasks with fail-to-pass behavioral test       38 / 45  (84%)
   ├─ Tasks with pass-to-pass regression test        2 / 45  ( 4%)   ← largest gap
   ├─ Tasks meeting >=60% behavioral weight         34 / 45  (76%)
   ├─ 0% behavioral, justified (C/CUDA can't compile) 5 / 45
   ├─ 0% behavioral, fixable (Python/TS)             2 / 45
   └─ Borderline (<60% behavioral, fixable)          4 / 45
```

> The largest single-step improvement is closing the **P2P regression
> gap**: 43 of 45 tasks have no pass-to-pass check. P2P tests are cheap
> insurance (10–20% reward weight) and are what catches narrow fixes that
> break neighboring behavior.

## Tier 1 — current state (45 tasks audited)

| Metric | Value | Target |
|---|---|---|
| Tasks with fail-to-pass behavioral test | 38/45 (84%) | 100% of applicable tasks |
| Tasks with pass-to-pass regression test | **2/45 (4%)** | 100% |
| Tasks meeting >=60% behavioral weight | 34/45 (76%) | 100% of applicable tasks |
| Tasks with 0% behavioral (justified: C/CUDA can't compile) | 5/45 | Mark as `structural_only_justified=true` |
| Tasks with 0% behavioral (fixable: Python/TS) | 2/45 | Rewrite tests |
| Tasks borderline (<60% behavioral, fixable) | 4/45 | Add behavioral checks |

### Fixable, 0% behavioral

| Task | Why current tests are weak | Fix |
|---|---|---|
| `sd-scripts-torch-compile-sdxl` | 10 pure AST checks | Mock `torch.compile`, run the function on small CPU tensors |
| `openclaw-agents-md-create` | All text checks | Add content-quality behavioral checks (rendered code-block parse, key-section presence) |

### Borderline (<60% behavioral)

| Task | Behavioral % | Fix |
|---|---:|---|
| `banodoco-wrapped-page-clone` | 25% | Add TypeScript compilation + runtime import checks |
| `banodoco-video-perf-optimize` | 30% | Add runtime IntersectionObserver mock tests |
| `comfyui-frontend-autoscale-layout` | 50% | Already has F2P; add one more behavioral check |
| `comfyui-triton-windows-amd-fix` | 10% (GPU kernel) | Borderline-justified exception — accept |

### Justified exceptions (0% behavioral, accept)

These 5 cannot execute in a CPU-only Docker sandbox; mark each
`structural_only_justified = true` in `task.toml`:

| Task | Reason |
|---|---|
| `llama-cpp-lora-moe-rank1` | CUDA code, no compiler available |
| `sageattention-headdim-256` | C/CUDA, no compiler available |
| `amdgpu-kernel-619-compat` | Linux kernel module, no kernel headers |
| `triton-amd-fp8-lowering` | Triton kernel, no GPU runtime |
| `triton-msvc-c4267-warnings` | C++ with MSVC-specific fixes |

## Priority 1 — add pass-to-pass regression tests

Single highest-impact improvement. The best P2P tests are the **repo's
own CI / mandatory tests** — they define the real regression contract
that must hold before any PR is merged. When upstream tests aren't
viable, fall back to synthetic checks.

### Three-tier P2P strategy

| Tier | When | Example | Tasks affected |
|---|---|---|---|
| **Tier 1 — upstream tests** | Repo has CPU-safe test suite | `python3 -m pytest tests/library/ -x` | ~20 (desloppify, sd-scripts, ComfyUI, vibecomfy, ViT-Prisma) |
| **Tier 2 — synthetic behavioral** | No viable upstream tests but code runs | Import function, call with normal input, assert output | ~18 |
| **Tier 3 — structural P2P** | C/C++/CUDA, cannot compile | Check existing symbols/APIs preserved | 5 |

### Tier 1 — run upstream tests (BEST)

```bash
# PASS-TO-PASS: upstream test suite (CPU-safe subset)
cd /workspace
python3 -m pytest tests/library/ -x --timeout=60 -q 2>/dev/null
if [ $? -eq 0 ]; then REWARD=$((REWARD + P2P_WEIGHT)); fi
```

Pick unit tests for config/parsing/data/utilities. Avoid tests that need
GPU, model weights, or network. If pytest isn't installed, add
`RUN pip install --no-cache-dir pytest pytest-timeout` to the Dockerfile.

### Tier 2 — synthetic behavioral (GOOD)

```bash
# PASS-TO-PASS: Normal operation must not break
python3 -c "
from module import function_under_test
result = function_under_test(normal_input)
assert result == expected_normal_output, f'Regression: got {result}'
" 2>/dev/null
if [ $? -eq 0 ]; then REWARD=$((REWARD + P2P_WEIGHT)); fi
```

### Weight

P2P tests should carry **10–20% of total reward**. Cheap insurance, not
the primary signal.

## Priority 2 — transition validation

Before accepting any task, verify the fail-to-pass contract holds.
SWE-bench does this offline during dataset creation (`grading.py`
pre-computes F2P/P2P labels, not at eval time).

### Process (add to `/review-task`)

```
1. Build Docker image for the task
2. Run test.sh on base commit (no gold patch)
   - At least one F2P check MUST fail
   - All P2P checks MUST pass
3. Apply gold patch
4. Run test.sh again
   - ALL checks MUST pass
5. Record: base_score, gold_score, stable_f2p=true/false
```

If `base_score == gold_score`, tests don't discriminate buggy from fixed
code → reject the tests.

This does NOT need a new script. It can be a manual step in
`/review-task` or a lightweight addition to `run_validate.py` Pass 2.
Running tests 3× for flake detection (V1 doc suggested this) is a V2
improvement — single-run transition check is sufficient for now.

## Priority 3 — fix the 6 fixable tasks

Rewrite tests for the 2 critical + 4 borderline tasks listed above,
following the existing `/write-tests` tier system. Target: ≥60%
behavioral, at least one F2P, at least one P2P.

## What our commands already cover

| Requirement | Where it lives |
|---|---|
| ≥60% behavioral, ≤40% structural | `/write-tests` Rules |
| Core bug = fail-to-pass behavioral test | `/write-tests` Tier System |
| No gold-only symbol imports | `/write-tests` "Narrow Test Anti-Pattern" |
| No exact error strings unless contractual | `/write-tests` "Narrow Test Anti-Pattern" |
| Max stub score ≤ 0.30 | `/write-tests` Step 4 Self-Audit |
| Alternative fix score ≥ 0.70 | `/write-tests` Step 4 Self-Audit |
| Narrow test detection | `/review-task` Part A, Q2 + Q6 |
| F2P coverage check | `/review-task` Part A, Q7 |
| Gaming resistance check | `/review-task` Part A, Q1 + Q3 |

**Not yet in our commands:** P2P regression test requirement, transition
validation step.

## What we should add to commands

### `/write-tests` — extend the Rules section

```
- Every task must include at least one pass-to-pass regression check (10-20% weight)
- Before submitting: verify test.sh gives LOWER score on base commit than with gold patch applied
```

### `/review-task` — extend Part A

```
8. Pass-to-Pass Coverage: At least one regression test that passes on
   BOTH buggy and fixed code? If not, flag CRITICAL.
9. Transition Check: Run test.sh on base commit. At least one F2P test
   must fail. Run on gold commit. All must pass. If base_score ==
   gold_score, flag CRITICAL.
```

## Anti-gaming defenses — Harbor vs the field

ImpossibleBench's actual code reveals surprisingly few hard defenses;
their primary mechanism (test restoration at scoring time) is exactly
what Harbor already does (test.sh mounted post-agent).

| Defense | ImpossibleBench | Harbor |
|---|---|---|
| Tests hidden from agent | Configurable flag | **Already hidden** (mounted after agent completes) |
| Test restoration at scoring | `git checkout` + reapply | **Already done** (fresh mount) |
| Network isolation | `network_mode: none` for LiveCodeBench | `allow_internet=true` required (for agent install) |
| Monkey-patch detection | None (LLM judge post-hoc only) | None |
| `__eq__` overload detection | None (LLM judge post-hoc only) | None |

The only gap: no pre-verification integrity check for agent-modified
files that could affect test execution (e.g., injecting into
`site-packages`, writing `conftest.py`). This is a V2 concern — no
evidence current agents do this.

## Research tools — when to use (NOT default)

These are **audit tools for investigating suspicious results**, not part
of the standard task creation pipeline.

| Tool | What it actually does | When to use |
|---|---|---|
| **PatchDiff** | 2 Docker containers, 10–100 LLM calls, 30–90 min/task. Generates tests that distinguish gold vs agent patch. | Audit a specific suspicious high-scoring submission |
| **SWE-ABS mutation** | LLM generates plausible-wrong patches that pass your tests, then strengthens tests. $0.70–2/task. | Strengthen a task that keeps getting gamed |
| **UTBoost intramorphic** | Compares test logs between gold and agent patches. Hardcoded to SWE-bench data format. | Not applicable (requires SWE-bench log format) |
| **TRACE taxonomy** | 54-category cheat classification. For large-scale pattern analysis. | Post-mortem on a full eval run with suspicious results |

**Manual equivalents that give 90% of the value:**
- PatchDiff → "Can I write a plausible-but-wrong fix that passes all my tests?" (already in `/write-tests` step 4)
- SWE-ABS mutation → same question, but try 2–3 different wrong approaches
- SWE-ABS test decoupling → "Do my tests check behavior or implementation details?" (already in `/write-tests` narrow test section)

## Implementation reference repos

All verified 2026-03-29. File paths confirmed via GitHub API.

| Source | Repo | Key files | What to study |
|---|---|---|---|
| SWE-bench | [SWE-bench/SWE-bench](https://github.com/SWE-bench/SWE-bench) | `swebench/harness/grading.py` | F2P/P2P grading logic, status transition tracking |
| SWE-ABS | [OpenAgentEval/SWE-ABS](https://github.com/OpenAgentEval/SWE-ABS) | `docs/stage1_guide_en.md` | Test decoupling philosophy (not the pipeline) |
| PatchDiff | [ZJU-CTAG/PatchDiff](https://github.com/ZJU-CTAG/PatchDiff) | `src/framework.py` | Flaky test filtering (20× re-run protocol) |
| ImpossibleBench | [safety-research/impossiblebench](https://github.com/safety-research/impossiblebench) | `src/impossiblebench/swebench_scorers.py` | Test reset defense pattern |

## Open questions / follow-ups

1. **Close the P2P gap on the 18 Tier-2 tasks** (no upstream tests but
   code is callable). Each one should ship a synthetic behavioral P2P;
   the gain is across-the-board narrow-fix protection. Largest ROI item
   in this audit.

2. **Mark the 5 GPU/CUDA tasks as `structural_only_justified=true`.**
   Without this flag, a future audit will keep flagging them as
   "missing F2P behavioral" — this is the right way to express
   "intentionally exempt".

3. **Wire transition validation into `/review-task`.** Single-run
   `base_score < gold_score` check is enough for V1. Defer the
   3×-flake-detection variant.

4. **Add the 2 missing Rules to `/write-tests` and 2 missing questions
   to `/review-task` Part A** (P2P requirement + transition check).
   Cheap doc edits; aligns the commands with this audit.

5. **Don't spin up PatchDiff/SWE-ABS on the standard creation path.**
   They are 30–90 min/task and 10–100 LLM calls each — worth it for
   forensic deep-dives, not for routine task authoring.

## Sources

- OpenAI SWE-bench Verified critique (Feb 2026): [openai.com](https://openai.com/index/why-we-no-longer-evaluate-swe-bench-verified/)
- SWE-ABS paper: [arxiv 2603.00520](https://arxiv.org/abs/2603.00520)
- PatchDiff paper: [arxiv 2503.15223](https://arxiv.org/abs/2503.15223)
- UTBoost paper (ACL 2025): [arxiv 2506.09289](https://arxiv.org/abs/2506.09289)
- SWE-Bench+ paper: [arxiv 2410.06992](https://arxiv.org/abs/2410.06992)
- TRACE paper: [arxiv 2601.20103](https://arxiv.org/abs/2601.20103)
- SWE-bench Pro paper: [arxiv 2509.16941](https://arxiv.org/abs/2509.16941)
- METR reward hacking: [metr.org](https://metr.org/blog/2025-06-05-recent-reward-hacking/)
- METR merge study: [metr.org](https://metr.org/notes/2026-03-10-many-swe-bench-passing-prs-would-not-be-merged-into-main/)
- ImpossibleBench: [github.com/safety-research/impossiblebench](https://github.com/safety-research/impossiblebench)
- NIST CAISI cheating examples: [nist.gov](https://www.nist.gov/caisi/cheating-ai-agent-evaluations/2-examples-cheating-caisis-agent-evaluations)
