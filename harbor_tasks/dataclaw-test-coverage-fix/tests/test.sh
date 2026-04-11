#!/usr/bin/env bash
#
# Verification script for dataclaw-test-coverage-fix (v3 — tuned for discrimination).
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
    print(f"  +{amount:.3f} -> {REWARD:.3f}  ({reason})")

def run_pytest_verbose(path, timeout=120):
    try:
        r = subprocess.run(
            [sys.executable, "-m", "pytest", path, "-v", "--tb=no", "--timeout=30"],
            capture_output=True, text=True, timeout=timeout, cwd=WORKSPACE)
        out = r.stdout + r.stderr
        per_file = {}
        for line in out.splitlines():
            m = re.search(r'(tests/\S+\.py)::\S+\s+(PASSED|FAILED|ERROR)', line)
            if m:
                fname = os.path.basename(m.group(1))
                status = m.group(2)
                if fname not in per_file:
                    per_file[fname] = [0, 0, 0]
                idx = {"PASSED": 0, "FAILED": 1, "ERROR": 2}[status]
                per_file[fname][idx] += 1
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
    try:
        r = subprocess.run(
            [sys.executable, "-m", "pytest", path, "-q", "--tb=no", "--timeout=10"],
            capture_output=True, text=True, timeout=timeout, cwd=WORKSPACE)
        out = r.stdout + r.stderr
        def _int(pat):
            m = re.search(pat, out)
            return int(m.group(1)) if m else 0
        return _int(r'(\d+) passed'), _int(r'(\d+) failed'), _int(r'(\d+) error')
    except:
        return 0, 0, 0

def run_coverage(timeout=120):
    try:
        r = subprocess.run(
            [sys.executable, "-m", "pytest", "tests/", "--cov=dataclaw",
             "--cov-report=term-missing", "-q", "--tb=no", "--timeout=30"],
            capture_output=True, text=True, timeout=timeout, cwd=WORKSPACE)
        out = r.stdout + r.stderr
        overall = 0
        m = re.search(r'TOTAL\s+\d+\s+\d+\s+(\d+)%', out)
        if m:
            overall = int(m.group(1))
        per_mod = {}
        for line in out.splitlines():
            mm = re.search(r'dataclaw/(\w+)\.py\s+\d+\s+\d+\s+(\d+)%', line)
            if mm:
                per_mod[mm.group(1)] = int(mm.group(2))
        return overall, per_mod
    except:
        return 0, {}

# -- AST helpers --
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
    except:
        return None

def meaningful_asserts(tree):
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
    types = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            fn = node.func
            if isinstance(fn, ast.Attribute) and fn.attr == "raises":
                types.add("raises")
        if isinstance(node, ast.Assert):
            test = node.test
            if isinstance(test, ast.Compare) and test.ops:
                for op in test.ops:
                    types.add(type(op).__name__)
            elif isinstance(test, ast.Call):
                fn = test.func
                if isinstance(fn, ast.Attribute):
                    types.add(fn.attr)
                elif isinstance(fn, ast.Name):
                    types.add(fn.id)
            elif isinstance(test, ast.UnaryOp) and isinstance(test.op, ast.Not):
                types.add("Not")
    return types

def count_parametrize_uses(tree):
    count = 0
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            for dec in node.decorator_list:
                if isinstance(dec, ast.Call):
                    fn = dec.func
                    if isinstance(fn, ast.Attribute) and fn.attr == "parametrize":
                        count += 1
    return count

# -- Gather data --
test_dir = "tests"
has_test_dir = os.path.isdir(test_dir)
test_files = sorted(f for f in (os.listdir(test_dir) if has_test_dir else [])
                    if f.startswith("test_") and f.endswith(".py"))

file_info = {}
total_asserts = 0
all_imported_mods = set()
all_assertion_types = set()
total_parametrize = 0
all_called_funcs = set()

for fname in test_files:
    tree = parse_file(os.path.join(test_dir, fname))
    if tree is None:
        continue
    ma = meaningful_asserts(tree)
    im = imported_dataclaw_modules(tree)
    at = assertion_types(tree)
    pc = count_parametrize_uses(tree)
    info = {"asserts": ma, "imported_mods": im, "assertion_types": at,
            "parametrize_count": pc}
    for mod in KNOWN_FUNCS:
        called = called_known_funcs(tree, mod)
        info[f"calls_{mod}"] = called
        all_called_funcs |= {f"{mod}.{fn}" for fn in called}
    file_info[fname] = info
    total_asserts += ma
    all_imported_mods |= im
    all_assertion_types |= at
    total_parametrize += pc

# -- Run full test suite once --
print("--- Running test suite ---")
per_file, total_pass, total_fail, total_err = run_pytest_verbose("tests/", timeout=120)
print(f"Total: {total_pass} pass, {total_fail} fail, {total_err} err")
for fname, counts in sorted(per_file.items()):
    print(f"  {fname}: {counts[0]} pass, {counts[1]} fail, {counts[2]} err")

total_known_funcs = sum(len(v) for v in KNOWN_FUNCS.values())
n_funcs = len(all_called_funcs)
print(f"\nFunction coverage: {n_funcs}/{total_known_funcs} known functions called")
print(f"  Called: {sorted(all_called_funcs)}")

# ====================================================================
# STRUCTURAL CHECKS (0.10 total)
# ====================================================================

print("\n--- Check 1: test file count ---")
if len(test_files) >= 4:
    add_reward(0.01, ">= 4 test files")

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
    if fixtures >= 2:
        add_reward(0.01, f"conftest.py has {fixtures} fixtures")

print("--- Check 3: module breadth ---")
if len(all_imported_mods) >= 5:
    add_reward(0.01, ">= 5 dataclaw modules tested")

# PARAMETRIZE — weighted heavier (0.04)
print("--- Check 4: parametrize usage ---")
print(f"  Total parametrize uses: {total_parametrize}")
if total_parametrize >= 8:
    add_reward(0.04, f"extensive parametrize ({total_parametrize} uses)")
elif total_parametrize >= 4:
    add_reward(0.03, f"good parametrize ({total_parametrize} uses)")
elif total_parametrize >= 1:
    add_reward(0.02, f"some parametrize ({total_parametrize} uses)")
else:
    print("  FAIL: no parametrize usage")

# ASSERTION VARIETY (0.03)
print("--- Check 4c: assertion variety ---")
print(f"  Types: {sorted(all_assertion_types)}")
if len(all_assertion_types) >= 8:
    add_reward(0.03, f">= 8 assertion types ({len(all_assertion_types)})")
elif len(all_assertion_types) >= 5:
    add_reward(0.02, f">= 5 assertion types ({len(all_assertion_types)})")
elif len(all_assertion_types) >= 3:
    add_reward(0.01, f">= 3 assertion types ({len(all_assertion_types)})")

# ====================================================================
# BEHAVIORAL - GRADUATED PYTEST PASS TIERS (0.10 total)
# ====================================================================

print("\n--- Check 5: >= 80 tests pass ---")
if total_asserts < 30:
    print("  SKIP: assertion guard")
elif total_pass >= 80:
    add_reward(0.01, f">= 80 tests pass ({total_pass})")

print("--- Check 6: >= 150 tests pass ---")
if total_asserts >= 30 and total_pass >= 150:
    add_reward(0.02, f">= 150 tests pass ({total_pass})")

print("--- Check 7: >= 250 tests pass ---")
if total_asserts >= 30 and total_pass >= 250:
    add_reward(0.03, f">= 250 tests pass ({total_pass})")

print("--- Check 8: >= 350 tests pass ---")
if total_asserts >= 30 and total_pass >= 350:
    add_reward(0.02, f">= 350 tests pass ({total_pass})")

# ====================================================================
# SUITE HEALTH (0.05 total) — softened for near-clean suites
# ====================================================================

print("--- Check 9: suite health ---")
if total_asserts >= 30:
    total_run = total_pass + total_fail + total_err
    fail_rate = (total_fail + total_err) / max(1, total_run) * 100
    print(f"  {total_pass} pass, {total_fail} fail = {fail_rate:.1f}% fail rate")
    if total_pass >= 200 and fail_rate == 0:
        add_reward(0.05, f"pristine suite: {total_pass} pass, 0 fail")
    elif total_pass >= 150 and fail_rate < 2:
        add_reward(0.04, f"near-pristine: {total_pass} pass, {fail_rate:.1f}% fail")
    elif total_pass >= 100 and fail_rate < 5:
        add_reward(0.03, f"healthy: {total_pass} pass, {fail_rate:.1f}% fail")
    elif total_pass >= 50 and fail_rate < 10:
        add_reward(0.02, f"acceptable: {total_pass} pass, {fail_rate:.1f}% fail")

# ====================================================================
# FUNCTION BREADTH (0.07 total)
# ====================================================================

print(f"\n--- Check 9c: function breadth ({n_funcs} funcs) ---")
if n_funcs >= 33:
    add_reward(0.07, f">= 33 unique functions ({n_funcs})")
elif n_funcs >= 28:
    add_reward(0.05, f">= 28 unique functions ({n_funcs})")
elif n_funcs >= 22:
    add_reward(0.04, f">= 22 unique functions ({n_funcs})")
elif n_funcs >= 15:
    add_reward(0.02, f">= 15 unique functions ({n_funcs})")

# ====================================================================
# PER-MODULE QUALITY GATES (0.22 total)
# ====================================================================

# test_secrets.py (0.08 — RAISED, key differentiator)
print("\n--- Check 10: test_secrets.py quality ---")
if "test_secrets.py" in file_info:
    info = file_info["test_secrets.py"]
    sec = per_file.get("test_secrets.py", [0, 0, 0])
    sec_pass = sec[0]
    n_called = len(info["calls_secrets"])
    n_asserts = info["asserts"]
    print(f"  pytest: {sec_pass} pass, funcs: {n_called}, asserts: {n_asserts}")
    if sec_pass >= 55 and n_called >= 6 and n_asserts >= 50:
        add_reward(0.08, "test_secrets: full quality gate")
    elif sec_pass >= 35 and n_called >= 5 and n_asserts >= 30:
        add_reward(0.04, "test_secrets: mid quality gate")
    elif sec_pass >= 15 and n_called >= 3:
        add_reward(0.02, "test_secrets: partial")

# test_anonymizer.py (0.05)
print("--- Check 11: test_anonymizer.py quality ---")
if "test_anonymizer.py" in file_info:
    info = file_info["test_anonymizer.py"]
    anon = per_file.get("test_anonymizer.py", [0, 0, 0])
    anon_pass = anon[0]
    n_called = len(info["calls_anonymizer"])
    n_asserts = info["asserts"]
    print(f"  pytest: {anon_pass} pass, funcs: {n_called}, asserts: {n_asserts}")
    if anon_pass >= 30 and n_called >= 5 and n_asserts >= 30:
        add_reward(0.05, "test_anonymizer: full quality gate")
    elif anon_pass >= 15 and n_called >= 3 and n_asserts >= 12:
        add_reward(0.025, "test_anonymizer: mid")
    elif anon_pass >= 5:
        add_reward(0.01, "test_anonymizer: partial")

# test_parser.py (0.05)
print("--- Check 12: test_parser.py quality ---")
if "test_parser.py" in file_info:
    info = file_info["test_parser.py"]
    par = per_file.get("test_parser.py", [0, 0, 0])
    par_pass = par[0]
    n_called = len(info["calls_parser"])
    n_asserts = info["asserts"]
    print(f"  pytest: {par_pass} pass, funcs: {n_called}, asserts: {n_asserts}")
    if par_pass >= 40 and n_called >= 7 and n_asserts >= 35:
        add_reward(0.05, "test_parser: full quality gate")
    elif par_pass >= 18 and n_called >= 5 and n_asserts >= 15:
        add_reward(0.025, "test_parser: mid")
    elif par_pass >= 5:
        add_reward(0.01, "test_parser: partial")

# test_cli/config (0.04)
print("--- Check 13: test_cli/config quality ---")
best_13 = 0.0
for fname in ["test_cli.py", "test_config.py"]:
    if fname not in file_info:
        continue
    fc = per_file.get(fname, [0, 0, 0])
    fc_pass = fc[0]
    n_asserts = file_info[fname]["asserts"]
    mod = "cli" if "cli" in fname else "config"
    n_called = len(file_info[fname].get(f"calls_{mod}", set()))
    print(f"  {fname}: {fc_pass} pass, asserts: {n_asserts}, funcs: {n_called}")
    if fc_pass >= 20 and n_asserts >= 18 and n_called >= 5:
        best_13 = max(best_13, 0.04)
    elif fc_pass >= 10 and n_asserts >= 8 and n_called >= 3:
        best_13 = max(best_13, 0.02)
    elif fc_pass >= 3:
        best_13 = max(best_13, 0.01)
if best_13 > 0:
    add_reward(best_13, "cli/config tests")

# ====================================================================
# LINE COVERAGE (0.16 total)
# ====================================================================

print("\n--- Coverage Analysis ---")
coverage_pct, per_mod_cov = run_coverage(timeout=120)
print(f"  Overall: {coverage_pct}%")
for mod, pct in sorted(per_mod_cov.items()):
    print(f"    {mod}: {pct}%")

if coverage_pct >= 35:
    add_reward(0.02, f">= 35% coverage ({coverage_pct}%)")
if coverage_pct >= 50:
    add_reward(0.03, f">= 50% coverage ({coverage_pct}%)")
if coverage_pct >= 65:
    add_reward(0.04, f">= 65% coverage ({coverage_pct}%)")
if coverage_pct >= 78:
    add_reward(0.03, f">= 78% coverage ({coverage_pct}%)")

# Per-module depth (0.04)
deep_modules = 0
for mod in ["secrets", "anonymizer", "parser", "config"]:
    if per_mod_cov.get(mod, 0) >= 90:
        deep_modules += 1
print(f"  Core modules >= 90%: {deep_modules}/4")
if deep_modules >= 4:
    add_reward(0.04, "all 4 core modules >= 90%")
elif deep_modules >= 3:
    add_reward(0.03, f"{deep_modules}/4 core >= 90%")
elif deep_modules >= 2:
    add_reward(0.02, f"{deep_modules}/4 core >= 90%")

# ====================================================================
# MUTATION TESTING (0.50 total — primary discriminator)
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
    if not os.path.isfile(src_file):
        return 0
    backup = src_file + ".verifier_bak"
    try:
        shutil.copy2(src_file, backup)
        with open(src_file, "a") as f:
            f.write(mutation_code)
        clear_pycache()
        mp, mf, me = run_pytest_quick(test_path, timeout=15)
        nf = max(0, base_count - mp)
        print(f"    After: {mp} pass, {mf} fail (base: {base_count}) -> {nf} new failures")
        if mp == 0 and mf == 0 and me > 0:
            return 0
        return nf
    except:
        return 0
    finally:
        if os.path.isfile(backup):
            shutil.copy2(backup, src_file)
            os.remove(backup)
        clear_pycache()

print(f"\nMutation baseline: {total_pass} tests pass")

# Check 18 (0.06): scan_text mutation — RAISED weight
print("\n--- Check 18: scan_text mutation ---")
if total_pass > 0:
    sec_test = "tests/test_secrets.py" if os.path.isfile("tests/test_secrets.py") else "tests/"
    sec_base = per_file.get("test_secrets.py", [0, 0, 0])[0] if "test_secrets.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "secrets.py"),
        "\n\n# VERIFIER MUTATION\nscan_text = lambda *_a, **_kw: []\n",
        sec_test, sec_base)
    if nf >= 25:
        add_reward(0.06, f"scan_text: {nf} detected (excellent)")
    elif nf >= 12:
        add_reward(0.03, f"scan_text: {nf} detected (good)")
    elif nf >= 3:
        add_reward(0.01, f"scan_text: {nf} detected (basic)")

# Check 19 (0.05): redact_text mutation
print("--- Check 19: redact_text mutation ---")
if total_pass > 0:
    sec_test = "tests/test_secrets.py" if os.path.isfile("tests/test_secrets.py") else "tests/"
    sec_base = per_file.get("test_secrets.py", [0, 0, 0])[0] if "test_secrets.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "secrets.py"),
        "\n\n# VERIFIER MUTATION\nredact_text = lambda text, *_a, **_kw: (text, 0)\n",
        sec_test, sec_base)
    if nf >= 15:
        add_reward(0.05, f"redact_text: {nf} detected (excellent)")
    elif nf >= 8:
        add_reward(0.03, f"redact_text: {nf} detected (good)")
    elif nf >= 2:
        add_reward(0.01, f"redact_text: {nf} detected (basic)")

# Check 20 (0.06): anonymizer mutation — RAISED weight
print("--- Check 20: anonymizer mutation ---")
if total_pass > 0:
    anon_test = "tests/test_anonymizer.py" if os.path.isfile("tests/test_anonymizer.py") else "tests/"
    anon_base = per_file.get("test_anonymizer.py", [0, 0, 0])[0] if "test_anonymizer.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "anonymizer.py"),
        "\n\n# VERIFIER MUTATION\n"
        "_hash_username = lambda *_a, **_kw: _a[0] if _a else ''\n"
        "anonymize_path = lambda *_a, **_kw: _a[0] if _a else ''\n",
        anon_test, anon_base)
    if nf >= 15:
        add_reward(0.06, f"anonymizer: {nf} detected (excellent)")
    elif nf >= 8:
        add_reward(0.03, f"anonymizer: {nf} detected (good)")
    elif nf >= 2:
        add_reward(0.01, f"anonymizer: {nf} detected (basic)")

# Check 21 (0.04): parser mutation
print("--- Check 21: parser mutation ---")
if total_pass > 0:
    par_test = "tests/test_parser.py" if os.path.isfile("tests/test_parser.py") else "tests/"
    par_base = per_file.get("test_parser.py", [0, 0, 0])[0] if "test_parser.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "parser.py"),
        "\n\n# VERIFIER MUTATION\n"
        "_build_project_name = lambda *_a, **_kw: ''\n"
        "_normalize_timestamp = lambda *_a, **_kw: None\n",
        par_test, par_base)
    if nf >= 12:
        add_reward(0.04, f"parser: {nf} detected (excellent)")
    elif nf >= 6:
        add_reward(0.025, f"parser: {nf} detected (good)")
    elif nf >= 2:
        add_reward(0.01, f"parser: {nf} detected (basic)")

# Check 22 (0.05): entropy mutation — RAISED weight
print("\n--- Check 22: entropy mutation ---")
if total_pass > 0:
    sec_test = "tests/test_secrets.py" if os.path.isfile("tests/test_secrets.py") else "tests/"
    sec_base = per_file.get("test_secrets.py", [0, 0, 0])[0] if "test_secrets.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "secrets.py"),
        "\n\n# VERIFIER MUTATION\n_shannon_entropy = lambda *_a, **_kw: 0.0\n",
        sec_test, sec_base)
    if nf >= 8:
        add_reward(0.05, f"entropy: {nf} detected (excellent)")
    elif nf >= 4:
        add_reward(0.03, f"entropy: {nf} detected (good)")
    elif nf >= 1:
        add_reward(0.01, f"entropy: {nf} detected (basic)")

# Check 23 (0.04): allowlist mutation
print("--- Check 23: allowlist mutation ---")
if total_pass > 0:
    sec_test = "tests/test_secrets.py" if os.path.isfile("tests/test_secrets.py") else "tests/"
    sec_base = per_file.get("test_secrets.py", [0, 0, 0])[0] if "test_secrets.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "secrets.py"),
        "\n\n# VERIFIER MUTATION\nALLOWLIST = []\n",
        sec_test, sec_base)
    if nf >= 8:
        add_reward(0.04, f"allowlist: {nf} detected (excellent)")
    elif nf >= 4:
        add_reward(0.02, f"allowlist: {nf} detected (good)")
    elif nf >= 1:
        add_reward(0.01, f"allowlist: {nf} detected (basic)")

# Check 24 (0.04): anonymize_text identity
print("--- Check 24: anonymize_text mutation ---")
if total_pass > 0:
    anon_test = "tests/test_anonymizer.py" if os.path.isfile("tests/test_anonymizer.py") else "tests/"
    anon_base = per_file.get("test_anonymizer.py", [0, 0, 0])[0] if "test_anonymizer.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "anonymizer.py"),
        "\n\n# VERIFIER MUTATION\nanonymize_text = lambda text, *_a, **_kw: text\n",
        anon_test, anon_base)
    if nf >= 8:
        add_reward(0.04, f"anonymize_text: {nf} detected (excellent)")
    elif nf >= 4:
        add_reward(0.02, f"anonymize_text: {nf} detected (good)")
    elif nf >= 1:
        add_reward(0.01, f"anonymize_text: {nf} detected (basic)")

# Check 25 (0.04): redact_custom_strings
print("--- Check 25: redact_custom_strings mutation ---")
if total_pass > 0:
    sec_test = "tests/test_secrets.py" if os.path.isfile("tests/test_secrets.py") else "tests/"
    sec_base = per_file.get("test_secrets.py", [0, 0, 0])[0] if "test_secrets.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "secrets.py"),
        "\n\n# VERIFIER MUTATION\nredact_custom_strings = lambda text, *_a, **_kw: (text, 0)\n",
        sec_test, sec_base)
    if nf >= 6:
        add_reward(0.04, f"redact_custom: {nf} detected (excellent)")
    elif nf >= 3:
        add_reward(0.02, f"redact_custom: {nf} detected (good)")
    elif nf >= 1:
        add_reward(0.01, f"redact_custom: {nf} detected (basic)")

# Check 26 (0.03): redact_session
print("--- Check 26: redact_session mutation ---")
if total_pass > 0:
    sec_test = "tests/test_secrets.py" if os.path.isfile("tests/test_secrets.py") else "tests/"
    sec_base = per_file.get("test_secrets.py", [0, 0, 0])[0] if "test_secrets.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "secrets.py"),
        "\n\n# VERIFIER MUTATION\nredact_session = lambda session, *_a, **_kw: (session, 0)\n",
        sec_test, sec_base)
    if nf >= 5:
        add_reward(0.03, f"redact_session: {nf} detected (excellent)")
    elif nf >= 2:
        add_reward(0.015, f"redact_session: {nf} detected (good)")

# Check 27 (0.03): _summarize_tool_input
print("--- Check 27: tool_input mutation ---")
if total_pass > 0:
    par_test = "tests/test_parser.py" if os.path.isfile("tests/test_parser.py") else "tests/"
    par_base = per_file.get("test_parser.py", [0, 0, 0])[0] if "test_parser.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "parser.py"),
        "\n\n# VERIFIER MUTATION\n_summarize_tool_input = lambda *_a, **_kw: ''\n",
        par_test, par_base)
    if nf >= 5:
        add_reward(0.03, f"tool_input: {nf} detected (excellent)")
    elif nf >= 2:
        add_reward(0.015, f"tool_input: {nf} detected (good)")

# Check 28 (0.04): _has_mixed_char_types always True
print("--- Check 28: mixed_char mutation ---")
if total_pass > 0:
    sec_test = "tests/test_secrets.py" if os.path.isfile("tests/test_secrets.py") else "tests/"
    sec_base = per_file.get("test_secrets.py", [0, 0, 0])[0] if "test_secrets.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "secrets.py"),
        "\n\n# VERIFIER MUTATION\n_has_mixed_char_types = lambda *_a, **_kw: True\n",
        sec_test, sec_base)
    if nf >= 4:
        add_reward(0.04, f"mixed_char: {nf} detected (excellent)")
    elif nf >= 2:
        add_reward(0.02, f"mixed_char: {nf} detected (good)")
    elif nf >= 1:
        add_reward(0.01, f"mixed_char: {nf} detected (basic)")

# Check 29 (0.04): _extract_user_content returns empty
print("--- Check 29: extract_user mutation ---")
if total_pass > 0:
    par_test = "tests/test_parser.py" if os.path.isfile("tests/test_parser.py") else "tests/"
    par_base = per_file.get("test_parser.py", [0, 0, 0])[0] if "test_parser.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "parser.py"),
        "\n\n# VERIFIER MUTATION\n_extract_user_content = lambda *_a, **_kw: ''\n",
        par_test, par_base)
    if nf >= 6:
        add_reward(0.04, f"extract_user: {nf} detected (excellent)")
    elif nf >= 3:
        add_reward(0.02, f"extract_user: {nf} detected (good)")
    elif nf >= 1:
        add_reward(0.01, f"extract_user: {nf} detected (basic)")

# Check 30 (0.04): _extract_assistant_content returns empty — NEW
print("--- Check 30: extract_assistant mutation (NEW) ---")
if total_pass > 0:
    par_test = "tests/test_parser.py" if os.path.isfile("tests/test_parser.py") else "tests/"
    par_base = per_file.get("test_parser.py", [0, 0, 0])[0] if "test_parser.py" in per_file else total_pass
    nf = run_mutation(
        os.path.join(WORKSPACE, "dataclaw", "parser.py"),
        "\n\n# VERIFIER MUTATION\n_extract_assistant_content = lambda *_a, **_kw: ('', '')\n",
        par_test, par_base)
    if nf >= 6:
        add_reward(0.04, f"extract_assistant: {nf} detected (excellent)")
    elif nf >= 3:
        add_reward(0.02, f"extract_assistant: {nf} detected (good)")
    elif nf >= 1:
        add_reward(0.01, f"extract_assistant: {nf} detected (basic)")

# ====================================================================
# P2P (0.05) + F2P (0.05)
# ====================================================================

print("\n--- P2P: dataclaw importable ---")
p2p_pass = True
try:
    import importlib
    for mod_name in ["dataclaw.secrets", "dataclaw.anonymizer", "dataclaw.parser", "dataclaw.config"]:
        try:
            importlib.import_module(mod_name)
        except ImportError as e:
            p2p_pass = False
            break
    if p2p_pass:
        from dataclaw.secrets import scan_text
        from dataclaw.anonymizer import _hash_username
        if not callable(scan_text) or not callable(_hash_username):
            p2p_pass = False
except:
    p2p_pass = False
if p2p_pass:
    add_reward(0.02, "P2P: dataclaw importable")

print("\n--- F2P: test suite passes ---")
try:
    p2p_run = subprocess.run(
        [sys.executable, "-m", "pytest", "tests/", "-x", "--timeout=60", "-q"],
        capture_output=True, text=True, timeout=120, cwd=WORKSPACE)
    print(p2p_run.stdout[-500:] if len(p2p_run.stdout) > 500 else p2p_run.stdout)
    if p2p_run.returncode == 0:
        add_reward(0.05, "F2P: all tests pass")
    else:
        total_run_f2p = total_pass + total_fail + total_err
        if total_run_f2p > 0:
            pass_rate = total_pass / total_run_f2p
            if pass_rate >= 0.97:
                add_reward(0.03, f"F2P: near-clean ({pass_rate:.1%})")
            elif pass_rate >= 0.90:
                add_reward(0.01, f"F2P: mostly passing ({pass_rate:.1%})")
except:
    print("  FAIL")

print()
print("=" * 50)
print(f"Final reward: {REWARD:.2f}")
print("=" * 50)

with open("/logs/verifier/reward.txt", "w") as f:
    f.write(f"{REWARD}")
PYEOF
