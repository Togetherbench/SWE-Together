#!/bin/bash
set +e


# Canonical PATH (E2B strips Dockerfile ENV PATH; restore tool dirs)
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

export PATH=/usr/local/bin:/usr/bin:/bin:$PATH
WORKSPACE="/workspace/dataclaw"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"
GATES_FILE="$LOG_DIR/gates.json"
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail="${detail//\"/\\\"}"
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

write_reward() {
    printf "%.4f\n" "$1" > "$LOG_DIR/reward.txt"
}

if ! cd "$WORKSPACE" 2>/dev/null; then
    emit t1_f2p_suite_runs_and_passes false "no workspace"
    emit t1_f2p_module_breadth false "no workspace"
    emit t1_f2p_config_behavior false "no workspace"
    emit t1_f2p_parser_or_cli_behavior false "no workspace"
    emit t2_f2p_secrets_redacted_constant false "no workspace"
    emit t2_f2p_anonymizer_hash_format false "no workspace"
    emit p2p_src_unmodified true "no workspace"
    emit p2p_baseline_sane false "no workspace"
    write_reward 0.0
    exit 0
fi

python3 -m pip install --quiet pytest pytest-timeout >/dev/null 2>&1

# ---------- Source-immutability check ----------
SRC_OK=1
hash_file=/baseline/dataclaw_src_hash
if [ -s "$hash_file" ]; then
    expected=$(cat "$hash_file")
    actual=$(cd "$WORKSPACE" && find . \( -name .git -o -name node_modules -o -name dist -o -name build -o -name target -o -name __pycache__ \) -prune -o \
            -type f \( -name '*.py' -o -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.rs' -o -name '*.go' -o -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.h' -o -name '*.hpp' -o -name '*.toml' -o -name '*.yaml' -o -name '*.yml' \) -print 2>/dev/null \
            | grep -v '/tests/' | sort | xargs -I {} sha256sum {} 2>/dev/null | sort | sha256sum | awk '{print $1}')
    if [ "$expected" = "$actual" ]; then
        emit p2p_src_unmodified true ""
    else
        emit p2p_src_unmodified false "src tree changed"
        SRC_OK=0
    fi
else
    # Fallback: compute sha over dataclaw/*.py only and stash it for later runs is not possible;
    # in absence of baseline, attempt a soft check via git if available.
    if [ -d "$WORKSPACE/.git" ]; then
        cd "$WORKSPACE"
        # If any tracked .py file under dataclaw/ shows in diff, consider modified.
        modified=$(git diff --name-only HEAD -- 'dataclaw/*.py' 2>/dev/null | head -n1)
        if [ -n "$modified" ]; then
            emit p2p_src_unmodified false "git diff shows dataclaw modified: $modified"
            SRC_OK=0
        else
            emit p2p_src_unmodified true "git clean"
        fi
    else
        emit p2p_src_unmodified true "no baseline"
    fi
fi

# Run the heavy lifting in python and emit gate results.
python3 - "$GATES_FILE" "$SRC_OK" << 'PYEOF'
import os, re, sys, json, shutil, subprocess
from pathlib import Path
from collections import defaultdict

GATES_FILE = sys.argv[1]
SRC_OK = sys.argv[2] == "1"

WORKSPACE = Path("/workspace/dataclaw")
DC = WORKSPACE / "dataclaw"
TESTS = WORKSPACE / "tests"
os.chdir(WORKSPACE)

def emit(gid, passed, detail=""):
    detail = detail.replace('"', '\\"')
    line = '{"id":"%s","passed":%s,"detail":"%s"}\n' % (gid, "true" if passed else "false", detail)
    with open(GATES_FILE, "a") as f:
        f.write(line)

# --- Discover tests ---
test_files = []
if TESTS.is_dir():
    test_files = sorted(p for p in TESTS.glob("test_*.py"))

if not TESTS.is_dir() or not test_files:
    emit("t1_f2p_suite_runs_and_passes", False, "no tests/ or no test_*.py")
    emit("t1_f2p_module_breadth", False, "no tests")
    emit("t1_f2p_config_behavior", False, "no tests")
    emit("t1_f2p_parser_or_cli_behavior", False, "no tests")
    emit("t2_f2p_secrets_redacted_constant", False, "no tests")
    emit("t2_f2p_anonymizer_hash_format", False, "no tests")
    emit("p2p_baseline_sane", False, "no tests")
    sys.exit(0)

def run_pytest(args, timeout=240, env_extra=None):
    env = os.environ.copy()
    if env_extra: env.update(env_extra)
    try:
        r = subprocess.run(
            [sys.executable, "-m", "pytest"] + args
              + ["--tb=line", "--timeout=20", "-q", "--no-header",
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

def count_failed_lines(out):
    # Lines starting with FAILED indicate assertion failures (vs collection errors)
    return len(re.findall(r'^FAILED ', out, re.MULTILINE))

# --- Baseline run ---
out, rc = run_pytest(["tests/"], timeout=300)
n_pass, n_fail, n_err = parse_counts(out)
total = n_pass + n_fail + n_err
baseline_pass = n_pass
baseline_failed = count_failed_lines(out)

print(f"Baseline pass={n_pass} fail={n_fail} err={n_err} total={total}")
print(out[-2000:])

baseline_sane = total > 0 and n_pass >= 1
if not baseline_sane:
    emit("p2p_baseline_sane", False, f"baseline collected={total} pass={n_pass}")
else:
    emit("p2p_baseline_sane", True, "")

# --- t1_f2p_suite_runs_and_passes ---
# Behavioral: run the agent's tests; require ≥20 passing across ≥4 test files,
# ratio ≥0.80, and ≥3 'assert' statements per test file.
suite_ok = (
    len(test_files) >= 4
    and n_pass >= 20
    and total > 0
    and (n_pass / total) >= 0.80
)
# Also require minimum assertion density per file (anti-trivial)
assertion_density_ok = True
for tf in test_files:
    try:
        src = tf.read_text(errors="ignore")
    except Exception:
        assertion_density_ok = False
        break
    n_assert = len(re.findall(r'\bassert\b', src))
    if n_assert < 3:
        assertion_density_ok = False
        break

suite_pass = suite_ok and assertion_density_ok
emit("t1_f2p_suite_runs_and_passes", suite_pass,
     f"files={len(test_files)} pass={n_pass} total={total} dense={assertion_density_ok}")

# If baseline is broken or src modified, no point running mutations — fail rest.
if not baseline_sane:
    for g in ["t1_f2p_module_breadth", "t1_f2p_config_behavior",
              "t1_f2p_parser_or_cli_behavior",
              "t2_f2p_secrets_redacted_constant",
              "t2_f2p_anonymizer_hash_format"]:
        emit(g, False, "baseline not sane")
    sys.exit(0)

# ---------- Mutation testing ----------
# Each mutation is a (file, old, new, slice, kind) where kind in {"value","rename"}.
# Value mutations require behavioral assertions to catch.
MUTATIONS = [
    # ---- secrets ----
    ("secrets.py", 'REDACTED = "[REDACTED]"', 'REDACTED = "[NOT_REDACTED_XYZ]"',
     "secrets_redacted", "secrets", "value"),
    # ---- anonymizer ----
    ("anonymizer.py",
     'hashlib.sha256(username.encode()).hexdigest()[:8]',
     'hashlib.sha256(username.encode()).hexdigest()[:4]',
     "anon_hash_len", "anonymizer", "value"),
    ("anonymizer.py",
     'return "user_" + hashlib.sha256',
     'return "USR_" + hashlib.sha256',
     "anon_hash_prefix", "anonymizer", "value"),
    # ---- config ----
    ("config.py", '"redact_strings": []', '"redact_strings": ["BUG_INJECT"]',
     "config_redact_strings", "config", "value"),
    ("config.py", '"excluded_projects": []', '"excluded_projects": ["BUG_PROJ"]',
     "config_excluded_projects", "config", "value"),
    # ---- parser (value mutations) ----
    ("parser.py", '/ 1000', '* 1000', "parser_ts_div", "parser", "value"),
    ("parser.py", '.jsonl', '.JSONLBUG', "parser_ext", "parser", "value"),
    ("parser.py", 'def parse_session', 'def _orig_parse_session',
     "parser_rename", "parser", "rename"),
    # ---- cli (value mutations) ----
    ("cli.py", '1024.0', '2048.0', "cli_size_kb", "cli", "value"),
    ("cli.py", "'***'", "'###'", "cli_mask_star", "cli", "value"),
    ("cli.py", '"***"', '"###"', "cli_mask_star_dq", "cli", "value"),
    ("cli.py", 'def _format_size', 'def _orig_format_size',
     "cli_rename_fs", "cli", "rename"),
]

# Filter: pattern must actually occur in source
applicable = []
for fname, old, new, mid, slc, kind in MUTATIONS:
    p = DC / fname
    if not p.exists():
        continue
    src = p.read_text()
    if old in src:
        applicable.append((fname, old, new, mid, slc, kind))

print(f"Applicable mutations: {[m[3] for m in applicable]}")

def run_suite(timeout=180):
    try:
        r = subprocess.run(
            [sys.executable, "-m", "pytest", "tests/", "-q", "--tb=line",
             "--timeout=15", "--no-header", "-p", "no:cacheprovider"],
            capture_output=True, text=True, timeout=timeout,
            cwd=str(WORKSPACE))
        o = r.stdout + r.stderr
        p, f, e = parse_counts(o)
        failed_lines = count_failed_lines(o)
        return p, f, e, failed_lines, o
    except subprocess.TimeoutExpired:
        return 0, 0, 999, 0, "TIMEOUT"
    except Exception as ex:
        return 0, 0, 999, 0, f"ERR {ex}"

slice_caught = defaultdict(list)   # slice -> list of (mid, caught_strict, caught_loose)
mutation_caught = {}                # mid -> caught_strict (bool)

for fname, old, new, mid, slc, kind in applicable:
    if not SRC_OK:
        # Don't run mutations if src already changed; mark all uncaught.
        slice_caught[slc].append((mid, False, False))
        mutation_caught[mid] = False
        continue
    p = DC / fname
    orig = p.read_text()
    mutated = orig.replace(old, new, 1)
    if mutated == orig:
        continue
    p.write_text(mutated)
    for cache in DC.rglob("__pycache__"):
        try: shutil.rmtree(cache)
        except Exception: pass
    try:
        n_p, n_f, n_e, fl, log = run_suite(timeout=180)
        # STRICT: at least one assertion-level FAILED line (not just ERROR)
        # OR pass-count strictly dropped vs baseline (regression in passing tests)
        caught_strict = (fl > 0) or (n_p < baseline_pass and (n_f > 0))
        # LOOSE: any failure or error — used for rename mutations
        caught_loose = (n_f > 0) or (n_e > 0) or (n_p < baseline_pass)
        # For "value" kind mutations, require strict; for rename, loose is OK.
        if kind == "value":
            caught = caught_strict
        else:
            caught = caught_loose
        print(f"  [{slc}] {mid} ({kind}): pass={n_p} fail={n_f} err={n_e} FAILED_lines={fl} caught={caught}")
        slice_caught[slc].append((mid, caught_strict, caught_loose))
        mutation_caught[mid] = caught
    finally:
        p.write_text(orig)
        for cache in DC.rglob("__pycache__"):
            try: shutil.rmtree(cache)
            except Exception: pass

# ---------- Gate evaluation ----------

# t1_f2p_module_breadth: count slices with ≥1 STRICT (value-mutation) catch.
# A slice is "behaviorally covered" only if a value mutation was caught strictly.
covered_slices = set()
for slc in ["secrets", "anonymizer", "parser", "cli", "config"]:
    results = slice_caught.get(slc, [])
    # Only count strict catches against value mutations (kind tracked via mid set)
    # Easier: a strict catch implies behavioral coverage.
    if any(strict for (_mid, strict, _loose) in results):
        covered_slices.add(slc)
n_modules = len(covered_slices)
emit("t1_f2p_module_breadth", n_modules >= 4,
     f"covered={sorted(covered_slices)} ({n_modules}/5)")

# t1_f2p_config_behavior: at least one config value mutation caught strictly.
config_caught = any(
    mutation_caught.get(mid, False)
    for mid in ["config_redact_strings", "config_excluded_projects"]
)
emit("t1_f2p_config_behavior", config_caught,
     "config value-mutations not caught" if not config_caught else "")

# t1_f2p_parser_or_cli_behavior: at least one VALUE mutation in parser or cli caught strictly.
pc_value_mids = ["parser_ts_div", "parser_ext", "cli_size_kb",
                 "cli_mask_star", "cli_mask_star_dq"]
pc_caught = any(mutation_caught.get(mid, False) for mid in pc_value_mids)
# If none of those patterns existed, fall back: require strict catch in parser or cli slice
if not any(mid in mutation_caught for mid in pc_value_mids):
    pc_caught = any(strict for slc in ("parser", "cli")
                    for (_m, strict, _l) in slice_caught.get(slc, []))
emit("t1_f2p_parser_or_cli_behavior", pc_caught,
     "no behavioral parser/cli mutation caught" if not pc_caught else "")

# t2_f2p_secrets_redacted_constant: secrets.REDACTED mutation caught strictly.
secrets_caught = mutation_caught.get("secrets_redacted", False)
emit("t2_f2p_secrets_redacted_constant", secrets_caught,
     "REDACTED constant mutation not caught" if not secrets_caught else "")

# t2_f2p_anonymizer_hash_format: at least one anonymizer hash mutation caught strictly.
anon_caught = (mutation_caught.get("anon_hash_len", False)
               or mutation_caught.get("anon_hash_prefix", False))
emit("t2_f2p_anonymizer_hash_format", anon_caught,
     "anonymizer hash mutations not caught" if not anon_caught else "")

PYEOF

# ---------- Compute reward from gates.json ----------
python3 - "$GATES_FILE" "$LOG_DIR/reward.txt" << 'PYEOF'
import json, sys
gates_file = sys.argv[1]
reward_file = sys.argv[2]

# F2P weights from manifest
weights = {
    "t1_f2p_suite_runs_and_passes": 0.15,
    "t1_f2p_module_breadth": 0.15,
    "t1_f2p_config_behavior": 0.15,
    "t1_f2p_parser_or_cli_behavior": 0.15,
    "t2_f2p_secrets_redacted_constant": 0.20,
    "t2_f2p_anonymizer_hash_format": 0.20,
}
diagnostic = {"p2p_src_unmodified", "p2p_baseline_sane"}

results = {}
with open(gates_file) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        results[obj["id"]] = obj["passed"]

# Hard diagnostic: src unmodified MUST pass; if it failed, reward=0
src_ok = results.get("p2p_src_unmodified", True)
if not src_ok:
    with open(reward_file, "w") as f:
        f.write("0.0000\n")
    sys.exit(0)

reward = 0.0
for gid, w in weights.items():
    if results.get(gid, False):
        reward += w

with open(reward_file, "w") as f:
    f.write(f"{reward:.4f}\n")
PYEOF
# ---- v042 upstream CI gates (auto-injected) ----
# v043 upstream gates: prelude(s) + per-gate execution.
(
    set +e
    # prelude 0
    echo 'c2V0ICtlOyBjb21tYW5kIC12IHB5dGhvbjMgPi9kZXYvbnVsbCAmJiBlY2hvIE9L' | base64 -d | bash 2>&1 | tail -2
) 2>/dev/null

run_v043_gate() {
    local id="$1" label="$2"; shift 2
    local cmd="$*"
    local rc out tail
    out=$(timeout 240 bash -c "$cmd" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        emit "$id" true ""
    else
        tail="${out: -180}"
        tail="${tail//\"/\'}"
        tail="${tail//$'\n'/ }"
        emit "$id" false "rc=$rc; $tail"
    fi
}
run_v043_gate f2p_upstream_8138ab05 'py_compile_changed_generic' 'cd /workspace/dataclaw && cd /workspace && python3 -m py_compile /workspace/dataclaw/tests/__init__.py /workspace/dataclaw/tests/conftest.py /workspace/dataclaw/tests/test_config.py /workspace/dataclaw/tests/test_secrets.py /workspace/dataclaw/tests/test_anonymizer.py /workspace/dataclaw/tests/test_parser.py /workspace/dataclaw/tests/test_cli.py'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"f2p_upstream_8138ab05": 0.2, "t1_f2p_config_behavior": 0.12, "t1_f2p_module_breadth": 0.12, "t1_f2p_parser_or_cli_behavior": 0.12, "t1_f2p_suite_runs_and_passes": 0.12, "t2_f2p_anonymizer_hash_format": 0.16, "t2_f2p_secrets_redacted_constant": 0.16}
P2P_REGRESSION = ["p2p_src_unmodified", "p2p_baseline_sane"]
P2P_REGRESSION = []
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                gid = d.get('id')
                if gid: verdicts[gid] = bool(d.get('passed'))
            except Exception: pass
except FileNotFoundError: pass
# P2P failures are diagnostics/penalty inputs; they never feed bounded penalty/diagnostics.
reward = 0.0
for gid, w in WEIGHTS.items():
    if verdicts.get(gid, False): reward += w
if reward > 1.0: reward = 1.0
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('V043_REWARD=%.4f' % reward)
V043_PY
# ---- v042 end upstream CI gates ----


exit 0

# >>> auto_gate_bridge >>>
# Auto-generated by scripts/fix_emit_gates.py.
# Bridges manifest gates → /logs/verifier/gates.json so the canonical
# F2P-coverage formula matches the legacy reward.txt for tasks that were
# scored only via inline `add_reward` style. Idempotent.
#
# Semantics:
#   F2P gate without an explicit emit → proportionally pass `round(N*L)`
#     gates (where N = total F2P gates, L = legacy reward.txt), so the
#     canonical f2p_pass_rate reproduces the legacy reward.
#   P2P_REGRESSION without an explicit emit → passed: true (informational,
#     matches pre-canonical bash where unemitted P2P had no effect).
#
# After bridging, reward.txt is left as the legacy value. The host-side
# canonicalize_reward_from_gates() (per_turn_replay.py, oracle_replay.py)
# reads the now-complete gates.json and recomputes via the unified formula.
python3 - <<'AUTO_GATE_BRIDGE_PYEOF'
import json, os, sys
from pathlib import Path

LOGS = Path("/logs/verifier")
gates_path = LOGS / "gates.json"
reward_path = LOGS / "reward.txt"

# Locate the manifest at runtime. Harbor mounts the harbor task's tests/
# dir at /tests so the manifest is /tests/test_manifest.yaml.
manifest_candidates = [
    Path("/tests/test_manifest.yaml"),
    Path(os.environ.get("TEST_MANIFEST", "")),
]
manifest_path = next((p for p in manifest_candidates if p and p.is_file()), None)
if manifest_path is None:
    sys.exit(0)

try:
    import yaml
    raw = yaml.safe_load(manifest_path.read_text())
except Exception:
    sys.exit(0)

gates = (raw or {}).get("gates") or []
if not gates:
    sys.exit(0)

try:
    legacy_reward = float(reward_path.read_text().strip())
except Exception:
    legacy_reward = 0.0

existing_ids = set()
try:
    txt = gates_path.read_text().strip()
    if txt.startswith("[") or txt.startswith("{"):
        d = json.loads(txt)
        if isinstance(d, dict) and "gates" in d:
            for g in d["gates"]:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
        elif isinstance(d, list):
            for g in d:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
    else:
        for line in txt.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if obj.get("id"):
                    existing_ids.add(obj["id"])
            except Exception:
                pass
except FileNotFoundError:
    pass

all_gate_ids = []
f2p_missing_ids = []
p2p_missing_ids = []
for g in gates:
    if not isinstance(g, dict):
        continue
    gid = g.get("id")
    kind = g.get("kind", "F2P")
    if not gid:
        continue
    all_gate_ids.append((gid, kind))
    if gid in existing_ids:
        continue
    if kind == "F2P":
        f2p_missing_ids.append(gid)
    elif kind.startswith("P2P"):  # P2P_REGRESSION, P2P, deprecated kinds
        p2p_missing_ids.append(gid)

f2p_total = sum(1 for gid, kind in all_gate_ids if kind == "F2P")
target_passes = int(round(legacy_reward * f2p_total))

explicit_pass = 0
try:
    with gates_path.open() as _f:
        for line in _f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("id") and d.get("passed"):
                for (gid, kind) in all_gate_ids:
                    if gid == d["id"] and kind == "F2P":
                        explicit_pass += 1
                        break
except Exception:
    pass

bridge_passes = max(0, target_passes - explicit_pass)
bridge_passes = min(bridge_passes, len(f2p_missing_ids))

to_append = []
for i, gid in enumerate(f2p_missing_ids):
    passed = bool(i < bridge_passes)
    detail = "auto-bridge: F2P proportional (target=%d/%d, legacy=%.3f)" % (
        target_passes, f2p_total, legacy_reward,
    )
    to_append.append({"id": gid, "passed": passed, "detail": detail})
for gid in p2p_missing_ids:
    to_append.append({
        "id": gid,
        "passed": True,
        "detail": "auto-bridge: P2P default-pass (no explicit emit)",
    })

if to_append:
    LOGS.mkdir(parents=True, exist_ok=True)
    with gates_path.open("a") as _f:
        for obj in to_append:
            _f.write(json.dumps(obj) + "\n")
AUTO_GATE_BRIDGE_PYEOF
# <<< auto_gate_bridge <<<
