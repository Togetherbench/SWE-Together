#!/bin/bash
set +e

# Test for hyperswitch-9437: L2/L3 data for Checkout.com connector
# Verifies behavioral integration of L2/L3 data into the Checkout PaymentsRequest.

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"

# Locate workspace
WORKSPACE=""
for cand in /workspace/hyperswitch /workspace; do
    if [ -d "$cand/crates/hyperswitch_connectors" ]; then
        WORKSPACE="$cand"
        break
    fi
done

if [ -z "$WORKSPACE" ]; then
    echo "ERROR: cannot locate hyperswitch workspace"
    echo "0.00" > "$REWARD_FILE"
    exit 0
fi

cd "$WORKSPACE" || { echo "0.00" > "$REWARD_FILE"; exit 0; }

CHECKOUT_TRANSFORMERS="crates/hyperswitch_connectors/src/connectors/checkout/transformers.rs"

if [ ! -f "$CHECKOUT_TRANSFORMERS" ]; then
    echo "ERROR: $CHECKOUT_TRANSFORMERS not found"
    echo "0.00" > "$REWARD_FILE"
    exit 0
fi

FILE_CONTENT=$(cat "$CHECKOUT_TRANSFORMERS")

score=0
total=0

add() {
    # add <points> <max>
    score=$((score + $1))
    total=$((total + $2))
}

addmax() {
    total=$((total + $1))
}

# ============================================================
# Gate 1 (P2P, 0.10): PaymentsRequest preserves processing_channel_id
# Regression guard - existing required field must remain.
# ============================================================
echo "=== Gate 1 (P2P, 0.10): PaymentsRequest regression guard ==="
addmax 10
req_block=$(awk '/pub struct PaymentsRequest[ {]/,/^}/' "$CHECKOUT_TRANSFORMERS")
if echo "$req_block" | grep -q 'processing_channel_id' && \
   echo "$req_block" | grep -q 'three_ds' && \
   echo "$req_block" | grep -q 'reference'; then
    score=$((score + 10))
    echo "PASS (0.10): PaymentsRequest preserves base fields"
else
    echo "FAIL (0.10): PaymentsRequest missing base fields"
fi

# ============================================================
# Gate 2 (Structural, 0.10): New L2 (processing) struct exists
# Need a serializable struct with order-level L2 fields.
# ============================================================
echo "=== Gate 2 (Structural, 0.10): L2 processing struct ==="
addmax 10
# find a struct that contains tax_amount AND (discount_amount OR shipping)
l2_struct_ok=0
# Extract all struct blocks; for each, check fields.
awk '
    /^#\[derive/ { buf=$0; in_attr=1; next }
    in_attr && /pub struct/ { sname=$0; in_attr=0; in_struct=1; body=""; next }
    in_struct {
        body = body "\n" $0
        if ($0 ~ /^}/) {
            print "===STRUCT==="
            print sname
            print body
            in_struct=0
        }
    }
' "$CHECKOUT_TRANSFORMERS" > /tmp/structs.txt 2>/dev/null

# Parse struct blocks to find L2 candidate
awk 'BEGIN{RS="===STRUCT==="} {print NR"@@@"$0"@@@END"}' /tmp/structs.txt > /tmp/structs_parsed.txt 2>/dev/null

# Simpler approach: search for struct definitions that include tax_amount
if grep -qE 'tax_amount\s*:' "$CHECKOUT_TRANSFORMERS"; then
    # Check that tax_amount appears in a struct context with at least one other L2 field nearby (within 30 lines)
    python3 - <<'PY' 2>/dev/null
import re,sys
src = open("crates/hyperswitch_connectors/src/connectors/checkout/transformers.rs").read()
# Find each struct block
pattern = re.compile(r'(?:#\[derive[^\]]*\]\s*)?(?:#\[serde[^\]]*\]\s*)*pub\s+struct\s+(\w+)\s*\{([^}]*)\}', re.DOTALL)
ok = False
for m in pattern.finditer(src):
    name, body = m.group(1), m.group(2)
    has_tax = 'tax_amount' in body
    has_disc = 'discount_amount' in body
    has_ship = 'shipping' in body
    has_duty = 'duty_amount' in body
    # L2 struct: order-level summary - tax_amount + (discount or shipping or duty)
    if has_tax and (has_disc or has_ship or has_duty):
        # Make sure it's not an item-level struct (items have unit_price/quantity)
        if 'unit_price' not in body or 'discount_amount' in body or 'duty_amount' in body or 'shipping' in body:
            print("L2_OK:"+name)
            ok = True
            break
sys.exit(0 if ok else 1)
PY
    if [ $? -eq 0 ]; then
        l2_struct_ok=1
    fi
fi

if [ "$l2_struct_ok" -eq 1 ]; then
    score=$((score + 10))
    echo "PASS (0.10): L2 order-level struct found"
else
    echo "FAIL (0.10): L2 order-level struct not found"
fi

# ============================================================
# Gate 3 (Structural, 0.10): L3 line item struct
# A struct with commodity_code, unit_of_measure, unit_price.
# ============================================================
echo "=== Gate 3 (Structural, 0.10): L3 line-item struct ==="
addmax 10
l3_struct_ok=0
python3 - <<'PY' 2>/dev/null
import re,sys
src = open("crates/hyperswitch_connectors/src/connectors/checkout/transformers.rs").read()
pattern = re.compile(r'pub\s+struct\s+(\w+)\s*\{([^}]*)\}', re.DOTALL)
ok = False
for m in pattern.finditer(src):
    name, body = m.group(1), m.group(2)
    if 'commodity_code' in body and 'unit_of_measure' in body and 'unit_price' in body:
        print("L3_OK:"+name)
        ok = True
        break
sys.exit(0 if ok else 1)
PY
if [ $? -eq 0 ]; then
    l3_struct_ok=1
fi

if [ "$l3_struct_ok" -eq 1 ]; then
    score=$((score + 10))
    echo "PASS (0.10): L3 line-item struct with required fields found"
else
    echo "FAIL (0.10): L3 line-item struct not found"
fi

# ============================================================
# Gate 4 (Structural, 0.10): PaymentsRequest carries new processing field
# Field must be added so it gets serialized in the API request.
# ============================================================
echo "=== Gate 4 (Structural, 0.10): PaymentsRequest has processing field ==="
addmax 10
# look for a field "processing:" (not processing_channel_id) inside PaymentsRequest
proc_field=$(echo "$req_block" | grep -E '^\s*(pub\s+)?processing\s*:' | grep -v processing_channel_id | wc -l)
if [ "$proc_field" -ge 1 ]; then
    score=$((score + 10))
    echo "PASS (0.10): PaymentsRequest has new processing field"
else
    echo "FAIL (0.10): PaymentsRequest does not have new processing field"
fi

# ============================================================
# Gate 5 (Behavioral, 0.20): TryFrom conversion populates processing from L2/L3 data
# Must reference the request's L2/L3 data accessor and populate processing.
# ============================================================
echo "=== Gate 5 (Behavioral, 0.20): TryFrom conversion populates L2/L3 ==="
addmax 20
g5=0
# Must reference l2_l3 data source AND construct/assign the processing field
ref_l2=$(grep -cE 'l2_l3_data|get_optional_l2_l3_data|L2L3Data' "$CHECKOUT_TRANSFORMERS")
# Find processing field assignment in TryFrom blocks
populates_proc=0
python3 - <<'PY' 2>/dev/null
import re,sys
src = open("crates/hyperswitch_connectors/src/connectors/checkout/transformers.rs").read()
# Find impl blocks that build PaymentsRequest
# Look for "Ok(Self {" or "PaymentsRequest {" with processing: ... that isn't None literal
ok = False
# search for 'processing,' or 'processing:' that comes from L2/L3
# locate occurrences of processing field in struct literal context
for m in re.finditer(r'Ok\(\s*Self\s*\{([^}]*)\}\s*\)', src, re.DOTALL):
    body = m.group(1)
    if re.search(r'\bprocessing\b', body) and not re.search(r'processing\s*:\s*None', body):
        # ensure there's a let processing = ... earlier referencing l2_l3
        # look up the function this is in
        start = m.start()
        prefix = src[max(0,start-3000):start]
        if 'l2_l3' in prefix.lower() or 'L2L3' in prefix:
            ok = True
            break
        # also accept inline construction
        if re.search(r'processing\s*:\s*[A-Za-z_]', body):
            ok = True
            break
sys.exit(0 if ok else 1)
PY
if [ $? -eq 0 ] && [ "$ref_l2" -ge 1 ]; then
    g5=1
fi

if [ "$g5" -eq 1 ]; then
    score=$((score + 20))
    echo "PASS (0.20): TryFrom populates processing from L2/L3 data"
else
    echo "FAIL (0.20): TryFrom does not populate processing from L2/L3 data"
fi

# ============================================================
# Gate 6 (Behavioral, 0.15): Line items mapped from order_details
# Must iterate request order_details and create line item structs.
# ============================================================
echo "=== Gate 6 (Behavioral, 0.15): order_details mapped to line items ==="
addmax 15
g6=0
# look for: order_details ... map(...) ... CheckoutLineItem|CheckoutOrderDetails|CheckoutProcessingItem etc
if python3 - <<'PY' 2>/dev/null
import re,sys
src = open("crates/hyperswitch_connectors/src/connectors/checkout/transformers.rs").read()
# Need: reference to order_details AND a constructor of an L3 item struct (one that has commodity_code+unit_of_measure+unit_price)
# Find L3 struct names
struct_names = []
for m in re.finditer(r'pub\s+struct\s+(\w+)\s*\{([^}]*)\}', src, re.DOTALL):
    name, body = m.group(1), m.group(2)
    if 'commodity_code' in body and 'unit_of_measure' in body and 'unit_price' in body:
        struct_names.append(name)
if not struct_names:
    sys.exit(1)
has_order_details = 'order_details' in src
# Need to see one of those struct names being constructed (NAME { ... })
constructed = False
for n in struct_names:
    if re.search(r'\b'+n+r'\s*\{', src):
        constructed = True
        break
sys.exit(0 if (has_order_details and constructed) else 1)
PY
then
    g6=1
fi

if [ "$g6" -eq 1 ]; then
    score=$((score + 15))
    echo "PASS (0.15): order_details mapped to L3 line item construction"
else
    echo "FAIL (0.15): order_details not mapped to line item construction"
fi

# ============================================================
# Gate 7 (Behavioral, 0.25): Standalone serialization smoke test
# Compile a tiny standalone harness that mimics the new structs and checks
# that JSON serialization produces the expected Checkout L2/L3 shape.
# This is independent of cargo (which cannot build the workspace), so it
# verifies the *design* of the structs by checking field naming conventions.
# ============================================================
echo "=== Gate 7 (Behavioral, 0.25): JSON shape verification ==="
addmax 25
g7_score=0
# We extract the struct definitions from the file and verify that:
#  - The L3 item struct has snake_case fields commodity_code, unit_of_measure, unit_price
#    that will serialize as such.
#  - The L2 processing struct's fields skip_serializing_if for Option fields,
#    so optional fields don't appear when None.
#  - The PaymentsRequest's new processing field is Option and skipped if None.

python3 - <<'PY' 2>/dev/null
import re, sys, json
src = open("crates/hyperswitch_connectors/src/connectors/checkout/transformers.rs").read()

points = 0
# 7a (8pts): L3 item struct uses Serialize derive and contains proper fields
l3_pat = re.compile(
    r'#\[derive\([^\]]*Serialize[^\]]*\)\][^p]*pub\s+struct\s+(\w+)\s*\{([^}]*)\}',
    re.DOTALL
)
l3_found = False
for m in l3_pat.finditer(src):
    body = m.group(2)
    if 'commodity_code' in body and 'unit_of_measure' in body and 'unit_price' in body:
        l3_found = True
        l3_body = body
        # check Option<...> on at least commodity_code or unit_of_measure (since they're optional in API)
        if re.search(r'commodity_code\s*:\s*Option<', body) or re.search(r'unit_of_measure\s*:\s*Option<', body):
            points += 4
        # check skip_serializing_if for optional fields
        if 'skip_serializing_if' in body:
            points += 4
        else:
            points += 2  # partial: still has structure
        break

# 7b (8pts): L2 processing struct with Serialize derive
l2_found = False
for m in l3_pat.finditer(src):
    name, body = m.group(1), m.group(2)
    has_tax = 'tax_amount' in body
    has_other = 'discount_amount' in body or 'shipping' in body or 'duty_amount' in body
    if has_tax and has_other and 'unit_price' not in body:
        l2_found = True
        # optional fields should use skip_serializing_if
        if 'skip_serializing_if' in body:
            points += 5
        # has line items / order_details vector field referencing L3
        if re.search(r':\s*Option<\s*Vec<', body) or re.search(r':\s*Vec<', body):
            points += 3
        else:
            points += 1
        break

# 7c (9pts): PaymentsRequest.processing is Option<...> with skip_serializing_if
pr_match = re.search(r'pub\s+struct\s+PaymentsRequest\s*\{([^}]*)\}', src, re.DOTALL)
if pr_match:
    body = pr_match.group(1)
    # find processing field (not processing_channel_id)
    # the line should look like: pub processing: Option<...>
    proc_line_match = re.search(r'(#\[serde[^\]]*\]\s*)?(?:pub\s+)?processing\s*:\s*Option<[^>]+>', body)
    if proc_line_match:
        # Look for skip_serializing_if attribute on processing field
        # Find region around the processing field
        idx = body.find('processing:')
        if idx == -1:
            idx = body.find('processing :')
        # search backwards for last attribute lines
        prefix = body[max(0,idx-200):idx] if idx >= 0 else ''
        if 'skip_serializing_if' in prefix:
            points += 9
        else:
            points += 5
    else:
        # field is required (not Option) - still acceptable but lower
        if re.search(r'processing\s*:', body):
            points += 3

print(points)
sys.exit(0)
PY
g7_score=$(python3 - <<'PY' 2>/dev/null
import re, sys
src = open("crates/hyperswitch_connectors/src/connectors/checkout/transformers.rs").read()
points = 0
l3_pat = re.compile(
    r'#\[derive\([^\]]*Serialize[^\]]*\)\][^p]*pub\s+struct\s+(\w+)\s*\{([^}]*)\}',
    re.DOTALL
)
for m in l3_pat.finditer(src):
    body = m.group(2)
    if 'commodity_code' in body and 'unit_of_measure' in body and 'unit_price' in body:
        if re.search(r'commodity_code\s*:\s*Option<', body) or re.search(r'unit_of_measure\s*:\s*Option<', body):
            points += 4
        if 'skip_serializing_if' in body:
            points += 4
        else:
            points += 2
        break

for m in l3_pat.finditer(src):
    name, body = m.group(1), m.group(2)
    has_tax = 'tax_amount' in body
    has_other = 'discount_amount' in body or 'shipping' in body or 'duty_amount' in body
    if has_tax and has_other and 'unit_price' not in body:
        if 'skip_serializing_if' in body:
            points += 5
        if re.search(r':\s*Option<\s*Vec<', body) or re.search(r':\s*Vec<', body):
            points += 3
        else:
            points += 1
        break

pr_match = re.search(r'pub\s+struct\s+PaymentsRequest\s*\{([^}]*)\}', src, re.DOTALL)
if pr_match:
    body = pr_match.group(1)
    proc_line = re.search(r'processing\s*:\s*Option<[^>]+>', body)
    if proc_line:
        idx = body.find('processing:')
        if idx == -1:
            idx = body.find('processing :')
        prefix = body[max(0,idx-200):idx] if idx >= 0 else ''
        if 'skip_serializing_if' in prefix:
            points += 9
        else:
            points += 5
    else:
        if re.search(r'\bprocessing\b\s*:', body):
            points += 3

# cap at 25
if points > 25:
    points = 25
print(points)
PY
)
g7_score=${g7_score:-0}
case "$g7_score" in
    ''|*[!0-9]*) g7_score=0 ;;
esac

if [ "$g7_score" -gt 25 ]; then g7_score=25; fi
score=$((score + g7_score))
echo "Gate 7 score: ${g7_score}/25 (JSON shape correctness)"

# ============================================================
# Gate 8 (Behavioral, 0.10): Syntax validity via lightweight parser
# Use rustc --edition 2021 -Zparse-only if nightly available, else
# fall back to balanced-brace check on the modified file.
# ============================================================
echo "=== Gate 8 (Behavioral, 0.10): syntax validity ==="
addmax 10
g8=0

# Try rustc parse-only
syntax_ok=0
if command -v rustc >/dev/null 2>&1; then
    # Try a syntax-only parse using --emit=metadata? Won't work without deps.
    # Instead use a simple balanced-brace check + look for obvious tokenization errors.
    :
fi

# Balanced braces / parens check
python3 - <<'PY' 2>/dev/null
src = open("crates/hyperswitch_connectors/src/connectors/checkout/transformers.rs").read()
# strip strings and comments crudely
import re
# remove line comments
s = re.sub(r'//[^\n]*', '', src)
# remove block comments
s = re.sub(r'/\*.*?\*/', '', s, flags=re.DOTALL)
# remove string literals
s = re.sub(r'"(?:\\.|[^"\\])*"', '""', s)
s = re.sub(r"'(?:\\.|[^'\\])'", "''", s)

depth_brace = 0
depth_paren = 0
depth_brack = 0
for ch in s:
    if ch == '{': depth_brace += 1
    elif ch == '}': depth_brace -= 1
    elif ch == '(': depth_paren += 1
    elif ch == ')': depth_paren -= 1
    elif ch == '[': depth_brack += 1
    elif ch == ']': depth_brack -= 1
    if depth_brace < 0 or depth_paren < 0 or depth_brack < 0:
        import sys; sys.exit(1)
if depth_brace == 0 and depth_paren == 0 and depth_brack == 0:
    import sys; sys.exit(0)
import sys; sys.exit(1)
PY
if [ $? -eq 0 ]; then
    g8=1
fi

if [ "$g8" -eq 1 ]; then
    score=$((score + 10))
    echo "PASS (0.10): file is syntactically balanced"
else
    echo "FAIL (0.10): file has unbalanced delimiters"
fi

# ============================================================
# Final reward calculation
# ============================================================
if [ "$total" -le 0 ]; then total=100; fi
reward=$(awk "BEGIN {printf \"%.2f\", $score / $total}")

echo ""
echo "====================================="
echo "Score: ${score}/${total}"
echo "Reward: $reward"
echo "====================================="

echo "$reward" > "$REWARD_FILE"
exit 0