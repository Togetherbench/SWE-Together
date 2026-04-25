#!/bin/bash
set +e

export PATH=/usr/local/bin:/usr/bin:/bin:$PATH
WORKSPACE="/workspace/dataclaw"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"
REWARD=0.0

cd "$WORKSPACE" 2>/dev/null || { echo "0.0" > "$LOG_DIR/reward.txt"; exit 0; }

python3 -m pip install --quiet pytest pytest-timeout >/dev/null 2>&1

python3 << 'PYEOF' > "$LOG_DIR/run.log" 2>&1
import os, re, subprocess, sys, json, shutil, tempfile
from pathlib import Path

WORKSPACE = Path("/workspace/dataclaw")
DC = WORKSPACE / "dataclaw"
TESTS = WORKSPACE / "tests"
os.chdir(WORKSPACE)

REWARD = 0.0
def add(amount, reason):
    global REWARD
    REWARD += amount
    print(f"  +{amount:.4f} -> {REWARD:.4f}  ({reason})")

def write_reward():
    Path("/logs/verifier/reward.txt").write_text(f"{REWARD:.4f}\n")

# ----------------------------------------------------------------------
# R1: no-op gate. Tests dir absent or empty -> 0.0
# ----------------------------------------------------------------------
if not TESTS.is_dir():
    print("No tests/ — no-op, reward=0.0")
    write_reward(); sys.exit(0)

test_files = sorted(p for p in TESTS.glob("test_*.py"))
if not test_files:
    print("No test_*.py — no-op, reward=0.0")
    write_reward(); sys.exit(0)

print(f"Found test files: {[p.name for p in test_files]}")

def run_pytest(args, timeout=240, env_extra=None):
    env = os.environ.copy()
    if env_extra: env.update(env_extra)
    try:
        r = subprocess.run(
            [sys.executable, "-m", "pytest"] + args
              + ["--tb=no", "--timeout=20", "-q", "--no-header",
                 "-p", "no:cacheprovider"],
            capture_output=True, text=True, timeout=timeout,
            cwd=str(WORKSPACE), env=env)
        return r.stdout + r.stderr, r.returncode
    except subprocess.TimeoutExpired:
        return "TIMEOUT", 1
    except Exception as e:
        return f"ERROR: {e}", 1

def grab(pat, s):
    m = re.search(pat, s)
    return int(m.group(1)) if m else 0

def parse_counts(out):
    p = grab(r'(\d+) passed', out)
    f = grab(r'(\d+) failed', out)
    e = grab(r'(\d+) error', out)
    return p, f, e

# ----------------------------------------------------------------------
# Baseline run (P2P-style gate): tests must mostly pass on clean source.
# ----------------------------------------------------------------------
print("\n=== BASELINE ===")
out, rc = run_pytest(["tests/"], timeout=300)
print(out[-3500:])
n_pass, n_fail, n_err = parse_counts(out)
total = n_pass + n_fail + n_err
print(f"Baseline pass={n_pass} fail={n_fail} err={n_err} total={total}")

# Need at least a real suite that runs
if total == 0:
    print("No tests collected — reward=0.0")
    write_reward(); sys.exit(0)

if n_pass < 8:
    print(f"Baseline passing < 8 ({n_pass}) — trivial suite, reward=0.0")
    write_reward(); sys.exit(0)

if (n_pass / total) < 0.80:
    print(f"Baseline pass ratio < 0.80 — unreliable, reward=0.0")
    write_reward(); sys.exit(0)

baseline_pass = n_pass
print(f"Baseline established: {baseline_pass} passing")

# ----------------------------------------------------------------------
# Compute per-module test discovery — used to weight gates fairly.
# A real suite covers MULTIPLE modules; suites that only test one slice
# get penalized.
# ----------------------------------------------------------------------
print("\n=== MODULE COVERAGE PROBE ===")
# Look at test file contents to see which dataclaw modules are imported.
modules_imported = {"secrets": False, "anonymizer": False,
                    "parser": False, "cli": False, "config": False}
for tf in test_files:
    try:
        src = tf.read_text(errors="ignore")
    except Exception:
        continue
    for mod in modules_imported:
        if (f"dataclaw.{mod}" in src) or (f"from dataclaw import {mod}" in src):
            modules_imported[mod] = True
modules_covered = sum(modules_imported.values())
print(f"Modules referenced in tests: {modules_imported} (count={modules_covered})")

# ----------------------------------------------------------------------
# MUTATION TESTING — the bulk of the reward.
# Each mutation probes a DIFFERENT slice of behavior across DIFFERENT
# modules (R2). A correctly-fixed patch (thorough tests) catches most;
# an incomplete one catches few.
# ----------------------------------------------------------------------

# Each tuple: (file, old, new, desc, weight, slice_id)
# slice_id groups mutations targeting the same module so single-module
# suites cannot ace the test by hammering one file.
MUTATIONS = [
    # ---- secrets.py ----
    ("secrets.py",
     'REDACTED = "[REDACTED]"',
     'REDACTED = "[NOT_REDACTED_XYZ]"',
     "secrets.REDACTED constant", "secrets"),
    ("secrets.py",
     'def _shannon_entropy(s: str) -> float:',
     'def _shannon_entropy(s: str) -> float:\n    return 0.0\n    # mutated below',
     "_shannon_entropy returns 0", "secrets"),
    ("secrets.py",
     'def redact_text(',
     'def _orig_redact_text(',
     "redact_text rename (breaks symbol)", "secrets"),
    # ---- anonymizer.py ----
    ("anonymizer.py",
     'hashlib.sha256(username.encode()).hexdigest()[:8]',
     'hashlib.sha256(username.encode()).hexdigest()[:4]',
     "username hash truncation", "anonymizer"),
    ("anonymizer.py",
     'return "user_" + hashlib.sha256',
     'return "USR_" + hashlib.sha256',
     "username hash prefix", "anonymizer"),
    # ---- config.py ----
    ("config.py",
     '"redact_strings": []',
     '"redact_strings": ["BUG_INJECT"]',
     "DEFAULT_CONFIG redact_strings", "config"),
    ("config.py",
     '"excluded_projects": []',
     '"excluded_projects": ["BUG_PROJ"]',
     "DEFAULT_CONFIG excluded_projects", "config"),
    # ---- parser.py: try a few likely-stable patterns ----
    # We probe before applying, so missing patterns are skipped silently.
    ("parser.py",
     'def parse_session',
     'def _orig_parse_session',
     "parse_session rename", "parser"),
    # ---- cli.py: probe a likely helper if present ----
    ("cli.py",
     'def _format_size',
     'def _orig_format_size',
     "_format_size rename", "cli"),
    ("cli.py",
     'def _mask_secret',
     'def _orig_mask_secret',
     "_mask_secret rename", "cli"),
]

# Filter to applicable mutations (pattern actually present in source).
applicable = []
for fname, old, new, desc, slc in MUTATIONS:
    p = DC / fname
    if not p.exists():
        print(f"  skip ({desc}): file {fname} missing")
        continue
    src = p.read_text()
    if old in src:
        applicable.append((fname, old, new, desc, slc))
    else:
        print(f"  skip ({desc}): pattern not found in {fname}")

print(f"\n=== MUTATIONS ({len(applicable)} applicable) ===")
if not applicable:
    print("No applicable mutations — cannot grade. reward=0.0")
    write_reward(); sys.exit(0)

# Group mutations by slice
from collections import defaultdict
slices = defaultdict(list)
for m in applicable:
    slices[m[4]].append(m)

print(f"Slices: { {k: len(v) for k, v in slices.items()} }")

def run_suite(timeout=180):
    try:
        r = subprocess.run(
            [sys.executable, "-m", "pytest", "tests/", "-q", "--tb=no",
             "--timeout=15", "--no-header", "-p", "no:cacheprovider",
             "-x" if False else "--ignore-glob=**/conftest_disabled*"],
            capture_output=True, text=True, timeout=timeout,
            cwd=str(WORKSPACE))
        o = r.stdout + r.stderr
        p, f, e = parse_counts(o)
        return p, f + e, o
    except subprocess.TimeoutExpired:
        return 0, 999, "TIMEOUT"
    except Exception as ex:
        return 0, 999, f"ERR {ex}"

# Run each mutation: detected = (failures > 0) AND (passes < baseline)
slice_results = defaultdict(list)  # slice_id -> list of (desc, caught_bool)

for fname, old, new, desc, slc in applicable:
    p = DC / fname
    orig = p.read_text()
    mutated = orig.replace(old, new, 1)
    if mutated == orig:
        print(f"  {desc}: replace was a no-op, skipping")
        continue
    p.write_text(mutated)
    # Clear pycache to ensure re-import
    for cache in DC.rglob("__pycache__"):
        try: shutil.rmtree(cache)
        except Exception: pass
    try:
        n_p, n_fe, log = run_suite(timeout=180)
        # Caught if any failure/error OR pass count dropped vs baseline
        caught = (n_fe > 0) or (n_p < baseline_pass)
        print(f"  [{slc}] {desc}: pass={n_p} fail+err={n_fe} caught={caught}")
        slice_results[slc].append((desc, caught))
    finally:
        p.write_text(orig)
        for cache in DC.rglob("__pycache__"):
            try: shutil.rmtree(cache)
            except Exception: pass

# ----------------------------------------------------------------------
# Score: weight slices independently so the agent can't max-out by
# only testing one module.
# ----------------------------------------------------------------------
# Reward budget:
#   Mutation slices  : 0.80  (split across slices that have mutations)
#   Module coverage  : 0.20  (proportional to # of dataclaw modules
#                              actually imported by tests, capped at 5)
#
# Within each slice: caught_ratio = caught / total_in_slice.
# Slice weight = 0.80 / num_slices_with_mutations.
# This means a suite that catches every mutation in 1 slice but ignores
# others lands ~0.80/N + coverage; a thorough suite lands near 1.0.

slices_active = [s for s, lst in slice_results.items() if lst]
print(f"\nActive slices: {slices_active}")
if not slices_active:
    print("No mutation results recorded — reward=0.0")
    write_reward(); sys.exit(0)

slice_weight = 0.80 / len(slices_active)
print(f"Per-slice weight: {slice_weight:.4f}")

for slc in slices_active:
    results = slice_results[slc]
    caught = sum(1 for _, c in results if c)
    ratio = caught / len(results)
    contrib = slice_weight * ratio
    add(contrib, f"slice {slc}: {caught}/{len(results)} caught")

# Module coverage component (R5: completeness)
# Reward proportional to fraction of dataclaw's 5 modules actually tested.
cov_ratio = modules_covered / 5.0
add(0.20 * cov_ratio, f"module coverage {modules_covered}/5")

# Cap and floor
if REWARD > 1.0: REWARD = 1.0
if REWARD < 0.0: REWARD = 0.0

print(f"\n=== FINAL REWARD: {REWARD:.4f} ===")
write_reward()
PYEOF

# Ensure reward file exists even if python crashed
if [ ! -f "$LOG_DIR/reward.txt" ]; then
    echo "0.0" > "$LOG_DIR/reward.txt"
fi

REWARD=$(cat "$LOG_DIR/reward.txt" 2>/dev/null || echo "0.0")
echo "$REWARD" > /logs/verifier/reward.txt