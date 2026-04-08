"""Pre-audit linter for harbor_tasks test.sh files.

Adapted from agentsmd-rl/taskforge/lint.py for our bash test.sh format.
Catches common anti-patterns that reduce test quality and discriminative power.

Usage:
    python src/lint_tests.py                         # lint all tasks
    python src/lint_tests.py --tasks "comfyui-*"     # glob pattern
    python src/lint_tests.py --severity critical      # only critical issues
    python src/lint_tests.py --json                   # machine-readable output
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from enum import Enum
from typing import Sequence


class Severity(str, Enum):
    CRITICAL = "critical"
    WARNING = "warning"
    INFO = "info"


@dataclass
class LintIssue:
    severity: Severity
    line: int  # 0 if file-level
    rule: str
    message: str
    antipattern: int = 0  # Maps to anti-pattern # (0=none)


@dataclass
class LintResult:
    issues: list[LintIssue] = field(default_factory=list)
    weight_sum: float = 0.0
    behavioral_ratio: float = 0.0
    has_gate: bool = False
    has_f2p: bool = False
    reward_path: str = ""

    @property
    def critical_count(self) -> int:
        return sum(1 for i in self.issues if i.severity == Severity.CRITICAL)

    @property
    def warning_count(self) -> int:
        return sum(1 for i in self.issues if i.severity == Severity.WARNING)

    @property
    def passed(self) -> bool:
        return self.critical_count == 0


def lint_test_sh(content: str) -> LintResult:
    """Run all lint checks on a test.sh file."""
    result = LintResult()
    lines = content.splitlines()

    _check_set_flags(lines, result)
    _check_reward_path(lines, result)
    _check_weight_sum(content, result)
    _check_gate(content, result)
    _check_f2p(content, result)
    _check_comment_stripping(lines, result)
    _check_import_fallback(lines, result)
    _check_file_exists_fallback(lines, result)
    _check_ungated_structural(content, result)
    _check_self_referential(content, result)
    _check_single_expensive_test(content, result)
    _check_conditional_gates(content, result)

    return result


# ---------------------------------------------------------------------------
# Individual checks
# ---------------------------------------------------------------------------

def _check_set_flags(lines: Sequence[str], result: LintResult) -> None:
    """set -e causes test.sh to abort on first failure — must use set +e."""
    for i, line in enumerate(lines):
        stripped = line.strip()
        if re.match(r'^set\s+-[a-z]*e', stripped) and 'set +e' not in stripped:
            result.issues.append(LintIssue(
                severity=Severity.CRITICAL,
                line=i + 1,
                rule="set-e-abort",
                message="'set -e' aborts on first failure — use 'set +e' "
                        "so all checks run and partial scores accumulate",
            ))


def _check_reward_path(lines: Sequence[str], result: LintResult) -> None:
    """Reward must go to /logs/verifier/reward.txt."""
    content = "\n".join(lines)
    canonical = "/logs/verifier/reward.txt"

    # Check if reward is written somewhere
    has_reward_write = bool(re.search(
        r'(?:>|>>|tee)\s*["\']?(?:/logs/verifier/reward|.*reward\.txt)',
        content
    ))
    has_reward_var = bool(re.search(r'REWARD_FILE', content))

    if not has_reward_write and not has_reward_var:
        # Check for echo to reward path
        if canonical not in content and 'reward.txt' not in content:
            result.issues.append(LintIssue(
                severity=Severity.CRITICAL,
                line=0,
                rule="no-reward-write",
                message=f"No reward output found — must write to {canonical}",
            ))
    elif canonical not in content and '$REWARD_FILE' not in content and '${REWARD_FILE}' not in content:
        # Find the actual path used
        paths = re.findall(r'>\s*"?([^"\s]+reward[^"\s]*)"?', content)
        for path in paths:
            if 'reward.txt' in path and '/logs/verifier' not in path:
                result.issues.append(LintIssue(
                    severity=Severity.WARNING,
                    line=0,
                    rule="reward-path",
                    message=f"Reward written to '{path}', expected '{canonical}'",
                ))
                break


def _check_weight_sum(content: str, result: LintResult) -> None:
    """Check weight annotations sum to ~1.0.

    Supports our three conventions:
    1. Header weight comments: (0.10) in header block
    2. SCORE/TOTAL: integer accumulator divided at end
    3. REWARD float: direct float accumulator
    """
    # Pattern 1: Header weight breakdown comments — look for a block of (0.XX) weights
    # Match lines like "  Check 1  (0.10)  description"
    header_weights = re.findall(
        r'#[^#\n]*\((\d+\.\d+)\)[^#\n]*(?:F2P|P2P|Silver|Gold|Bronze|behavioral|structural|regression)',
        content, re.IGNORECASE
    )

    # Pattern 2: Per-test weight comments like "# weight: 0.10" or "# (0.10):"
    per_test_weights = re.findall(
        r'#\s*(?:weight|Weight)\s*[:=]\s*(\d+\.\d+)', content
    )

    # Pattern 3: TOTAL=N denominator with SCORE accumulator
    total_match = re.search(r'TOTAL\s*=\s*(\d+)', content)
    score_increments = re.findall(r'SCORE\s*\+=?\s*(\d+)', content)
    # Filter out SCORE=0 initialization
    score_increments = [s for s in score_increments if s != '0']

    # Pattern 4: Direct reward increments
    # bash: add_reward 0.10  |  python: add_reward(0.10, ...)  |  REWARD += 0.10
    reward_increments = re.findall(
        r'add_reward\s+(\d+\.\d+)', content  # bash style
    )
    reward_increments += re.findall(
        r'add_reward\((\d+\.\d+)', content  # python style
    )
    reward_increments += re.findall(
        r'REWARD\s*\+\s*=?\s*(\d+\.\d+)', content  # REWARD += 0.10
    )
    # Deduplicate won't matter — we sum all occurrences (each is a separate test)

    # Priority: reward_increments (most specific) > SCORE/TOTAL > header > per_test
    weights = reward_increments or header_weights or per_test_weights
    if weights:
        total = sum(float(w) for w in weights)
        result.weight_sum = total

        # If the test uses min(1.0, ...) capping, sums >1.0 are intentional
        # (multiple mutually exclusive paths). Only flag sums >1.0 if no cap.
        has_cap = bool(re.search(r'min\s*\(\s*1\.0', content))
        if total < 0.85:
            result.issues.append(LintIssue(
                severity=Severity.WARNING if total > 0.50 else Severity.CRITICAL,
                line=0,
                rule="weight-sum",
                message=f"Weights sum to {total:.2f}, expected ~1.00 "
                        f"(found {len(weights)} weight annotations)",
            ))
        elif total > 1.10 and not has_cap:
            result.issues.append(LintIssue(
                severity=Severity.WARNING,
                line=0,
                rule="weight-sum",
                message=f"Weights sum to {total:.2f} without min(1.0) cap "
                        f"(found {len(weights)} weight annotations)",
            ))
    elif total_match and score_increments:
        total_possible = int(total_match.group(1))
        max_score = sum(int(s) for s in score_increments)
        result.weight_sum = max_score / total_possible if total_possible else 0
        if abs(result.weight_sum - 1.0) > 0.10:
            result.issues.append(LintIssue(
                severity=Severity.WARNING,
                line=0,
                rule="weight-sum",
                message=f"Max SCORE={max_score} / TOTAL={total_possible} = "
                        f"{result.weight_sum:.2f}, expected ~1.00",
            ))


def _check_gate(content: str, result: LintResult) -> None:
    """Should have a gate check (syntax/compilation) that aborts on failure."""
    gate_patterns = [
        r'GATE',
        r'[Gg]ate.*[Ff]ail',
        r'[Ss]yntax.*[Cc]heck',
        r'ast\.parse',
        r'python3\s+-c\s+["\'].*compile',
        r'cargo\s+check',
        r'cargo\s+build',
        r'npx\s+tsc',
        r'node\s+--check',
        r'g\+\+.*-fsyntax-only',
    ]
    result.has_gate = any(re.search(p, content) for p in gate_patterns)
    if not result.has_gate:
        result.issues.append(LintIssue(
            severity=Severity.WARNING,
            line=0,
            rule="no-gate",
            message="No gate/syntax check found. test.sh should have a gate that "
                    "scores 0 if the code doesn't parse/compile.",
        ))


def _check_f2p(content: str, result: LintResult) -> None:
    """Should have at least one fail-to-pass behavioral test."""
    f2p_patterns = [
        r'[Ff]ail.to.[Pp]ass',
        r'\bF2P\b',
        r'\bf2p\b',
        r'[Ff]AIL.*on.*buggy',
        r'should.*fail.*before.*fix',
        r'[Bb]ehavioral.*[Ff]ail',
        r'[Bb]ug.*trigger',
    ]
    result.has_f2p = any(re.search(p, content) for p in f2p_patterns)
    if not result.has_f2p:
        result.issues.append(LintIssue(
            severity=Severity.WARNING,
            line=0,
            rule="no-f2p",
            message="No fail-to-pass test detected (no F2P/f2p/fail-to-pass label). "
                    "At least one test should FAIL on buggy code and PASS after fix.",
        ))


def _check_comment_stripping(lines: Sequence[str], result: LintResult) -> None:
    """Anti-pattern #9: grep on source without stripping comments first."""
    for i, line in enumerate(lines):
        stripped = line.strip()
        if re.match(r'(grep|rg)\s+(-[a-z]+\s+)*["\']', stripped):
            context = "\n".join(lines[max(0, i - 10):i])
            if not re.search(r'strip.*comment|remove.*comment|sed.*#|grep -v.*#', context, re.IGNORECASE):
                if any(kw in stripped for kw in ['$TARGET', '$FILE', '/workspace', '.py', '.rs', '.ts', '.js', '.cu', '.h']):
                    result.issues.append(LintIssue(
                        severity=Severity.WARNING,
                        line=i + 1,
                        rule="comment-injection",
                        message="grep on source without comment stripping — agent can "
                                "inject keywords via comments to pass this check",
                        antipattern=9,
                    ))
                    break


def _check_import_fallback(lines: Sequence[str], result: LintResult) -> None:
    """Anti-pattern #2: AST fallback on import failure."""
    in_try = False
    has_import_in_try = False
    for i, line in enumerate(lines):
        stripped = line.strip()
        if 'try:' in stripped or 'try {' in stripped:
            in_try = True
            has_import_in_try = False
        elif in_try and ('import ' in stripped or 'require(' in stripped):
            has_import_in_try = True
        elif in_try and ('except' in stripped or 'catch' in stripped):
            if has_import_in_try:
                next_lines = "\n".join(lines[i:i + 5])
                if re.search(r'ast\.|structural|grep|check_', next_lines, re.IGNORECASE):
                    result.issues.append(LintIssue(
                        severity=Severity.CRITICAL,
                        line=i + 1,
                        rule="import-fallback",
                        message="Import failure falls back to AST/structural check — "
                                "stub file with keywords passes the fallback. "
                                "Import failure should = 0 points.",
                        antipattern=2,
                    ))
            in_try = False


def _check_file_exists_fallback(lines: Sequence[str], result: LintResult) -> None:
    """Anti-pattern #10: File-exists in error fallback awards points.

    Reduced false positives: skip temp-file cleanup (finally/unlink),
    compilation pre-checks (tsc/cargo), and file-exists gates that
    fail in their else branch.
    """
    for i, line in enumerate(lines):
        stripped = line.strip()
        if 'os.path.exists' in stripped or 'test -f' in stripped or '[ -f' in stripped:
            # Skip temp-file cleanup patterns (finally block + unlink/rm)
            next_lines = "\n".join(lines[i:i + 3])
            if re.search(r'unlink|os\.remove|rm\s', next_lines):
                continue

            # Skip compilation pre-checks (tsc, cargo, node_modules)
            if re.search(r'tsc|tsconfig|cargo|node_modules|\.lock', stripped):
                continue

            # Only flag if inside an error handler AND awards points
            context = "\n".join(lines[max(0, i - 5):i + 3])
            if re.search(r'except|catch', context):
                score_context = "\n".join(lines[i:i + 5])
                if re.search(r'REWARD|SCORE|PASS|score|reward', score_context, re.IGNORECASE):
                    result.issues.append(LintIssue(
                        severity=Severity.CRITICAL,
                        line=i + 1,
                        rule="exists-fallback",
                        message="File-exists check in error fallback awards points — "
                                "empty file scores. Remove existence fallbacks.",
                        antipattern=10,
                    ))
                    break


def _check_ungated_structural(content: str, result: LintResult) -> None:
    """Anti-patterns #7/#8: Structural checks without behavioral gate."""
    has_gate_var = bool(re.search(r'GATE_PASS|gate_pass|BEHAVIORAL_PASS', content))
    has_structural = bool(re.search(
        r'[Ss]tructural|[Aa]nti.?[Ss]tub|[Bb]ronze|AST.*check',
        content
    ))

    if has_structural and not has_gate_var:
        result.issues.append(LintIssue(
            severity=Severity.WARNING,
            line=0,
            rule="ungated-structural",
            message="Structural/anti-stub checks may run even when gate fails. "
                    "Gate structural points behind behavioral/compilation passing.",
            antipattern=7,
        ))


def _check_self_referential(content: str, result: LintResult) -> None:
    """Anti-pattern #1: Extracting values from agent code to verify agent code."""
    patterns = [
        # Reading a value from agent's file and using it as ground truth
        r'expected\s*=.*open\s*\(.*workspace',
        r'EXPECTED\s*=.*\$\(.*cat.*workspace',
        # Extracting constants from agent code
        r'extract.*from.*workspace.*assert.*extract',
    ]
    for pat in patterns:
        match = re.search(pat, content, re.IGNORECASE)
        if match:
            result.issues.append(LintIssue(
                severity=Severity.CRITICAL,
                line=0,
                rule="self-referential",
                message="Test extracts values from agent code to verify itself — "
                        "always compare against FIXED ground truth constants.",
                antipattern=1,
            ))
            break


def _check_single_expensive_test(content: str, result: LintResult) -> None:
    """Detect single tests worth >=0.30 of total score (plateau risk)."""
    # Look for individual test weights >= 0.30
    weights = re.findall(r'\((\d+\.\d+)\)', content)
    for w in weights:
        val = float(w)
        if val >= 0.30:
            result.issues.append(LintIssue(
                severity=Severity.WARNING,
                line=0,
                rule="expensive-test",
                message=f"Single test worth {val:.2f} (>=0.30) creates a binary gate. "
                        "Break into 3-5 micro-tests for graduated scoring.",
            ))
            break


def _check_conditional_gates(content: str, result: LintResult) -> None:
    """Detect conditional test execution (T6 failure skips T7/T9 pattern)."""
    # Look for patterns where one test's result gates another
    patterns = [
        r'if\s*\[\s*.*(?:T\d+|TEST\d+|PASS_\w+).*\].*then',
        r'if\s+\$\{?(?:T\d+|TEST\d+|CHECK\d+)',
        r'(?:SKIP|skip).*(?:T\d+|TEST\d+|test\d+)',
    ]
    for pat in patterns:
        if re.search(pat, content):
            result.issues.append(LintIssue(
                severity=Severity.WARNING,
                line=0,
                rule="conditional-gate",
                message="Test execution gated on another test's result — "
                        "if the gate fails, downstream tests auto-skip. "
                        "Test each aspect independently.",
            ))
            break


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    import argparse
    import fnmatch
    import json
    import sys
    from pathlib import Path

    parser = argparse.ArgumentParser(description="Lint harbor task test.sh files")
    parser.add_argument("--tasks", help="Glob pattern for task names (e.g., 'comfyui-*')")
    parser.add_argument("--severity", choices=["critical", "warning", "info"],
                        default="warning")
    parser.add_argument("--json", action="store_true", dest="json_output")
    args = parser.parse_args()

    min_severity = {"critical": 0, "warning": 1, "info": 2}[args.severity]
    severity_order = {Severity.CRITICAL: 0, Severity.WARNING: 1, Severity.INFO: 2}

    base = Path("harbor_tasks")
    if not base.exists():
        print("harbor_tasks/ not found — run from repo root")
        sys.exit(1)

    tasks = sorted(
        t for t in base.iterdir()
        if t.is_dir() and (t / "tests" / "test.sh").exists()
    )
    if args.tasks:
        tasks = [t for t in tasks if fnmatch.fnmatch(t.name, args.tasks)]

    if not tasks:
        print("No tasks found.")
        sys.exit(1)

    if not args.json_output:
        print(f"Linting {len(tasks)} tasks...\n")

    total_critical = 0
    total_passed = 0
    all_results = []

    for task_dir in tasks:
        content = (task_dir / "tests" / "test.sh").read_text()
        result = lint_test_sh(content)

        filtered = [i for i in result.issues
                     if severity_order[i.severity] <= min_severity]

        if args.json_output:
            all_results.append({
                "task": task_dir.name,
                "passed": result.passed,
                "weight_sum": result.weight_sum,
                "has_gate": result.has_gate,
                "has_f2p": result.has_f2p,
                "issues": [
                    {"severity": i.severity.value, "rule": i.rule,
                     "line": i.line, "message": i.message}
                    for i in filtered
                ],
            })
        elif filtered:
            label = "FAIL" if result.critical_count else "WARN"
            print(f"{label} {task_dir.name}")
            for issue in filtered:
                prefix = "  !!" if issue.severity == Severity.CRITICAL else "  ."
                loc = f":{issue.line}" if issue.line else ""
                print(f"{prefix} [{issue.rule}]{loc} {issue.message}")
            print()
        else:
            if not args.json_output:
                print(f"PASS {task_dir.name}")

        total_critical += result.critical_count
        if result.passed:
            total_passed += 1

    if args.json_output:
        json.dump(all_results, sys.stdout, indent=2)
        print()
    else:
        print(f"\n{'=' * 60}")
        print(f"  {len(tasks)} tasks linted")
        print(f"  {total_passed} passed ({total_passed * 100 // len(tasks)}%)")
        print(f"  {len(tasks) - total_passed} failed (critical issues)")
        print(f"  {total_critical} total critical issues")
        print(f"{'=' * 60}")


if __name__ == "__main__":
    main()
