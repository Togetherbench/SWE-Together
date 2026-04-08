#!/usr/bin/env bash
#
# Verification script for dataclaw-test-coverage-fix.
# Checks that the agent wrote comprehensive, passing tests for the dataclaw package.
#
# Weight budget (sums to 1.10, capped at 1.00):
#   Structural (0.14): checks 1-7  (file existence, fixtures, assertion quality)
#   Behavioral  (0.86): checks 8-21 (pytest pass tiers, per-module quality, mutation)
#   P2P         (0.10): import smoke check + upstream pytest suite passes
#
# Max stub score analysis:
#   - Stub tests (import + assert True) earn: checks 1-3 (0.06) + check 5 maybe (0.02)
#     + check 8 partial (0.05) = 0.13 max
#   - Empty test files: check 1 (0.02) = 0.02
#   - Realistic stub ceiling: ~0.25 (files exist, conftest, some trivial passes)
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

def run_pytest_verbose(path, timeout=30):
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

def run_pytest_quick(path, timeout=15):
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
        return 0, 0, 0
    except Exception:
        return 0, 0, 0

# ── AST helpers ──────────────────────────────────────────────────
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
    """Count assertions that are not bare literals (rejects assert True)."""
    n = 0
    for node in ast.walk(tree):
        if isinstance(node, ast.Assert) and not isinstance(node.test, ast.Constant):
            n += 1
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

def assertion_types(tree):
    """Return set of distinct assertion method names (assertEqual, assertIn, etc.)
    and pytest-style patterns (==, in, is, raises, etc.)."""
    types = set()
    for node in ast.walk(tree):
        # pytest.raises
        if isinstance(node, ast.Call):
            fn = node.func
            if isinstance(fn, ast.Attribute) and fn.attr == "raises":
                types.add("raises")
        # assert x == y, assert x != y, assert x in y, etc.
        if isinstance(node, ast.Assert):
            test = node.test
            if isinstance(test, ast.Compare) and test.ops:
                for op in test.ops:
                    types.add(type(op).__name__)  # Eq, NotEq, In, NotIn, Is, IsNot, Lt, Gt...
            elif isinstance(test, ast.Call):
                fn = test.func
                if isinstance(fn, ast.Attribute):
                    types.add(fn.attr)  # assertEqual, assertTrue, assertIn...
                elif isinstance(fn, ast.Name):
                    types.add(fn.id)
            elif isinstance(test, ast.UnaryOp) and isinstance(test.op, ast.Not):
                types.add("Not")
    return types

# ── Gather data ──────────────────────────────────────────────────
test_dir = "tests"
has_test_dir = os.path.isdir(test_dir)
test_files = sorted(f for f in (os.listdir(test_dir) if has_test_dir else [])
                    if f.startswith("test_") and f.endswith(".py"))

file_info = {}
total_asserts = 0
all_imported_mods = set()
all_assertion_types = set()

for fname in test_files:
    tree = parse_file(os.path.join(test_dir, fname))
    if tree is None:
        continue
    ma = meaningful_asserts(tree)
    im = imported_dataclaw_modules(tree)
    at = assertion_types(tree)
    info = {"asserts": ma, "imported_mods": im, "assertion_types": at}
    for mod in KNOWN_FUNCS:
        info[f"calls_{mod}"] = called_known_funcs(tree, mod)
    file_info[fname] = info
    total_asserts += ma
    all_imported_mods |= im
    all_assertion_types |= at

# ── Run full test suite once ─────────────────────────────────────
print("--- Running test suite ---")
per_file, total_pass, total_fail, total_err = run_pytest_verbose("tests/", timeout=30)
print(f"Total: {total_pass} pass, {total_fail} fail, {total_err} err")
for fname, counts in sorted(per_file.items()):
    print(f"  {fname}: {counts[0]} pass, {counts[1]} fail, {counts[2]} err")

# ====================================================================
# STRUCTURAL CHECKS (0.14 total)
# ====================================================================

# Check 1 (0.02): >= 4 test_*.py files
print("\n--- Check 1: test file count ---")
print(f"  Found {len(test_files)} test files: {test_files}")
if len(test_files) >= 4:
    add_reward(0.02, ">= 4 test files")
else:
    print("  FAIL: need >= 4 test_*.py files")

# Check 2 (0.02): conftest.py with >= 2 non-stub fixtures
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

# Check 3 (0.02): >= 25 meaningful assertions total
print("--- Check 3: assertion count ---")
print(f"  Total meaningful assertions: {total_asserts}")
if total_asserts >= 25:
    add_reward(0.02, ">= 25 meaningful assertions")
else:
    print("  FAIL: too few meaningful assertions")

# Check 4 (0.02): >= 4 dataclaw modules imported across test files
print("--- Check 4: module coverage breadth ---")
print(f"  Modules imported: {all_imported_mods}")
if len(all_imported_mods) >= 4:
    add_reward(0.02, ">= 4 dataclaw modules tested")
else:
    print("  FAIL: too few modules covered")

# Check 5 (0.02): >= 3 distinct assertion types (Eq, In, Is, raises, Not, etc.)
print("--- Check 5: assertion variety ---")
print(f"  Distinct assertion types: {all_assertion_types}")
if len(all_assertion_types) >= 3:
    add_reward(0.02, f">= 3 assertion types ({len(all_assertion_types)} found)")
else:
    print("  FAIL: too few assertion types")

# Check 6 (0.02): >= 50 meaningful assertions total (deeper quality)
print("--- Check 6: deep assertion count ---")
if total_asserts >= 50:
    add_reward(0.02, ">= 50 meaningful assertions")
else:
    print(f"  FAIL: {total_asserts} < 50 meaningful assertions")

# Check 7 (0.02): >= 5 distinct assertion types
print("--- Check 7: deep assertion variety ---")
if len(all_assertion_types) >= 5:
    add_reward(0.02, f">= 5 assertion types ({len(all_assertion_types)} found)")
else:
    print(f"  FAIL: {len(all_assertion_types)} < 5 assertion types")

# ====================================================================
# BEHAVIORAL — GRADUATED PYTEST PASS TIERS (0.30 total)
# ====================================================================

# Check 8 (0.05): tests exist and at least 1 passes
print("\n--- Check 8: tests exist and pass ---")
if total_pass >= 1:
    add_reward(0.05, f"at least 1 test passes ({total_pass})")
else:
    print("  FAIL: no passing tests")

# Check 9 (0.05): >= 5 tests pass
print("--- Check 9: >= 5 tests pass ---")
if total_pass >= 5:
    add_reward(0.05, f">= 5 tests pass ({total_pass})")
else:
    print(f"  FAIL: {total_pass} < 5 passing")

# Check 10 (0.05): >= 10 tests pass
print("--- Check 10: >= 10 tests pass ---")
if total_pass >= 10:
    add_reward(0.05, f">= 10 tests pass ({total_pass})")
else:
    print(f"  FAIL: {total_pass} < 10 passing")

# Check 11 (0.05): >= 20 tests pass
print("--- Check 11: >= 20 tests pass ---")
if total_pass >= 20:
    add_reward(0.05, f">= 20 tests pass ({total_pass})")
else:
    print(f"  FAIL: {total_pass} < 20 passing")

# Check 12 (0.05): >= 40 tests pass
print("--- Check 12: >= 40 tests pass ---")
if total_pass >= 40:
    add_reward(0.05, f">= 40 tests pass ({total_pass})")
else:
    print(f"  FAIL: {total_pass} < 40 passing")

# Check 13 (0.05): suite health — >= 30 pass AND <= 2 failures
print("--- Check 13: suite health (low failure rate) ---")
if total_pass >= 30 and total_fail <= 2:
    add_reward(0.05, f"healthy suite: {total_pass} pass, {total_fail} fail")
else:
    print(f"  FAIL: {total_pass} pass, {total_fail} fail (need >= 30 pass, <= 2 fail)")

# ====================================================================
# BEHAVIORAL — PER-MODULE QUALITY GATES (0.24 total)
# Each module: tests pass + call real functions + have real assertions
# ====================================================================

# Check 14 (0.08): test_secrets.py quality
print("\n--- Check 14: test_secrets.py quality ---")
if "test_secrets.py" in file_info:
    info = file_info["test_secrets.py"]
    sec = per_file.get("test_secrets.py", [0, 0, 0])
    sec_pass = sec[0]
    n_called = len(info["calls_secrets"])
    n_asserts = info["asserts"]
    print(f"  pytest: {sec_pass} pass")
    print(f"  secrets funcs called: {n_called} {info['calls_secrets']}")
    print(f"  meaningful asserts: {n_asserts}")
    if sec_pass >= 10 and n_called >= 3 and n_asserts >= 8:
        add_reward(0.08, "test_secrets: full quality gate met")
    elif sec_pass >= 5 and n_called >= 2 and n_asserts >= 4:
        add_reward(0.05, "test_secrets: mid quality gate")
    elif sec_pass >= 2:
        add_reward(0.02, "test_secrets: partial")
    else:
        print("  FAIL: insufficient quality")
else:
    print("  SKIP: test_secrets.py not found")

# Check 15 (0.06): test_anonymizer.py quality
print("--- Check 15: test_anonymizer.py quality ---")
if "test_anonymizer.py" in file_info:
    info = file_info["test_anonymizer.py"]
    anon = per_file.get("test_anonymizer.py", [0, 0, 0])
    anon_pass = anon[0]
    n_called = len(info["calls_anonymizer"])
    n_asserts = info["asserts"]
    print(f"  pytest: {anon_pass} pass")
    print(f"  anonymizer funcs called: {n_called} {info['calls_anonymizer']}")
    print(f"  meaningful asserts: {n_asserts}")
    if anon_pass >= 8 and n_called >= 3 and n_asserts >= 5:
        add_reward(0.06, "test_anonymizer: full quality gate")
    elif anon_pass >= 4 and n_called >= 2 and n_asserts >= 3:
        add_reward(0.04, "test_anonymizer: mid quality gate")
    elif anon_pass >= 2:
        add_reward(0.02, "test_anonymizer: partial")
    else:
        print("  FAIL")
else:
    print("  SKIP: test_anonymizer.py not found")

# Check 16 (0.05): test_parser.py quality
print("--- Check 16: test_parser.py quality ---")
if "test_parser.py" in file_info:
    info = file_info["test_parser.py"]
    par = per_file.get("test_parser.py", [0, 0, 0])
    par_pass = par[0]
    n_called = len(info["calls_parser"])
    n_asserts = info["asserts"]
    print(f"  pytest: {par_pass} pass")
    print(f"  parser funcs called: {n_called} {info['calls_parser']}")
    print(f"  meaningful asserts: {n_asserts}")
    if par_pass >= 6 and n_called >= 3 and n_asserts >= 5:
        add_reward(0.05, "test_parser: full quality gate")
    elif par_pass >= 3 and n_called >= 2 and n_asserts >= 3:
        add_reward(0.03, "test_parser: mid quality gate")
    elif par_pass >= 2:
        add_reward(0.02, "test_parser: partial")
    else:
        print("  FAIL")
else:
    print("  SKIP: test_parser.py not found")

# Check 17 (0.05): test_cli.py or test_config.py (best of both)
print("--- Check 17: test_cli/config quality ---")
best_17 = 0.0
for fname in ["test_cli.py", "test_config.py"]:
    if fname not in file_info:
        continue
    fc = per_file.get(fname, [0, 0, 0])
    fc_pass = fc[0]
    n_asserts = file_info[fname]["asserts"]
    mod = "cli" if "cli" in fname else "config"
    n_called = len(file_info[fname].get(f"calls_{mod}", set()))
    print(f"  {fname}: {fc_pass} pass, asserts: {n_asserts}, funcs: {n_called}")
    if fc_pass >= 5 and n_asserts >= 3 and n_called >= 2:
        best_17 = max(best_17, 0.05)
    elif fc_pass >= 3 and n_asserts >= 2:
        best_17 = max(best_17, 0.03)
    elif fc_pass >= 1:
        best_17 = max(best_17, 0.01)
if best_17 > 0:
    add_reward(best_17, "cli/config tests")
else:
    print("  FAIL: no cli or config tests meeting threshold")

# ====================================================================
# BEHAVIORAL — MUTATION TESTING (0.32 total)
#
# Anti-gaming mechanism: mutate source functions, verify agent's tests
# detect the change. Graduated scoring per mutation instead of all-or-nothing.
# ====================================================================

def clear_pycache():
    for base in [os.path.join(WORKSPACE, "dataclaw"),
                 os.path.join(WORKSPACE, "tests")]:
        if not os.path.isdir(base):
            continue
        for root, dirs, _ in os.walk(base):
            for d in list(dirs):
                if d == "__pycache__":
                    shutil.rmtree(os.path.join(root, d), ignore_errors=True)

def run_mutation(src_file, mutation_code, test_path, base_count):
    """Mutate src_file, run pytest, return count of new failures."""
    if not os.path.isfile(src_file):
        print(f"    Source not found: {src_file}")
        return 0
    backup = src_file + ".verifier_bak"
    try:
        shutil.copy2(src_file, backup)
        with open(src_file, "a") as f:
            f.write(mutation_code)
        clear_pycache()
        mp, mf, me = run_pytest_quick(test_path, timeout=15)
        nf = max(0, base_count - mp)
        print(f"    After mutation: {mp} pass, {mf} fail, {me} err (base: {base_count})")
        print(f"    New failures: {nf}")
        if mp == 0 and mf == 0 and me > 0:
            print("    WARNING: all errored, mutation may have broken import")
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

# Check 18a (0.04): scan_text mutation — scan_text returns []
# Check 18b (0.04): More scan_text failures detected (graduated)
print("\n--- Check 18: scan_text mutation ---")
if total_pass > 0:
    sec_test = "tests/test_secrets.py" if os.path.isfile("tests/test_secrets.py") else "tests/"
    sec_base = per_file.get("test_secrets.py", [0, 0, 0])[0] if "test_secrets.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "secrets.py"),
        "\n\n# VERIFIER MUTATION\nscan_text = lambda *_a, **_kw: []\n",
        sec_test, sec_base,
    )
    if nf >= 5:
        add_reward(0.08, f"scan_text mutation: {nf} tests detected (excellent)")
    elif nf >= 3:
        add_reward(0.06, f"scan_text mutation: {nf} tests detected (good)")
    elif nf >= 1:
        add_reward(0.04, f"scan_text mutation: {nf} detected (basic)")
    else:
        print("  FAIL: scan_text mutation not detected by any test")
else:
    print("  SKIP: no passing tests")

# Check 19a (0.04): redact_text mutation — returns input unchanged
# Check 19b (0.04): More redact failures detected (graduated)
print("--- Check 19: redact_text mutation ---")
if total_pass > 0:
    sec_test = "tests/test_secrets.py" if os.path.isfile("tests/test_secrets.py") else "tests/"
    sec_base = per_file.get("test_secrets.py", [0, 0, 0])[0] if "test_secrets.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "secrets.py"),
        "\n\n# VERIFIER MUTATION\nredact_text = lambda text, *_a, **_kw: text\n",
        sec_test, sec_base,
    )
    if nf >= 3:
        add_reward(0.08, f"redact_text mutation: {nf} tests detected (excellent)")
    elif nf >= 2:
        add_reward(0.06, f"redact_text mutation: {nf} tests detected (good)")
    elif nf >= 1:
        add_reward(0.04, f"redact_text mutation: {nf} detected (basic)")
    else:
        print("  FAIL: redact_text mutation not detected by any test")
else:
    print("  SKIP: no passing tests")

# Check 20a (0.04): anonymizer identity — _hash_username returns input
# Check 20b (0.04): More anonymizer failures detected (graduated)
print("--- Check 20: anonymizer mutation ---")
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
    if nf >= 3:
        add_reward(0.08, f"anonymizer mutation: {nf} tests detected (excellent)")
    elif nf >= 2:
        add_reward(0.06, f"anonymizer mutation: {nf} tests detected (good)")
    elif nf >= 1:
        add_reward(0.04, f"anonymizer mutation: {nf} detected (basic)")
    else:
        print("  FAIL: anonymizer mutation not detected by any test")
else:
    print("  SKIP: no passing tests")

# Check 21a (0.04): parser mutation — returns empty/None
# Check 21b (0.04): More parser failures detected (graduated)
print("--- Check 21: parser mutation ---")
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
    if nf >= 3:
        add_reward(0.08, f"parser mutation: {nf} tests detected (excellent)")
    elif nf >= 2:
        add_reward(0.06, f"parser mutation: {nf} tests detected (good)")
    elif nf >= 1:
        add_reward(0.04, f"parser mutation: {nf} detected (basic)")
    else:
        print("  FAIL: parser mutation not detected by any test")
else:
    print("  SKIP: no passing tests")

# ====================================================================
# P2P: Upstream dataclaw package is importable and functional
#
# The dataclaw package at this commit should be importable with its
# core modules (secrets, anonymizer, parser, cli, config). This
# verifies the agent hasn't broken the package itself while writing
# tests. Weight: 0.05
# ====================================================================
print("\n--- P2P: dataclaw package importable ---")
p2p_pass = True
try:
    import importlib
    for mod_name in ["dataclaw.secrets", "dataclaw.anonymizer", "dataclaw.parser",
                     "dataclaw.config"]:
        try:
            importlib.import_module(mod_name)
        except ImportError as e:
            print(f"  FAIL: cannot import {mod_name}: {e}")
            p2p_pass = False
            break
    if p2p_pass:
        # Smoke-test: secrets.scan_text and anonymizer._hash_username exist
        from dataclaw.secrets import scan_text
        from dataclaw.anonymizer import _hash_username
        if not callable(scan_text):
            print("  FAIL: scan_text not callable")
            p2p_pass = False
        if not callable(_hash_username):
            print("  FAIL: _hash_username not callable")
            p2p_pass = False
except Exception as e:
    print(f"  FAIL: unexpected error: {e}")
    p2p_pass = False

if p2p_pass:
    add_reward(0.05, "P2P: dataclaw package importable + key functions exist")
else:
    print("  FAIL: dataclaw package import/smoke check failed")

# ====================================================================
# P2P: Upstream test suite passes (agent tests don't crash/hang)
#
# Run the agent-written tests end-to-end with a timeout and -x (fail
# fast). A clean exit (rc 0) means no failures, no collection errors,
# and no hangs. Weight: 0.05
# ====================================================================
print("\n--- P2P: upstream pytest run ---")
try:
    p2p_run = subprocess.run(
        [sys.executable, "-m", "pytest", "tests/", "-x", "--timeout=60", "-q"],
        capture_output=True, text=True, timeout=90,
        cwd=WORKSPACE,
    )
    print(p2p_run.stdout[-500:] if len(p2p_run.stdout) > 500 else p2p_run.stdout)
    if p2p_run.returncode == 0:
        add_reward(0.05, "P2P: upstream pytest suite passes cleanly")
    else:
        print(f"  FAIL: pytest exited with rc={p2p_run.returncode}")
except subprocess.TimeoutExpired:
    print("  FAIL: pytest timed out (90s)")
except Exception as e:
    print(f"  FAIL: {e}")

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
