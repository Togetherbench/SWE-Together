Implement the following plan:

# Plan: Complete Zone Classification System

## Context

The initial zone implementation (zones.py, zone stamps, scoring exclusion, TS line classifier) is working but has three gaps:

1. **Potentials denominator mismatch** — Scoring excludes test/config/generated/vendor findings from the numerator, but phase runners still count ALL files in potentials. This inflates pass rates.
2. **ZONE_POLICIES.skip_detectors defined but not enforced** — Only `phase_dupes` filters by zone. Graph-based and other detectors still run on and generate findings for all files.
3. **No user override mechanism** — Misclassifications (e.g. a production `config.py`) can't be corrected.

Additionally, pattern matching is pure substring which can cause false positives, and some zone rules should be shared across languages.

## Design Principles

- **Zones are like soft exclusions** — auto-detected on first scan, stored in state, visible to the user/LLM, adjustable via CLI. Unlike `--exclude` (files invisible), zones keep files visible but score them differently.
- **Language-agnostic core, per-language rules** — Zone enum, policies, scoring are shared. Classification rules are per-language with common base patterns.
- **Full graph, filtered output** — Dependency graph includes ALL files (so import relationships are accurate). Findings are filtered by zone BEFORE creating finding objects. Exception: `phase_dupes` pre-filters functions (O(n²) cost justifies it).
- **Deterministic, no LLM** — Classification is path-pattern-based. LLM only consumes zone metadata.

## Implementation

### 1. Pattern matching precision — `desloppify/zones.py`

Replace raw `pattern in rel_path` with `_match_pattern()` that distinguishes pattern types:

```python
def _match_pattern(rel_path: str, pattern: str) -> bool:
    """Match a zone pattern against a relative file path.

    - "/dir/" → substring match on full path (directory pattern)
    - "exact.py" → basename exact match (no / in pattern, has extension)
    - "prefix_" → basename starts-with (trailing _)
    - "_suffix.py" → basename ends-with (leading _)
    - ".suffix" → basename ends-with (e.g. ".test.", ".d.ts")
    - Fallback: substring on full path
    """
```

This fixes: `config.py` only matches files literally named `config.py` (any depth — that's correct, a file named `config.py` IS config). `test_` only matches basenames starting with `test_`, not directory names containing `test_`.

Update `classify_file()` to use `_match_pattern`.

### 2. Common + per-language zone rules — `desloppify/zones.py` + lang configs

Add shared universal rules to `zones.py`:
```python
COMMON_ZONE_RULES = [
    ZoneRule(Zone.VENDOR, ["/vendor/", "/third_party/", "/vendored/"]),
    ZoneRule(Zone.GENERATED, ["/generated/", "/__generated__/"]),
    ZoneRule(Zone.TEST, ["/tests/", "/test/", "/fixtures/"]),
    ZoneRule(Zone.SCRIPT, ["/scripts/", "/bin/"]),
]
```

Language-specific rules prepend (higher priority, first-match wins). Define these as **module-level variables** in the respective language modules (`desloppify/lang/python/__init__.py` and `desloppify/lang/typescript/__init__.py`):
```python
# In desloppify/lang/python/__init__.py:
PY_ZONE_RULES = [<python-specific>] + COMMON_ZONE_RULES

# In desloppify/lang/typescript/__init__.py:
TS_ZONE_RULES = [<ts-specific>] + COMMON_ZONE_RULES
```

Each language's rules list should include at least one language-specific `ZoneRule` before the common rules. Python-specific rules should include patterns like `test_` for test file prefixes. TypeScript-specific rules should include patterns like `.test.`, `.spec.`, or `__tests__` for test file conventions.

### 3. Potentials adjustment — `desloppify/zones.py` + all phase runners

Add helper to `zones.py`:
```python
def adjust_potential(zone_map, files: list[str], total: int) -> int:
    """Subtract non-production files from a potential count. No-op if zone_map is None."""
```

Add `production_count()` method to `FileZoneMap`.

Add `counts()` method to `FileZoneMap` that returns a `dict` mapping zone values to the number of files in each zone:
```python
def counts(self) -> dict:
    """Return {zone_value: count} for all zones in this map."""
```

Apply in **every phase runner** that returns potentials:

**Python** (`lang/python/__init__.py`):
- `_phase_unused`: adjust `total_files`
- `_phase_structural`: adjust `file_count` (structural potential)
- `_phase_coupling`: adjust `total_graph_files` and `single_candidates` using graph file list
- `_phase_smells`: adjust `total_files`

**TypeScript** (`lang/typescript/__init__.py`):
- `_phase_logs`: adjust `total_files`
- `_phase_unused`: adjust `total_files`
- `_phase_exports`: adjust `total_exports` — NOTE: this is export count not file count, so leave as-is (exports are per-symbol, not per-file, and test files don't usually have exported APIs)
- `_phase_deprecated`: leave as-is (same reasoning — symbol count)
- `_phase_structural`: adjust `file_count`
- `_phase_coupling`: adjust `total_graph_files`, `single_candidates`, `coupling_edges + cross_edges`
- `_phase_smells`: adjust `total_smell_files`

Pattern for each phase runner:
```python
from ...zones import adjust_potential
files = lang.file_finder(path) if lang.file_finder else []
potentials = {
    "detector_name": adjust_potential(lang._zone_map, files, raw_total),
}
```

For coupling phases, the file list comes from the graph:
```python
graph_files = list(graph.keys())
adjusted = adjust_potential(lang._zone_map, graph_files, total_graph_files)
```

### 4. Skip-detector enforcement in phase runners

**Approach: filter findings, not inputs.** The dependency graph must stay complete (all files) so import relationships are accurate. A production file imported ONLY by test files should NOT be flagged as orphaned. Instead, after running detectors, skip creating findings for files in zones where the detector is skipped.

Add helper to `zones.py`:
```python
def should_skip_finding(zone_map, filepath: str, detector: str) -> bool:
    """Check if a finding should be skipped based on zone policy."""
    if zone_map is None:
        return False
    zone = zone_map.get(filepath)
    policy = ZONE_POLICIES.get(zone)
    return policy is not None and detector in policy.skip_detectors
```

Apply in coupling phase runners (both Python and TS) — wrap finding creation:
```python
# Before: unconditionally create findings
results.extend(make_orphaned_findings(orphan_entries, log))

# After: filter entries first
from ...zones import should_skip_finding
orphan_entries = [e for e in orphan_entries
                  if not should_skip_finding(lang._zone_map, e["file"], "orphaned")]
results.extend(make_orphaned_findings(orphan_entries, log))
```

Same pattern for: `single_use`, `orphaned`, `facade`, `coupling`, `cycles` (filter by first file in cycle).

**NOT applied to cheap detectors** (smells, structural, unused, logs, exports, deprecated) — those still run on all files, get zone-stamped, and scoring handles exclusion. This preserves informational value.

### 5. Zone overrides — state config + CLI

**Storage:** `state["config"]["zone_overrides"]` = `{"relative/path": "zone_value"}`.

**FileZoneMap changes** (`zones.py`): Add `overrides: dict[str, str] | None` param to `__init__`. Overrides take priority over rule-based classification.

**LangConfig changes** (`lang/base.py`): Add a `zone_rules` field (type `list`, default empty list `[]`) to the `LangConfig` dataclass so each language config can carry its zone rules.

**Pipeline threading** (`plan.py`): `generate_findings()` and `_generate_findings_from_lang()` accept `zone_overrides` param. `cmd_scan` reads overrides from state and passes them through.

**New CLI subcommand** — `desloppify zone`:
- `desloppify zone show` — show zone classifications for all scanned files (highlight overrides)
- `desloppify zone set <path> <zone>` — add/update override in state config
- `desloppify zone clear <path>` — remove override

New file: `desloppify/commands/zone_cmd.py`
Wire in: `desloppify/cli.py` (add subparser + command dispatch)

**First-scan reporting:** When zone_distribution is first computed, include it in query.json so the LLM can tell the user what was classified and suggest overrides if something looks wrong.

### 6. Narrative zone awareness — `desloppify/narrative.py`

Add reminder when non-production zones have files:
```
"N files classified as non-production (test/config/generated).
 Override with `desloppify zone set <file> production` if any are misclassified."
```

Only show on first scan or when zone distribution changes.

## Files to modify

| File | Changes |
|------|--------|
| `desloppify/zones.py` | `_match_pattern()`, `COMMON_ZONE_RULES`, `adjust_potential()`, `should_skip_finding()`, `FileZoneMap.production_count()`, `FileZoneMap.counts()`, `FileZoneMap.__init__` overrides param |
| `desloppify/lang/python/__init__.py` | Define `PY_ZONE_RULES` module-level variable; adjust potentials in `_phase_unused`, `_phase_structural`, `_phase_coupling`, `_phase_smells`; filter entries in `_phase_coupling`; import from zones |
| `desloppify/lang/typescript/__init__.py` | Define `TS_ZONE_RULES` module-level variable; same potentials adjustment + entry filtering for all TS phase runners; import from zones |
| `desloppify/lang/base.py` | Add `zone_rules` field to `LangConfig` dataclass (default `[]`) |
| `desloppify/plan.py` | Thread `zone_overrides` through `generate_findings` → `_generate_findings_from_lang` |
| `desloppify/commands/scan.py` | Pass `zone_overrides` from state to `generate_findings` |
| `desloppify/cli.py` | Add `zone` subcommand parser, wire `cmd_zone` |
| **NEW** `desloppify/commands/zone_cmd.py` | `cmd_zone` handler: show/set/clear |
| `desloppify/narrative.py` | Zone-aware first-scan reminder |

## Verification

1. **Potentials check**: Scan desloppify (Python, 72 files, all production). Potentials should be unchanged (no non-production files to subtract). Then create a dummy `test_foo.py`, rescan — potentials should drop by 1 for file-based detectors.
2. **Finding filtering**: Add a test file with an orphaned function. Verify no `orphaned` finding is created for it.
3. **Graph accuracy**: Verify a production file imported only by a test file is NOT flagged as orphaned (graph keeps all edges).
4. **Override round-trip**: `desloppify zone set foo.py production` → rescan → verify `foo.py` is classified as production.
5. **Zone show**: `desloppify zone show` displays all files with their zones, overrides highlighted.
6. **Backward compat**: Load old state without `zone_overrides` — no errors.
7. **Cross-language**: Test on both Python and TS repos.
8. **Score comparison**: Before/after scan comparison — score should be stable for all-production codebases, improved for codebases with test files that were generating false positives.


If you need specific details from before exiting plan mode (like exact code snippets, error messages, or content you generated), read the full transcript at: /user_c042661f/.claude/projects/-Users-user_c042661f-Documents-desloppify/8706443a-a172-4bf4-b68d-c26eb8aac423.jsonl