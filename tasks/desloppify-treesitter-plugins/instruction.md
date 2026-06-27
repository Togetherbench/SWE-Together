Implement the following plan:

# Make Generic Language Plugins Fully Functional

## Context

We already have 22 generic language plugins (go, rust, ruby, swift, etc.) that run external tools and produce findings. But these findings are **dead weight** — they exist in state but don't participate in scoring, narrative, or actions. The generic detector IDs (e.g., `golangci_lint`, `rubocop_lint`) aren't registered in the canonical detector registry, scoring policy, or narrative system. Additionally, generic plugins don't run shared phases (security, boilerplate duplication, subjective review, duplicates).

The goal: make generic plugins behave like first-class citizens. Findings should score, narrative should generate actions, shared phases should run, and tools with `--fix` support should have auto-fixers.

---

## Step 1: Dynamic Detector Registration

**Problem:** `DETECTORS` dict in `registry.py` and `DETECTOR_SCORING_POLICIES` in `scoring_internal/policy/core.py` are static. Generic tool IDs aren't in them, so findings from generic plugins have zero scoring impact and generate no narrative actions.

**Solution:** Add runtime registration functions that generic plugins call at import time.

### `desloppify/core/registry.py` — add `register_detector()`

```python
def register_detector(meta: DetectorMeta) -> None:
    """Register a detector at runtime (used by generic plugins)."""
    DETECTORS[meta.name] = meta
    if meta.name not in _DISPLAY_ORDER:
        _DISPLAY_ORDER.append(meta.name)
```

### `desloppify/engine/scoring_internal/policy/core.py` — add `register_scoring_policy()`

```python
def register_scoring_policy(policy: DetectorScoringPolicy) -> None:
    """Register a scoring policy at runtime (used by generic plugins)."""
    DETECTOR_SCORING_POLICIES[policy.detector] = policy
    _rebuild_derived()

def _rebuild_derived() -> None:
    """Rebuild DIMENSIONS, DIMENSIONS_BY_NAME, FILE_BASED_DETECTORS from current state."""
    global DIMENSIONS, DIMENSIONS_BY_NAME, FILE_BASED_DETECTORS
    DIMENSIONS = _build_dimensions()
    DIMENSIONS_BY_NAME = {d.name: d for d in DIMENSIONS}
    FILE_BASED_DETECTORS = {
        det for det, pol in DETECTOR_SCORING_POLICIES.items() if pol.file_based
    }
```

### `desloppify/intelligence/narrative/_constants.py` — add `refresh_detector_tools()`

`DETECTOR_TOOLS` is computed at import time from `DETECTORS`. Since narrative modules import it by name (`from _constants import DETECTOR_TOOLS`), they hold a reference to the dict object. Mutating in-place ensures all references see updates.

```python
def refresh_detector_tools() -> None:
    """Rebuild DETECTOR_TOOLS from current DETECTORS (call after dynamic registration)."""
    DETECTOR_TOOLS.clear()
    DETECTOR_TOOLS.update(_detector_tools())
```

---

## Step 2: Wire `generic_lang()` to Register Detectors

### `desloppify/languages/framework/generic.py`

When `generic_lang()` creates a plugin, register each tool as a detector:

```python
from desloppify.core.registry import DetectorMeta, register_detector
from desloppify.engine.scoring_internal.policy.core import (
    DetectorScoringPolicy, register_scoring_policy,
)
from desloppify.intelligence.narrative._constants import refresh_detector_tools

def generic_lang(...):
    # ... existing code ...

    # Register each tool as a detector so findings participate in scoring/narrative
    for tool in tools:
        register_detector(DetectorMeta(
            name=tool["id"],
            display=tool["label"],
            dimension="Code quality",
            action_type="manual_fix",
            guidance=f"review and fix {tool['label']} findings",
        ))
        register_scoring_policy(DetectorScoringPolicy(
            detector=tool["id"],
            dimension="Code quality",
            tier=tool["tier"],
            file_based=True,
        ))
    refresh_detector_tools()

    # ... register_generic_lang(name, cfg) ...
```

**Timing:** `generic_lang()` is called during `load_all()` in discovery.py, which runs before any scan/narrative computation. By the time scoring/narrative code reads the registries, they're already populated.

**Why `dimension="Code quality"` for all?** External linting tools primarily detect code quality issues (style, bugs, unused code). This maps naturally. Security-specific tools could be mapped to "Security" in future via an optional `dimension` key in the tool spec.

---

## Step 3: Append Shared Phases to Generic Plugins

**Problem:** Generic plugins only have tool-specific phases. They miss cross-language phases: security (regex-based secret/vulnerability detection), boilerplate duplication (jscpd), subjective review, and duplicate function detection.

**Solution:** Append shared phases in `generic_lang()`.

### `desloppify/languages/framework/generic.py`

```python
from desloppify.languages.framework.base.phase_builders import (
    detector_phase_security,
    shared_subjective_duplicates_tail,
)

def generic_lang(...):
    phases = [make_tool_phase(...) for t in tools]

    # Shared phases that work without deep language analysis:
    # - security: regex-based, needs file_finder only
    # - subjective review: needs file_finder only
    # - boilerplate duplication: external jscpd, language-agnostic
    # - duplicates: needs extract_functions (noop returns [], detector handles gracefully)
    phases.append(detector_phase_security())
    phases.extend(shared_subjective_duplicates_tail())

    cfg = LangConfig(..., phases=phases, ...)
```

**What's NOT included:** `test_coverage` — requires a real dep graph. With `empty_dep_graph`, it would build the graph (returns `{}`), then find 0 production files, producing misleading results. Better to omit.

**Graceful degradation:**
- `phase_dupes()` calls `extract_functions()` → `noop_extract_functions()` → `[]` → `detect_duplicates([])` → `[], 0`. No findings, no crash.
- `phase_security()` calls `file_finder()` → works, scans all source files with regex patterns.
- `phase_boilerplate_duplication()` calls external `jscpd` → works if installed, empty results if not.
- `phase_subjective_review()` uses `review_cache` from LangRun (defaults to `{}`), `file_finder()` → works.

---

## Step 4: Optional Tool Fixers

**Problem:** Many linting tools support `--fix` mode (rubocop, golangci-lint, cargo clippy, ktlint, swiftlint, etc.) but generic plugins ship with `fixers={}`.

**Solution:** Extend tool spec with optional `fix_cmd`. When present, create a `FixerConfig`.

### Tool spec extension

```python
{
    "label": "rubocop",
    "cmd": "rubocop --format=json",
    "fmt": "rubocop",
    "id": "rubocop_lint",
    "tier": 2,
    "fix_cmd": "rubocop --auto-correct",  # NEW — optional
}
```

### `desloppify/languages/framework/generic.py` — fixer creation

```python
def _make_generic_fixer(tool: dict) -> FixerConfig:
    """Create a FixerConfig from a tool spec with fix_cmd."""
    smell_id = tool["id"]
    fix_cmd = tool["fix_cmd"]
    parser = _PARSERS[tool["fmt"]]
    detect_cmd = tool["cmd"]

    def detect(path, **kwargs):
        try:
            result = subprocess.run(
                detect_cmd, shell=True, cwd=str(path),
                capture_output=True, text=True, timeout=120,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return []
        output = (result.stdout or "") + (result.stderr or "")
        return parser(output, path)

    def fix(entries, dry_run=False, path=None, **kwargs):
        if dry_run or not path:
            return FixResult(entries=[{"file": e["file"], "line": e["line"]} for e in entries])
        try:
            subprocess.run(
                fix_cmd, shell=True, cwd=str(path),
                capture_output=True, text=True, timeout=120,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return FixResult(entries=[], skip_reasons={"tool_unavailable": len(entries)})
        # Re-detect to see what's left
        remaining = detect(path)
        fixed_count = len(entries) - len(remaining)
        return FixResult(entries=[{"file": e["file"], "fixed": True} for e in entries[:fixed_count]])

    return FixerConfig(
        label=f"Fix {tool['label']} issues",
        detect=detect,
        fix=fix,
        detector=smell_id,
        verb="Fixed",
        dry_verb="Would fix",
    )
```

### Wire into `generic_lang()`

```python
fixers = {}
for tool in tools:
    if "fix_cmd" in tool:
        fixer_name = tool["id"].replace("_", "-")
        fixers[fixer_name] = _make_generic_fixer(tool)
        # Update detector meta to include fixer
        register_detector(DetectorMeta(
            ...,
            action_type="auto_fix",  # Changed from manual_fix
            fixers=(fixer_name,),
        ))

cfg = LangConfig(..., fixers=fixers, ...)
```

### Update plugin files with fix_cmd

| Plugin | fix_cmd |
|--------|---------|
| `go` | `golangci-lint run --fix` |
| `rust` | `cargo clippy --fix --allow-dirty` |
| `ruby` | `rubocop --auto-correct` |
| `swift` | `swiftlint --fix` |
| `kotlin` | `ktlint --format` |
| `elixir` | (none — credo has no auto-fix) |
| `php` | (none — phpstan has no auto-fix) |
| `cxx` | (none — cppcheck has no auto-fix) |
| `bash` | (none — shellcheck has no auto-fix) |
| `perl` | (none — perlcritic has no auto-fix) |
| `lua` | (none — luacheck has no auto-fix) |

---

## Step 5: Update `langs` Command

### `desloppify/app/commands/langs.py`

Update `_get_tool_labels()` to show fixer availability:

```python
def _get_tool_labels(cfg: LangConfig) -> str:
    if cfg.integration_depth == "full":
        return "custom detectors"
    labels = [p.label for p in cfg.phases if p.label not in _SHARED_PHASE_LABELS]
    suffix = ""
    if cfg.fixers:
        suffix = " (auto-fix)"
    return (", ".join(labels) if labels else "none") + suffix
```

Where `_SHARED_PHASE_LABELS` filters out "Security", "Subjective review", "Boilerplate duplication", "Duplicates" from the tool list since those are framework phases, not tool-specific.

---

## Files to Modify

| File | Change |
|------|--------|
| `desloppify/core/registry.py` | Add `register_detector()` |
| `desloppify/engine/scoring_internal/policy/core.py` | Add `register_scoring_policy()`, `_rebuild_derived()` |
| `desloppify/intelligence/narrative/_constants.py` | Add `refresh_detector_tools()` |
| `desloppify/languages/framework/generic.py` | Register detectors, append shared phases, optional fixers |
| `desloppify/languages/go/__init__.py` | Add `fix_cmd` to golangci-lint tool |
| `desloppify/languages/rust/__init__.py` | Add `fix_cmd` to cargo clippy tool |
| `desloppify/languages/ruby/__init__.py` | Add `fix_cmd` to rubocop tool |
| `desloppify/languages/swift/__init__.py` | Add `fix_cmd` to swiftlint tool |
| `desloppify/languages/kotlin/__init__.py` | Add `fix_cmd` to ktlint tool |
| `desloppify/app/commands/langs.py` | Filter shared phase labels from tool list |
| `desloppify/tests/lang/common/test_generic_plugin.py` | New tests for scoring, narrative, fixers |

---

## Tests to Add (`test_generic_plugin.py`)

```
# Dynamic registration
test_register_detector_adds_to_detectors_dict
test_register_scoring_policy_rebuilds_dimensions
test_refresh_detector_tools_updates_in_place

# Scoring integration
test_generic_findings_contribute_to_code_quality_dimension
test_generic_findings_score_with_correct_tier

# Narrative integration
test_generic_detector_appears_in_detector_tools
test_narrative_actions_include_generic_detectors

# Shared phases
test_generic_plugin_has_security_phase
test_generic_plugin_has_subjective_review_phase
test_generic_plugin_has_duplicates_phase
test_generic_plugin_has_boilerplate_duplication_phase
test_generic_plugin_phase_order_matches_convention

# Fixers
test_fix_cmd_creates_fixer_config
test_fixer_detect_calls_tool
test_fixer_dry_run_returns_entries
test_tool_without_fix_cmd_has_no_fixer
test_fixer_name_uses_dash_convention

# Langs command
test_langs_hides_shared_phases_from_tool_list
test_langs_shows_auto_fix_suffix
```

---

## Verification

```bash
# All tests pass
python -m pytest desloppify/ -q

# Go scan shows scoring impact (if golangci-lint installed)
python -m desloppify --lang go scan --path /some/go/project
# → findings should appear in dimension scores, narrative should have actions

# Self-scan still works
python -m desloppify --lang python scan --path desloppify

# Langs command shows updated info
python -m desloppify langs

# Fix command works for tools with fix_cmd (if tool installed)
python -m desloppify --lang ruby fix rubocop-lint --dry-run --path /some/ruby/project
```


If you need specific details from before exiting plan mode (like exact code snippets, error messages, or content you generated), read the full transcript at: /user_c042661f/.claude/projects/-Users-user_c042661f-Documents-desloppify/dfcde3bc-d318-4975-870f-dde5f813f55e.jsonl
