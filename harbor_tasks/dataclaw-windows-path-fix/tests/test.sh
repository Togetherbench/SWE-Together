#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")" 2>/dev/null || true

cd /workspace/repo 2>/dev/null || cd /workspace/dataclaw 2>/dev/null || cd /workspace/$(ls /workspace | head -1)

python3 << 'PYEOF'
import sys, json

results = {}

def record(name, weight, passed, detail=""):
    results[name] = {"pass": bool(passed), "weight": weight, "detail": detail}

# Pre-check
try:
    import dataclaw
    from dataclaw.parser import _build_project_name
    from dataclaw.anonymizer import anonymize_path, anonymize_text
except Exception as e:
    print(f"FATAL: cannot import: {e}")
    with open("/logs/verifier/reward.txt", "w") as f:
        f.write("0.00\n")
    sys.exit(0)

# ──────────────────────────────────────────────────────────────
# P2P REGRESSION GUARDS (Unix paths must still work) — 18%
# ──────────────────────────────────────────────────────────────

# 1. Unix _build_project_name (6%)
try:
    cases = [
        ("-Users-alice-Documents-myproject", "myproject"),
        ("-home-bob-project", "project"),
        ("-Users-alice-Documents-my-cool-project", "my-cool-project"),
        ("standalone", "standalone"),
    ]
    failures = []
    for inp, exp in cases:
        got = _build_project_name(inp)
        if got != exp:
            failures.append(f"{inp!r}->{got!r} (exp {exp!r})")
    record("p2p_unix_build_project_name", 6, not failures, "; ".join(failures) or "ok")
except Exception as e:
    record("p2p_unix_build_project_name", 6, False, str(e))

# 2. Unix anonymize_path (6%)
try:
    r = anonymize_path("/Users/alice/Documents/proj/f.py", "alice", "user_abc", "/Users/alice")
    ok1 = r == "proj/f.py"
    r2 = anonymize_path("/home/bob/work/x.py", "bob", "user_xyz", "/home/bob")
    ok2 = "user_xyz" not in r2 and "bob" not in r2 and "work/x.py" in r2
    # actually for bare home (not in common dirs), should hash
    r3 = anonymize_path("/Users/alice/randomdir/f.py", "alice", "user_abc", "/Users/alice")
    ok3 = "alice" not in r3 and "user_abc" in r3 and "randomdir" in r3
    record("p2p_unix_anonymize_path", 6, ok1 and ok3, f"r={r!r} r3={r3!r}")
except Exception as e:
    record("p2p_unix_anonymize_path", 6, False, str(e))

# 3. Unix anonymize_text (6%)
try:
    r = anonymize_text("at /Users/alice/project", "alice", "user_abc")
    ok = "alice" not in r and "user_abc" in r
    r2 = anonymize_text("see -Users-alice-stuff", "alice", "user_abc")
    ok2 = "alice" not in r2 and "user_abc" in r2
    record("p2p_unix_anonymize_text", 6, ok and ok2, f"r={r!r} r2={r2!r}")
except Exception as e:
    record("p2p_unix_anonymize_text", 6, False, str(e))

# ──────────────────────────────────────────────────────────────
# F2P BEHAVIORAL GATES — Windows path support — 64%
# ──────────────────────────────────────────────────────────────

# 4. Windows _build_project_name (Claude Code dir-name encoding) — 16%
# Claude Code on Windows encodes C:\Users\alice\Documents\myapp.
# The exact encoding may use single-hyphen drive (C-) or double-hyphen (C--).
# Accept either encoding scheme as long as output is correct.
try:
    # Test core: drive-letter-prefixed encodings should yield project name.
    # Try both common encodings: "C-Users-..." (colon dropped) and "C--Users-..." (colon as hyphen)
    test_groups = [
        # (list of acceptable input encodings, expected output)
        (["C-Users-alice-Documents-myapp", "C--Users-alice-Documents-myapp"], "myapp"),
        (["D-Users-bob-project", "D--Users-bob-project"], "project"),
        (["C-Users-alice-Desktop-stuff", "C--Users-alice-Desktop-stuff"], "stuff"),
        (["C-Users-alice-Downloads-thing", "C--Users-alice-Downloads-thing"], "thing"),
        (["C-Users-alice-Documents-my-cool-project", "C--Users-alice-Documents-my-cool-project"], "my-cool-project"),
        (["E-Users-admin-work-repo", "E--Users-admin-work-repo"], "work-repo"),
    ]
    passes = 0
    total = len(test_groups)
    details = []
    for inputs, expected in test_groups:
        got_any = False
        for inp in inputs:
            try:
                if _build_project_name(inp) == expected:
                    got_any = True
                    break
            except Exception:
                pass
        if got_any:
            passes += 1
        else:
            outs = []
            for inp in inputs:
                try:
                    outs.append(f"{inp}->{_build_project_name(inp)!r}")
                except Exception as e:
                    outs.append(f"{inp}->ERR")
            details.append(f"exp {expected!r}: " + " | ".join(outs))
    # Partial credit
    frac = passes / total
    record("f2p_win_build_project_name", 16, frac >= 0.83,
           f"{passes}/{total} groups; {'; '.join(details) if details else 'all ok'}")
    # Store frac for partial credit
    results["f2p_win_build_project_name"]["partial"] = frac
except Exception as e:
    record("f2p_win_build_project_name", 16, False, str(e))

# 5. Windows anonymize_path with backslash paths — 16%
try:
    cases = []
    # Documents prefix - should strip
    r1 = anonymize_path(
        "C:\\Users\\alice\\Documents\\myproject\\file.py",
        "alice", "user_abc", "C:\\Users\\alice"
    )
    ok1 = "alice" not in r1 and "Users" not in r1 and "myproject" in r1 and "file.py" in r1
    cases.append(("Documents backslash", ok1, r1))

    # Bare home - should hash username
    r2 = anonymize_path(
        "C:\\Users\\alice\\somedir\\file.py",
        "alice", "user_abc", "C:\\Users\\alice"
    )
    ok2 = "alice" not in r2 and "user_abc" in r2 and "somedir" in r2
    cases.append(("bare home backslash", ok2, r2))

    # Other drive letter
    r3 = anonymize_path(
        "D:\\Users\\bob\\Desktop\\proj\\app.py",
        "bob", "user_xyz", "D:\\Users\\bob"
    )
    ok3 = "bob" not in r3 and "Users" not in r3 and "proj" in r3 and "app.py" in r3
    cases.append(("D drive Desktop", ok3, r3))

    # Forward-slash Windows path (Python often normalizes)
    r4 = anonymize_path(
        "C:/Users/alice/Documents/work/x.py",
        "alice", "user_abc", "C:\\Users\\alice"
    )
    ok4 = "alice" not in r4 and "work" in r4 and "x.py" in r4
    cases.append(("forward-slash windows", ok4, r4))

    passes = sum(1 for _, ok, _ in cases if ok)
    total = len(cases)
    frac = passes / total
    detail = "; ".join(f"{n}:{'ok' if ok else f'FAIL({r!r})'}" for n, ok, r in cases)
    record("f2p_win_anonymize_path", 16, frac >= 0.75, detail)
    results["f2p_win_anonymize_path"]["partial"] = frac
except Exception as e:
    record("f2p_win_anonymize_path", 16, False, str(e))

# 6. Windows anonymize_text with short usernames (forces dedicated regex) — 16%
try:
    cases = []
    # Short usernames (< 4 chars) bypass bare-username fallback
    r1 = anonymize_text("Open C:\\Users\\Jo\\project", "Jo", "user_abc")
    ok1 = "Jo" not in r1 and "user_abc" in r1
    cases.append(("Jo backslash", ok1, r1))

    r2 = anonymize_text("In C:\\Users\\Bo\\docs\\file", "Bo", "user_xyz")
    ok2 = "Bo" not in r2 and "user_xyz" in r2
    cases.append(("Bo backslash", ok2, r2))

    # Different drive letter
    r3 = anonymize_text("Data at D:\\Users\\Al\\stuff", "Al", "user_def")
    ok3 = "Al" not in r3.replace("user_def","X") or "user_def" in r3
    # More precise: ensure hash present and "Al" not isolated
    ok3 = "user_def" in r3
    cases.append(("D drive short user", ok3, r3))

    # Longer username with backslash
    r4 = anonymize_text("at C:\\Users\\peteromalley\\project", "peteromalley", "user_abc12345")
    ok4 = "peteromalley" not in r4 and "user_abc12345" in r4
    cases.append(("long user backslash", ok4, r4))

    passes = sum(1 for _, ok, _ in cases if ok)
    total = len(cases)
    frac = passes / total
    detail = "; ".join(f"{n}:{'ok' if ok else f'FAIL({r!r})'}" for n, ok, r in cases)
    record("f2p_win_anonymize_text", 16, frac >= 0.75, detail)
    results["f2p_win_anonymize_text"]["partial"] = frac
except Exception as e:
    record("f2p_win_anonymize_text", 16, False, str(e))

# 7. Windows path round-trip / consistency — 16%
# Check that hyphen-encoded windows form is also handled in anonymize_text
# AND that absolute Windows paths are recognized somewhere (e.g. parser._extract_files_touched-like logic)
try:
    sub = 0
    total = 4

    # 7a: hyphen-encoded windows form in text
    r1 = anonymize_text("see C--Users-alice-stuff", "alice", "user_abc")
    if "alice" not in r1 and "user_abc" in r1:
        sub += 1
    # also accept C-Users-alice form
    if sub == 0:
        r1b = anonymize_text("see C-Users-alice-stuff", "alice", "user_abc")
        if "alice" not in r1b and "user_abc" in r1b:
            sub += 1

    # 7b: anonymize_path returns no original username for Windows non-home path
    r2 = anonymize_path(
        "C:\\Users\\alice\\Documents\\app\\main.py",
        "alice", "user_abc", "C:\\Users\\alice"
    )
    if "alice" not in r2 and ("main.py" in r2):
        sub += 1

    # 7c: forward-slash drive path
    r3 = anonymize_path(
        "C:/Users/alice/Documents/proj/x.py",
        "alice", "user_abc", "C:/Users/alice"
    )
    if "alice" not in r3 and "x.py" in r3:
        sub += 1

    # 7d: anonymize_text with mixed forward slashes
    r4 = anonymize_text("path C:/Users/alice/code", "alice", "user_abc")
    if "alice" not in r4 and "user_abc" in r4:
        sub += 1

    frac = sub / total
    record("f2p_win_consistency", 16, frac >= 0.75,
           f"{sub}/{total} consistency checks passed")
    results["f2p_win_consistency"]["partial"] = frac
except Exception as e:
    record("f2p_win_consistency", 16, False, str(e))

# ──────────────────────────────────────────────────────────────
# STRUCTURAL — repo test suite still passes — 18%
# ──────────────────────────────────────────────────────────────

# 8. Existing pytest suite still green (regression coverage) — 12%
import subprocess, os
try:
    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    proc = subprocess.run(
        [sys.executable, "-m", "pytest", "-x", "-q", "--tb=line",
         "--ignore=tests/test_anonymizer.py" if False else "tests"],
        capture_output=True, text=True, timeout=120, env=env
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    # accept return code 0 or 5 (no tests collected)
    ok = proc.returncode == 0
    tail = out.strip().splitlines()[-3:] if out else []
    record("struct_pytest_suite", 12, ok, f"rc={proc.returncode} {' | '.join(tail)[:300]}")
except Exception as e:
    record("struct_pytest_suite", 12, False, str(e))

# 9. CLI still imports & --help works — 6%
try:
    proc = subprocess.run(
        [sys.executable, "-m", "dataclaw.cli", "--help"],
        capture_output=True, text=True, timeout=30
    )
    ok = proc.returncode == 0 and ("usage" in proc.stdout.lower() or "usage" in proc.stderr.lower())
    record("struct_cli_help", 6, ok, f"rc={proc.returncode}")
except Exception as e:
    record("struct_cli_help", 6, False, str(e))

# ──────────────────────────────────────────────────────────────
# Summary & reward (with partial credit for graded tests)
# ──────────────────────────────────────────────────────────────
total_weight = sum(r["weight"] for r in results.values())
earned = 0.0
for name, r in results.items():
    if "partial" in r:
        # partial credit: scale by frac, but require >= 0.5 to get any credit
        frac = r["partial"]
        if frac >= 0.5:
            earned += r["weight"] * frac
    else:
        if r["pass"]:
            earned += r["weight"]

print("=" * 60)
for name, r in sorted(results.items()):
    status = "PASS" if r["pass"] else "FAIL"
    extra = f" partial={r['partial']:.2f}" if "partial" in r else ""
    print(f"  {status}: {name} (w={r['weight']}%){extra} - {r['detail'][:200]}")
print("=" * 60)

reward = earned / total_weight if total_weight > 0 else 0.0
print(f"Score: {earned:.2f}/{total_weight} = {reward:.3f}")

with open("/logs/verifier/reward.txt", "w") as f:
    f.write(f"{reward:.2f}\n")
PYEOF

REWARD=$(cat /logs/verifier/reward.txt 2>/dev/null || echo "0.00")
echo "Final reward: $REWARD"