# DataClaw: Write Comprehensive Test Suite

## Context

DataClaw is a Python package at `/workspace/dataclaw` that processes and anonymizes AI conversation data. The package currently has **zero tests**. Your task is to write a comprehensive pytest-based test suite.

## Package Structure

The `dataclaw/` package has these modules:
- `secrets.py` — Secret detection and redaction in text
- `anonymizer.py` — Path and username anonymization
- `parser.py` — JSONL session file parsing and project discovery
- `cli.py` — CLI entry points and utility functions
- `config.py` — JSON configuration file management

Read the source code in each module to understand the functions and their behavior before writing tests.

## Requirements

1. Create a `tests/` directory with a `conftest.py` containing shared fixtures
2. Write test files covering **all** modules in `dataclaw/`
3. All tests must pass: `cd /workspace/dataclaw && python -m pytest tests/ -v`

## Quality Bar

- Use meaningful assertions that verify actual behavior (not `assert True`)
- Test both normal operation and edge cases (empty inputs, invalid data, error paths, boundary conditions)
- Use pytest features appropriately (fixtures, parametrize, monkeypatch, tmp_path)
- Tests should be robust enough to detect regressions if source functions are mutated
- Cover all modules with sufficient depth — don't just test the easy or obvious functions
- Aim for thorough coverage of each module's public and private API
