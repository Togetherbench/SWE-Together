#!/usr/bin/env python3
"""Migrate harbor tasks from bespoke F2P weighted gates to SWE-rebench-style
log-parser eval.

For each task in `harbor_tasks/`, this script:
  1. Detects the language / test framework from the Dockerfile.
  2. Splits the canonical patch into source-changes vs test-changes.
  3. Extracts FAIL_TO_PASS = test names ADDED in the test_patch.
  4. Picks the right log parser (pytest / vitest / gotest / cargo / etc).
  5. Emits `tests/install_config.json` with everything needed to run eval.
  6. Replaces `tests/test.sh` with the new eval script that:
        - applies the agent's diff (if any)
        - runs the test_cmd
        - parses stdout via the named log_parser
        - scores = passed_FAIL_TO_PASS / total_FAIL_TO_PASS  (binary, SWE-bench style)
        - cap to 0 if any PASS_TO_PASS regresses (when present)

The old `tests/test_manifest.yaml` is preserved as `tests/test_manifest.yaml.legacy.bak`
so you can revert if needed.

Usage:
  python data-pipeline/scaffold/build_swerebench_configs.py --dry-run    # plan only
  python data-pipeline/scaffold/build_swerebench_configs.py              # all tasks
  python data-pipeline/scaffold/build_swerebench_configs.py --task <name>  # one task
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HARBOR_TASKS = ROOT / "harbor_tasks"
SC_CANONICAL_PATCHES = ROOT / "data-pipeline" / "artifacts_swechat" / "canonical_patches"
LOG_PARSERS_DIR = ROOT / "data-pipeline" / "scaffold" / "log_parsers"


def _find_canonical(sid: str) -> Path | None:
    """Locate `<sid>.json` across SWE-chat + every non-SWE-chat source dir
    (artifacts_dataclaw/, artifacts_hyperswitch/, artifacts_pi-mono/, ...)."""
    if SC_CANONICAL_PATCHES / f"{sid}.json" in (p for p in (SC_CANONICAL_PATCHES,)):
        pass  # silence linter
    p = SC_CANONICAL_PATCHES / f"{sid}.json"
    if p.exists():
        return p
    for d in sorted((ROOT / "data-pipeline").glob("artifacts_*/canonical_patches")):
        if d == SC_CANONICAL_PATCHES:
            continue
        q = d / f"{sid}.json"
        if q.exists():
            return q
    return None

# ──────────────────────────────────────────────────────────────────────────────
# Language + framework detection
# ──────────────────────────────────────────────────────────────────────────────

LANG_HEURISTICS = [
    # (regex on Dockerfile, language)
    (r"\b(rustup|cargo install|cargo build|cargo test|cargo nextest)\b", "rust"),
    (r"\b(BUN_INSTALL|bun install|bun run|bun test)\b", "ts_bun"),
    (r"\b(pnpm install|pnpm test)\b", "ts_pnpm"),
    (r"\b(npm install|npm run|npm test|yarn install)\b", "ts_npm"),
    (r"\b(GOPATH|go install|/usr/local/go|go test|go build|go mod)\b", "go"),
    (r"\b(pip install|requirements\.txt|pyproject\.toml|poetry|uv pip)\b", "python"),
]

# language → (default log_parser, default test_cmd template)
LANG_PARSER = {
    "rust":     ("parse_log_cargo",  "cargo test --workspace --no-fail-fast 2>&1"),
    # vitest needs --reporter=verbose for per-test ✓/× lines that parse_log_vitest reads.
    # `bun x` / `pnpm exec` invoke the local install rather than relying on a `test` script.
    "ts_bun":   ("parse_log_vitest", "bun x vitest run --reporter=verbose 2>&1"),
    "ts_pnpm":  ("parse_log_vitest", "pnpm exec vitest run --reporter=verbose 2>&1"),
    "ts_npm":   ("parse_log_jest",   "npx jest --verbose 2>&1"),
    "go":       ("parse_log_gotest", "go test ./... 2>&1"),
    "python":   ("parse_log_pytest", "python -m pytest 2>&1"),
}


def detect_language(dockerfile: str) -> str:
    for pattern, lang in LANG_HEURISTICS:
        if re.search(pattern, dockerfile, re.IGNORECASE):
            return lang
    return "unknown"


# ──────────────────────────────────────────────────────────────────────────────
# Canonical patch splitter — separate source vs test files
# ──────────────────────────────────────────────────────────────────────────────

# Test file path patterns per language
TEST_PATH_PATTERNS = {
    "rust":     [r".*test.*\.rs$", r".*\btests/.*\.rs$"],   # also inline `mod tests` lives in source files (handled separately)
    "ts_bun":   [r".*\.test\.[tj]sx?$", r".*\.spec\.[tj]sx?$", r".*__tests__/.*"],
    "ts_pnpm":  [r".*\.test\.[tj]sx?$", r".*\.spec\.[tj]sx?$", r".*__tests__/.*"],
    "ts_npm":   [r".*\.test\.[tj]sx?$", r".*\.spec\.[tj]sx?$", r".*__tests__/.*"],
    "go":       [r".*_test\.go$"],
    "python":   [r".*test_.*\.py$", r".*_test\.py$", r".*tests?/.*\.py$"],
}


def split_patch(patch: str, lang: str) -> tuple[str, str, list[str], list[str]]:
    """Split unified diff into (source_patch, test_patch, source_files, test_files).

    Identifies test files by path pattern (per-language).
    """
    test_patterns = [re.compile(p) for p in TEST_PATH_PATTERNS.get(lang, [])]

    # Split patch into per-file hunks
    file_blocks: list[tuple[str, list[str]]] = []  # (path, lines)
    current_path = None
    current_lines: list[str] = []

    for line in patch.splitlines():
        if line.startswith("diff --git "):
            if current_path is not None:
                file_blocks.append((current_path, current_lines))
            # Extract path from "diff --git a/<path> b/<path>"
            m = re.match(r"diff --git a/(\S+) b/\S+", line)
            current_path = m.group(1) if m else "?"
            current_lines = [line]
        else:
            current_lines.append(line)
    if current_path is not None:
        file_blocks.append((current_path, current_lines))

    test_blocks: list[tuple[str, list[str]]] = []
    source_blocks: list[tuple[str, list[str]]] = []
    for path, lines in file_blocks:
        is_test = any(p.match(path) for p in test_patterns)
        if is_test:
            test_blocks.append((path, lines))
        else:
            source_blocks.append((path, lines))

    test_patch = "\n".join("\n".join(lines) for _, lines in test_blocks)
    source_patch = "\n".join("\n".join(lines) for _, lines in source_blocks)
    test_files = [p for p, _ in test_blocks]
    source_files = [p for p, _ in source_blocks]
    return source_patch, test_patch, source_files, test_files


# ──────────────────────────────────────────────────────────────────────────────
# FAIL_TO_PASS extractor — find test functions ADDED in test_patch
# ──────────────────────────────────────────────────────────────────────────────

# (regex on `+`-prefixed line, capture group → test name)
ADDED_TEST_PATTERNS = {
    "rust":     [r"^\+\s*fn (test_\w+)", r"^\+\s*fn (\w+_test)"],
    "ts_bun":   [r'^\+\s*(?:test|it)\(\s*[\'"]([^\'"]+)[\'"]'],
    "ts_pnpm":  [r'^\+\s*(?:test|it)\(\s*[\'"]([^\'"]+)[\'"]'],
    "ts_npm":   [r'^\+\s*(?:test|it)\(\s*[\'"]([^\'"]+)[\'"]'],
    "go":       [r"^\+\s*func (Test\w+)\("],
    "python":   [r"^\+\s*def (test_\w+)\("],
}


def extract_added_tests(test_patch: str, lang: str) -> list[str]:
    pats = [re.compile(p, re.MULTILINE) for p in ADDED_TEST_PATTERNS.get(lang, [])]
    found: list[str] = []
    for pat in pats:
        for m in pat.finditer(test_patch):
            name = m.group(1)
            if name not in found:
                found.append(name)
    return found


# ──────────────────────────────────────────────────────────────────────────────
# install_config builder + new eval.sh template
# ──────────────────────────────────────────────────────────────────────────────

EVAL_SH_TEMPLATE = r'''#!/usr/bin/env bash
# SWE-rebench-style eval (auto-generated by build_swerebench_configs.py).
# Reads tests/install_config.json, runs the test_cmd, parses stdout via the
# named log_parser (vendored from SWE-rebench-V2 — copied into this tests/
# dir at scaffold time), scores by FAIL_TO_PASS pass rate.
#
# Harbor mounts the entire tests/ directory at /tests in the sandbox, so
# log_parsers.py and swe_constants.py live alongside this script.
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location.
# DO NOT REMOVE: regression in commit f3698bcf4 silently zero'd 175/176 task scores. Restored 2026-05-08.
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

TASK_DIR="${TASK_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
EVAL_DIR="${EVAL_DIR:-/tests}"
mkdir -p "$LOGS_DIR"

CONFIG="$TASK_DIR/tests/install_config.json"
if [ ! -f "$CONFIG" ]; then
    echo "ERROR: missing $CONFIG" >&2
    echo 0.0 > "$LOGS_DIR/reward.txt"
    exit 1
fi
if [ ! -f "$EVAL_DIR/log_parsers.py" ]; then
    echo "ERROR: log_parsers not mounted at $EVAL_DIR — orchestrator must mount data-pipeline/scaffold/log_parsers/ here" >&2
    echo 0.0 > "$LOGS_DIR/reward.txt"
    exit 1
fi

REPO_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG'))['repo_dir'])")
TEST_CMD=$(python3 -c "import json; print(json.load(open('$CONFIG'))['test_cmd'])")

cd "$REPO_DIR" || { echo "ERROR: cd $REPO_DIR" >&2; echo 0.0 > "$LOGS_DIR/reward.txt"; exit 1; }

LOG="$LOGS_DIR/test_run.log"
echo "[eval] running: $TEST_CMD" | tee -a "$LOG"
eval "$TEST_CMD" 2>&1 | tee -a "$LOG"

python3 - "$CONFIG" "$LOG" "$LOGS_DIR/reward.txt" "$EVAL_DIR" <<'PYEOF'
import json, sys
cfg_path, log_path, reward_path, eval_dir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
sys.path.insert(0, eval_dir)
from log_parsers import NAME_TO_PARSER

cfg = json.load(open(cfg_path))
import re as _re
_ansi_re = _re.compile(r"\x1b\[[0-9;]*[mGKHfABCDsuJ]")
log = _ansi_re.sub("", open(log_path).read())

parser = NAME_TO_PARSER.get(cfg["log_parser"])
if parser is None:
    print(f"[eval] ERROR: unknown log_parser {cfg['log_parser']!r}")
    open(reward_path, "w").write("0.0\n")
    sys.exit(0)

parsed = parser(log)  # {test_name: status}
fail_to_pass = cfg.get("FAIL_TO_PASS", [])
pass_to_pass = cfg.get("PASS_TO_PASS", [])

if not fail_to_pass:
    print("[eval] no FAIL_TO_PASS — falling back to overall pass rate")
    total = len(parsed)
    if total == 0:
        reward = 0.0
    else:
        passed = sum(1 for v in parsed.values() if v == "PASSED")
        reward = passed / total
else:
    f2p_pass = sum(1 for t in fail_to_pass if parsed.get(t) == "PASSED")
    reward = f2p_pass / max(1, len(fail_to_pass))
    if pass_to_pass:
        p2p_fail = sum(1 for t in pass_to_pass if parsed.get(t) and parsed[t] != "PASSED")
        if p2p_fail > 0:
            print(f"[eval] {p2p_fail} P2P regression(s) — zeroing reward")
            reward = 0.0

reward = max(0.0, min(1.0, reward))
open(reward_path, "w").write(f"{reward:.6f}\n")
print(f"[eval] reward={reward:.4f}  parser={cfg['log_parser']}  "
      f"FAIL_TO_PASS: {sum(1 for t in fail_to_pass if parsed.get(t) == 'PASSED')}/{len(fail_to_pass)}")
PYEOF

cat "$LOGS_DIR/reward.txt"
'''


def build_install_config(task_name: str, dockerfile: str, canonical: dict) -> dict | None:
    """Construct the install_config.json contents for a task.

    Returns None if we can't determine essential fields (language, repo_dir, etc.).
    """
    lang = detect_language(dockerfile)
    if lang not in LANG_PARSER:
        return {"_error": f"language '{lang}' not supported"}

    parser_name, default_cmd = LANG_PARSER[lang]

    # Repo dir: parse the last WORKDIR (before USER agent) or git clone target
    repo_dir = None
    workdirs = re.findall(r"^WORKDIR\s+(\S+)", dockerfile, re.MULTILINE)
    if workdirs:
        # Take the last WORKDIR — typically the agent's runtime dir
        repo_dir = workdirs[-1]
    if not repo_dir:
        m = re.search(r"git clone\s+\S+\s+(\S+)", dockerfile)
        if m:
            repo_dir = m.group(1).rstrip("/")
    if not repo_dir:
        repo_dir = "/workspace/repo"  # fallback

    # Patch splitting + FAIL_TO_PASS extraction
    patch = canonical.get("patch", "")
    source_patch, test_patch, source_files, test_files = split_patch(patch, lang)
    fail_to_pass = extract_added_tests(test_patch, lang)

    # For Rust, also try function-level extraction from source patch
    # (canonical Rust convention: inline #[cfg(test)] mod tests)
    if lang == "rust" and not fail_to_pass:
        fail_to_pass = extract_added_tests(source_patch, "rust")

    return {
        "task_name": task_name,
        "language": lang,
        "log_parser": parser_name,
        "test_cmd": default_cmd,
        "repo_dir": repo_dir,
        "FAIL_TO_PASS": fail_to_pass,
        "PASS_TO_PASS": [],  # left empty for now — could extract from existing test files later
        "source_files": source_files,
        "test_files": test_files,
        "commit_sha": canonical.get("commit_sha"),
        "commit_message_first_line": (canonical.get("commit_message", "") or "").splitlines()[0] if canonical.get("commit_message") else "",
        "agent_percentage": canonical.get("agent_percentage"),
    }


def task_session_id(task_name: str) -> str | None:
    p = HARBOR_TASKS / task_name / "original_session.json"
    if not p.exists():
        return None
    try:
        return json.load(open(p)).get("session_id")
    except Exception:
        return None


# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--task", action="append", default=None,
                   help="Process only this task (repeatable). Default: all tasks.")
    p.add_argument("--dry-run", action="store_true",
                   help="Show plan + counts; do not write files.")
    args = p.parse_args()

    targets = args.task or sorted(d.name for d in HARBOR_TASKS.iterdir()
                                  if d.is_dir() and d.name != "README.md")

    stats = {"processed": 0, "no_dockerfile": 0, "no_canonical": 0,
             "lang_unknown": 0, "no_fail_to_pass": 0, "configs_written": 0}
    by_lang: dict[str, int] = {}
    by_parser: dict[str, int] = {}
    no_f2p_tasks: list[str] = []

    for t in targets:
        df = HARBOR_TASKS / t / "environment" / "Dockerfile"
        if not df.exists():
            stats["no_dockerfile"] += 1
            continue
        sid = task_session_id(t)
        canonical_path = _find_canonical(sid) if sid else None
        if not sid or canonical_path is None:
            stats["no_canonical"] += 1
            continue
        canonical = json.load(open(canonical_path))
        cfg = build_install_config(t, df.read_text(), canonical)
        if not cfg or "_error" in (cfg or {}):
            stats["lang_unknown"] += 1
            continue
        stats["processed"] += 1
        by_lang[cfg["language"]] = by_lang.get(cfg["language"], 0) + 1
        by_parser[cfg["log_parser"]] = by_parser.get(cfg["log_parser"], 0) + 1
        if not cfg["FAIL_TO_PASS"]:
            stats["no_fail_to_pass"] += 1
            no_f2p_tasks.append(t)

        if not args.dry_run:
            tests_dir = HARBOR_TASKS / t / "tests"
            tests_dir.mkdir(exist_ok=True)
            # Backup existing manifest + test.sh
            for f in ["test_manifest.yaml", "test.sh"]:
                src = tests_dir / f
                dst = tests_dir / f"{f}.legacy.bak"
                if src.exists() and not dst.exists():
                    shutil.copy2(src, dst)
            # Write install_config.json
            json.dump(cfg, open(tests_dir / "install_config.json", "w"), indent=2)
            # Write new eval test.sh
            (tests_dir / "test.sh").write_text(EVAL_SH_TEMPLATE)
            os.chmod(tests_dir / "test.sh", 0o755)
            # Copy log_parsers.py + swe_constants.py alongside test.sh so
            # Harbor's tests/ → /tests mount makes them available at runtime
            for fname in ["log_parsers.py", "swe_constants.py"]:
                shutil.copy2(LOG_PARSERS_DIR / fname, tests_dir / fname)
            stats["configs_written"] += 1

    print("=== migration stats ===")
    for k, v in stats.items():
        print(f"  {k:<22} {v}")
    print()
    print("=== by language ===")
    for lang, n in sorted(by_lang.items(), key=lambda kv: -kv[1]):
        print(f"  {lang:<10} {n}")
    print()
    print("=== by parser ===")
    for parser, n in sorted(by_parser.items(), key=lambda kv: -kv[1]):
        print(f"  {parser:<22} {n}")
    if no_f2p_tasks:
        print()
        print(f"=== {len(no_f2p_tasks)} tasks with EMPTY FAIL_TO_PASS (canonical patch added no recognizable tests) ===")
        for t in no_f2p_tasks[:10]:
            print(f"  {t}")
        if len(no_f2p_tasks) > 10:
            print(f"  ... and {len(no_f2p_tasks)-10} more")
    return 0


if __name__ == "__main__":
    sys.exit(main())
