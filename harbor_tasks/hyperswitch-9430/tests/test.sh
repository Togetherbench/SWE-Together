#!/bin/bash
set +e
#
# Verifier: Add billing_processor_id to business profile
#
# Strategy: Validate that the agent threaded `billing_processor_id` through
# every layer of the stack, end-to-end, in a way that would actually compile.
# We can't run cargo check (diesel OOMs), so we use AST-ish structural checks
# with cross-layer consistency requirements.
#
# Scoring tiers (total = 1.0):
#   F2P (behavioral, 0.65):
#     G1 (0.10) Migration up/down adds & drops column
#     G2 (0.10) Diesel schema declares column on business_profile
#     G3 (0.20) Diesel ORM: Profile + ProfileNew + ProfileUpdateInternal + apply_changeset threading
#     G4 (0.15) Domain model Profile struct + ProfileSetter wiring
#     G5 (0.10) API admin.rs: ProfileCreate/Update/Response have field + threading
#   P2P (regression, 0.15):
#     G6 (0.05) schema.rs still parses (business_profile block intact)
#     G7 (0.05) diesel business_profile.rs apply_changeset for v2 still consistent
#     G8 (0.05) router core admin.rs still compiles structurally (no broken braces)
#   Structural (0.20):
#     G9 (0.10) Router db/events.rs default-construct includes new field
#     G10(0.05) v2 schema OR v2 migration support (any of the two)
#     G11(0.05) Type used is Option<...> consistently across layers

REPO="/workspace/hyperswitch"
RESULTS_DIR="/logs/verifier"
mkdir -p "$RESULTS_DIR"

REWARD=0.0
add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.4f", a+b}')
}

# Auto-detect repo path
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
API_ADMIN="$REPO/crates/api_models/src/admin.rs"
ROUTER_ADMIN="$REPO/crates/router/src/core/admin.rs"
ROUTER_API_ADMIN="$REPO/crates/router/src/types/api/admin.rs"
ROUTER_DB_EVENTS="$REPO/crates/router/src/db/events.rs"

export DIESEL_BP DIESEL_SCHEMA DIESEL_SCHEMA_V2 DOMAIN_BP API_ADMIN ROUTER_ADMIN ROUTER_API_ADMIN ROUTER_DB_EVENTS

###############################################################################
# Helper python (sourced inline)
###############################################################################
read -r -d '' PY_HELPERS <<'PYHELP'
import os, re, sys

def read(p):
    try:
        return open(p, encoding='utf-8', errors='replace').read()
    except Exception:
        return ""

def find_struct_blocks(src, name):
    """Return list of struct body blocks (without enclosing braces) for `struct NAME`."""
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

def has_field(blocks, field):
    return any(re.search(r'\bpub\s+' + re.escape(field) + r'\s*:', b) for b in blocks)

def field_type(blocks, field):
    for b in blocks:
        m = re.search(r'\bpub\s+' + re.escape(field) + r'\s*:\s*([^,\n]+)', b)
        if m:
            return m.group(1).strip()
    return None

def braces_balanced(src):
    depth = 0
    in_str = False
    in_char = False
    in_line_cmt = False
    in_block_cmt = False
    i = 0
    while i < len(src):
        c = src[i]
        nxt = src[i+1] if i+1 < len(src) else ''
        if in_line_cmt:
            if c == '\n':
                in_line_cmt = False
        elif in_block_cmt:
            if c == '*' and nxt == '/':
                in_block_cmt = False
                i += 1
        elif in_str:
            if c == '\\':
                i += 1
            elif c == '"':
                in_str = False
        elif in_char:
            if c == '\\':
                i += 1
            elif c == "'":
                in_char = False
        else:
            if c == '/' and nxt == '/':
                in_line_cmt = True
                i += 1
            elif c == '/' and nxt == '*':
                in_block_cmt = True
                i += 1
            elif c == '"':
                in_str = True
            elif c == "'":
                # skip lifetime annotations heuristically: only treat as char if followed by char then '
                # not perfect but good enough
                pass
            elif c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth < 0:
                    return False
        i += 1
    return depth == 0
PYHELP

###############################################################################
# GATE 1 (F2P, 0.10): Migration up/down adds & drops column on business_profile
###############################################################################
echo
echo "=== GATE 1 (0.10): Migration adds & drops billing_processor_id ==="
python3 - <<PYEOF
$PY_HELPERS
import os, re, sys
repo = os.environ['REPO']

def find_mig(root):
    if not os.path.isdir(root):
        return None
    for d in sorted(os.listdir(root)):
        full = os.path.join(root, d)
        up = os.path.join(full, 'up.sql')
        dn = os.path.join(full, 'down.sql')
        if os.path.isfile(up) and os.path.isfile(dn):
            try:
                u = open(up).read().lower()
                d_ = open(dn).read().lower()
            except Exception:
                continue
            if ('billing_processor_id' in u and 'business_profile' in u
                    and 'billing_processor_id' in d_):
                return (up, dn, u, d_)
    return None

m = find_mig(os.path.join(repo, 'migrations'))
ok = False
if m:
    _, _, u, d_ = m
    add_ok = re.search(r'add\s+column.*billing_processor_id', u, re.S) is not None
    drop_ok = re.search(r'drop\s+column.*billing_processor_id', d_, re.S) is not None
    ok = add_ok and drop_ok
    print(f"add={add_ok} drop={drop_ok} dir={os.path.dirname(m[0])}")
else:
    print("no v1 migration found")
sys.exit(0 if ok else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G1"; add_reward 0.10; else echo "FAIL G1"; fi

###############################################################################
# GATE 2 (F2P, 0.10): schema.rs declares column on business_profile
###############################################################################
echo
echo "=== GATE 2 (0.10): schema.rs declares billing_processor_id Nullable<Varchar> ==="
python3 - <<PYEOF
$PY_HELPERS
import re, sys, os
src = read(os.environ['DIESEL_SCHEMA'])
# find table macro for business_profile
m = re.search(r'business_profile\s*\([^)]*\)\s*\{', src)
ok = False
if m:
    i = m.end() - 1
    depth = 0
    start = i + 1
    while i < len(src):
        c = src[i]
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                block = src[start:i]
                ok = bool(re.search(r'billing_processor_id\s*->\s*Nullable<\s*Varchar\s*>', block))
                break
        i += 1
print(f"declared={ok}")
sys.exit(0 if ok else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G2"; add_reward 0.10; else echo "FAIL G2"; fi

###############################################################################
# GATE 3 (F2P, 0.20): Diesel ORM full propagation in business_profile.rs
###############################################################################
echo
echo "=== GATE 3 (0.20): Diesel ORM Profile/ProfileNew/ProfileUpdateInternal + apply_changeset ==="
python3 - <<PYEOF
$PY_HELPERS
import re, sys, os
src = read(os.environ['DIESEL_BP'])
if not src:
    print("missing"); sys.exit(2)

profile = find_struct_blocks(src, 'Profile')
profile_new = find_struct_blocks(src, 'ProfileNew')
update_internal = find_struct_blocks(src, 'ProfileUpdateInternal')

f = 'billing_processor_id'
p_ok = has_field(profile, f)
pn_ok = has_field(profile_new, f)
ui_ok = has_field(update_internal, f)

# apply_changeset must destructure the field AND assign it back to Profile
apply_blocks = find_fn_blocks(src, 'apply_changeset')
apply_ok_count = 0
for b in apply_blocks:
    has_destr = re.search(r'\b' + f + r'\s*[,}\n]', b) is not None
    has_assign = re.search(r'\b' + f + r'\s*:\s*[A-Za-z_]', b) is not None
    if has_destr and has_assign:
        apply_ok_count += 1

# We expect at least one apply_changeset properly threaded (v1 minimum).
apply_ok = apply_ok_count >= 1

print(f"Profile={p_ok} ProfileNew={pn_ok} ProfileUpdateInternal={ui_ok} apply_blocks={len(apply_blocks)} apply_threaded={apply_ok_count}")

full = p_ok and pn_ok and ui_ok and apply_ok
partial = p_ok and (pn_ok or ui_ok)
if full:
    sys.exit(0)
elif partial:
    sys.exit(3)
else:
    sys.exit(1)
PYEOF
G3=$?
if [ $G3 -eq 0 ]; then
    echo "PASS G3 (full)"; add_reward 0.20
elif [ $G3 -eq 3 ]; then
    echo "PARTIAL G3"; add_reward 0.10
else
    echo "FAIL G3"
fi

###############################################################################
# GATE 4 (F2P, 0.15): Domain model Profile + ProfileSetter wiring
###############################################################################
echo
echo "=== GATE 4 (0.15): Domain Profile + setter/From wiring ==="
python3 - <<PYEOF
$PY_HELPERS
import re, sys, os
src = read(os.environ['DOMAIN_BP'])
if not src:
    print("missing"); sys.exit(1)
f = 'billing_processor_id'

profile = find_struct_blocks(src, 'Profile')
setter = find_struct_blocks(src, 'ProfileSetter')

p_ok = has_field(profile, f)
s_ok = has_field(setter, f)

# Look for `From<ProfileSetter> for Profile` impls — they should mention the field
from_setter_ok = False
for m in re.finditer(r'impl\s+From<ProfileSetter>\s+for\s+Profile\s*\{', src):
    i = m.end() - 1
    depth = 0
    start = i + 1
    while i < len(src):
        c = src[i]
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                blk = src[start:i]
                if re.search(r'\b' + f + r'\b', blk):
                    from_setter_ok = True
                break
        i += 1

# Also accept domain Profile sets the field via direct construction in any conversion fn
construct_ok = False
for m in re.finditer(r'\bProfile\s*\{', src):
    i = m.end() - 1
    depth = 0
    start = i + 1
    while i < len(src):
        c = src[i]
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                blk = src[start:i]
                if re.search(r'\b' + f + r'\s*[:,}]', blk):
                    construct_ok = True
                    break
                break
        i += 1
    if construct_ok:
        break

print(f"domain_Profile={p_ok} ProfileSetter={s_ok} From_setter={from_setter_ok} any_construct={construct_ok}")

# Full credit: domain Profile has field AND it's threaded somewhere (setter or construction)
full = p_ok and (s_ok or from_setter_ok or construct_ok)
partial = p_ok or s_ok
if full:
    sys.exit(0)
elif partial:
    sys.exit(3)
else:
    sys.exit(1)
PYEOF
G4=$?
if [ $G4 -eq 0 ]; then
    echo "PASS G4"; add_reward 0.15
elif [ $G4 -eq 3 ]; then
    echo "PARTIAL G4"; add_reward 0.07
else
    echo "FAIL G4"
fi

###############################################################################
# GATE 5 (F2P, 0.10): API admin.rs ProfileCreate/Update/Response
###############################################################################
echo
echo "=== GATE 5 (0.10): api_models admin.rs ProfileCreate/Update/Response ==="
python3 - <<PYEOF
$PY_HELPERS
import re, sys, os
src = read(os.environ['API_ADMIN'])
if not src:
    print("missing"); sys.exit(1)
f = 'billing_processor_id'

create = find_struct_blocks(src, 'ProfileCreate')
update = find_struct_blocks(src, 'ProfileUpdate')
resp = find_struct_blocks(src, 'ProfileResponse')

c_ok = has_field(create, f)
u_ok = has_field(update, f)
r_ok = has_field(resp, f)

print(f"ProfileCreate={c_ok} ProfileUpdate={u_ok} ProfileResponse={r_ok}")

count = sum([c_ok, u_ok, r_ok])
if count >= 3:
    sys.exit(0)
elif count >= 2:
    sys.exit(3)
elif count >= 1:
    sys.exit(4)
else:
    sys.exit(1)
PYEOF
G5=$?
case $G5 in
    0) echo "PASS G5 (full)"; add_reward 0.10 ;;
    3) echo "PARTIAL G5 (2/3)"; add_reward 0.07 ;;
    4) echo "PARTIAL G5 (1/3)"; add_reward 0.03 ;;
    *) echo "FAIL G5" ;;
esac

###############################################################################
# GATE 6 (P2P, 0.05): schema.rs business_profile block braces balanced
###############################################################################
echo
echo "=== GATE 6 (0.05, P2P): schema.rs braces balanced ==="
python3 - <<PYEOF
$PY_HELPERS
import sys, os
src = read(os.environ['DIESEL_SCHEMA'])
ok = bool(src) and braces_balanced(src)
print(f"balanced={ok}")
sys.exit(0 if ok else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G6"; add_reward 0.05; else echo "FAIL G6"; fi

###############################################################################
# GATE 7 (P2P, 0.05): diesel business_profile.rs apply_changeset structural sanity
###############################################################################
echo
echo "=== GATE 7 (0.05, P2P): diesel business_profile.rs structural sanity ==="
python3 - <<PYEOF
$PY_HELPERS
import sys, os, re
src = read(os.environ['DIESEL_BP'])
if not src:
    print("missing"); sys.exit(1)

balanced = braces_balanced(src)

# Each apply_changeset must destructure all fields it then constructs Profile with.
# Heuristic: count occurrences of `billing_processor_id` should be balanced (>=2 per apply impl threading)
apply_blocks = find_fn_blocks(src, 'apply_changeset')
inconsistent = 0
for b in apply_blocks:
    destr = re.search(r'let\s+Self\s*\{', b)
    if destr and 'billing_processor_id' in b:
        # count: must appear at least twice (destructure + assign) when present
        n = b.count('billing_processor_id')
        if n < 2:
            inconsistent += 1

ok = balanced and inconsistent == 0
print(f"balanced={balanced} inconsistent_apply={inconsistent}")
sys.exit(0 if ok else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G7"; add_reward 0.05; else echo "FAIL G7"; fi

###############################################################################
# GATE 8 (P2P, 0.05): router core admin.rs braces balanced
###############################################################################
echo
echo "=== GATE 8 (0.05, P2P): router core admin.rs balanced ==="
python3 - <<PYEOF
$PY_HELPERS
import sys, os
src = read(os.environ['ROUTER_ADMIN'])
ok = bool(src) and braces_balanced(src)
print(f"balanced={ok}")
sys.exit(0 if ok else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G8"; add_reward 0.05; else echo "FAIL G8"; fi

###############################################################################
# GATE 9 (Structural, 0.10): db/events.rs default-construct includes new field
###############################################################################
echo
echo "=== GATE 9 (0.10): router db/events.rs default-construct includes field ==="
python3 - <<PYEOF
$PY_HELPERS
import sys, os, re
src = read(os.environ['ROUTER_DB_EVENTS'])
if not src:
    print("missing"); sys.exit(1)
# Anywhere this file constructs a domain::Profile (or Profile { ... }) it should include the field
ok = False
# find every Profile { ... } literal
for m in re.finditer(r'\bProfile\s*\{', src):
    i = m.end() - 1
    depth = 0
    start = i + 1
    while i < len(src):
        c = src[i]
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                blk = src[start:i]
                if 'billing_processor_id' in blk:
                    ok = True
                break
        i += 1
    if ok:
        break

# If no Profile literal exists in this file (maybe restructured), don't fail hard — accept if any reference
if not ok and 'billing_processor_id' in src:
    ok = True

print(f"events_field_present={ok}")
sys.exit(0 if ok else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G9"; add_reward 0.10; else echo "FAIL G9"; fi

###############################################################################
# GATE 10 (Structural, 0.05): v2 schema OR v2 migration support
###############################################################################
echo
echo "=== GATE 10 (0.05): v2 schema or v2 migration includes column ==="
python3 - <<PYEOF
$PY_HELPERS
import sys, os, re
repo = os.environ['REPO']
ok = False

# v2 schema check
v2 = read(os.environ['DIESEL_SCHEMA_V2'])
if v2:
    m = re.search(r'business_profile\s*\([^)]*\)\s*\{', v2)
    if m:
        i = m.end() - 1
        depth = 0
        start = i + 1
        while i < len(v2):
            c = v2[i]
            if c == '{': depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    blk = v2[start:i]
                    if re.search(r'billing_processor_id\s*->\s*Nullable<\s*Varchar\s*>', blk):
                        ok = True
                    break
            i += 1

# v2 migrations dir
if not ok:
    v2_mig = os.path.join(repo, 'v2_compatible_migrations')
    if os.path.isdir(v2_mig):
        for d in sorted(os.listdir(v2_mig)):
            up = os.path.join(v2_mig, d, 'up.sql')
            if os.path.isfile(up):
                u = open(up).read().lower()
                if 'billing_processor_id' in u and 'business_profile' in u:
                    ok = True
                    break

print(f"v2_support={ok}")
sys.exit(0 if ok else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G10"; add_reward 0.05; else echo "FAIL G10"; fi

###############################################################################
# GATE 11 (Structural, 0.05): Type used is Option<...> across ORM + domain + API
###############################################################################
echo
echo "=== GATE 11 (0.05): Type is Option<...> consistently ==="
python3 - <<PYEOF
$PY_HELPERS
import sys, os, re

def is_optional_in(path, struct_names):
    src = read(path)
    if not src:
        return None
    for name in struct_names:
        for blk in find_struct_blocks(src, name):
            t = field_type([blk], 'billing_processor_id')
            if t:
                return t.startswith('Option<')
    return None

orm_ok = is_optional_in(os.environ['DIESEL_BP'], ['Profile', 'ProfileNew', 'ProfileUpdateInternal'])
domain_ok = is_optional_in(os.environ['DOMAIN_BP'], ['Profile', 'ProfileSetter'])
api_ok = is_optional_in(os.environ['API_ADMIN'], ['ProfileCreate', 'ProfileUpdate', 'ProfileResponse'])

# None means field not found at all -> treat as fail; True means optional; False means non-optional (would break null inserts)
results = [orm_ok, domain_ok, api_ok]
print(f"orm_opt={orm_ok} domain_opt={domain_ok} api_opt={api_ok}")

# Pass if at least 2 layers explicitly use Option<...>
true_count = sum(1 for r in results if r is True)
false_count = sum(1 for r in results if r is False)
ok = true_count >= 2 and false_count == 0
sys.exit(0 if ok else 1)
PYEOF
if [ $? -eq 0 ]; then echo "PASS G11"; add_reward 0.05; else echo "FAIL G11"; fi

###############################################################################
# Final
###############################################################################
echo
echo "============================================="
echo "FINAL REWARD: $REWARD"
echo "============================================="
echo "$REWARD" > /logs/verifier/reward.txt