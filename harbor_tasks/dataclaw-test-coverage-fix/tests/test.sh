#!/bin/bash
set +e

WORKSPACE="/workspace/dataclaw"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"
REWARD=0.0

cd "$WORKSPACE" 2>/dev/null || { echo "0.0" > "$LOG_DIR/reward.txt"; exit 0; }

python3 -m pip install --quiet pytest pytest-timeout >/dev/null 2>&1

# ============================================================================
# CORE PRINCIPLE: All reward must come from behavioral evidence that the agent
# wrote tests that actually exercise dataclaw modules. A no-op patch (no
# tests/ directory, or empty test files) MUST score 0.0.
#
# Strategy: Run the agent's test suite under multiple mutations of dataclaw
# source code. A genuine test suite catches mutations (tests fail on mutant);
# a no-op or trivial test suite catches nothing.
# ============================================================================

python3 << 'PYEOF' > "$LOG_DIR/run.log" 2>&1
import os, re, subprocess, sys, json, shutil
from pathlib import Path

WORKSPACE = "/workspace/dataclaw"
DC = Path(WORKSPACE) / "dataclaw"
TESTS = Path(WORKSPACE) / "tests"
os.chdir(WORKSPACE)

REWARD = 0.0
def add(amount, reason):
    global REWARD
    REWARD += amount
    print(f"  +{amount:.4f} -> {REWARD:.4f}  ({reason})")

def write_reward():
    Path("/logs/verifier/reward.txt").write_text(f"{REWARD:.4f}\n")

# -------------------------------------------------------------------------
# Hard prerequisite: tests/ directory must exist with at least one test_*.py
# Without this, no-op state → 0.0
# -------------------------------------------------------------------------
if not TESTS.is_dir():
    print("No tests/ directory — no-op state, reward = 0.0")
    write_reward()
    sys.exit(0)

test_files = sorted(p for p in TESTS.glob("test_*.py"))
if not test_files:
    print("No test_*.py files — no-op state, reward = 0.0")
    write_reward()
    sys.exit(0)

print(f"Found {len(test_files)} test files: {[p.name for p in test_files]}")

def run_pytest(args, timeout=180, cwd=WORKSPACE):
    try:
        r = subprocess.run(
            [sys.executable, "-m", "pytest"] + args + ["--tb=no", "--timeout=20", "-q", "--no-header"],
            capture_output=True, text=True, timeout=timeout, cwd=cwd)
        return r.stdout + r.stderr, r.returncode
    except subprocess.TimeoutExpired:
        return "TIMEOUT", 1
    except Exception as e:
        return f"ERROR: {e}", 1

def grab(pat, s):
    m = re.search(pat, s)
    return int(m.group(1)) if m else 0

# -------------------------------------------------------------------------
# Baseline: run the agent's tests on UNMODIFIED dataclaw source.
# This is a P2P gate. If tests don't pass on clean source, the suite is
# broken and we can't measure mutation detection meaningfully → reward = 0.
# -------------------------------------------------------------------------
print("\n=== BASELINE (unmodified source) ===")
out, rc = run_pytest(["tests/"], timeout=240)
print(out[-3000:])
n_pass = grab(r'(\d+) passed', out)
n_fail = grab(r'(\d+) failed', out)
n_err  = grab(r'(\d+) error', out)
print(f"Baseline: pass={n_pass} fail={n_fail} err={n_err}")

if n_pass < 5:
    print("Baseline pass count < 5: trivial or broken suite. Reward = 0.0")
    write_reward()
    sys.exit(0)

# Need most tests passing on clean source (gate, not reward)
total = n_pass + n_fail + n_err
if total == 0 or (n_pass / total) < 0.80:
    print("Baseline pass ratio < 80%: suite is unreliable. Reward = 0.0")
    write_reward()
    sys.exit(0)

# -------------------------------------------------------------------------
# MUTATION TESTING — the entire reward signal.
# For each mutation: inject a behavioral bug into dataclaw source, run the
# agent's test suite, and check if any test fails. Real tests catch real
# bugs. A no-op (no tests at all) was already short-circuited above; an
# empty-but-present tests/ dir would have 0 baseline passes and exit.
# -------------------------------------------------------------------------

def backup(p):
    return p.read_text()

def restore(p, s):
    p.write_text(s)

def run_suite_quick(timeout=120):
    """Run full agent suite, return (passed, failed_or_errored)."""
    try:
        r = subprocess.run(
            [sys.executable, "-m", "pytest", "tests/", "-q", "--tb=no",
             "--timeout=15", "--no-header", "-p", "no:cacheprovider"],
            capture_output=True, text=True, timeout=timeout, cwd=WORKSPACE)
        o = r.stdout + r.stderr
        p = grab(r'(\d+) passed', o)
        f = grab(r'(\d+) failed', o) + grab(r'(\d+) error', o)
        return p, f, o
    except subprocess.TimeoutExpired:
        return 0, 999, "TIMEOUT"
    except Exception as e:
        return 0, 999, f"ERR {e}"

# Each mutation = (file, old_substring, new_substring, description)
# These are real behavioral changes to dataclaw — a thorough test suite
# should catch each one. Patterns are chosen to be present in the original
# unmodified source (verified by checking before mutating).
MUTATIONS = [
    # secrets.py — REDACTED constant change: any redact_text test should catch
    ("secrets.py",
     'REDACTED = "[REDACTED]"',
     'REDACTED = "[NOT_REDACTED]"',
     "REDACTED constant value"),
    # secrets.py — break shannon entropy (return 0 always)
    ("secrets.py",
     'def _shannon_entropy(s: str) -> float:',
     'def _shannon_entropy(s: str) -> float:\n    return 0.0\n    # original below',
     "_shannon_entropy returns 0"),
    # anonymizer.py — change hash length from 8 to 4
    ("anonymizer.py",
     'hashlib.sha256(username.encode()).hexdigest()[:8]',
     'hashlib.sha256(username.encode()).hexdigest()[:4]',
     "username hash length 8->4"),
    # anonymizer.py — change user_ prefix
    ("anonymizer.py",
     'return "user_" + hashlib.sha256',
     'return "USR_" + hashlib.sha256',
     "username hash prefix"),
    # config.py — DEFAULT_CONFIG redact_strings default
    ("config.py",
     '"redact_strings": []',
     '"redact_strings": ["BUG"]',
     "DEFAULT_CONFIG redact_strings default"),
    # config.py — break load_config to always return empty dict
    ("config.py",
     'def load_config()',
     'def _orig_load_config()',
     "load_config rename (breaks import)"),
]

# Filter mutations: only keep ones whose 'old' string actually appears
applicable = []
for fname, old, new, desc in MUTATIONS:
    p = DC / fname
    if not p.exists():
        continue
    src = p.read_text()
    if old in src:
        applicable.append((fname, old, new, desc))
    else:
        print(f"  skip mutation '{desc}': pattern not found in {fname}")

print(f"\n=== MUTATION TESTS ({len(applicable)} applicable) ===")

if not applicable:
    print("No applicable mutations — cannot measure. Reward = 0.0")
    write_reward()
    sys.exit(0)

caught = 0
total_muts = 0

for fname, old, new, desc in applicable:
    p = DC / fname
    orig = backup(p)
    # Apply mutation
    mutated = orig.replace(old, new, 1)
    if mutated == orig:
        continue
    p.write_text(mutated)
    # Also need to invalidate any __pycache__
    pyc_dir = DC / "__pycache__"
    if pyc_dir.exists():
        shutil.rmtree(pyc_dir, ignore_errors=True)
    try:
        np, nf, _ = run_suite_quick(timeout=120)
        # Catch = at least one test failed/errored that didn't fail on baseline
        # (we approximate "didn't fail on baseline" with: failures are now > baseline failures)
        catch = nf > (n_fail + n_err)
        total_muts += 1
        if catch:
            caught += 1
            print(f"  CAUGHT  [{desc}]  (passed={np} failed/err={nf})")
        else:
            print(f"  MISSED  [{desc}]  (passed={np} failed/err={nf})")
    finally:
        restore(p, orig)
        if pyc_dir.exists():
            shutil.rmtree(pyc_dir, ignore_errors=True)

print(f"\nMutations caught: {caught}/{total_muts}")

# -------------------------------------------------------------------------
# REWARD: 100% from mutation-catch ratio.
# - No-op patch: no tests/ → exited at 0.0 already.
# - Empty tests/: exited at 0.0 already (baseline pass count check).
# - Trivial tests (assert True): would pass baseline but catch 0 mutations
#   → ratio = 0 → reward = 0.0.
# - Real test suite: catches mutations → proportional reward.
# -------------------------------------------------------------------------
if total_muts == 0:
    print("No mutations were applied. Reward = 0.0")
    write_reward()
    sys.exit(0)

ratio = caught / total_muts

# Full weight 1.0 distributed by mutation-catch ratio.
# Require catching at least 2 mutations for any reward (filters out lucky catches).
if caught < 2:
    print(f"Only {caught} mutation(s) caught — insufficient signal. Reward = 0.0")
    write_reward()
    sys.exit(0)

add(1.0 * ratio, f"mutation catch ratio {caught}/{total_muts}")

print(f"\nFINAL REWARD: {REWARD:.4f}")
write_reward()
PYEOF

# Fallback in case python script crashed without writing
if [ ! -f "$LOG_DIR/reward.txt" ]; then
    echo "0.0" > "$LOG_DIR/reward.txt"
fi

REWARD=$(cat "$LOG_DIR/reward.txt")
echo "Reward: $REWARD"
echo "$REWARD" > "$LOG_DIR/reward.txt"