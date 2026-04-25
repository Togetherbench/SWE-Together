#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")" 2>/dev/null || true
REWARD="0.00"

cd /workspace/repo 2>/dev/null || cd /workspace/dataclaw 2>/dev/null || cd /workspace/$(ls /workspace 2>/dev/null | head -1) 2>/dev/null

SCORE=$(python3 << 'PYEOF'
import sys

total = 0.0

# ── P2P GATES (must pass on base; fail → reward 0) ──
try:
    import dataclaw
    from dataclaw.parser import _build_project_name
    from dataclaw.anonymizer import anonymize_path, anonymize_text
except Exception as e:
    print("0.00")
    sys.exit(0)

# P2P: Unix _build_project_name still works
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
    if r != "proj/f.py":
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

# ── F2P GATES (fail on base, pass on fix) ──

# F2P 1: Windows _build_project_name (33%)
# Base has no Windows handling. Accept either C-... or C--... encoding.
f2p1_pass = 0
f2p1_total = 0
groups = [
    (["C-Users-alice-Documents-myapp", "C--Users-alice-Documents-myapp"], "myapp"),
    (["D-Users-bob-project", "D--Users-bob-project"], "project"),
    (["C-Users-alice-Desktop-stuff", "C--Users-alice-Desktop-stuff"], "stuff"),
    (["C-Users-alice-Downloads-thing", "C--Users-alice-Downloads-thing"], "thing"),
    (["C-Users-alice-Documents-my-cool-project", "C--Users-alice-Documents-my-cool-project"], "my-cool-project"),
    (["E-Users-admin-work-repo", "E--Users-admin-work-repo"], "work-repo"),
]
for inputs, expected in groups:
    f2p1_total += 1
    for inp in inputs:
        try:
            if _build_project_name(inp) == expected:
                f2p1_pass += 1
                break
        except Exception:
            pass
f2p1_frac = f2p1_pass / f2p1_total if f2p1_total else 0
total += 0.33 * f2p1_frac

# F2P 2: Windows anonymize_path (33%)
f2p2_pass = 0
f2p2_total = 0

# (a) backslash Documents prefix → strip
f2p2_total += 1
try:
    r = anonymize_path("C:\\Users\\alice\\Documents\\myproject\\file.py",
                       "alice", "user_abc", "C:\\Users\\alice")
    if "alice" not in r and "Users" not in r and "myproject" in r and "file.py" in r:
        f2p2_pass += 1
except Exception:
    pass

# (b) bare home backslash → hash
f2p2_total += 1
try:
    r = anonymize_path("C:\\Users\\alice\\somedir\\file.py",
                       "alice", "user_abc", "C:\\Users\\alice")
    if "alice" not in r and "user_abc" in r and "somedir" in r:
        f2p2_pass += 1
except Exception:
    pass

# (c) D: drive Desktop → strip
f2p2_total += 1
try:
    r = anonymize_path("D:\\Users\\bob\\Desktop\\proj\\app.py",
                       "bob", "user_xyz", "D:\\Users\\bob")
    if "bob" not in r and "Users" not in r and "proj" in r and "app.py" in r:
        f2p2_pass += 1
except Exception:
    pass

# (d) forward-slash windows path
f2p2_total += 1
try:
    r = anonymize_path("C:/Users/alice/Documents/work/x.py",
                       "alice", "user_abc", "C:\\Users\\alice")
    if "alice" not in r and "work" in r and "x.py" in r:
        f2p2_pass += 1
except Exception:
    pass

f2p2_frac = f2p2_pass / f2p2_total
total += 0.33 * f2p2_frac

# F2P 3: Windows anonymize_text (34%)
f2p3_pass = 0
f2p3_total = 0

# (a) Short username Jo with backslash — bare-username fallback bypasses short names
f2p3_total += 1
try:
    r = anonymize_text("Open C:\\Users\\Jo\\project", "Jo", "user_abc")
    if "Jo" not in r and "user_abc" in r:
        f2p3_pass += 1
except Exception:
    pass

# (b) Short username Bo with backslash
f2p3_total += 1
try:
    r = anonymize_text("In C:\\Users\\Bo\\docs\\file", "Bo", "user_xyz")
    if "Bo" not in r and "user_xyz" in r:
        f2p3_pass += 1
except Exception:
    pass

# (c) D drive short user
f2p3_total += 1
try:
    r = anonymize_text("Data at D:\\Users\\Al\\stuff", "Al", "user_def")
    if "user_def" in r:
        f2p3_pass += 1
except Exception:
    pass

# (d) Long username with backslash — base lacks backslash regex
f2p3_total += 1
try:
    r = anonymize_text("at C:\\Users\\peteromalley\\project", "peteromalley", "user_abc12345")
    if "peteromalley" not in r and "user_abc12345" in r:
        f2p3_pass += 1
except Exception:
    pass

f2p3_frac = f2p3_pass / f2p3_total
total += 0.34 * f2p3_frac

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