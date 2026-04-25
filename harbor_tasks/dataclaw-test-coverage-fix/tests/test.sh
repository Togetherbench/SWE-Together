#!/bin/bash
set +e

WORKSPACE="/workspace/dataclaw"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

cd "$WORKSPACE" 2>/dev/null || { echo "0.0" > "$LOG_DIR/reward.txt"; exit 0; }

# Make sure pytest + plugins are available
python3 -m pip install --quiet pytest pytest-timeout pytest-cov >/dev/null 2>&1

python3 << 'PYEOF' > "$LOG_DIR/run.log" 2>&1
import ast, os, re, subprocess, sys, json, shutil, tempfile, random, string
from pathlib import Path

WORKSPACE = "/workspace/dataclaw"
os.chdir(WORKSPACE)

REWARD = 0.0
def add(amount, reason):
    global REWARD
    REWARD += amount
    print(f"  +{amount:.4f} -> {REWARD:.4f}  ({reason})")

def sub(amount, reason):
    global REWARD
    REWARD -= amount
    print(f"  -{amount:.4f} -> {REWARD:.4f}  ({reason})")

# ---------------------------------------------------------------------------
# 1. Existence checks (small)
# ---------------------------------------------------------------------------
print("=== STRUCTURE ===")
test_dir = Path(WORKSPACE) / "tests"
if not test_dir.is_dir():
    print("No tests/ directory")
    print(f"FINAL REWARD: {REWARD}")
    Path("/logs/verifier/reward.txt").write_text(f"{REWARD:.4f}\n")
    sys.exit(0)

test_files = sorted(p.name for p in test_dir.glob("test_*.py"))
print(f"Test files: {test_files}")

# Expected modules
EXPECTED_MODS = {"secrets", "anonymizer", "parser", "cli", "config"}
covered_mods = set()
for tf in test_files:
    for m in EXPECTED_MODS:
        if m in tf:
            covered_mods.add(m)

# Up to 0.05 for having a test file per module
mod_cov_score = 0.05 * (len(covered_mods) / len(EXPECTED_MODS))
add(mod_cov_score, f"module file coverage: {len(covered_mods)}/{len(EXPECTED_MODS)}")

# Conftest exists (small bonus)
if (test_dir / "conftest.py").exists():
    add(0.02, "conftest.py present")

# ---------------------------------------------------------------------------
# 2. Run the suite — must pass cleanly (this is the gate)
# ---------------------------------------------------------------------------
print("\n=== TEST EXECUTION ===")
def run_pytest(args, timeout=180):
    try:
        r = subprocess.run(
            [sys.executable, "-m", "pytest"] + args + ["--tb=no", "--timeout=30", "-q"],
            capture_output=True, text=True, timeout=timeout, cwd=WORKSPACE)
        return r.stdout + r.stderr, r.returncode
    except subprocess.TimeoutExpired:
        return "TIMEOUT", 1
    except Exception as e:
        return f"ERROR: {e}", 1

out, rc = run_pytest(["tests/"], timeout=240)
print(out[-3000:])

def _grab(pat, s):
    m = re.search(pat, s)
    return int(m.group(1)) if m else 0
n_pass = _grab(r'(\d+) passed', out)
n_fail = _grab(r'(\d+) failed', out)
n_err  = _grab(r'(\d+) error', out)
print(f"Pass={n_pass}  Fail={n_fail}  Err={n_err}")

# Score for tests passing
if n_pass + n_fail + n_err == 0:
    add(0.0, "no tests collected")
else:
    pass_ratio = n_pass / (n_pass + n_fail + n_err)
    # Up to 0.10 for tests passing cleanly
    add(0.10 * pass_ratio, f"pass ratio = {pass_ratio:.2f}")

# Need at least some absolute volume of tests for credit
if n_pass >= 30:
    add(0.04, ">=30 tests pass")
elif n_pass >= 15:
    add(0.02, ">=15 tests pass")

# ---------------------------------------------------------------------------
# 3. Coverage measurement (real signal of how thorough the suite is)
# ---------------------------------------------------------------------------
print("\n=== COVERAGE ===")
try:
    cov = subprocess.run(
        [sys.executable, "-m", "pytest", "tests/", "--cov=dataclaw",
         "--cov-report=term", "--cov-report=json:/tmp/cov.json",
         "-q", "--tb=no", "--timeout=30"],
        capture_output=True, text=True, timeout=240, cwd=WORKSPACE)
    cov_out = cov.stdout + cov.stderr
    print(cov_out[-2500:])
except Exception as e:
    cov_out = ""
    print(f"coverage failed: {e}")

per_mod_cov = {}
total_cov = 0
try:
    if Path("/tmp/cov.json").exists():
        data = json.loads(Path("/tmp/cov.json").read_text())
        total_cov = data.get("totals", {}).get("percent_covered", 0)
        for fname, info in (data.get("files") or {}).items():
            base = os.path.basename(fname).replace(".py", "")
            if base in EXPECTED_MODS:
                per_mod_cov[base] = info.get("summary", {}).get("percent_covered", 0)
except Exception as e:
    print(f"cov json parse error: {e}")

if total_cov == 0:
    # fallback to text parse
    m = re.search(r'TOTAL\s+\d+\s+\d+\s+(\d+)%', cov_out)
    if m:
        total_cov = int(m.group(1))
    for line in cov_out.splitlines():
        mm = re.search(r'dataclaw/(\w+)\.py\s+\d+\s+\d+\s+(\d+)%', line)
        if mm:
            per_mod_cov[mm.group(1)] = int(mm.group(2))

print(f"Total coverage: {total_cov:.1f}%")
print(f"Per module: {per_mod_cov}")

# Up to 0.20 weight for total coverage (linear above 30%, capped at 85%)
def cov_score(pct, max_w):
    if pct <= 30: return 0.0
    if pct >= 85: return max_w
    return max_w * (pct - 30) / (85 - 30)

add(cov_score(total_cov, 0.20), f"overall coverage {total_cov:.1f}%")

# Per-module coverage requirement: each mod should have meaningful coverage
# Up to 0.10 distributed across the 5 modules
per_mod_weight = 0.10 / len(EXPECTED_MODS)
for mod in EXPECTED_MODS:
    pc = per_mod_cov.get(mod, 0)
    add(cov_score(pc, per_mod_weight), f"{mod} coverage {pc:.0f}%")

# ---------------------------------------------------------------------------
# 4. Mutation testing — strongest behavioral signal
#    Inject bugs into source modules; tests should catch them.
# ---------------------------------------------------------------------------
print("\n=== MUTATION TESTS ===")

DC = Path(WORKSPACE) / "dataclaw"

def backup(path):
    return path.read_text()

def restore(path, content):
    path.write_text(content)

def run_tests_quick(test_path, timeout=90):
    try:
        r = subprocess.run(
            [sys.executable, "-m", "pytest", test_path, "-q", "--tb=no",
             "--timeout=15", "-x", "--no-header"],
            capture_output=True, text=True, timeout=timeout, cwd=WORKSPACE)
        out2 = r.stdout + r.stderr
        passed = _grab(r'(\d+) passed', out2)
        failed = _grab(r'(\d+) failed', out2) + _grab(r'(\d+) error', out2)
        return passed, failed, out2
    except subprocess.TimeoutExpired:
        return 0, 1, "timeout"
    except Exception:
        return 0, 1, "exception"

mutations = [
    # (file, old_substring, new_substring, target_test, description)
    ("secrets.py",
     'return "[REDACTED]"',
     'return "[NOT_REDACTED]"',
     "tests/test_secrets.py",
     "REDACTED constant"),
    ("anonymizer.py",
     'hashlib.sha256(username.encode()).hexdigest()[:8]',
     'hashlib.sha256(username.encode()).hexdigest()[:4]',
     "tests/test_anonymizer.py",
     "hash length"),
    ("config.py",
     '"redact_strings": []',
     '"redact_strings": ["BUG"]',
     "tests/test_config.py",
     "DEFAULT_CONFIG redact_strings"),
]

# Also do generic numeric mutations: flip True/False return, change comparison
def make_numeric_mutation(src):
    # Try to invert one boolean return
    candidates = [
        ('return True', 'return False'),
        ('return False', 'return True'),
        ('!= 0', '== 0'),
    ]
    for old, new in candidates:
        if old in src:
            return src.replace(old, new, 1), f"flip {old}->{new}"
    return None, None

mutations_caught = 0
mutations_total = 0

for fname, old, new, test_target, desc in mutations:
    target = DC / fname
    if not target.exists():
        continue
    src = backup(target)
    if old not in src:
        print(f"  skip {desc}: pattern not found")
        continue
    mutated = src.replace(old, new, 1)
    target.write_text(mutated)
    try:
        # Use the targeted test file if present, else full suite
        tpath = test_target if (Path(WORKSPACE) / test_target).exists() else "tests/"
        p, f, _ = run_tests_quick(tpath, timeout=60)
        mutations_total += 1
        if f > 0:
            mutations_caught += 1
            print(f"  CAUGHT mutation: {desc} ({f} failures)")
        else:
            print(f"  MISSED mutation: {desc} (all {p} passed)")
    finally:
        restore(target, src)

# Generic mutation per module
GENERIC_TARGETS = [
    ("secrets.py", "tests/test_secrets.py"),
    ("anonymizer.py", "tests/test_anonymizer.py"),
    ("parser.py", "tests/test_parser.py"),
    ("cli.py", "tests/test_cli.py"),
]

for fname, test_target in GENERIC_TARGETS:
    target = DC / fname
    if not target.exists():
        continue
    src = backup(target)
    mutated, mdesc = make_numeric_mutation(src)
    if mutated is None:
        continue
    target.write_text(mutated)
    try:
        tpath = test_target if (Path(WORKSPACE) / test_target).exists() else "tests/"
        p, f, _ = run_tests_quick(tpath, timeout=60)
        mutations_total += 1
        if f > 0:
            mutations_caught += 1
            print(f"  CAUGHT generic ({fname}): {mdesc}")
        else:
            print(f"  MISSED generic ({fname}): {mdesc}")
    finally:
        restore(target, src)

# Specific behavioral mutation: make _shannon_entropy always return 0
sec = DC / "secrets.py"
if sec.exists():
    src = backup(sec)
    # Replace shannon_entropy body
    pat = re.search(r'def _shannon_entropy\([^)]*\)[^:]*:\s*\n', src)
    if pat:
        # Indent-aware injection
        lines = src.split('\n')
        new_lines = []
        i = 0
        injected = False
        while i < len(lines):
            line = lines[i]
            new_lines.append(line)
            if not injected and re.match(r'^def _shannon_entropy', line):
                # Insert immediate-return on next line
                new_lines.append('    return 999.0  # mutation')
                injected = True
                # Skip original body until next def at column 0
                i += 1
                while i < len(lines) and (lines[i].startswith(' ') or lines[i].startswith('\t') or not lines[i].strip()):
                    i += 1
                continue
            i += 1
        if injected:
            sec.write_text('\n'.join(new_lines))
            try:
                p, f, _ = run_tests_quick("tests/test_secrets.py", timeout=60)
                mutations_total += 1
                if f > 0:
                    mutations_caught += 1
                    print("  CAUGHT shannon_entropy stub")
                else:
                    print("  MISSED shannon_entropy stub")
            finally:
                restore(sec, src)

# Specific mutation: anonymize_text returns input unchanged
anon_p = DC / "anonymizer.py"
if anon_p.exists():
    src = backup(anon_p)
    lines = src.split('\n')
    new_lines = []
    injected = False
    i = 0
    while i < len(lines):
        line = lines[i]
        new_lines.append(line)
        if not injected and re.match(r'^def anonymize_text\b', line):
            new_lines.append('    return text  # mutation')
            injected = True
            i += 1
            while i < len(lines) and (lines[i].startswith(' ') or lines[i].startswith('\t') or not lines[i].strip()):
                i += 1
            continue
        i += 1
    if injected:
        anon_p.write_text('\n'.join(new_lines))
        try:
            p, f, _ = run_tests_quick("tests/test_anonymizer.py", timeout=60)
            mutations_total += 1
            if f > 0:
                mutations_caught += 1
                print("  CAUGHT anonymize_text stub")
            else:
                print("  MISSED anonymize_text stub")
        finally:
            restore(anon_p, src)

# Mutation: load_config always returns {}
cfg_p = DC / "config.py"
if cfg_p.exists():
    src = backup(cfg_p)
    lines = src.split('\n')
    new_lines = []
    injected = False
    i = 0
    while i < len(lines):
        line = lines[i]
        new_lines.append(line)
        if not injected and re.match(r'^def load_config\b', line):
            new_lines.append('    return {}  # mutation')
            injected = True
            i += 1
            while i < len(lines) and (lines[i].startswith(' ') or lines[i].startswith('\t') or not lines[i].strip()):
                i += 1
            continue
        i += 1
    if injected:
        cfg_p.write_text('\n'.join(new_lines))
        try:
            p, f, _ = run_tests_quick("tests/test_config.py", timeout=60)
            mutations_total += 1
            if f > 0:
                mutations_caught += 1
                print("  CAUGHT load_config stub")
            else:
                print("  MISSED load_config stub")
        finally:
            restore(cfg_p, src)

# Mutation: scan_text returns []
if sec.exists():
    src = backup(sec)
    lines = src.split('\n')
    new_lines = []
    injected = False
    i = 0
    while i < len(lines):
        line = lines[i]
        new_lines.append(line)
        if not injected and re.match(r'^def scan_text\b', line):
            new_lines.append('    return []  # mutation')
            injected = True
            i += 1
            while i < len(lines) and (lines[i].startswith(' ') or lines[i].startswith('\t') or not lines[i].strip()):
                i += 1
            continue
        i += 1
    if injected:
        sec.write_text('\n'.join(new_lines))
        try:
            p, f, _ = run_tests_quick("tests/test_secrets.py", timeout=60)
            mutations_total += 1
            if f > 0:
                mutations_caught += 1
                print("  CAUGHT scan_text empty stub")
            else:
                print("  MISSED scan_text empty stub")
        finally:
            restore(sec, src)

# Mutation: redact_text returns input unchanged
if sec.exists():
    src = backup(sec)
    lines = src.split('\n')
    new_lines = []
    injected = False
    i = 0
    while i < len(lines):
        line = lines[i]
        new_lines.append(line)
        if not injected and re.match(r'^def redact_text\b', line):
            new_lines.append('    return text, 0  # mutation')
            injected = True
            i += 1
            while i < len(lines) and (lines[i].startswith(' ') or lines[i].startswith('\t') or not lines[i].strip()):
                i += 1
            continue
        i += 1
    if injected:
        sec.write_text('\n'.join(new_lines))
        try:
            p, f, _ = run_tests_quick("tests/test_secrets.py", timeout=60)
            mutations_total += 1
            if f > 0:
                mutations_caught += 1
                print("  CAUGHT redact_text passthrough")
            else:
                print("  MISSED redact_text passthrough")
        finally:
            restore(sec, src)

# Mutation: _build_project_name returns "x"
parser_p = DC / "parser.py"
if parser_p.exists():
    src = backup(parser_p)
    lines = src.split('\n')
    new_lines = []
    injected = False
    i = 0
    while i < len(lines):
        line = lines[i]
        new_lines.append(line)
        if not injected and re.match(r'^def _build_project_name\b', line):
            new_lines.append('    return "x"  # mutation')
            injected = True
            i += 1
            while i < len(lines) and (lines[i].startswith(' ') or lines[i].startswith('\t') or not lines[i].strip()):
                i += 1
            continue
        i += 1
    if injected:
        parser_p.write_text('\n'.join(new_lines))
        try:
            p, f, _ = run_tests_quick("tests/test_parser.py", timeout=60)
            mutations_total += 1
            if f > 0:
                mutations_caught += 1
                print("  CAUGHT _build_project_name stub")
            else:
                print("  MISSED _build_project_name stub")
        finally:
            restore(parser_p, src)

# Mutation: _format_size always returns "0 B"
cli_p = DC / "cli.py"
if cli_p.exists():
    src = backup(cli_p)
    lines = src.split('\n')
    new_lines = []
    injected = False
    i = 0
    while i < len(lines):
        line = lines[i]
        new_lines.append(line)
        if not injected and re.match(r'^def _format_size\b', line):
            new_lines.append('    return "0 B"  # mutation')
            injected = True
            i += 1
            while i < len(lines) and (lines[i].startswith(' ') or lines[i].startswith('\t') or not lines[i].strip()):
                i += 1
            continue
        i += 1
    if injected:
        cli_p.write_text('\n'.join(new_lines))
        try:
            tpath = "tests/test_cli.py" if (Path(WORKSPACE) / "tests/test_cli.py").exists() else "tests/"
            p, f, _ = run_tests_quick(tpath, timeout=60)
            mutations_total += 1
            if f > 0:
                mutations_caught += 1
                print("  CAUGHT _format_size stub")
            else:
                print("  MISSED _format_size stub")
        finally:
            restore(cli_p, src)

print(f"\nMutations caught: {mutations_caught}/{mutations_total}")
# Up to 0.40 weight for mutation catching — this is the dominant signal
if mutations_total > 0:
    catch_ratio = mutations_caught / mutations_total
    add(0.40 * catch_ratio, f"mutations caught {mutations_caught}/{mutations_total}")

# ---------------------------------------------------------------------------
# 5. Quality of asserts (small)
# ---------------------------------------------------------------------------
print("\n=== ASSERT QUALITY ===")
total_asserts = 0
trivial_asserts = 0
raises_uses = 0
parametrize_uses = 0

for tf in test_files:
    p = test_dir / tf
    try:
        tree = ast.parse(p.read_text())
    except:
        continue
    for node in ast.walk(tree):
        if isinstance(node, ast.Assert):
            total_asserts += 1
            if isinstance(node.test, ast.Constant):
                trivial_asserts += 1
        if isinstance(node, ast.Call):
            fn = node.func
            if isinstance(fn, ast.Attribute) and fn.attr == "raises":
                raises_uses += 1
            if isinstance(fn, ast.Attribute) and fn.attr == "parametrize":
                parametrize_uses += 1

print(f"asserts={total_asserts} trivial={trivial_asserts} raises={raises_uses} parametrize={parametrize_uses}")

# Up to 0.05 for assertion volume
if total_asserts >= 100:
    add(0.03, "assert volume >=100")
elif total_asserts >= 50:
    add(0.02, "assert volume >=50")
elif total_asserts >= 20:
    add(0.01, "assert volume >=20")

if raises_uses >= 3:
    add(0.01, "uses pytest.raises")
if parametrize_uses >= 2:
    add(0.01, "uses parametrize")

# Penalty for trivial-only asserts
if total_asserts > 0 and (trivial_asserts / total_asserts) > 0.3:
    sub(0.05, "too many trivial asserts")

# ---------------------------------------------------------------------------
# Final
# ---------------------------------------------------------------------------
REWARD = max(0.0, min(1.0, REWARD))
print(f"\nFINAL REWARD: {REWARD:.4f}")
Path("/logs/verifier/reward.txt").write_text(f"{REWARD:.4f}\n")
PYEOF

cat "$LOG_DIR/run.log"

if [ ! -f "$LOG_DIR/reward.txt" ]; then
    echo "0.0000" > "$LOG_DIR/reward.txt"
fi

REWARD=$(cat "$LOG_DIR/reward.txt")
echo "REWARD=$REWARD"
echo "$REWARD" > /logs/verifier/reward.txt