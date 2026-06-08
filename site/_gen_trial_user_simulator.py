#!/usr/bin/env python3
"""Generate the user-simulator trajectory visualization for one opencode trial,
as BOTH `site/trial_user_simulator.md` (English) and
`site/trial_user_simulator.html` (styled to match the site).

It replays the two functions that build the user-sim prompt:
  - UserEnabledOpenCode._snapshot_latest_turn()  (parses the opencode JSON stream)
  - UserAgent._build_turn_summary()              (assembles the per-turn prompt)
against the logged artifacts of a real trial. NOTE: this replica tracks the
*current* wrapper code, so the "input" panels show what today's snapshot logic
produces from the raw events — not necessarily the exact bytes this historical
trial's sim saw at runtime (the parser has since improved). The raw events and
the decisions (OUTPUT) are read verbatim from the trial.

Turn 0 is the seed: the real human's first message IS `instruction.md`. The
agent's turn-0 run reacts to it; the user simulator only takes over from turn 1.

Mapping: the consult for turn N reads the agent's turn-(N-1) work:
    episode-N  <-  command-{N-1}-*/stdout.txt (last non-empty)
                +  patches/turn-{N-1}.incremental.patch
"""
from __future__ import annotations
import html as _html
import importlib.util
import json
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path("/Users/yfwu/Projects/swe-together")
TRIAL = ROOT / "trials_lite_opencode/trials_70_opencode_opus_r1/dataclaw-anonymizer-tests__sRqXKy9"
AGENT = TRIAL / "agent"
TASK_DIR = ROOT / "harbor_tasks/dataclaw-anonymizer-tests"
OUT_MD = ROOT / "site/trial_user_simulator.md"
OUT_HTML = ROOT / "site/trial_user_simulator.html"
CTX_BUDGET = 3000  # opencode default user_context_chars (max(500, 3000))
# Mirror the wrapper: emit only the tool NAME (activity indicator). The sim
# simulates a human user, who reacts to the agent's narration + the code diff,
# not internal tool args/results. Flip to match if the wrapper flags change.
_SHOW_TOOL_ARGS = False
_SHOW_TOOL_RESULTS = False

TASK_NAME = "dataclaw-anonymizer-tests"
COHORT = "trials_70_opencode_opus_r1"


# ── faithful replicas of the runtime parsing/prompt-building ──────────────

def _normalize_content(raw):
    if raw is None:
        return ""
    if isinstance(raw, str):
        return raw
    if isinstance(raw, list):
        parts = []
        for p in raw:
            parts.append(p.get("text") or p.get("content") or "" if isinstance(p, dict) else str(p))
        return "\n".join(p for p in parts if p)
    if isinstance(raw, dict):
        return raw.get("text") or raw.get("content") or str(raw)
    return str(raw)


def snapshot_latest_turn(raw_stdout: str) -> tuple[str, str]:
    """Faithful replica of UserEnabledOpenCode._snapshot_latest_turn().

    Mirrors the current wrapper: step_finish dropped (token noise), and the two
    sections partitioned by role — observation = the agent's FINAL narration
    (≤3000), trajectory = everything else (intermediate thinking + tool calls +
    results) with that final report removed (no duplication)."""
    events: list[tuple] = []  # ("text", sid, str) | ("tool", sid, (name,args,result))
    step_id = 0
    current_turn_open = False
    for line in raw_stdout.split("\n"):
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue
        etype = event.get("type")
        part = event.get("part") or {}
        if etype == "step_start":
            step_id += 1
            current_turn_open = True
            continue
        if etype == "step_finish":
            current_turn_open = False
            continue
        if etype == "text" and current_turn_open:
            text = _normalize_content(part.get("text") or part)
            if text.strip():
                events.append(("text", step_id, text.strip()))
            continue
        if etype == "tool_use" and current_turn_open:
            name = part.get("tool") or part.get("name") or "?"
            state = part.get("state")
            if not isinstance(state, dict):
                state = {}
            args = state.get("input") or part.get("input") or part.get("arguments") or {}
            if not isinstance(args, str):
                args = json.dumps(args)
            result = state.get("output") or part.get("output") or part.get("result") or ""
            if isinstance(result, dict):
                result = json.dumps(result)
            events.append(("tool", step_id, (name, args, str(result) if result else "")))
            continue

    if not events:
        tail = raw_stdout[-CTX_BUDGET:] if len(raw_stdout) > CTX_BUDGET else raw_stdout
        return tail, tail

    last_text_idx = None
    for i, ev in enumerate(events):
        if ev[0] == "text":
            last_text_idx = i

    steps: list[str] = []
    for i, (kind, sid, payload) in enumerate(events):
        if kind == "text":
            if i == last_text_idx:
                continue
            snippet = payload if len(payload) <= 300 else payload[:300] + "…"
            steps.append(f"[{sid}] thinking: {snippet}")
        else:
            name, args, result = payload
            if _SHOW_TOOL_ARGS and args and args != "{}":
                if len(args) > 200:
                    args = args[:200] + "…"
                steps.append(f"[{sid}] tool_call({name}): {args}")
            else:
                steps.append(f"[{sid}] tool_call({name})")
            if _SHOW_TOOL_RESULTS and result:
                r = result if len(result) <= 300 else "…[truncated]…\n" + result[-300:]
                steps.append(f"[{sid}] result: {r}")

    trajectory = "\n".join(steps) if steps else "(no intermediate steps)"
    if len(trajectory) > CTX_BUDGET * 2:
        trajectory = "…[earlier steps elided]…\n" + trajectory[-CTX_BUDGET * 2:]

    if last_text_idx is not None:
        sid, report = events[last_text_idx][1], events[last_text_idx][2]
        observation = f"[{sid}] agent: {report[:3000]}"
    else:
        observation = "(no agent narration this turn)"
        for kind, sid, payload in reversed(events):
            if kind == "tool" and payload[2]:
                observation = f"[{sid}] result: {str(payload[2])[:500]}"
                break
    return trajectory, observation


def fmt_duration(seconds: float) -> str:
    if seconds < 60:
        return f"{seconds:.0f}s"
    minutes = seconds / 60
    if minutes < 60:
        return f"{minutes:.0f}min {seconds % 60:.0f}s"
    hours = int(minutes // 60)
    return f"{hours}h {int(minutes % 60)}min"


def build_turn_summary(step, total_calls, task, trajectory, observation,
                       diff, elapsed_sec, turn_duration_sec) -> str:
    """Faithful replica of UserAgent._build_turn_summary() (opencode path:
    analysis is always None, is_completion_attempt is always True)."""
    sections = [f"## Turn {step}"]
    if elapsed_sec and elapsed_sec > 0:
        tp = [f"Elapsed: {fmt_duration(elapsed_sec)}"]
        if turn_duration_sec and turn_duration_sec > 0:
            tp.append(f"this turn took {fmt_duration(turn_duration_sec)}")
        sections.append(f"**Timing:** {', '.join(tp)}")
    sections.append("** The agent is signaling completion.")
    if total_calls == 1:
        sections.append(f"\n## Task\n{task[:16000]}")
    sections.append(f"\n## Agent activity (this turn)\n{trajectory}")
    sections.append(f"\n## Agent output\n{observation}")
    if diff:
        sections.append(f"\n## Code changes (this turn)\n```diff\n{diff}\n```")
    sections.append("\nPick ONE tool. Default to no-op unless you have a clear, "
                    "new reason to speak.")
    return "\n".join(sections)


# ── log access ────────────────────────────────────────────────────────────

def read_text(p: Path) -> str:
    try:
        return p.read_text()
    except Exception:
        return ""


def last_command_stdout(turn_idx: int) -> str:
    cmds = sorted(AGENT.glob(f"command-{turn_idx}-*"),
                  key=lambda d: int(d.name.split("-")[-1]))
    for d in reversed(cmds):
        s = read_text(d / "stdout.txt")
        if s.strip():
            return s
    return ""


def incremental_diff(turn_idx: int) -> str:
    return read_text(AGENT / "patches" / f"turn-{turn_idx}.incremental.patch").strip()


# ── action metadata ─────────────────────────────────────────────────────────

ACTION_META = {
    "no-op":           {"emoji": "🤐", "label": "no-op",           "blurb": "stay silent, let the agent keep working"},
    "question":        {"emoji": "❓", "label": "question",        "blurb": "probe progress or reasoning"},
    "redirect":        {"emoji": "🛑", "label": "redirect",        "blurb": "correct course (usually starts with wait/no/stop)"},
    "new_requirement": {"emoji": "➕", "label": "new_requirement", "blurb": "add scope or move to the next sub-task"},
    "check_external":  {"emoji": "🔗", "label": "check_external",  "blurb": "ask the agent to check a PR/issue/deploy"},
}

INTERNAL_PREFIXES = ("error:", "fallback_noop:", "noop_guard:", "hard_cap_reached")


def reconstruct_system_prompt(kwargs: dict) -> str:
    """Build the EXACT system prompt the runtime sent, by importing the real
    UserAgent (stdlib-only) and reading its `_sys`. Bypasses the package
    __init__ (which pulls in harbor) by loading the module file directly."""
    mod_path = ROOT / "src/user_agent/user_agent.py"
    spec = importlib.util.spec_from_file_location("ua_mod", mod_path)
    ua = importlib.util.module_from_spec(spec)
    sys.modules["ua_mod"] = ua  # needed for dataclass type resolution
    spec.loader.exec_module(ua)
    agent = ua.UserAgent(
        llm=None,
        original_user_messages=kwargs.get("original_user_messages"),
        session_analysis=kwargs.get("session_analysis", ""),
        max_messages=kwargs.get("max_messages"),
    )
    return agent._sys


# ── build the turn model (turn 0 seed + sim turns) ──────────────────────────

def build_model():
    instruction = read_text(TASK_DIR / "instruction.md").strip()

    # Read the ACTUAL models from the trial's config.json — never hardcode.
    # `agent.model_name` is the action (coding) agent; `kwargs.user_model_name`
    # is the user simulator (gemini-3.1-pro-preview for these cohorts, not the
    # wrapper's claude-opus default).
    cfg = json.loads(read_text(TRIAL / "config.json"))
    action_model = cfg["agent"]["model_name"]
    user_model = cfg["agent"]["kwargs"].get("user_model_name", "(unknown)")

    # Prefer the RECORDED prompt (episode-N/user_sim_prompt.json, written by the
    # wrapper) — that is the literal prompt the sim received, no reconstruction.
    # Fall back to replaying the current parser for older trials that predate it.
    def recorded_prompt(turn_n):
        p = AGENT / f"episode-{turn_n}" / "user_sim_prompt.json"
        if p.exists():
            try:
                return json.loads(read_text(p))
            except Exception:
                return None
        return None

    any_recorded = any(recorded_prompt(int(ep.name.split("-")[-1])) is not None
                       for ep in AGENT.glob("episode-*"))
    prompt_source = "recorded" if any_recorded else "reconstructed"

    if any_recorded:
        # system prompt is constant; read it from the first recorded episode
        first = next((recorded_prompt(int(ep.name.split("-")[-1]))
                      for ep in sorted(AGENT.glob("episode-*"),
                                       key=lambda d: int(d.name.split("-")[-1]))
                      if recorded_prompt(int(ep.name.split("-")[-1]))), None)
        system_prompt = (first or {}).get("system_prompt") \
            or reconstruct_system_prompt(cfg["agent"]["kwargs"])
    else:
        system_prompt = reconstruct_system_prompt(cfg["agent"]["kwargs"])

    # exact task_description the sim saw in Turn 1 (unquoted from command-0-1)
    c01 = read_text(AGENT / "command-0-1" / "command.txt")
    sep = c01.find(" -- ")
    full_task = (c01[sep + 4:] if sep > 0 else instruction).lstrip()
    if full_task.startswith("'"):
        full_task = full_task[1:]

    decisions = []
    for ep in sorted(AGENT.glob("episode-*"), key=lambda d: int(d.name.split("-")[-1])):
        decisions.append(json.loads(read_text(ep / "user_decision.json")))
    ts0 = datetime.fromisoformat(decisions[0]["timestamp"])

    reward = read_text(TRIAL / "verifier" / "reward.txt").strip()

    # Turn 0 — the seed: instruction.md is the real first user message; the
    # agent's turn-0 run is what it did in response.
    t0_traj, _ = snapshot_latest_turn(last_command_stdout(0))
    turns = [{
        "kind": "seed",
        "n": 0,
        "user_input": instruction,
        "agent_activity": t0_traj,
    }]

    for i, d in enumerate(decisions):
        turn = d["turn"]
        src = turn - 1
        traj, obs = snapshot_latest_turn(last_command_stdout(src))
        # (no observation re-truncation — the wrapper dropped the redundant
        # [:ctx_budget] clamp; observation is already bounded by the snapshot.)
        diff = incremental_diff(src)
        ts = datetime.fromisoformat(d["timestamp"])
        elapsed = (ts - ts0).total_seconds()
        turn_dur = ((ts - datetime.fromisoformat(decisions[i - 1]["timestamp"])).total_seconds()
                    if i > 0 else 0.0)
        rec = recorded_prompt(turn)
        if rec and rec.get("turn_content"):
            # Verbatim — the literal prompt the sim received this turn.
            summary = rec["turn_content"]
        else:
            summary = build_turn_summary(turn, d["stats"]["total_calls"], full_task,
                                         traj, obs, diff, elapsed, turn_dur)
        raw = (d.get("raw_response") or "").strip()
        if raw.startswith(INTERNAL_PREFIXES):
            raw = ""
        turns.append({
            "kind": "sim",
            "n": turn,
            "src": src,
            "gt_left": d["ground_truth_remaining"],
            "action": d["action"],
            "has_message": d["has_message"],
            "content": d["content"],
            "raw": raw,
            "summary": summary,
        })

    return {
        "reward": reward,
        "n_turns": len(decisions),
        "n_msgs": sum(1 for d in decisions if d["has_message"]),
        "action_model": action_model,
        "action_disp": action_model.split("/")[-1],
        "user_model": user_model,
        "user_disp": user_model.split("/")[-1],
        "system_prompt": system_prompt,
        "prompt_source": prompt_source,
        "turns": turns,
    }


# ── markdown renderer ───────────────────────────────────────────────────────

def fence(content: str, lang: str = "text") -> list[str]:
    longest = run = 0
    for ch in content:
        run = run + 1 if ch == "`" else 0
        longest = max(longest, run)
    ticks = "`" * max(3, longest + 1)
    return [f"{ticks}{lang}", content, ticks]


def render_md(m) -> str:
    out: list[str] = []
    A = out.append
    A("# User-simulator trajectory — input and output, turn by turn\n")
    A(f"> **Trial:** `{TASK_NAME}` · **harness:** opencode · **action (coding) "
      f"model:** `{m['action_disp']}` · **user-sim model:** `{m['user_disp']}` · "
      f"**cohort:** `{COHORT}`\n")
    A(f"> <sub>full model ids — action: `{m['action_model']}` · user-sim: "
      f"`{m['user_model']}` (read from the trial's `config.json`)</sub>\n")
    A(f"> **Final reward:** **{m['reward']}** · **Turns:** {m['n_turns']} · "
      f"**User-sim interventions:** {m['n_msgs']} (the rest are no-ops)\n")
    A("\nEach turn below shows **what the user simulator sees (INPUT)** and "
      "**what it decided to do (OUTPUT)**. The OUTPUT is read verbatim from the "
      "trial's `episode-*/user_decision.json`.\n")
    if m["prompt_source"] == "recorded":
        A("\n> **INPUT is ground truth:** each panel is the literal prompt the "
          "sim received, read verbatim from `episode-*/user_sim_prompt.json` "
          "(the wrapper now records it). No reconstruction.\n")
    else:
        A("\n> **INPUT is reconstructed:** this trial predates prompt recording, "
          "so each panel is rebuilt from the raw logs (`command-*/stdout.txt` + "
          "`patches/turn-*.incremental.patch`) by replaying the **current** "
          "`_snapshot_latest_turn()` / `_build_turn_summary()` logic — what "
          "today's code would produce, not necessarily the exact bytes the "
          "historical run saw. (Timing is approximated from decision timestamps.)\n")

    A("\n---\n")
    A("## The message sent to the user-sim LLM (every turn)\n")
    A("```")
    A("messages = [")
    A('  {"role": "system",  "content": <persona + Session Analysis + fixed rules>},   # constant each turn')
    A('  ...history (prior turn summaries + sim decisions, accumulated),               # message_history=')
    A('  {"role": "user",    "content": <this turn\'s summary ↓↓↓>},                    # prompt=, appended last')
    A("]")
    A('tools = [no-op, question, redirect, new_requirement, check_external]   # tool_choice="required"')
    A("```")
    A("\nEvery **INPUT** panel below is that final user message (the turn "
      "summary). Every **OUTPUT** is the single tool the user-sim was forced "
      "to call (`episode-N/user_decision.json`).\n")

    # system prompt
    A("\n---\n")
    A("## The system prompt (constant every turn)\n")
    A("This is the literal first `{\"role\": \"system\"}` message — the same on "
      "every turn. It is `persona.render()` + the task's **Session Analysis** "
      "(`user_simulation_prompt.md`) + the fixed behavioral rules, reconstructed "
      "by building the real `UserAgent._sys` from this trial's `config.json`.\n")
    A(f"<details><summary>show the full system prompt "
      f"({len(m['system_prompt'])} chars)</summary>\n")
    out.extend(fence(m["system_prompt"]))
    A("\n</details>\n")

    # overview
    A("\n---\n")
    A("## Trajectory at a glance\n")
    A("```mermaid")
    A("flowchart TD")
    A("    T0([Turn 0 · real user: instruction.md<br/>agent reviews the diff])")
    prev = 0
    for t in m["turns"][1:]:
        n = t["n"]
        if t["has_message"]:
            A(f"    T{prev} --> T{n}{{{{Turn {n} · {t['action']}}}}}")
        else:
            A(f"    T{prev} --> T{n}([Turn {n} · no-op])")
        prev = n
    A("```")

    for t in m["turns"]:
        A("\n---\n")
        if t["kind"] == "seed":
            A("## Turn 0 — the seed (real human input)\n")
            A("<sub>The first user message is the task itself: "
              "`harbor_tasks/" + TASK_NAME + "/instruction.md`. There is no "
              "user-sim consult yet — the simulator only takes over from Turn 1, "
              "reacting to what the agent did here.</sub>\n")
            A("\n### ⬇️ REAL USER INPUT — `instruction.md`\n")
            out.extend(fence(t["user_input"]))
            A("\n### ⬆️ AGENT (turn 0) — initial run\n")
            out.extend(fence(t["agent_activity"]))
            continue

        n = t["n"]
        A(f"## Turn {n}\n")
        A(f"<sub>`episode-{n}/` · reacts to the agent's **turn {t['src']}** work "
          f"(`command-{t['src']}-*`, `turn-{t['src']}.incremental.patch`) · "
          f"GT remaining {t['gt_left']}</sub>\n")
        A("\n### ⬇️ INPUT — the turn summary the sim sees\n")
        if m["prompt_source"] != "recorded":
            A("> Note: the `**Timing**` line is approximated from decision "
              "timestamps (computed at runtime from a monotonic clock, not "
              "persisted); every other field is replayed verbatim from the logs.\n")
        if len(t["summary"]) > 2600:
            A(f"<details open><summary>turn summary ({len(t['summary'])} chars — "
              "click to collapse)</summary>\n")
            out.extend(fence(t["summary"]))
            A("\n</details>\n")
        else:
            out.extend(fence(t["summary"]))
        A("\n### ⬆️ OUTPUT — the sim's decision\n")
        meta = ACTION_META.get(t["action"], {"emoji": "", "label": t["action"]})
        badge = f"{meta['emoji']} {meta['label']}"
        if t["has_message"]:
            A(f"**`{badge}`** → message injected to the agent:\n")
            out.extend(fence(t["content"]))
        else:
            A(f"**`{badge}`** — stays silent this turn (the wrapper sends the "
              "agent a synthetic `continue`).\n")
        if t["raw"]:
            A("\n<sub>model reasoning (raw_response):</sub>\n")
            out.extend(fence(t["raw"][:600]))

    return "\n".join(out)


# ── html renderer ───────────────────────────────────────────────────────────

def esc(s: str) -> str:
    return _html.escape(s, quote=False)


# All selectors are namespaced `tv-` — the base styles.css already defines a
# `.turn` (grid) used on the Task page, which would otherwise crush our cards.
PAGE_CSS = """
.tv-head { padding: 64px 0 8px; }
.tv-chips { display:flex; flex-wrap:wrap; gap:8px; margin-top:18px; }
.tv-chip { font-family:var(--mono); font-size:12.5px; color:var(--muted);
  background:var(--surface); border:1px solid var(--line-2);
  border-radius:999px; padding:5px 12px; }
.tv-chip b { color:var(--ink); font-weight:650; }
.tv-chip.reward b { color:var(--accent-ink); }

.tv-msgbox { background:var(--dark); color:#e9e9ee; border-radius:var(--radius);
  padding:20px 22px; font-family:var(--mono); font-size:13px; line-height:1.7;
  overflow-x:auto; margin:18px 0 8px; }
.tv-msgbox .c { color:#8a8a96; }
.tv-msgbox .k { color:#ff7eb0; }

.tv-sys { border:1px solid var(--line-2); border-radius:var(--radius);
  background:var(--surface); overflow:hidden; }
.tv-sys summary { cursor:pointer; padding:14px 18px; font-weight:600;
  font-size:14px; list-style:none; background:#fcfcfd; }
.tv-sys summary::-webkit-details-marker { display:none; }
.tv-sys summary::before { content:"▸ "; color:var(--accent); }
.tv-sys[open] summary::before { content:"▾ "; }
.tv-sys[open] summary { border-bottom:1px solid var(--line); }
pre.tv-syspre { border-radius:0; max-height:560px; }

.tv-legend { display:flex; flex-wrap:wrap; gap:10px; margin:24px 0 8px; }
.tv-leg { display:inline-flex; align-items:center; gap:7px; font-size:13px;
  color:var(--muted); border:1px solid var(--line-2); border-radius:8px;
  padding:6px 11px; background:var(--surface); }

/* timeline */
.tv-tl { position:relative; margin-top:34px; padding-left:34px; }
.tv-tl::before { content:""; position:absolute; left:9px; top:6px; bottom:6px;
  width:2px; background:var(--line-2); }
.tv-turn { position:relative; margin:0 0 26px; }
.tv-turn::before { content:""; position:absolute; left:-32px; top:6px;
  width:14px; height:14px; border-radius:50%; background:var(--surface);
  border:2px solid var(--faint); z-index:1; }
.tv-turn[data-action="question"]::before        { border-color:#2f6df0; }
.tv-turn[data-action="redirect"]::before        { border-color:var(--accent); }
.tv-turn[data-action="new_requirement"]::before { border-color:#16a34a; }
.tv-turn[data-action="check_external"]::before  { border-color:#8b5cf6; }
.tv-turn[data-action="no-op"]::before           { border-color:var(--faint); background:var(--faint); }
.tv-turn[data-action="seed"]::before            { border-color:var(--ink); background:var(--ink); }

.tv-card { border:1px solid var(--line-2); border-radius:var(--radius);
  background:var(--surface); overflow:hidden; }
.tv-top { display:flex; align-items:center; gap:12px; flex-wrap:wrap;
  padding:14px 18px; border-bottom:1px solid var(--line); background:#fcfcfd; }
.tv-no { font-weight:700; letter-spacing:-.01em; font-size:15px; }
.tv-csub { font-family:var(--mono); font-size:12px; color:var(--faint); }
.tv-badge { display:inline-flex; align-items:center; gap:6px; font-family:var(--mono);
  font-size:12.5px; font-weight:600; padding:4px 10px; border-radius:999px;
  border:1px solid var(--line-2); }
.tv-badge[data-a="question"]        { color:#2f6df0; background:#eef3fe; border-color:#d4e2fd; }
.tv-badge[data-a="redirect"]        { color:var(--accent-ink); background:var(--accent-50); border-color:#ffd7e6; }
.tv-badge[data-a="new_requirement"] { color:#15803d; background:#eefbf1; border-color:#cdeed7; }
.tv-badge[data-a="check_external"]  { color:#6d28d9; background:#f3effd; border-color:#e2d7fb; }
.tv-badge[data-a="no-op"]           { color:var(--muted); background:#f3f3f5; }
.tv-badge[data-a="seed"]            { color:#fff; background:var(--ink); border-color:var(--ink); }

.tv-io { display:grid; grid-template-columns: 1fr 1fr; }
@media (max-width:820px){ .tv-io { grid-template-columns:1fr; } }
.tv-col { padding:16px 18px; min-width:0; }
.tv-col + .tv-col { border-left:1px solid var(--line); }
@media (max-width:820px){ .tv-col + .tv-col { border-left:none; border-top:1px solid var(--line); } }
.tv-lbl { font-family:var(--mono); font-size:11.5px; font-weight:600;
  letter-spacing:.06em; text-transform:uppercase; margin:0 0 10px; }
.tv-in  .tv-lbl { color:var(--muted); }
.tv-out .tv-lbl { color:var(--accent-ink); }
.tv-note { font-size:12px; color:var(--faint); margin:-4px 0 10px; }

pre.tv-pre { margin:0; padding:14px 15px; background:#0f0f12; color:#e6e6eb;
  border-radius:var(--radius-sm); font-family:var(--mono); font-size:12px;
  line-height:1.65; overflow:auto; max-height:420px; white-space:pre-wrap;
  word-break:break-word; }
pre.tv-pre .h { color:#ff9ec4; font-weight:700; }   /* ## headings */
pre.tv-pre .sig { color:#9ad0ff; }                  /* [n] step markers */
pre.tv-pre .dim { color:#8a8a96; }
.tv-msg { margin:0; padding:14px 15px; border-radius:var(--radius-sm);
  font-family:var(--mono); font-size:13px; line-height:1.6; white-space:pre-wrap;
  word-break:break-word; background:var(--accent-50); border:1px solid #ffd7e6;
  color:#7a0b3c; }
.tv-msg.seed { background:#f5f5f7; border-color:var(--line-2); color:var(--ink); }
.tv-silent { font-family:var(--mono); font-size:13px; color:var(--muted);
  background:#f5f5f7; border:1px dashed var(--line-2); border-radius:var(--radius-sm);
  padding:14px 15px; }
.tv-rawbox { margin-top:12px; }
.tv-rawbox summary { cursor:pointer; font-size:12px; color:var(--faint); font-family:var(--mono); }
.tv-callout { border:1px solid #ffd7e6; background:var(--accent-50); border-radius:var(--radius);
  padding:18px 20px; margin:22px 0; font-size:14.5px; color:#5c0a30; }
.tv-callout b { color:var(--accent-ink); }
.tv-notes { color:var(--muted); font-size:15px; line-height:1.7; }
.tv-notes code { font-family:var(--mono); font-size:.92em; background:#f0f0f2;
  padding:1px 5px; border-radius:5px; color:var(--ink); }
"""


def highlight_summary(text: str) -> str:
    """Light syntax tint for the turn-summary pre block."""
    lines = []
    for ln in esc(text).split("\n"):
        s = ln.lstrip()
        if s.startswith("## ") or s.startswith("** "):
            lines.append(f'<span class="h">{ln}</span>')
        elif s.startswith("[") and "]" in s[:6]:
            lines.append(f'<span class="sig">{ln}</span>')
        elif s.startswith("**Timing") or s.startswith("Pick ONE"):
            lines.append(f'<span class="dim">{ln}</span>')
        else:
            lines.append(ln)
    return "\n".join(lines)


def render_html(m) -> str:
    nav = """<header class="nav">
  <div class="wrap nav-inner">
    <a class="brand" href="index.html">
      <img src="togetherbench-icon.png" alt="TogetherBench" />
      <b>Together<span class="tld">Bench</span></b>
    </a>
    <nav class="nav-links">
      <a href="index.html">Overview</a>
      <a href="design.html">Design</a>
      <a href="tasks.html">Task</a>
      <a href="trial_user_simulator.html" class="active">Simulator</a>
      <a class="gh" href="https://github.com/togetherbench" target="_blank" rel="noopener">GitHub</a>
    </nav>
  </div>
</header>"""

    footer = """<footer>
  <div class="wrap">
    <div>
      <div class="fb"><img src="togetherbench-icon.png" alt="" /><b>Together<span class="tld">Bench</span></b></div>
      <p>A benchmark of real multi-turn coding sessions, measuring coding-agent performance under
         iterative user correction.</p>
    </div>
    <div class="flinks">
      <a href="index.html">Overview</a>
      <a href="design.html">Design</a>
      <a href="tasks.html">Task</a>
      <a href="trial_user_simulator.html">Simulator</a>
      <a href="https://github.com/togetherbench" target="_blank" rel="noopener">GitHub</a>
    </div>
  </div>
</footer>"""

    P: list[str] = []
    A = P.append
    A("<!DOCTYPE html>")
    A('<html lang="en">')
    A("<head>")
    A('<meta charset="utf-8" />')
    A('<meta name="viewport" content="width=device-width, initial-scale=1" />')
    A("<title>User Simulator — TogetherBench</title>")
    A('<meta name="description" content="A turn-by-turn look at what the LLM user simulator sees and decides on one opencode trial." />')
    A('<link rel="icon" type="image/png" href="togetherbench-icon.png" />')
    A('<link rel="stylesheet" href="styles.css" />')
    A(f"<style>{PAGE_CSS}</style>")
    A("</head>")
    A("<body>")
    A(nav)
    A("<main>")

    # head
    A('<section class="tv-head"><div class="wrap">')
    A('<p class="eyebrow">User simulator</p>')
    A('<h1 class="page-title">Watching the simulator, turn by turn</h1>')
    A('<p class="page-lede">What the LLM user-simulator <b>sees</b> (the turn '
      'summary) and what it <b>decides</b> (one tool call) on every turn of a '
      'real trial. Turn&nbsp;0 is the real human seed — the task’s '
      '<code>instruction.md</code>.</p>')
    A('<div class="tv-chips">')
    A(f'<span class="tv-chip">trial <b>{TASK_NAME}</b></span>')
    A('<span class="tv-chip">harness <b>opencode</b></span>')
    A(f'<span class="tv-chip" title="{esc(m["action_model"])}">action model <b>{esc(m["action_disp"])}</b></span>')
    A(f'<span class="tv-chip" title="{esc(m["user_model"])}">user-sim <b>{esc(m["user_disp"])}</b></span>')
    A(f'<span class="tv-chip reward">reward <b>{esc(m["reward"])}</b></span>')
    A(f'<span class="tv-chip">turns <b>{m["n_turns"]}</b></span>')
    A(f'<span class="tv-chip">interventions <b>{m["n_msgs"]}</b></span>')
    A("</div>")
    A("</div></section>")

    # message structure
    A('<section style="padding-top:30px"><div class="wrap">')
    A('<h2 class="sec-title">The message sent to the user-sim LLM</h2>')
    A('<p class="sec-intro">Every turn, the simulator gets a constant system '
      'prompt, the accumulated history, and this turn’s summary as the '
      'final user message. It must call exactly one tool.</p>')
    A('<div class="tv-msgbox">'
      '<span class="c"># messages sent each turn</span><br>'
      'messages = [<br>'
      '&nbsp;&nbsp;{<span class="k">"role"</span>: <span class="k">"system"</span>, '
      '<span class="k">"content"</span>: &lt;persona + Session Analysis + fixed rules&gt;}'
      '<span class="c">,  // constant</span><br>'
      '&nbsp;&nbsp;...history (prior turn summaries + sim decisions)'
      '<span class="c">,  // message_history=</span><br>'
      '&nbsp;&nbsp;{<span class="k">"role"</span>: <span class="k">"user"</span>, '
      '<span class="k">"content"</span>: &lt;this turn’s summary&gt;}'
      '<span class="c">  // prompt=, appended last</span><br>'
      ']<br>'
      'tools = [no-op, question, redirect, new_requirement, check_external]'
      '<span class="c">   // tool_choice="required"</span>'
      '</div>')
    # legend
    A('<div class="tv-legend">')
    for a in ("question", "redirect", "new_requirement", "check_external", "no-op"):
        mta = ACTION_META[a]
        A(f'<span class="tv-leg"><span class="tv-badge" data-a="{a}">{mta["emoji"]} '
          f'{mta["label"]}</span> {esc(mta["blurb"])}</span>')
    A("</div>")
    A("</div></section>")

    # system prompt (constant every turn)
    A('<section style="padding-top:6px"><div class="wrap">')
    A('<h2 class="sec-title">The system prompt</h2>')
    A('<p class="sec-intro">The literal first <code>system</code> message — '
      'identical every turn. It is <code>persona.render()</code> + the task’s '
      '<b>Session Analysis</b> (<code>user_simulation_prompt.md</code>) + the '
      'fixed behavioral rules, reconstructed by building the real '
      '<code>UserAgent._sys</code> from this trial’s <code>config.json</code>.</p>')
    A('<details class="tv-sys"><summary>Show the full system prompt '
      f'({len(m["system_prompt"])} chars)</summary>'
      f'<pre class="tv-pre tv-syspre">{highlight_summary(m["system_prompt"])}</pre>'
      '</details>')
    A("</div></section>")

    # timeline
    A('<section style="padding-top:10px"><div class="wrap">')
    A('<h2 class="sec-title">The trajectory</h2>')
    A('<div class="tv-tl">')

    for t in m["turns"]:
        if t["kind"] == "seed":
            A('<div class="tv-turn" data-action="seed"><div class="tv-card">')
            A('<div class="tv-top">'
              '<span class="tv-no">Turn 0</span>'
              '<span class="tv-badge" data-a="seed">🌱 real user seed</span>'
              '<span class="tv-csub">instruction.md · agent’s initial run</span>'
              '</div>')
            A('<div class="tv-io">')
            A('<div class="tv-col tv-in"><p class="tv-lbl">⬇ Real user input — instruction.md</p>'
              f'<pre class="tv-msg seed">{esc(t["user_input"])}</pre></div>')
            A('<div class="tv-col tv-out"><p class="tv-lbl">⬆ Agent (turn 0) — initial run</p>'
              f'<pre class="tv-pre">{highlight_summary(t["agent_activity"])}</pre></div>')
            A("</div>")
            A("</div></div>")
            continue

        a = t["action"]
        mta = ACTION_META.get(a, {"emoji": "", "label": a})
        A(f'<div class="tv-turn" data-action="{a}"><div class="tv-card">')
        A('<div class="tv-top">'
          f'<span class="tv-no">Turn {t["n"]}</span>'
          f'<span class="tv-badge" data-a="{a}">{mta["emoji"]} {mta["label"]}</span>'
          f'<span class="tv-csub">episode-{t["n"]} · reacts to agent turn '
          f'{t["src"]} · GT left {t["gt_left"]}</span>'
          '</div>')
        A('<div class="tv-io">')
        # INPUT
        in_note = ("Recorded verbatim from user_sim_prompt.json."
                   if m["prompt_source"] == "recorded"
                   else "Timing approximated from decision timestamps; "
                        "all else replayed from logs by the current parser.")
        A('<div class="tv-col tv-in"><p class="tv-lbl">⬇ Input — turn summary the sim sees</p>'
          f'<p class="tv-note">{in_note}</p>'
          f'<pre class="tv-pre">{highlight_summary(t["summary"])}</pre></div>')
        # OUTPUT
        A('<div class="tv-col tv-out"><p class="tv-lbl">⬆ Output — the sim’s decision</p>')
        if t["has_message"]:
            A(f'<pre class="tv-msg">{esc(t["content"])}</pre>')
        else:
            A('<div class="tv-silent">🤐 no-op — stays silent; wrapper sends the agent a synthetic <code>continue</code>.</div>')
        if t["raw"]:
            A('<details class="tv-rawbox"><summary>model reasoning (raw_response)</summary>'
              f'<pre class="tv-pre">{esc(t["raw"][:600])}</pre></details>')
        A("</div>")  # tv-out
        A("</div>")  # tv-io
        A("</div></div>")  # tv-card / tv-turn

    A("</div>")  # tv-tl
    A("</div></section>")

    A("</main>")
    A(footer)
    A("</body>")
    A("</html>")
    return "\n".join(P)


def main():
    m = build_model()
    OUT_MD.write_text(render_md(m))
    OUT_HTML.write_text(render_html(m))
    print(f"wrote {OUT_MD.name} and {OUT_HTML.name} "
          f"(turns={m['n_turns']}, msgs={m['n_msgs']}, reward={m['reward']})")


if __name__ == "__main__":
    main()
