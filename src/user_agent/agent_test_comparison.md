# Harness & User Simulator Comparison Report

**Date:** 2026-04-03
**Action model:** Claude Sonnet 4.6 (all runs)
**Tasks:** 3 (sageattention-headdim-256, sd-scripts-dedup-early-exit, openclaw-agents-md-create)
**User Simulator Version:** 0.3.1
**Design:** 2 harnesses x 2 user models x 3 tasks = 12 experiments + 3 structured output experiments

---

## 1. User Simulator Model Comparison: Gemini 3.1 Pro vs Opus 4.6

### 1.1 Message Counts vs Ground Truth

| Task | GT msgs | CC + Gemini | CC + Opus | T2 + Gemini | T2 + Opus |
|------|---------|-------------|-----------|-------------|-----------|
| sd-scripts | 4 | **3** (0.75x) | 2 (0.5x) | 2 (0.5x) | 2 (0.5x) |
| sageattention | 6 | **2** (0.33x) | 1 (0.17x) | 1 (0.17x) | 1 (0.17x) |
| openclaw | 5 | 0 (0x) | 0 (0x) | 0 (0x) | 0 (0x) |

**Target range:** 0.5x–2x of GT message count.

**Finding:** Both models under-simulate on sageattention and openclaw. The difference between models is marginal (±1 message) — task-level `user_simulation_prompt.md` design dominates model choice.

### 1.2 Message Quality: Do Simulated Messages Match Real User Behavior?

#### sd-scripts-dedup-early-exit (GT=4)

The real user followed a progressive deepening pattern: instruction → safety check → broader safety check → cleanup review.

| Turn | Real user (ground truth) | Gemini (CC) | Opus (CC) |
|------|--------------------------|-------------|-----------|
| 1 | "can we avoid enumerating all images when `should_dedupe` is False?" | (instruction.md) | (instruction.md) |
| 2 | "Is it safe to replace `getattr(dataset, ...)` with `dataset.skip_...`?" | `new_requirement`: same question | `question`: same question |
| 3 | "Is it safe to replace `getattr(subset, ...)` with `subset.flip_aug`...?" | `new_requirement`: same question | `redirect`: "you confirmed it's safe but didn't actually replace it" |
| 4 | "I've did some cleanup... check the current implementation again." | `new_requirement`: "clean that up too" | (silent) |

**Gemini** faithfully replayed GT-2, GT-3, GT-4 content. Action types were all `new_requirement` — slightly inaccurate (GT-2/3 are safety questions).

**Opus** produced more realistic messages. Turn 2 matched GT exactly. Turn 3 was a behavioral redirect ("you confirmed but didn't replace") — the sim observed the agent's actual behavior rather than blindly replaying GT. This is arguably more realistic than the ground truth itself.

#### sageattention-headdim-256 (GT=6)

| Turn | Real user (ground truth) | Gemini (CC) | Opus (CC) |
|------|--------------------------|-------------|-----------|
| 1 | "Is there a reason it only works with head_dim <= 128?" | (instruction.md) | (instruction.md) |
| 2 | "What changes do we need to support head dim 256?" | (not sent — subsumed by instruction) | (not sent) |
| 3 | "Why do we need to make this change to `fused.cu`?" | `question`: exact match | `question`: exact match |
| 4 | "Why do we need a `CTA_SIZE_HOST` different from `CTA_SIZE`?" | `question`: exact match | (silent — hit max_messages cap) |
| 5–6 | Code review questions ("any other issue with head dim 256?") | (capped at 2) | (capped at 2) |

Both models accurately reproduced the "why" questions from the real session. The bottleneck is `max_messages=2` (set in user_simulation_prompt.md), not model quality.

#### openclaw-agents-md-create (GT=5)

Zero messages across all configurations. The real user's follow-ups (GT 2–5) were Chinese-language product exploration questions unrelated to the AGENTS.md task. The sim prompt's triggers don't cover this conversational shift. This is a task design issue, not a model issue.

### 1.3 Model Comparison Summary

| Dimension | Gemini 3.1 Pro | Opus 4.6 |
|-----------|---------------|----------|
| Intervention rate | Slightly higher (+1 msg on 2/3 tasks) | More conservative |
| GT content fidelity | High — closely mirrors GT phrasing | High — sometimes more natural than GT |
| Action type accuracy | Defaults to `new_requirement` for everything | Better discrimination (`question` vs `redirect`) |
| Behavioral grounding | Replays GT content | Reacts to agent's actual behavior |

**Verdict:** Both models produce realistic messages when they fire. Neither compensates for weak task-level trigger design. Gemini is slightly more active; Opus is slightly more natural per message.

---

## 2. Harness Comparison: Claude Code vs Terminus 2

### 2.1 Architecture

| Dimension | Claude Code | Terminus 2 |
|-----------|-------------|------------|
| **Runtime** | External CLI process (`claude --print`) | In-process LLM agent (direct API calls) |
| **Multi-turn** | `claude --resume <session_id>` (new process per turn) | Direct chat history injection (`chat.messages.append(...)`) |
| **Tool usage** | Claude Code built-in tools (file read/write, bash, search) | Harbor `Command` tools (terminal execution) |
| **Config file discovery** | Natively reads CLAUDE.md, `.claude/` + injected via `repo_config.py` | Only via `repo_config.py` injection |
| **Max turns** | 15 (`_MAX_RESUME_TURNS`) | 1,000,000 (timeout-limited in practice) |
| **Context summarization** | Not supported | Supports proactive summarization |

### 2.2 What is a "Turn"?

The two harnesses define "turn" completely differently:

**Terminus 2 turn** = one LLM API call + one command execution. User sim is consulted after **every step**. A typical task has 10–20 turns.

**Claude Code turn** = one complete `claude --print` execution. Claude Code internally runs its own autonomous loop (reading files, writing code, running tests — potentially dozens of steps). User sim is only consulted **after the entire CLI process exits**. A typical task has 1–4 turns.

```
Terminus 2:                          Claude Code:
LLM call → cmd → user sim?          claude --print (10+ internal steps)
LLM call → cmd → user sim?              ↓ exits
LLM call → cmd → user sim?          user sim consulted
...  (10-20 cycles)                  claude --resume (10+ internal steps)
                                         ↓ exits
                                     user sim consulted
```

This mirrors real usage: when you use Claude Code, you give an instruction, it works autonomously, then comes back to you. You don't interrupt it mid-file-read. The benchmark replicates this pattern — `completing=True` on every Claude Code turn corresponds to "Claude Code finished and is waiting for your response."

### 2.3 What Does the User Simulator See?

This is the most important difference for simulation realism.

**Terminus 2** gives structured step summaries:
```
[12] agent: The dedup logic needs a guard...
  > terminal: file saved
[13] tool_call(bash): git diff library/config_util.py
  > terminal: +        if not should_dedupe: continue
```

**Claude Code (before v0.5)** gave the raw tail of stream-json stdout — 3000 characters of mixed JSON containing thinking, tool calls, and results. Not human-readable.

**Claude Code (v0.5+)** now parses stream-json into structured steps matching Terminus format:
```
[1] thinking: Let me look at the last commit...
[2] tool_call(Bash): git show fa99b4a --stat
[8] agent: The problem is clear: should_dedupe is computed but never used...
[9] tool_call(Edit): /workspace/sd-scripts/library/config_util.py
```

Verified: 57,544 chars of raw JSON → 11 structured steps. This is closer to what a real user sees (formatted tool output, code diffs, agent explanations).

### 2.4 Structured vs Raw Output Impact

Reran all 3 tasks with Claude Code + Gemini after switching to structured output:

| Task | Raw output (msgs / reward) | Structured output (msgs / reward) |
|------|---------------------------|----------------------------------|
| sd-scripts | 3 / 0.93 | **1 / 0.68** |
| sageattention | 2 / 0.35 | **2 / 0.35** (identical msgs) |
| openclaw | 0 / 0.25 | **0 / 0.14** |

**sageattention:** Identical messages — same GT-3 and GT-4 questions fired in both cases. Structured output didn't change behavior here.

**sd-scripts:** Dropped from 3 to 1 message. With structured output the user sim could clearly see the agent had already completed the fix, so it didn't send redundant follow-ups. The raw-output sim sent extra messages partly because it couldn't clearly parse what the agent had done.

**Interpretation:** Structured output makes the user sim **more informed and more conservative** — it sees exactly what the agent did, so it only intervenes when genuinely needed. This is closer to how a real user behaves: if you can clearly see the agent fixed the issue, you don't ask follow-up questions.

### 2.5 Results by Harness

| Task | User model | CC msgs / reward | T2 msgs / reward | CC sim calls | T2 sim calls |
|------|-----------|-----------------|-----------------|-------------|-------------|
| sd-scripts | Gemini | 3 / 0.93 | 2 / 0.68 | 4 | 19 |
| sd-scripts | Opus | 2 / 0.68 | 2 / 0.68 | 3 | 16 |
| sageattention | Gemini | 2 / 0.35 | 1 / 0.35 | 3 | 15 |
| sageattention | Opus | 1 / 0.35 | 1 / 0.35 | 2 | 12 |
| openclaw | Gemini | 0 / 0.25 | 0 / 0.50 | 1 | 10 |
| openclaw | Opus | 0 / 0.21 | 0 / 0.18 | — | 9 |

**Message counts are similar across harnesses.** Terminus calls user sim 4–5x more often (10–19 vs 1–4 calls), but most are no-ops. The fine-grained invocation doesn't produce more messages — it just creates more decision points where the sim chooses silence.

### 2.6 Configuration Fairness Between Harnesses

The following has been aligned to ensure a fair comparison:

| Dimension | Status | Notes |
|-----------|--------|-------|
| Repo config file injection | **Aligned** | Both harnesses inject via `repo_config.py` |
| User sim model | **Aligned** | Same model, same system prompt |
| User sim observation format | **Aligned** | Both now produce structured step summaries |
| Max messages | **Aligned** | Both use soft GT-based guidance, no hard cap |
| Session analysis | **Aligned** | Same `user_simulation_prompt.md` + identical guidance suffix |

The following remain structurally different — these are inherent to each harness architecture, not configuration gaps:

| Dimension | Claude Code | Terminus 2 | Impact |
|-----------|-------------|------------|--------|
| Intervention granularity | After full autonomous run (2–4 calls) | After every LLM step (10–20 calls) | **Medium** — T2 has more chances to intervene but mostly no-ops |
| Action model provider | Anthropic API only | Any LiteLLM provider | **Low** — we standardize on Sonnet 4.6 |
| Tool set | Claude Code built-in (Read/Edit/Bash/Grep/Glob/Write...) | Harbor Command (terminal execution only) | **High** — different agent capabilities |
| Context management | Claude Code internal | T2 supports proactive summarization | **Low** |
| CLAUDE.md loading | Dual (native auto-discovery + injected) | Injected only | **Low** — duplicate content is harmless |
| `allow_internet` | **Must be `true`** (CLI installation requires network) | Can be `false` | **Medium** — CC agent can access the internet during task execution, which could leak benchmark answers via GitHub |

**The biggest fairness gap is `allow_internet`.** Claude Code requires network access to install the CLI inside the Docker container, which means the agent also has internet during task execution. Terminus 2 doesn't need network access. This gives CC agents the potential to look up the benchmark repo or PRs on GitHub. This is an inherent limitation of Claude Code's architecture — the CLI must be installed at runtime, not baked into the Docker image.

---

## 3. Realism Assessment

### 3.1 What's Realistic

- **Message content matches GT well** — when the sim fires, it sends messages that closely match what the real user said (especially GT-2, GT-3 on both tasks)
- **Opus produces behaviorally-grounded responses** — "you confirmed but didn't replace it" is more realistic than replaying GT verbatim
- **Claude Code turn structure matches real usage** — autonomous execution → user review → optional follow-up
- **Structured output improves realism** — sim sees what a real user would see (agent actions + results), not raw JSON

### 3.2 What's Not Realistic

- **No mid-task interruption in Claude Code** — real users occasionally interrupt ("wait, stop, that's wrong") during execution. Claude Code harness can only speak between complete runs.
- **User sim context window is small** — 3000 chars means early-turn context is lost. A real user remembers the full conversation.
- **Claude Code completes too much in one turn** — CC runs the entire task autonomously in one `--print` invocation. By the time the user sim is consulted, the task is already done. The sim sees a completed result and has nothing to add. T2 gives the sim 10–20 chances to intervene *during* work, which is why T2 gets more messages on openclaw (1–3 msgs vs 0 for CC). This is the fundamental tradeoff: CC is more realistic in turn structure, but T2 produces more user interaction.

---

## 4. Effect of Soft Message Guidance (v0.5)

In v0.5, we replaced the hard `max_messages` cap with a soft GT-based guidance range (`GT*0.5` – `GT*1.5`) injected into the user sim's system prompt. This section compares the same 12 experiment configurations before and after.

### 4.1 Message Counts: Hard Cap vs Soft Guidance

| Task | GT | Config | Hard cap (before) | Soft guidance (after) |
|------|-----|--------|-------------------|----------------------|
| sd-scripts | 4 | CC + Gemini | 3 | **3** |
| sd-scripts | 4 | CC + Opus | 2 | **5** |
| sd-scripts | 4 | T2 + Gemini | 2 | **2** |
| sd-scripts | 4 | T2 + Opus | 2 | **1** |
| sageattention | 6 | CC + Gemini | 2 | **2** |
| sageattention | 6 | CC + Opus | 1 | **1** |
| sageattention | 6 | T2 + Gemini | 1 | **2** |
| sageattention | 6 | T2 + Opus | 1 | **1** |
| openclaw | 5 | CC + Gemini | 0 | **0** (session ID fixed, sim chose no-op) |
| openclaw | 5 | CC + Opus | 0 | **0** (session ID fixed, sim chose no-op) |
| openclaw | 5 | T2 + Gemini | 0 | **1** |
| openclaw | 5 | T2 + Opus | 0 | **3** |

### 4.2 Key Improvements

**openclaw finally gets user intervention.** With hard cap, all 12 runs produced 0 messages. With soft guidance:
- T2 + Opus: **3 messages** — quality checks on AGENTS.md completeness ("what about error handling and type conventions?", "show me the full content before you mark it done")
- T2 + Gemini: **1 message** — redirect about missing sections ("AGENTS.md looks incomplete — I need single-test commands, import guidelines...")
- Reward jumped to **0.86** on the T2+Gemini run (from 0.18–0.50 range)

**sd-scripts CC + Opus jumped from 2 to 5 messages.** The sim now asks to see code state, requests the `getattr` replacement, and does a final review — closer to the real user's 4-message arc.

**sageattention T2 + Gemini went from 1 to 2 messages** — now matching the CC+Gemini result. The old hard cap of 2 was already tight; soft guidance didn't change CC behavior but helped T2.

### 4.3 Message Quality (New Runs)

**openclaw T2 + Opus (3 messages):**
```
Turn 8 [question]: can you show me the full AGENTS.md content before you mark it done?
Turn 9 [question]: the output got cut off — can you scroll down and show me the rest?
Turn 10 [question]: what about the error handling and type conventions sections?
```
These are natural quality-check messages — the kind a real user sends when reviewing generated documentation. Previously impossible due to hard cap.

**sd-scripts CC + Opus (5 messages):**
```
Turn 1 [question]: can you show me the current state of the dedup section?
Turn 2 [question]: can you paste the actual code from line 600-650?
Turn 3 [question]: Is it safe to replace getattr(dataset, ...) with dataset.skip_...?
Turn 4 [redirect]: ok so go ahead and replace it then. and while you're at it...
Turn 5 [question]: can you show me the dedup section one more time?
```
Progressive: inspect → clarify safety → direct action → review. GT-faithful pattern with natural language.

---

## 5. Simulator vs Ground Truth Behavioral Consistency

This section analyzes how faithfully the user simulator reproduces real user behavior across all 12 v0.5 experiments.

### 5.1 sd-scripts-dedup-early-exit

**GT pattern:** Instruction → safety question → broader safety question → cleanup review (4 messages, progressive deepening).

| GT msg | Content | CC+Gemini | CC+Opus | T2+Gemini | T2+Opus |
|--------|---------|-----------|---------|-----------|---------|
| GT-1 | (instruction — in instruction.md) | — | — | — | — |
| GT-2 | "Is it safe to replace `getattr(dataset, ...)`?" | **exact match** (Turn 1) | Turn 3 (after 2 "show me code" questions) | **exact match** (Turn 10) | **exact match** (Turn 6) |
| GT-3 | "Is it safe to replace `getattr(subset, ...)`?" | Turn 2 (exact match) | Turn 4 (bundled with redirect) | Turn 16 (exact match) | not sent |
| GT-4 | "I've done cleanup... check again" | Turn 3 (rephrased as redirect) | Turn 5 ("show me one more time") | not sent | not sent |

**GT coverage:** CC+Gemini covered GT-2,3,4 (3/3). CC+Opus covered GT-2,3 (2/3) but added 2 invented "show me" messages. T2+Gemini covered GT-2,3 (2/3). T2+Opus covered GT-2 only (1/3).

**Invented messages (not in GT):**
- CC+Opus Turns 1,2,5: "show me the current state" / "paste code from line 600-650" / "show me one more time" — code inspection requests the real user never made
- CC+Gemini Turn 3: redirect "you missed my question" — plausible but not in GT

**Consistency score: HIGH.** All 4 configs sent GT-2 verbatim. 3/4 sent GT-3. The core safety-question arc is well-reproduced regardless of harness/model.

### 5.2 sageattention-headdim-256

**GT pattern:** Instruction → implementation question → 4 Socratic "why" questions probing the change rationale (6 messages). GT-1,2 are subsumed by instruction.md; GT-3,4 are the key follow-ups.

| GT msg | Content | CC+Gemini | CC+Opus | T2+Gemini | T2+Opus |
|--------|---------|-----------|---------|-----------|---------|
| GT-1,2 | (subsumed by instruction.md) | — | — | — | — |
| GT-3 | "Why do we need to make this change to `fused.cu`?" | **exact match** (Turn 1) | **exact match** (Turn 1) | **exact match** (Turn 11) | **exact match** (Turn 14) |
| GT-4 | "Why `CTA_SIZE_HOST` different from `CTA_SIZE`?" | **exact match** (Turn 2) | not sent | **exact match** (Turn 14) | not sent |
| GT-5,6 | Code review ("any other issue?", "don't build") | not sent | not sent | not sent | not sent |

**GT coverage:** CC+Gemini and T2+Gemini covered GT-3,4 (2/2 available). CC+Opus and T2+Opus covered GT-3 only (1/2).

**Invented messages:** None. Every sim message is a verbatim or near-verbatim match of a GT message.

**Consistency score: VERY HIGH.** The sim reproduces GT-3 identically across all 8 runs (4 hard-cap + 4 soft-guidance). GT-4 fires in 4/8 runs. No invented content. This is the best-calibrated task of the three.

### 5.3 openclaw-agents-md-create

**GT pattern:** Instruction → 4 Chinese-language product exploration questions unrelated to the AGENTS.md task.

| GT msg | Content | CC+Gemini | CC+Opus | T2+Gemini | T2+Opus |
|--------|---------|-----------|---------|-----------|---------|
| GT-1 | (instruction.md) | — | — | — | — |
| GT-2 | "给我讲讲这个项目是做什么的" | not sent | not sent | not sent | not sent |
| GT-3 | "在WhatsApp/Telegram上问AI问题？有什么意义" | not sent | not sent | not sent | not sent |
| GT-4 | "深入代码仔细看看到底有什么功能" | not sent | not sent | not sent | not sent |
| GT-5 | "对于ubuntu/linux的gui操作支持怎么样" | not sent | not sent | not sent | not sent |

**GT coverage:** 0/4 across all configs. No GT message was ever reproduced.

**Invented messages (T2 only, CC sent nothing):**
- T2+Gemini: "AGENTS.md looks incomplete — need single-test command, import guidelines..." (redirect)
- T2+Opus: "show me the full AGENTS.md content" / "output got cut off" / "error handling and type conventions?"

**All sim messages are invented** — none match GT. The sim focused on AGENTS.md quality (task-relevant) while the real user pivoted to Chinese product exploration (task-irrelevant). The sim's messages are arguably more useful for the benchmark task than the GT itself.

**Consistency score: NONE.** Sim and GT behaviors are completely divergent. This is by design — the `user_simulation_prompt.md` correctly scopes the sim to task-relevant behavior and suppresses the off-topic GT follow-ups.

### 5.4 Summary

| Task | GT coverage | Invented msgs | Content fidelity | Best config |
|------|------------|---------------|-----------------|-------------|
| sd-scripts | 1–3 of 3 follow-ups | 0–2 per run | High (verbatim matches) | CC+Gemini (3/3 GT, reward 0.93) |
| sageattention | 1–2 of 2 follow-ups | 0 | Very high (exact quotes) | CC+Gemini or T2+Gemini (2/2 GT) |
| openclaw | 0 of 4 follow-ups | 0–3 per run | N/A (GT is off-topic) | T2+Gemini (1 useful redirect, reward 0.86) |

**Key findings:**

1. **When GT is task-relevant, sim reproduces it faithfully.** sd-scripts and sageattention GT messages are directly about the coding task, and the sim matches them verbatim across models and harnesses.

2. **When GT is off-topic, sim invents task-relevant alternatives.** openclaw's GT pivots to product exploration; the sim stays on-task and generates quality-check messages instead. This is correct behavior for the benchmark.

3. **Gemini produces slightly higher GT coverage than Opus** (tends to send +1 GT-matching message). Opus sometimes fills the gap with invented "show me" messages instead.

4. **Harness affects timing, not content.** The same GT messages fire on both CC and T2 — just at different turn numbers (CC: turn 1–3, T2: turn 6–16) due to granularity differences.

---

## 6. Raw Trial Index

### v0.5 Runs (soft guidance, structured output)

| Trial ID | Task | Harness | User model | Msgs | Sim calls | Reward |
|----------|------|---------|-----------|------|-----------|--------|
| `g47L3vq` | sd-scripts | CC | Gemini | 3 | 4 | 0.93 |
| `x3s4nn2` | sd-scripts | CC | Opus | 5 | 6 | 0.68 |
| `FWPAHXX` | sd-scripts | T2 | Gemini | 2 | 20 | 0.68 |
| `E9znP7y` | sd-scripts | T2 | Opus | 1 | 15 | 0.68 |
| `bmMzwdw` | sageattention | CC | Gemini | 2 | 3 | 0.35 |
| `S2vg7YF` | sageattention | CC | Opus | 1 | 2 | 0.35 |
| `YPiFzwr` | sageattention | T2 | Gemini | 2 | 14 | 0.35 |
| `awDERzb` | sageattention | T2 | Opus | 1 | 17 | 0.35 |
| `dm3Eb3j` | openclaw | CC | Gemini | 0 | 1 | 0.21 | Session ID fix confirmed |
| `uS3gGn2` | openclaw | CC | Opus | 0 | 1 | 0.32 | Session ID fix confirmed |
| `Bp9oiCH` | openclaw | T2 | Gemini | 1 | 12 | 0.86 |
| `7AjnXnX` | openclaw | T2 | Opus | 3 | 12 | 0.21 |

### Earlier Runs (hard cap, pre-v0.5)

| Trial ID | Task | Harness | User model | Msgs | Sim calls | Reward | Notes |
|----------|------|---------|-----------|------|-----------|--------|-------|
| `FUDgabB` | sd-scripts | CC | Gemini | 3 | 4 | 0.93 | Raw output |
| `7Fm8T8D` | sd-scripts | CC | Gemini | 1 | 2 | 0.68 | Structured output, hard cap |
| `ZALXAbM` | sd-scripts | CC | Opus | 2 | 3 | 0.68 | |
| `GzHWDoe` | sd-scripts | T2 | Gemini | 2 | 19 | 0.68 | |
| `njqcPh8` | sd-scripts | T2 | Opus | 2 | 16 | 0.68 | |
| `urFCZax` | sageattention | CC | Gemini | 2 | 3 | 0.35 | |
| `Fycwid8` | sageattention | CC | Opus | 1 | 2 | 0.35 | |
| `nxQb7Lh` | sageattention | T2 | Gemini | 1 | 15 | 0.35 | |
| `Ga7qvz3` | sageattention | T2 | Opus | 1 | 12 | 0.35 | |
| `uJHAHEb` | openclaw | CC | Gemini | 0 | 1 | 0.25 | |
| `YPPnV8v` | openclaw | CC | Opus | 0 | — | 0.21 | Session ID parse failure |
| `AgFnyCF` | openclaw | T2 | Gemini | 0 | 10 | 0.50 | |
| `gnocbRs` | openclaw | T2 | Opus | 0 | 9 | 0.18 | |
