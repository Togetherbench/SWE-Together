#!/bin/bash
set +e
# [v042-fix] Robust Rust toolchain setup. Direct cargo binary on PATH
# bypasses rustup's proxy (which fails 'could not choose a version of cargo
# to run' when no toolchain is installed).
export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"
hash -r 2>/dev/null || true
if command -v rustup >/dev/null 2>&1; then
    rustup show active-toolchain >/dev/null 2>&1 \
        || rustup default stable 2>&1 \
        || rustup install stable 2>&1 \
        || true
fi


export PATH=/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH

RESULTS_DIR="/logs/verifier"
mkdir -p "$RESULTS_DIR"

REWARD=0.0
add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.4f", a+b}')
}

REPO="/workspace/hyperswitch"
if [ ! -d "$REPO/crates/diesel_models" ]; then
    for cand in /workspace/hyperswitch /workspace/repo /workspace/*/; do
        if [ -d "${cand%/}/crates/diesel_models" ]; then
            REPO="${cand%/}"
            break
        fi
    done
fi

if [ ! -d "$REPO/crates/diesel_models" ]; then
    echo "P2P FAIL: cannot locate hyperswitch repo"
    echo "0.0" > "$RESULTS_DIR/reward.txt"
    exit 0
fi

export REPO
echo "REPO=$REPO"

DIESEL_BP="$REPO/crates/diesel_models/src/business_profile.rs"
DIESEL_SCHEMA="$REPO/crates/diesel_models/src/schema.rs"
DIESEL_SCHEMA_V2="$REPO/crates/diesel_models/src/schema_v2.rs"
DOMAIN_BP="$REPO/crates/hyperswitch_domain_models/src/business_profile.rs"
ROUTER_DB_EVENTS="$REPO/crates/router/src/db/events.rs"
API_MODELS_ADMIN="$REPO/crates/api_models/src/admin.rs"
ROUTER_CORE_ADMIN="$REPO/crates/router/src/core/admin.rs"

export DIESEL_BP DIESEL_SCHEMA DIESEL_SCHEMA_V2 DOMAIN_BP ROUTER_DB_EVENTS API_MODELS_ADMIN ROUTER_CORE_ADMIN

#############################################
# P2P GATES (regression guards)
#############################################

for f in "$DIESEL_BP" "$DIESEL_SCHEMA" "$DOMAIN_BP" "$ROUTER_DB_EVENTS"; do
    if [ ! -f "$f" ]; then
        echo "P2P FAIL: missing $f"
        echo "0.0" > "$RESULTS_DIR/reward.txt"
        exit 0
    fi
done

python3 - <<'PYEOF'
import os, re, sys
src = open(os.environ['DIESEL_SCHEMA'], encoding='utf-8', errors='replace').read()
m = re.search(r'business_profile\s*\([^)]*\)\s*\{', src)
sys.exit(0 if m else 1)
PYEOF
if [ $? -ne 0 ]; then
    echo "P2P FAIL: business_profile schema block missing"
    echo "0.0" > "$RESULTS_DIR/reward.txt"
    exit 0
fi

# Detect no-op: if NONE of the key files mention billing_processor_id, this is no-op
NOOP_CHECK=$(grep -l "billing_processor_id" "$DIESEL_BP" "$DIESEL_SCHEMA" "$DOMAIN_BP" "$ROUTER_DB_EVENTS" 2>/dev/null | wc -l)
if [ "$NOOP_CHECK" -eq 0 ]; then
    echo "NO-OP DETECTED: no file mentions billing_processor_id"
    echo "0.0" > "$RESULTS_DIR/reward.txt"
    exit 0
fi

#############################################
# F2P GATES (behavioral). Total = 1.0
#############################################

###############################################################################
# G1 (0.15): Migration up.sql ADDs and down.sql DROPs billing_processor_id
###############################################################################
echo
echo "=== G1 (0.15): Migration up/down for billing_processor_id ==="
python3 - <<'PYEOF'
import os, re, sys
repo = os.environ['REPO']

def scan(root):
    if not os.path.isdir(root):
        return False
    for d in sorted(os.listdir(root)):
        full = os.path.join(root, d)
        up = os.path.join(full, 'up.sql')
        dn = os.path.join(full, 'down.sql')
        if not (os.path.isfile(up) and os.path.isfile(dn)):
            continue
        try:
            u = open(up, encoding='utf-8', errors='replace').read().lower()
            d_ = open(dn, encoding='utf-8', errors='replace').read().lower()
        except Exception:
            continue
        if ('billing_processor_id' in u and 'business_profile' in u
                and 'billing_processor_id' in d_ and 'business_profile' in d_):
            add_ok = re.search(r'add\s+column[^;]*billing_processor_id', u, re.S) is not None
            drop_ok = re.search(r'drop\s+column[^;]*billing_processor_id', d_, re.S) is not None
            if add_ok and drop_ok:
                print(f"OK migration at {full}")
                return True
    return False

ok = scan(os.path.join(repo, 'migrations')) or scan(os.path.join(repo, 'v2_compatible_migrations'))
sys.exit(0 if ok else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G1"; add_reward 0.15; else echo "FAIL G1"; fi

###############################################################################
# G2 (0.10): schema.rs declares billing_processor_id Nullable<Varchar> in
#            business_profile table block
###############################################################################
echo
echo "=== G2 (0.10): schema.rs business_profile has billing_processor_id ==="
python3 - <<'PYEOF'
import os, re, sys
src = open(os.environ['DIESEL_SCHEMA'], encoding='utf-8', errors='replace').read()
m = re.search(r'business_profile\s*\([^)]*\)\s*\{', src)
ok = False
if m:
    i = m.end() - 1
    depth = 0
    start = i + 1
    while i < len(src):
        c = src[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                block = src[start:i]
                ok = bool(re.search(r'billing_processor_id\s*->\s*Nullable\s*<\s*Varchar\s*>', block))
                break
        i += 1
sys.exit(0 if ok else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G2"; add_reward 0.10; else echo "FAIL G2"; fi

###############################################################################
# G3 (0.20): diesel_models business_profile.rs — Profile, ProfileNew,
#   ProfileUpdateInternal all declare billing_processor_id field.
###############################################################################
echo
echo "=== G3 (0.20): diesel_models structs all carry billing_processor_id ==="
python3 - <<'PYEOF'
import os, re, sys

src = open(os.environ['DIESEL_BP'], encoding='utf-8', errors='replace').read()

def find_struct_blocks(src, name):
    out = []
    pat = re.compile(r'\bstruct\s+' + re.escape(name) + r'\b[^{;]*\{', re.S)
    for m in pat.finditer(src):
        i = m.end() - 1
        depth = 0
        start = i + 1
        while i < len(src):
            c = src[i]
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    out.append(src[start:i])
                    break
            i += 1
    return out

def has_field(blocks, field):
    return any(re.search(r'\bpub\s+' + re.escape(field) + r'\s*:', b) for b in blocks)

profile_blocks = find_struct_blocks(src, 'Profile')
new_blocks = find_struct_blocks(src, 'ProfileNew')
upd_blocks = find_struct_blocks(src, 'ProfileUpdateInternal')

p_ok = has_field(profile_blocks, 'billing_processor_id')
n_ok = has_field(new_blocks, 'billing_processor_id')
u_ok = has_field(upd_blocks, 'billing_processor_id')

print(f"Profile.billing_processor_id={p_ok} ProfileNew={n_ok} ProfileUpdateInternal={u_ok}")
score = sum([p_ok, n_ok, u_ok])
# All three required for full pass
sys.exit(0 if score == 3 else (2 if score == 2 else 1))
PYEOF
RC=$?
if [ $RC -eq 0 ]; then echo "PASS G3"; add_reward 0.20
elif [ $RC -eq 2 ]; then echo "PARTIAL G3 (2/3)"; add_reward 0.10
else echo "FAIL G3"; fi

###############################################################################
# G4 (0.20): apply_changeset threading: in business_profile.rs, the
#   ProfileUpdateInternal::apply_changeset fn must (a) destructure
#   billing_processor_id from self AND (b) write it into the returned Profile,
#   using `.or(source.billing_processor_id)` semantics or direct assignment.
###############################################################################
echo
echo "=== G4 (0.20): apply_changeset threads billing_processor_id ==="
python3 - <<'PYEOF'
import os, re, sys

src = open(os.environ['DIESEL_BP'], encoding='utf-8', errors='replace').read()

def find_fn_blocks(src, name):
    out = []
    pat = re.compile(r'\bfn\s+' + re.escape(name) + r'\b[^{]*\{', re.S)
    for m in pat.finditer(src):
        i = m.end() - 1
        depth = 0
        start = i + 1
        while i < len(src):
            c = src[i]
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    out.append(src[start:i])
                    break
            i += 1
    return out

apply_blocks = find_fn_blocks(src, 'apply_changeset')

threaded_full = 0
for b in apply_blocks:
    if 'billing_processor_id' not in b:
        continue
    # Check destructure: `billing_processor_id,` somewhere in self destructure
    # AND assignment in returned Profile { ... billing_processor_id: ... }
    destruct = re.search(r'\bbilling_processor_id\s*,', b) is not None
    # assignment in Profile struct construction:
    assign = re.search(
        r'billing_processor_id\s*:\s*billing_processor_id(\s*\.or\s*\(\s*source\.billing_processor_id\s*\))?',
        b,
    ) is not None
    # also accept simple `billing_processor_id,` shorthand in struct literal
    shorthand = re.search(r'\bbilling_processor_id\s*,', b)
    if destruct and (assign or (shorthand and b.count('billing_processor_id') >= 2)):
        threaded_full += 1

print(f"apply_changeset blocks fully threaded: {threaded_full}/{len(apply_blocks)}")
sys.exit(0 if threaded_full >= 1 else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G4"; add_reward 0.20; else echo "FAIL G4"; fi

###############################################################################
# G5 (0.15): domain_models business_profile.rs Profile struct carries
#   billing_processor_id field of MerchantConnectorAccountId type.
###############################################################################
echo
echo "=== G5 (0.15): domain_models Profile carries billing_processor_id ==="
python3 - <<'PYEOF'
import os, re, sys

path = os.environ['DOMAIN_BP']
if not os.path.isfile(path):
    sys.exit(1)
src = open(path, encoding='utf-8', errors='replace').read()

# Look for billing_processor_id declared with MerchantConnectorAccountId type
m = re.search(
    r'\bpub\s+billing_processor_id\s*:\s*Option\s*<\s*[^>]*MerchantConnectorAccountId\s*>',
    src,
)
print(f"domain field found: {m is not None}")
sys.exit(0 if m else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G5"; add_reward 0.15; else echo "FAIL G5"; fi

###############################################################################
# G6 (0.10): events.rs Profile construction includes billing_processor_id: None
#   (or Some(...)) — i.e., it threads the new field through the kafka event
#   construction path so the codebase compiles.
###############################################################################
echo
echo "=== G6 (0.10): events.rs threads billing_processor_id ==="
python3 - <<'PYEOF'
import os, re, sys
src = open(os.environ['ROUTER_DB_EVENTS'], encoding='utf-8', errors='replace').read()
ok = re.search(r'billing_processor_id\s*:\s*\w', src) is not None
print(f"events.rs threading: {ok}")
sys.exit(0 if ok else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G6"; add_reward 0.10; else echo "FAIL G6"; fi

###############################################################################
# G7 (0.10): Completeness — file fan-out. A complete fix touches
#   migration + schema + diesel_models + domain_models + events. Reference
#   count: at least 4 of 5 critical files mention billing_processor_id.
###############################################################################
echo
echo "=== G7 (0.10): completeness (≥4/5 critical files mention field) ==="
python3 - <<'PYEOF'
import os, sys, glob

repo = os.environ['REPO']
files = [
    os.environ['DIESEL_SCHEMA'],
    os.environ['DIESEL_BP'],
    os.environ['DOMAIN_BP'],
    os.environ['ROUTER_DB_EVENTS'],
]

# migration counts as 5th
migration_ok = False
for root in [os.path.join(repo, 'migrations'), os.path.join(repo, 'v2_compatible_migrations')]:
    if not os.path.isdir(root):
        continue
    for d in os.listdir(root):
        full = os.path.join(root, d)
        up = os.path.join(full, 'up.sql')
        if os.path.isfile(up):
            try:
                if 'billing_processor_id' in open(up, encoding='utf-8', errors='replace').read():
                    migration_ok = True
                    break
            except Exception:
                pass
    if migration_ok:
        break

count = 1 if migration_ok else 0
for f in files:
    if not os.path.isfile(f):
        continue
    try:
        if 'billing_processor_id' in open(f, encoding='utf-8', errors='replace').read():
            count += 1
    except Exception:
        pass

print(f"critical files touched: {count}/5")
sys.exit(0 if count >= 4 else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G7"; add_reward 0.10; else echo "FAIL G7"; fi

#############################################
# Final
#############################################
echo
echo "=== FINAL REWARD: $REWARD ==="
echo "$REWARD" > "$RESULTS_DIR/reward.txt"

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
