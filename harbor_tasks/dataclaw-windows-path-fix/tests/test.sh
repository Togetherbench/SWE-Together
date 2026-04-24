#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")" 2>/dev/null || true

cd /workspace/repo

python3 << 'PYEOF'
import sys

# Pre-check: can we import the package?
try:
    import dataclaw
except Exception as e:
    print(f"FATAL: Cannot import dataclaw: {e}")
    with open("/logs/verifier/reward.txt", "w") as f:
        f.write("0.00\n")
    sys.exit(0)

results = {}

# ──────────────────────────────────────────────────────────────
# Test 1 (F2P, 25%): _build_project_name handles Windows drive-letter paths
# On Windows, Claude Code encodes C:\Users\alice\Documents\myapp
# as the directory name "C-Users-alice-Documents-myapp".
# The function should extract "myapp" just like it does for
# "-Users-alice-Documents-myapp" on Unix.
# ──────────────────────────────────────────────────────────────
try:
    from dataclaw.parser import _build_project_name
    r1 = _build_project_name("C-Users-alice-Documents-myapp")
    r2 = _build_project_name("D-Users-bob-project")
    ok = (r1 == "myapp") and (r2 == "project")
    results["test1_build_project_name_win_basic"] = {
        "pass": ok, "weight": 25,
        "detail": f"r1={r1!r} (exp 'myapp'), r2={r2!r} (exp 'project')",
    }
except Exception as e:
    results["test1_build_project_name_win_basic"] = {
        "pass": False, "weight": 25, "detail": str(e),
    }

# ──────────────────────────────────────────────────────────────
# Test 2 (F2P, 15%): _build_project_name Windows edge cases
# Drive letter + common dirs, non-common dirs, bare home
# ──────────────────────────────────────────────────────────────
try:
    from dataclaw.parser import _build_project_name
    checks = [
        ("C-Users-alice-Desktop-stuff", "stuff"),
        ("C-Users-alice-Downloads-thing", "thing"),
        ("E-Users-admin-work-repo", "work-repo"),
    ]
    failures = []
    for inp, expected in checks:
        result = _build_project_name(inp)
        if result != expected:
            failures.append(f"{inp}: got {result!r}, expected {expected!r}")
    results["test2_build_project_name_win_edge"] = {
        "pass": len(failures) == 0, "weight": 15,
        "detail": "; ".join(failures) if failures else "all passed",
    }
except Exception as e:
    results["test2_build_project_name_win_edge"] = {
        "pass": False, "weight": 15, "detail": str(e),
    }

# ──────────────────────────────────────────────────────────────
# Test 3 (F2P, 25%): anonymize_path handles Windows backslash paths
# anonymize_path should strip "C:\Users\alice\Documents\" just like
# it strips "/Users/alice/Documents/", producing a relative path.
# ──────────────────────────────────────────────────────────────
try:
    from dataclaw.anonymizer import anonymize_path

    # Windows Documents path -> should strip to project-relative
    r1 = anonymize_path(
        "C:\\Users\\alice\\Documents\\myproject\\file.py",
        "alice", "user_abc", "C:\\Users\\alice",
    )
    ok1 = ("alice" not in r1 and "Users" not in r1
           and "myproject" in r1 and "file.py" in r1)

    # Windows bare home path -> should hash the username portion
    r2 = anonymize_path(
        "C:\\Users\\alice\\somedir\\file.py",
        "alice", "user_abc", "C:\\Users\\alice",
    )
    ok2 = "alice" not in r2 and "user_abc" in r2 and "somedir" in r2

    ok = ok1 and ok2
    results["test3_anonymize_path_windows"] = {
        "pass": ok, "weight": 25,
        "detail": f"r1={r1!r} ok1={ok1}, r2={r2!r} ok2={ok2}",
    }
except Exception as e:
    results["test3_anonymize_path_windows"] = {
        "pass": False, "weight": 25, "detail": str(e),
    }

# ──────────────────────────────────────────────────────────────
# Test 4 (F2P, 25%): anonymize_text handles Windows backslash paths
# Use short usernames (< 4 chars) so the bare-username fallback
# is skipped, verifying that dedicated Windows-aware regex exists.
# ──────────────────────────────────────────────────────────────
try:
    from dataclaw.anonymizer import anonymize_text

    r1 = anonymize_text("Open C:\\Users\\Jo\\project", "Jo", "user_abc")
    ok1 = "Jo" not in r1 and "user_abc" in r1

    r2 = anonymize_text("In C:\\Users\\Bo\\docs\\file", "Bo", "user_xyz")
    ok2 = "Bo" not in r2 and "user_xyz" in r2

    ok = ok1 and ok2
    results["test4_anonymize_text_windows"] = {
        "pass": ok, "weight": 25,
        "detail": f"r1={r1!r} ok1={ok1}, r2={r2!r} ok2={ok2}",
    }
except Exception as e:
    results["test4_anonymize_text_windows"] = {
        "pass": False, "weight": 25, "detail": str(e),
    }

# ──────────────────────────────────────────────────────────────
# Test 5 (P2P, 10%): Unix paths still work (regression check)
# ──────────────────────────────────────────────────────────────
try:
    from dataclaw.parser import _build_project_name
    from dataclaw.anonymizer import anonymize_path, anonymize_text

    r1 = _build_project_name("-Users-alice-Documents-myproject")
    ok1 = r1 == "myproject"

    r2 = _build_project_name("-home-bob-project")
    ok2 = r2 == "project"

    r3 = anonymize_path(
        "/Users/alice/Documents/proj/f.py",
        "alice", "user_abc", "/Users/alice",
    )
    ok3 = r3 == "proj/f.py"

    r4 = anonymize_text("at /Users/alice/project", "alice", "user_abc")
    ok4 = "alice" not in r4 and "user_abc" in r4

    ok = ok1 and ok2 and ok3 and ok4
    results["test5_regression_unix"] = {
        "pass": ok, "weight": 10,
        "detail": f"r1={r1!r} r2={r2!r} r3={r3!r} ok4={ok4}",
    }
except Exception as e:
    results["test5_regression_unix"] = {
        "pass": False, "weight": 10, "detail": str(e),
    }

# ──────────────────────────────────────────────────────────────
# Summary & reward
# ──────────────────────────────────────────────────────────────
total_weight = sum(r["weight"] for r in results.values())
earned_weight = sum(r["weight"] for r in results.values() if r["pass"])

print("=" * 60)
for name, r in sorted(results.items()):
    status = "PASS" if r["pass"] else "FAIL"
    print(f"  {status}: {name} (weight {r['weight']}%) - {r['detail']}")
print("=" * 60)

reward = earned_weight / total_weight if total_weight > 0 else 0.0
print(f"Score: {earned_weight}/{total_weight} = {reward:.2f}")

with open("/logs/verifier/reward.txt", "w") as f:
    f.write(f"{reward:.2f}\n")
PYEOF
