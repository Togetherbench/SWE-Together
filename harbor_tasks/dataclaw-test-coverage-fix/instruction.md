Implement the following plan:

# DataClaw: Tests + Findings Fix Plan (74.4 → 90+)

## Context

DataClaw is at 74.4/100 strict score with 28 open findings. The single biggest drag is **Test health at 5.8%** (-16 pts, the largest single lever). Zero tests exist today. Writing comprehensive tests + fixing the fixable findings should push us past 90.

## Execution Order

### Step 1: Test Infrastructure
**Create `tests/conftest.py`** — shared fixtures:
- `sample_session_entry()` — realistic JSONL entry dicts (user + assistant types)
- `mock_anonymizer()` — Anonymizer with patched `_detect_home_dir` returning deterministic values
- `tmp_config()` — monkeypatched CONFIG_FILE pointing to tmp_path

### Step 2: Test secrets.py (~55 tests, highest priority)
**Create `tests/test_secrets.py`** — all pure functions, no mocking needed:
- `_shannon_entropy`: empty string, repeated char, known values, boundary cases
- `_has_mixed_char_types`: upper-only, lower-only, digit-only, mixed
- `scan_text`: one test per pattern type (JWT, db_url, anthropic_key, openai_key, hf_token, github_token, pypi_token, npm_token, aws_key, aws_secret, slack_token, discord_webhook, private_key, cli_token_flag, env_secret, generic_secret, bearer, ip_address, url_token, email, high_entropy)
- Allowlist: noreply@, @example.com, private IPs, @pytest, example DB URLs
- `redact_text`: no secrets, single secret, overlapping matches, multiple secrets
- `redact_custom_strings`: empty text, short strings skipped, word boundary matching
- `redact_session`: empty messages, redacts content/thinking/tool_use fields

### Step 3: Test anonymizer.py (~25 tests)
**Create `tests/test_anonymizer.py`** — pure functions, patch `_detect_home_dir`:
- `_hash_username`: deterministic, different inputs differ, prefix format
- `anonymize_path`: Documents/Downloads/Desktop prefix stripping, bare home, path not under home
- `anonymize_text`: /Users/ and /home/ replacement, hyphen-encoded paths, temp paths, bare username (≥4 chars), short username skipped
- `Anonymizer` class: `.path()`, `.text()`, extra_usernames, deduplication
- `_replace_username`: case-insensitive, short username skipped

### Step 4: Test parser.py (~40 tests)
**Create `tests/test_parser.py`** — mix of pure functions and file I/O with tmp_path:
- `_build_project_name`: 10+ cases (Documents prefix, home prefix, common dirs, bare home, standalone, edge cases)
- `_normalize_timestamp`: None, string passthrough, int/float ms→ISO, other types
- `_summarize_tool_input`: Read/Write/Bash/Grep/Glob/Task/WebSearch/unknown tools
- `_extract_user_content`: string content, list content, empty/whitespace
- `_extract_assistant_content`: text blocks, thinking include/exclude, tool_uses, empty
- `_process_entry`: user entry, assistant entry, unknown type, metadata extraction
- `_parse_session_file`: valid JSONL, malformed lines skipped, OSError→None, empty file
- `discover_projects` + `parse_project_sessions`: monkeypatched PROJECTS_DIR with tmp_path

### Step 5: Test cli.py (~30 tests)
**Create `tests/test_cli.py`** — pure functions + mocked integration:
- `_format_size`: B, KB, MB, GB thresholds
- `_format_token_count`: plain, K, M, B thresholds
- `_parse_csv_arg`: None, empty, single, comma-separated
- `_merge_config_list`: merge, deduplicate, sort
- `default_repo_name`: format check
- `_build_dataset_card`: returns valid markdown with YAML frontmatter
- `export_to_jsonl`: writes JSONL, skips synthetic models, counts redactions (mock parse_project_sessions)
- `configure`: sets repo, merges exclude/redact lists (monkeypatch config file)
- `list_projects`: output with/without projects (monkeypatch discover_projects)
- `push_to_huggingface`: missing huggingface_hub, success flow, auth failure (mock HfApi)

### Step 6: Test config.py (~8 tests)
**Create `tests/test_config.py`** — monkeypatch CONFIG_FILE:
- `load_config`: no file→defaults, valid file merged, corrupt JSON→defaults+warning, extra keys preserved
- `save_config`: creates dir, writes JSON, OSError→warning

### Step 7: Fix Findings (Code Changes)

**Fix `dataclaw/parser.py`** (2 findings):
- `silent_except` (line 86): Add `skipped_lines` counter to stats dict, log count
- Type annotations: Add types to `_process_entry`, `_extract_user_content`, `_extract_assistant_content`, `_summarize_tool_input`

**Fix `dataclaw/config.py`** (2 findings):
- Add `DataClawConfig` TypedDict with typed fields
- Change `load_config() -> DataClawConfig` and `save_config(config: DataClawConfig)`

**Fix `dataclaw/cli.py`** (1 finding):
- Use `DataClawConfig` type in function signatures

### Step 8: Triage Remaining Findings

**Mark as `false_positive`** (2 security):
- `cli.py:566` — prints redaction *count*, not actual secrets
- `cli.py:621` — literal help text showing example command syntax

**Mark as `wontfix`** (11 findings):
- `security::secrets.py::119,120` — allowlist patterns ARE example URLs, not credentials; but they exist to prevent false positives on documentation DB URLs. `wontfix` (functional purpose)
- `smells::cli.py::magic_number` — 1024 is universally understood (bytes→KB)
- `smells::parser.py::magic_number` — /1000 for ms→s is self-documenting
- `smells::cli.py::deferred_import` — intentional for optional huggingface_hub dep
- `smells::config.py::swallowed_error` — resilient config is correct for CLI tools
- `review::cross_module_architecture::cli_hub_module` — premature decomposition for 5-file project
- `review::design_coherence::cli_mixed_responsibilities` — same as above
- `review::high_level_elegance::mixed_output_contracts` — intentional dual-audience (JSON for agents, interactive for humans)
- `review::mid_level_elegance::double_redaction_tool_inputs` — defense-in-depth, not a bug
- `review::mid_level_elegance::process_entry_mutation_bag` — standard JSONL accumulator pattern
- `review::low_level_elegance::build_project_name_complexity` — inherently complex problem, covered by tests
- `structural::cli.py` — 549 LOC is reasonable for a CLI entry point

### Step 9: Rescan
- `desloppify scan --path .` to verify mechanical improvements
- Check if score exceeds 90

## Expected Impact

| Dimension | Before | After (est.) |
|-----------|--------|-------------|
| Test health | 5.8% | ~85-90% |
| Security | 80.0% | ~90%+ |
| Code quality | 93.9% | ~96%+ |
| File health | 86.0% | 86.0% (structural wontfix'd) |

**Projected: 74.4 → ~91-95** (tests alone worth +12-15 pts)

## Verification
1. `cd /workspace/dataclaw && python -m pytest tests/ -v` — all tests pass
2. Check finding counts: open findings should drop from 28 to ~0-2
