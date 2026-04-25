#!/bin/bash
set +e

REPO="/workspace/hyperswitch"
RESULTS_DIR="/logs/verifier"
mkdir -p "$RESULTS_DIR"

REWARD=0.0
add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.4f", a+b}')
}

if [ ! -d "$REPO/crates/diesel_models" ]; then
    for cand in /workspace/hyperswitch /workspace/repo /workspace/*/; do
        if [ -d "${cand%/}/crates/diesel_models" ]; then
            REPO="${cand%/}"
            break
        fi
    done
fi

export REPO
echo "REPO=$REPO"

DIESEL_BP="$REPO/crates/diesel_models/src/business_profile.rs"
DIESEL_SCHEMA="$REPO/crates/diesel_models/src/schema.rs"
DIESEL_SCHEMA_V2="$REPO/crates/diesel_models/src/schema_v2.rs"
DOMAIN_BP="$REPO/crates/hyperswitch_domain_models/src/business_profile.rs"
ROUTER_DB_EVENTS="$REPO/crates/router/src/db/events.rs"

export DIESEL_BP DIESEL_SCHEMA DIESEL_SCHEMA_V2 DOMAIN_BP ROUTER_DB_EVENTS

#############################################
# P2P GATES (regression guards) — must pass on base AND fix
#############################################

# Required source files exist
for f in "$DIESEL_BP" "$DIESEL_SCHEMA" "$DOMAIN_BP" "$ROUTER_DB_EVENTS"; do
    if [ ! -f "$f" ]; then
        echo "P2P FAIL: missing $f"
        echo "0.0" > "$RESULTS_DIR/reward.txt"
        exit 0
    fi
done

# business_profile table block must still exist in schema.rs
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

#############################################
# F2P GATES (behavioral — must FAIL on no-op buggy base, PASS on fix)
# Total weight: 1.0
#############################################

###############################################################################
# G1 (0.20): Migration file adds AND drops billing_processor_id on business_profile
###############################################################################
echo
echo "=== G1 (0.20): Migration up/down for billing_processor_id ==="
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
if [ $? -eq 0 ]; then echo "PASS G1"; add_reward 0.20; else echo "FAIL G1"; fi

###############################################################################
# G2 (0.10): schema.rs declares billing_processor_id on business_profile table
###############################################################################
echo
echo "=== G2 (0.10): schema.rs declares billing_processor_id ==="
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
# G3 (0.25): diesel_models business_profile.rs — Profile + ProfileNew +
#   ProfileUpdateInternal all carry billing_processor_id AND apply_changeset
#   threads it from Self destructure into the Profile result.
###############################################################################
echo
echo "=== G3 (0.25): diesel_models Profile/ProfileNew/ProfileUpdateInternal threading ==="
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

# Need at least one struct of each kind to carry billing_processor_id
profile_blocks = find_struct_blocks(src, 'Profile')
new_blocks = find_struct_blocks(src, 'ProfileNew')
upd_blocks = find_struct_blocks(src, 'ProfileUpdateInternal')

p_ok = has_field(profile_blocks, 'billing_processor_id')
n_ok = has_field(new_blocks, 'billing_processor_id')
u_ok = has_field(upd_blocks, 'billing_processor_id')

# apply_changeset threading: must reference billing_processor_id inside an apply_changeset fn body
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
threaded = sum(1 for b in apply_blocks if 'billing_processor_id' in b)
# At least one apply_changeset body should mention billing_processor_id
apply_ok = threaded >= 1

print(f"profile={p_ok} new={n_ok} upd={u_ok} apply_threaded={threaded}")
sys.exit(0 if (p_ok and n_ok and u_ok and apply_ok) else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G3"; add_reward 0.25; else echo "FAIL G3"; fi

###############################################################################
# G4 (0.20): Domain model — Profile struct carries billing_processor_id AND
#   ProfileSetter (or From<ProfileSetter> impl) sets it through.
###############################################################################
echo
echo "=== G4 (0.20): domain Profile + setter threading ==="
python3 - <<'PYEOF'
import os, re, sys

src = open(os.environ['DOMAIN_BP'], encoding='utf-8', errors='replace').read()

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
    return any(re.search(r'\bpub(\s+)?' + re.escape(field) + r'\s*:', b) for b in blocks)

profile_blocks = find_struct_blocks(src, 'Profile')
setter_blocks = find_struct_blocks(src, 'ProfileSetter')

profile_has = has_field(profile_blocks, 'billing_processor_id')
# Either ProfileSetter has the field, or somewhere there's `billing_processor_id:` inside a From<ProfileSetter> impl block.
setter_has = has_field(setter_blocks, 'billing_processor_id')

# Count occurrences of billing_processor_id in this file - must be at least 2 (struct + setter/wiring)
total_occurrences = len(re.findall(r'\bbilling_processor_id\b', src))

print(f"profile_has={profile_has} setter_has={setter_has} total_occurrences={total_occurrences}")
ok = profile_has and setter_has and total_occurrences >= 3
sys.exit(0 if ok else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G4"; add_reward 0.20; else echo "FAIL G4"; fi

###############################################################################
# G5 (0.15): API admin.rs — ProfileCreate/Update/Response carry the field
###############################################################################
echo
echo "=== G5 (0.15): api_models admin.rs ProfileCreate/Update/Response ==="
python3 - <<'PYEOF'
import os, re, sys

api_admin = os.path.join(os.environ['REPO'], 'crates/api_models/src/admin.rs')
if not os.path.isfile(api_admin):
    sys.exit(1)
src = open(api_admin, encoding='utf-8', errors='replace').read()

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
    return any(re.search(r'\b' + re.escape(field) + r'\s*:', b) for b in blocks)

create_blocks = find_struct_blocks(src, 'ProfileCreate')
update_blocks = find_struct_blocks(src, 'ProfileUpdate')
response_blocks = find_struct_blocks(src, 'ProfileResponse')

c_ok = has_field(create_blocks, 'billing_processor_id')
u_ok = has_field(update_blocks, 'billing_processor_id')
r_ok = has_field(response_blocks, 'billing_processor_id')

print(f"create={c_ok} update={u_ok} response={r_ok}")
# Require at least 2 of the 3 (some implementations may skip update or response)
hits = sum([c_ok, u_ok, r_ok])
sys.exit(0 if hits >= 2 else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G5"; add_reward 0.15; else echo "FAIL G5"; fi

###############################################################################
# G6 (0.10): router/src/db/events.rs default-construct includes billing_processor_id
###############################################################################
echo
echo "=== G6 (0.10): router db/events.rs default-construct includes new field ==="
python3 - <<'PYEOF'
import os, re, sys
src = open(os.environ['ROUTER_DB_EVENTS'], encoding='utf-8', errors='replace').read()
ok = bool(re.search(r'billing_processor_id\s*:\s*None', src))
sys.exit(0 if ok else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G6"; add_reward 0.10; else echo "FAIL G6"; fi

#############################################
# Final
#############################################
echo
echo "=================================="
echo "FINAL REWARD: $REWARD"
echo "=================================="
echo "$REWARD" > "$RESULTS_DIR/reward.txt"