#!/usr/bin/env bash
#
# Verification script for dataclaw-test-coverage-fix.
# Checks that the agent wrote comprehensive, passing tests for the dataclaw package.
# Uses mutation testing to verify tests check real behavior, not just call functions.
# Writes 0.0–1.0 to /logs/verifier/reward.txt.
#
# Weight budget:
#   Structural (10%):  checks 1–3, 9–10  (AST analysis of test files)
#   Behavioral (90%):  checks 4–8 (basic pytest, 20%), checks 11–13 (mutation, 70%)
#
set +e

WORKSPACE="/workspace/dataclaw"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

cd "$WORKSPACE"

python3 << 'PYEOF'
import ast, os, re, subprocess, sys, shutil

REWARD = 0.0
WORKSPACE = "/workspace/dataclaw"

def add_reward(amount, reason):
    global REWARD
    REWARD = min(1.0, REWARD + amount)
    print(f"  +{amount:.2f} -> {REWARD:.3f}  ({reason})")

def run_pytest(path, timeout=15):
    """Run pytest -q --tb=no, return (passed, failed, errors)."""
    try:
        r = subprocess.run(
            [sys.executable, "-m", "pytest", path, "-q", "--tb=no"],
            capture_output=True, text=True, timeout=timeout,
            cwd=WORKSPACE,
        )
        out = r.stdout + r.stderr
        def _int(pat):
            m = re.search(pat, out)
            return int(m.group(1)) if m else 0
        return _int(r'(\d+) passed'), _int(r'(\d+) failed'), _int(r'(\d+) error')
    except subprocess.TimeoutExpired:
        print(f"    TIMEOUT running pytest on {path}")
        return 0, 0, 0
    except Exception as e:
        print(f"    ERROR: {e}")
        return 0, 0, 0

def run_pytest_verbose(path, timeout=25):
    """Run pytest -v --tb=no, return per-file {fname: [pass,fail,err]} and totals."""
    try:
        r = subprocess.run(
            [sys.executable, "-m", "pytest", path, "-v", "--tb=no"],
            capture_output=True, text=True, timeout=timeout,
            cwd=WORKSPACE,
        )
        out = r.stdout + r.stderr
        per_file = {}
        for line in out.splitlines():
            m = re.search(r'(tests/\S+\.py)::\S+\s+(PASSED|FAILED|ERROR)', line)
            if m:
                fname = os.path.basename(m.group(1))
                status = m.group(2)
                if fname not in per_file:
                    per_file[fname] = [0, 0, 0]
                if status == "PASSED":
                    per_file[fname][0] += 1
                elif status == "FAILED":
                    per_file[fname][1] += 1
                else:
                    per_file[fname][2] += 1
        def _int(pat):
            m2 = re.search(pat, out)
            return int(m2.group(1)) if m2 else 0
        return per_file, _int(r'(\d+) passed'), _int(r'(\d+) failed'), _int(r'(\d+) error')
    except subprocess.TimeoutExpired:
        print("    TIMEOUT running full suite")
        return {}, 0, 0, 0
    except Exception as e:
        print(f"    ERROR: {e}")
        return {}, 0, 0, 0

# ── AST helpers (for inspecting test code quality) ────────────────
KNOWN_FUNCS = {
    "secrets": {"_shannon_entropy", "_has_mixed_char_types", "scan_text",
                "redact_text", "redact_custom_strings", "redact_session"},
    "anonymizer": {"_hash_username", "anonymize_path", "anonymize_text",
                   "Anonymizer", "_replace_username", "_detect_home_dir"},
    "parser": {"_build_project_name", "_normalize_timestamp",
               "_summarize_tool_input", "_extract_user_content",
               "_extract_assistant_content", "_process_entry",
               "_parse_session_file", "discover_projects",
               "parse_project_sessions"},
    "cli": {"_format_size", "_format_token_count", "_parse_csv_arg",
            "_merge_config_list", "default_repo_name", "_build_dataset_card",
            "export_to_jsonl", "configure", "list_projects",
            "push_to_huggingface"},
    "config": {"load_config", "save_config", "DataClawConfig", "CONFIG_FILE"},
}

def parse_file(path):
    try:
        with open(path) as f:
            return ast.parse(f.read())
    except Exception:
        return None

def meaningful_asserts(tree):
    """Count assertions that aren't bare literals (rejects assert True)."""
    n = 0
    for node in ast.walk(tree):
        if isinstance(node, ast.Assert) and not isinstance(node.test, ast.Constant):
            n += 1
        if isinstance(node, ast.Call):
            fn = node.func
            if isinstance(fn, ast.Attribute) and fn.attr == "raises":
                n += 1
    return n

def pytest_raises_count(tree):
    n = 0
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            fn = node.func
            if isinstance(fn, ast.Attribute) and fn.attr == "raises":
                n += 1
    return n

def called_known_funcs(tree, module):
    """Which known functions from *module* are called in *tree*?"""
    target = KNOWN_FUNCS.get(module, set())
    found = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            name = None
            if isinstance(node.func, ast.Attribute):
                name = node.func.attr
            elif isinstance(node.func, ast.Name):
                name = node.func.id
            if name in target:
                found.add(name)
    return found

def imported_dataclaw_modules(tree):
    mods = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                for mod in KNOWN_FUNCS:
                    if f"dataclaw.{mod}" in alias.name:
                        mods.add(mod)
        elif isinstance(node, ast.ImportFrom) and node.module and "dataclaw" in node.module:
            for mod in KNOWN_FUNCS:
                if mod in node.module:
                    mods.add(mod)
    return mods

# ── Gather test file data ─────────────────────────────────────────
test_dir = "tests"
has_test_dir = os.path.isdir(test_dir)
test_files = sorted(f for f in (os.listdir(test_dir) if has_test_dir else [])
                    if f.startswith("test_") and f.endswith(".py"))

file_info = {}
total_asserts = 0
total_raises = 0
all_imported_mods = set()

for fname in test_files:
    tree = parse_file(os.path.join(test_dir, fname))
    if tree is None:
        continue
    ma = meaningful_asserts(tree)
    pr = pytest_raises_count(tree)
    im = imported_dataclaw_modules(tree)
    info = {"asserts": ma, "raises": pr, "imported_mods": im}
    for mod in KNOWN_FUNCS:
        info[f"calls_{mod}"] = called_known_funcs(tree, mod)
    file_info[fname] = info
    total_asserts += ma
    total_raises += pr
    all_imported_mods |= im

# ── Run full test suite once (verbose) ────────────────────────────
print("--- Running test suite ---")
per_file, total_pass, total_fail, total_err = run_pytest_verbose("tests/", timeout=25)
print(f"Total: {total_pass} pass, {total_fail} fail, {total_err} err")
for fname, counts in sorted(per_file.items()):
    print(f"  {fname}: {counts[0]} pass, {counts[1]} fail, {counts[2]} err")

# ====================================================================
# STRUCTURAL CHECKS (10%)
# ====================================================================

# Check 1 (0.02 Bronze): ≥4 test_*.py files
print("\n--- Check 1: test file count ---")
print(f"  Found {len(test_files)} test files: {test_files}")
if len(test_files) >= 4:
    add_reward(0.02, ">= 4 test files")
else:
    print("  FAIL: need >= 4 test_*.py files")

# Check 2 (0.02 Bronze): conftest.py with ≥2 non-stub fixtures
print("--- Check 2: conftest.py fixtures ---")
conftest_path = os.path.join(test_dir, "conftest.py")
if os.path.isfile(conftest_path):
    ct_tree = parse_file(conftest_path)
    fixtures = 0
    if ct_tree:
        for node in ast.walk(ct_tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                if node.decorator_list:
                    has_body = any(not isinstance(s, ast.Pass) for s in node.body)
                    if has_body:
                        fixtures += 1
    print(f"  Decorated non-stub functions: {fixtures}")
    if fixtures >= 2:
        add_reward(0.02, "conftest.py has >= 2 fixtures")
    else:
        print("  FAIL: need >= 2 decorated fixture functions")
else:
    print("  FAIL: conftest.py not found")

# Check 3 (0.02 Bronze): ≥25 meaningful assertions total
print("--- Check 3: assertion quality ---")
print(f"  Total meaningful assertions: {total_asserts}")
if total_asserts >= 25:
    add_reward(0.02, ">= 25 meaningful assertions")
else:
    print("  FAIL: too few meaningful assertions")

# Check 9 (0.02 Bronze): ≥4 dataclaw modules imported in test files
print("--- Check 9: module coverage breadth ---")
print(f"  Modules imported: {all_imported_mods}")
if len(all_imported_mods) >= 4:
    add_reward(0.02, ">= 4 dataclaw modules tested")
else:
    print("  FAIL: too few modules covered")

# Check 10 (0.02 Bronze): ≥3 pytest.raises usages
print("--- Check 10: error handling ---")
print(f"  Total pytest.raises: {total_raises}")
if total_raises >= 3:
    add_reward(0.02, ">= 3 pytest.raises usages")
else:
    print("  FAIL: no/few pytest.raises found")

# ====================================================================
# BEHAVIORAL — BASIC CHECKS (20%)
# Per-file quality gates using AST + pytest pass counts from single run
# ====================================================================

# Check 4 (0.05 Silver): test_secrets.py — passes + calls functions + assertions
print("\n--- Check 4: test_secrets.py ---")
if "test_secrets.py" in file_info:
    info = file_info["test_secrets.py"]
    sec = per_file.get("test_secrets.py", [0, 0, 0])
    sec_pass, sec_fail = sec[0], sec[1]
    n_called = len(info["calls_secrets"])
    n_asserts = info["asserts"]
    print(f"  pytest: {sec_pass} pass, {sec_fail} fail")
    print(f"  secrets funcs called: {n_called} {info['calls_secrets']}")
    print(f"  meaningful asserts: {n_asserts}")
    if sec_pass >= 8 and n_called >= 2 and n_asserts >= 5:
        add_reward(0.05, "test_secrets: quality gate met")
    elif sec_pass >= 3:
        add_reward(0.02, "test_secrets: partial")
    else:
        print("  FAIL: insufficient passing tests or quality")
else:
    print("  SKIP: test_secrets.py not found")

# Check 5 (0.04 Silver): test_anonymizer.py
print("--- Check 5: test_anonymizer.py ---")
if "test_anonymizer.py" in file_info:
    info = file_info["test_anonymizer.py"]
    anon = per_file.get("test_anonymizer.py", [0, 0, 0])
    anon_pass, anon_fail = anon[0], anon[1]
    n_called = len(info["calls_anonymizer"])
    n_asserts = info["asserts"]
    print(f"  pytest: {anon_pass} pass, {anon_fail} fail")
    print(f"  anonymizer funcs called: {n_called} {info['calls_anonymizer']}")
    print(f"  meaningful asserts: {n_asserts}")
    if anon_pass >= 5 and n_called >= 2 and n_asserts >= 3:
        add_reward(0.04, "test_anonymizer: quality gate met")
    elif anon_pass >= 2:
        add_reward(0.02, "test_anonymizer: partial")
    else:
        print("  FAIL")
else:
    print("  SKIP: test_anonymizer.py not found")

# Check 6 (0.04 Silver): test_parser.py
print("--- Check 6: test_parser.py ---")
if "test_parser.py" in file_info:
    info = file_info["test_parser.py"]
    par = per_file.get("test_parser.py", [0, 0, 0])
    par_pass, par_fail = par[0], par[1]
    n_called = len(info["calls_parser"])
    n_asserts = info["asserts"]
    print(f"  pytest: {par_pass} pass, {par_fail} fail")
    print(f"  parser funcs called: {n_called} {info['calls_parser']}")
    print(f"  meaningful asserts: {n_asserts}")
    if par_pass >= 3 and n_called >= 2 and n_asserts >= 3:
        add_reward(0.04, "test_parser: quality gate met")
    elif par_pass >= 2:
        add_reward(0.02, "test_parser: partial")
    else:
        print("  FAIL")
else:
    print("  SKIP: test_parser.py not found")

# Check 7 (0.03 Silver): test_cli.py or test_config.py (best of two)
print("--- Check 7: test_cli/config ---")
best_7 = 0.0
for fname in ["test_cli.py", "test_config.py"]:
    if fname not in file_info:
        continue
    fc = per_file.get(fname, [0, 0, 0])
    fc_pass = fc[0]
    n_asserts = file_info[fname]["asserts"]
    print(f"  {fname}: {fc_pass} pass, asserts: {n_asserts}")
    if fc_pass >= 3 and n_asserts >= 2:
        best_7 = max(best_7, 0.03)
    elif fc_pass >= 1:
        best_7 = max(best_7, 0.01)
if best_7 > 0:
    add_reward(best_7, "cli/config tests")
else:
    print("  FAIL: no cli or config tests meeting threshold")

# Check 8 (0.04 Silver): Total suite health
print("--- Check 8: total suite ---")
print(f"  Total: {total_pass} pass, {total_fail} fail")
if total_pass >= 30 and total_fail <= 2:
    add_reward(0.04, f"suite: {total_pass} pass, <= 2 fail")
elif total_pass >= 15:
    add_reward(0.02, f"suite: {total_pass} pass (partial)")
else:
    print(f"  FAIL: {total_pass} pass, {total_fail} fail")

# ====================================================================
# BEHAVIORAL — MUTATION TESTING (70%)
#
# Core anti-gaming mechanism: mutate source functions, verify agent's
# tests detect the change.  Trivial tests (e.g. assert func(x) is not
# None) will pass with the mutation and score 0 here.
# ====================================================================

def clear_pycache():
    """Clear __pycache__ under dataclaw/ and tests/ to force re-import."""
    for base in [os.path.join(WORKSPACE, "dataclaw"),
                 os.path.join(WORKSPACE, "tests")]:
        if not os.path.isdir(base):
            continue
        for root, dirs, _ in os.walk(base):
            for d in list(dirs):
                if d == "__pycache__":
                    shutil.rmtree(os.path.join(root, d), ignore_errors=True)

def run_mutation(src_file, mutation_code, test_path, base_count):
    """Mutate src_file by appending code, run pytest on test_path,
    return count of tests that went from passing to failing."""
    if not os.path.isfile(src_file):
        print(f"    Source not found: {src_file}")
        return 0
    backup = src_file + ".verifier_bak"
    try:
        shutil.copy2(src_file, backup)
        with open(src_file, "a") as f:
            f.write(mutation_code)
        clear_pycache()
        mp, mf, me = run_pytest(test_path, timeout=15)
        nf = max(0, base_count - mp)
        print(f"    After mutation: {mp} pass, {mf} fail, {me} err (base: {base_count})")
        print(f"    New failures: {nf}")
        # If everything errored, mutation may have broken the import entirely
        if mp == 0 and mf == 0 and me > 0:
            print("    WARNING: all tests errored — mutation may have broken import")
            return 0
        return nf
    except Exception as e:
        print(f"    Mutation error: {e}")
        return 0
    finally:
        if os.path.isfile(backup):
            shutil.copy2(backup, src_file)
            os.remove(backup)
        clear_pycache()

print(f"\nMutation baseline: {total_pass} total tests pass")

# ── Check 11 (0.28 F2P): scan_text → always returns [] ───────────
# Any test asserting scan_text detects patterns (JWT, API keys, etc.)
# will fail.  Trivial tests like assert isinstance(result, list) pass.
print("\n--- Check 11: scan_text mutation ---")
if total_pass > 0:
    sec_test = "tests/test_secrets.py" if os.path.isfile("tests/test_secrets.py") else "tests/"
    sec_base = per_file.get("test_secrets.py", [0, 0, 0])[0] if "test_secrets.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "secrets.py"),
        "\n\n# VERIFIER MUTATION\nscan_text = lambda *_a, **_kw: []\n",
        sec_test, sec_base,
    )
    if nf >= 3:
        add_reward(0.28, f"scan_text mutation: {nf} tests detected")
    elif nf >= 1:
        add_reward(0.18, f"scan_text mutation: {nf} detected (partial)")
    else:
        print("  FAIL: scan_text mutation not detected by any test")
else:
    print("  SKIP: no passing tests")

# ── Check 12 (0.22 F2P): anonymizer identity function ────────────
# _hash_username returns input unchanged, anonymize_path returns input.
# Tests asserting hashed output or stripped paths will detect this.
print("--- Check 12: anonymizer mutation ---")
if total_pass > 0:
    anon_test = "tests/test_anonymizer.py" if os.path.isfile("tests/test_anonymizer.py") else "tests/"
    anon_base = per_file.get("test_anonymizer.py", [0, 0, 0])[0] if "test_anonymizer.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "anonymizer.py"),
        "\n\n# VERIFIER MUTATION\n"
        "_hash_username = lambda *_a, **_kw: _a[0] if _a else ''\n"
        "anonymize_path = lambda *_a, **_kw: _a[0] if _a else ''\n",
        anon_test, anon_base,
    )
    if nf >= 2:
        add_reward(0.22, f"anonymizer mutation: {nf} tests detected")
    elif nf >= 1:
        add_reward(0.14, f"anonymizer mutation: {nf} detected (partial)")
    else:
        print("  FAIL: anonymizer mutation not detected by any test")
else:
    print("  SKIP: no passing tests")

# ── Check 13 (0.20 F2P): parser returns empty/None ───────────────
# _build_project_name returns "", _normalize_timestamp returns None.
# Tests asserting specific project names or ISO timestamps will detect.
print("--- Check 13: parser mutation ---")
if total_pass > 0:
    par_test = "tests/test_parser.py" if os.path.isfile("tests/test_parser.py") else "tests/"
    par_base = per_file.get("test_parser.py", [0, 0, 0])[0] if "test_parser.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "parser.py"),
        "\n\n# VERIFIER MUTATION\n"
        "_build_project_name = lambda *_a, **_kw: ''\n"
        "_normalize_timestamp = lambda *_a, **_kw: None\n",
        par_test, par_base,
    )
    if nf >= 2:
        add_reward(0.20, f"parser mutation: {nf} tests detected")
    elif nf >= 1:
        add_reward(0.13, f"parser mutation: {nf} detected (partial)")
    else:
        print("  FAIL: parser mutation not detected by any test")
else:
    print("  SKIP: no passing tests")

# ====================================================================
# RESULT
# ====================================================================
print()
print("=" * 50)
print(f"Final reward: {REWARD:.2f}")
print("=" * 50)

with open("/logs/verifier/reward.txt", "w") as f:
    f.write(f"{REWARD}")
PYEOF
