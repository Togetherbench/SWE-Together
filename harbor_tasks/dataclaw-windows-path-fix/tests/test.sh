#!/bin/bash
set +e


# Canonical PATH (E2B strips Dockerfile ENV PATH; restore tool dirs)
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")" 2>/dev/null || true
REWARD="0.00"

export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

cd /workspace/repo 2>/dev/null || cd /workspace/dataclaw 2>/dev/null || cd /workspace/$(ls /workspace 2>/dev/null | head -1) 2>/dev/null

if ! command -v python3 >/dev/null 2>&1; then
    echo "0.00" > "$REWARD_FILE"
    exit 0
fi

SCORE=$(python3 << 'PYEOF'
existing = 0.0  # injected: legacy restoration (avoid NameError)
import sys, os, re, subprocess

total = 0.0

# ── P2P diagnostics (must pass on base; failures are diagnostic) ──
try:
    import dataclaw
    from dataclaw.parser import _build_project_name
    from dataclaw.anonymizer import anonymize_path, anonymize_text
except Exception:
    print("0.00")
    sys.exit(0)

# P2P: Unix _build_project_name still works (regression guard)
try:
    cases = [
        ("-Users-alice-Documents-myproject", "myproject"),
        ("-home-bob-project", "project"),
        ("-Users-alice-Documents-my-cool-project", "my-cool-project"),
        ("standalone", "standalone"),
    ]
    for inp, exp in cases:
        if _build_project_name(inp) != exp:
            print("0.00"); sys.exit(0)
except Exception:
    print("0.00"); sys.exit(0)

# P2P: Unix anonymize_path
try:
    r = anonymize_path("/Users/alice/Documents/proj/f.py", "alice", "user_abc", "/Users/alice")
    # accept "proj/f.py" (canonical) on Unix
    if "alice" in r or "f.py" not in r or "proj" not in r:
        print("0.00"); sys.exit(0)
    r3 = anonymize_path("/Users/alice/randomdir/f.py", "alice", "user_abc", "/Users/alice")
    if "alice" in r3 or "user_abc" not in r3 or "randomdir" not in r3:
        print("0.00"); sys.exit(0)
except Exception:
    print("0.00"); sys.exit(0)

# P2P: Unix anonymize_text
try:
    r = anonymize_text("at /Users/alice/project", "alice", "user_abc")
    if "alice" in r or "user_abc" not in r:
        print("0.00"); sys.exit(0)
    r2 = anonymize_text("see -Users-alice-stuff", "alice", "user_abc")
    if "alice" in r2 or "user_abc" not in r2:
        print("0.00"); sys.exit(0)
except Exception:
    print("0.00"); sys.exit(0)


def safe_call(fn, *args, **kwargs):
    try:
        return fn(*args, **kwargs), None
    except Exception as e:
        return None, e


# ── F2P GATES (6 gates, weights sum to 1.00) ──

# ─────────────────────────────────────────────────────────────
# GATE 1 (weight 0.18): Windows _build_project_name handling
# Fixes parser.py — recognizes drive-letter-prefixed dir names.
# Accept either C-Users-... or C--Users-... encoding (both valid
# hyphen encodings of C:\Users\... or C:/Users/...).
# ─────────────────────────────────────────────────────────────
g1_pass = 0
g1_total = 0
groups = [
    (["C-Users-alice-Documents-myapp", "C--Users-alice-Documents-myapp",
      "C:-Users-alice-Documents-myapp"], "myapp"),
    (["D-Users-bob-project", "D--Users-bob-project",
      "D:-Users-bob-project"], "project"),
    (["C-Users-alice-Desktop-stuff", "C--Users-alice-Desktop-stuff",
      "C:-Users-alice-Desktop-stuff"], "stuff"),
    (["C-Users-alice-Downloads-thing", "C--Users-alice-Downloads-thing",
      "C:-Users-alice-Downloads-thing"], "thing"),
    (["C-Users-alice-Documents-my-cool-project",
      "C--Users-alice-Documents-my-cool-project",
      "C:-Users-alice-Documents-my-cool-project"], "my-cool-project"),
    (["E-Users-admin-work-repo", "E--Users-admin-work-repo",
      "E:-Users-admin-work-repo"], "work-repo"),
]
for inputs, expected in groups:
    g1_total += 1
    for inp in inputs:
        try:
            if _build_project_name(inp) == expected:
                g1_pass += 1
                break
        except Exception:
            pass
g1_frac = g1_pass / g1_total if g1_total else 0
total += 0.108 * g1_frac


# ─────────────────────────────────────────────────────────────
# GATE 2 (weight 0.18): anonymize_path — Windows backslash with
# Documents/Desktop/Downloads strips to project-relative.
# ─────────────────────────────────────────────────────────────
g2_pass = 0
g2_total = 0
cases = [
    ("C:\\Users\\alice\\Documents\\myproject\\file.py", "alice", "user_abc",
     "C:\\Users\\alice", ["myproject", "file.py"], ["alice", "Users", "C:"]),
    ("D:\\Users\\bob\\Desktop\\proj\\app.py", "bob", "user_xyz",
     "D:\\Users\\bob", ["proj", "app.py"], ["bob", "Users", "D:"]),
    ("C:\\Users\\alice\\Downloads\\stuff\\x.py", "alice", "user_abc",
     "C:\\Users\\alice", ["stuff", "x.py"], ["alice", "Users"]),
]
for path, user, h, home, must_have, must_not in cases:
    g2_total += 1
    try:
        r = anonymize_path(path, user, h, home)
        if r is None:
            continue
        ok = all(m in r for m in must_have) and all(m not in r for m in must_not)
        if ok:
            g2_pass += 1
    except Exception:
        pass
g2_frac = g2_pass / g2_total if g2_total else 0
total += 0.108 * g2_frac


# ─────────────────────────────────────────────────────────────
# GATE 3 (weight 0.16): anonymize_path — Windows backslash bare
# home dir (no Documents/Desktop) gets username hashed in.
# ─────────────────────────────────────────────────────────────
g3_pass = 0
g3_total = 0
cases = [
    ("C:\\Users\\alice\\somedir\\file.py", "alice", "user_abc",
     "C:\\Users\\alice", "somedir", "user_abc", "alice"),
    ("D:\\Users\\bob\\randomstuff\\app.py", "bob", "user_xyz",
     "D:\\Users\\bob", "randomstuff", "user_xyz", "bob"),
]
for path, user, h, home, has, has2, hasnt in cases:
    g3_total += 1
    try:
        r = anonymize_path(path, user, h, home)
        if r is None:
            continue
        if has in r and has2 in r and hasnt not in r:
            g3_pass += 1
    except Exception:
        pass
g3_frac = g3_pass / g3_total if g3_total else 0
total += 0.096 * g3_frac


# ─────────────────────────────────────────────────────────────
# GATE 4 (weight 0.18): anonymize_text — Windows backslash paths,
# both long and SHORT usernames (short usernames typically need
# the path-context regex since the bare-username fallback skips
# names <4 chars). This catches patches that only do replace().
# ─────────────────────────────────────────────────────────────
g4_pass = 0
g4_total = 0
cases = [
    # (text, username, hash, must_not_in, must_in)
    ("Open C:\\Users\\Jo\\project", "Jo", "user_abc",
     ["Jo"], ["user_abc"]),
    ("In C:\\Users\\Bo\\docs\\file", "Bo", "user_xyz",
     ["Bo"], ["user_xyz"]),
    ("Data at D:\\Users\\Al\\stuff", "Al", "user_def",
     ["Al"], ["user_def"]),
    ("at C:\\Users\\peteromalley\\project", "peteromalley", "user_abc12345",
     ["peteromalley"], ["user_abc12345"]),
    ("at E:\\Users\\developer\\work", "developer", "user_dev999",
     ["developer"], ["user_dev999"]),
]
for text, user, h, must_not, must_in in cases:
    g4_total += 1
    try:
        r = anonymize_text(text, user, h)
        if r is None:
            continue
        ok = all(m not in r for m in must_not) and all(m in r for m in must_in)
        if ok:
            g4_pass += 1
    except Exception:
        pass
g4_frac = g4_pass / g4_total if g4_total else 0
total += 0.108 * g4_frac


# ─────────────────────────────────────────────────────────────
# GATE 5 (weight 0.16): anonymize_text — Windows forward-slash
# (C:/Users/...) AND Windows forward-slash paths.
# This is a different code path than backslash and many partial
# fixes miss it.
# ─────────────────────────────────────────────────────────────
g5_pass = 0
g5_total = 0
cases = [
    ("see C:/Users/alice/project here", "alice", "user_abc",
     ["alice"], ["user_abc"]),
    ("file D:/Users/bob/work.py", "bob", "user_xyz",
     ["bob"], ["user_xyz"]),
]
for text, user, h, must_not, must_in in cases:
    g5_total += 1
    try:
        r = anonymize_text(text, user, h)
        if r is None:
            continue
        ok = all(m not in r for m in must_not) and all(m in r for m in must_in)
        if ok:
            g5_pass += 1
    except Exception:
        pass

# Also test anonymize_path on forward-slash Windows
cases2 = [
    ("C:/Users/alice/Documents/work/x.py", "alice", "user_abc", "C:\\Users\\alice",
     ["work", "x.py"], ["alice"]),
    ("D:/Users/bob/Desktop/proj/y.py", "bob", "user_xyz", "D:\\Users\\bob",
     ["proj", "y.py"], ["bob"]),
]
for path, user, h, home, must_have, must_not in cases2:
    g5_total += 1
    try:
        r = anonymize_path(path, user, h, home)
        if r is None:
            continue
        ok = all(m in r for m in must_have) and all(m not in r for m in must_not)
        if ok:
            g5_pass += 1
    except Exception:
        pass

g5_frac = g5_pass / g5_total if g5_total else 0
total += 0.096 * g5_frac


# ─────────────────────────────────────────────────────────────
# GATE 6 (weight 0.14): Project test suite — run pytest if avail.
# Required tests must include the existing P2P ones; we also
# look for any new windows-related tests that pass. We grade by
# pass-ratio in a curated subset of test files.
# ─────────────────────────────────────────────────────────────
g6_frac = 0.0
try:
    test_files = []
    for tf in ("tests/test_anonymizer.py", "tests/test_parser.py"):
        if os.path.exists(tf):
            test_files.append(tf)
    if test_files:
        proc = subprocess.run(
            [sys.executable, "-m", "pytest", "-q", "--tb=no", "--no-header"] + test_files,
            capture_output=True, text=True, timeout=120,
        )
        out = (proc.stdout or "") + "\n" + (proc.stderr or "")
        # Parse "N passed" and "N failed"
        m_pass = re.search(r"(\d+)\s+passed", out)
        m_fail = re.search(r"(\d+)\s+failed", out)
        m_err  = re.search(r"(\d+)\s+error", out)
        passed = int(m_pass.group(1)) if m_pass else 0
        failed = int(m_fail.group(1)) if m_fail else 0
        errored = int(m_err.group(1)) if m_err else 0
        denom = passed + failed + errored
        if denom > 0:
            g6_frac = passed / denom
        else:
            # No tests collected => neutral 0
            g6_frac = 0.0
    else:
        g6_frac = 0.0
except Exception:
    g6_frac = 0.0
total += 0.084 * g6_frac


# Clamp
if total < 0:
    total = 0.0
if total > 1.0:
    total = 1.0

print(f"{total:.2f}")
PYEOF
)

if [ -z "$SCORE" ]; then
    REWARD="0.00"
else
    REWARD="$SCORE"
fi

echo "$REWARD" > /logs/verifier/reward.txt

# ---- inner-claude upstream gates ----
pip install pytest -q 2>/dev/null || true

# F2P gate 1: anonymize_path Windows backslash paths
python3 -c "
import json, sys
sys.path.insert(0, '.')
passed = False
detail = 'unknown'
try:
    from dataclaw.anonymizer import anonymize_path
    r = anonymize_path('C:\\\\Users\\\\alice\\\\Documents\\\\myproject\\\\file.py', 'alice', 'user_abc12345', 'C:\\\\Users\\\\alice')
    passed = ('alice' not in r and 'myproject' in r)
    detail = repr(r)
except Exception as e:
    detail = str(e)
with open('/logs/verifier/gates.json', 'a') as f:
    json.dump({'id': 'f2p_upstream_anonymize_path_win', 'passed': passed, 'detail': detail}, f)
    f.write('\n')
" 2>/dev/null || true

# F2P gate 2: _build_project_name Windows drive prefix
python3 -c "
import json, sys
sys.path.insert(0, '.')
passed = False
detail = 'unknown'
try:
    from dataclaw.parser import _build_project_name
    r = _build_project_name('-C:-Users-alice-Documents-myproject')
    passed = (r == 'myproject')
    detail = repr(r)
except Exception as e:
    detail = str(e)
with open('/logs/verifier/gates.json', 'a') as f:
    json.dump({'id': 'f2p_upstream_parser_win_drive', 'passed': passed, 'detail': detail}, f)
    f.write('\n')
" 2>/dev/null || true

# P2P gate 1: py_compile changed source files
python3 -c "
import json, sys, py_compile
files = ['dataclaw/anonymizer.py', 'dataclaw/parser.py', 'dataclaw/cli.py']
passed = True
detail = 'ok'
for fname in files:
    try:
        py_compile.compile(fname, doraise=True)
    except Exception as e:
        passed = False
        detail = str(e)
        break
with open('/logs/verifier/gates.json', 'a') as f:
    json.dump({'id': 'p2p_upstream_py_compile', 'passed': passed, 'detail': detail}, f)
    f.write('\n')
" 2>/dev/null || true

# P2P gate 2: import check
python3 -c "
import json, sys
sys.path.insert(0, '.')
passed = True
detail = 'ok'
try:
    from dataclaw.anonymizer import anonymize_path, anonymize_text
    from dataclaw.parser import _build_project_name
except Exception as e:
    passed = False
    detail = str(e)
with open('/logs/verifier/gates.json', 'a') as f:
    json.dump({'id': 'p2p_upstream_import', 'passed': passed, 'detail': detail}, f)
    f.write('\n')
" 2>/dev/null || true

# Upstream reward tail
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {"f2p_upstream_anonymize_path_win": 0.20, "f2p_upstream_parser_win_drive": 0.20}
P2P_REGRESSION = ["p2p_upstream_py_compile", "p2p_upstream_import"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            gid = d.get('id')
            if gid:
                verdicts[gid] = bool(d.get('passed'))
except FileNotFoundError:
    pass
existing = 0.0
try:
    with open('/logs/verifier/reward.txt') as f:
        existing = float(f.read().strip() or 0)
except Exception:
    pass
f2p_any_pass = any(verdicts.get(gid) for gid in WEIGHTS)
if (not f2p_any_pass and existing <= 0):
    # No upstream F2P gate passed → fundamental Windows fix is missing → zero
    reward = 0.0
else:
    # weighted-replace formula (c8bc168a standard, replaces additive)
    inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('REWARD=%.4f' % reward)
PYEOF
# ---- end ----