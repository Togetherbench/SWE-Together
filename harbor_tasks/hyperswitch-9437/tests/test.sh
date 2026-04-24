#!/bin/bash
# Test script for hyperswitch-9437: L2/L3 data for Checkout.com connector
# Verifies that the checkout connector properly implements Level 2 and Level 3 payment data
#
# NOTE: cargo check -p hyperswitch_connectors is infeasible because diesel 2.2.10
# with 128-column-tables requires >8GB RAM. Tests use structural + syntax verification.
#
# Gate weights sum to 1.00:
#   Gate 1 (P2P, 0.10): PaymentsRequest struct exists with original fields
#   Gate 2 (F2P, 0.25): L2 processing struct with tax/discount/shipping fields
#   Gate 3 (F2P, 0.25): L3 item struct with commodity_code/unit_of_measure/unit_price
#   Gate 4 (F2P, 0.20): PaymentsRequest has processing and items fields added
#   Gate 5 (F2P, 0.20): Conversion logic maps L2/L3 data from request

set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

CHECKOUT_TRANSFORMERS="crates/hyperswitch_connectors/src/connectors/checkout/transformers.rs"

# Navigate to workspace
if [ -d /workspace/hyperswitch ]; then
    cd /workspace/hyperswitch
elif [ -d /workspace ]; then
    cd /workspace
fi

score=0  # accumulated in hundredths

# Read file content for all checks
FILE_CONTENT=""
if [ -f "$CHECKOUT_TRANSFORMERS" ]; then
    FILE_CONTENT=$(cat "$CHECKOUT_TRANSFORMERS")
fi

if [ -z "$FILE_CONTENT" ]; then
    echo "ERROR: Cannot find or read $CHECKOUT_TRANSFORMERS"
    echo "0.00" > "$REWARD_FILE"
    exit 0
fi

# ============================================================
# Gate 1 (P2P, weight 0.10): PaymentsRequest struct preserved
# Regression guard — the original PaymentsRequest struct must still exist
# with processing_channel_id. Passes on unmodified base AND on gold fix.
# ============================================================
g1=0
echo "=== Gate 1 (P2P): PaymentsRequest struct exists ==="
req_block=$(sed -n '/pub struct PaymentsRequest/,/^}/p' "$CHECKOUT_TRANSFORMERS" 2>/dev/null || true)
if echo "$req_block" | grep -q 'processing_channel_id'; then
    g1=1
    score=$((score + 10))
    echo "PASS (0.10): PaymentsRequest struct with processing_channel_id exists"
else
    echo "FAIL (0.10): PaymentsRequest struct with processing_channel_id not found"
fi

# ============================================================
# Gate 2 (F2P, weight 0.25): L2 processing struct with required fields
# Checkout API L2 data goes in a "processing" object with fields:
# tax_amount, discount_amount (from instruction.md order_tax_amount,
# discount_amount fields). Must be in a serializable struct definition.
# ============================================================
g2=0
echo "=== Gate 2 (F2P): L2 processing struct ==="
has_tax=$(echo "$FILE_CONTENT" | grep -c 'tax_amount')
has_discount=$(echo "$FILE_CONTENT" | grep -c 'discount_amount')
has_shipping=$(echo "$FILE_CONTENT" | grep -cE 'shipping_amount|shipping_cost')
# Need tax_amount plus at least one of discount or shipping
if [ "$has_tax" -ge 1 ] && { [ "$has_discount" -ge 1 ] || [ "$has_shipping" -ge 1 ]; }; then
    # Verify these appear near a struct definition with Serialize
    if echo "$FILE_CONTENT" | grep -B25 'tax_amount' | grep -qE 'struct|Serialize'; then
        g2=1
    fi
fi
if [ "$g2" -eq 1 ]; then
    score=$((score + 25))
    echo "PASS (0.25): L2 processing struct with tax/discount/shipping fields"
else
    echo "FAIL (0.25): L2 processing struct with tax/discount/shipping fields"
fi

# ============================================================
# Gate 3 (F2P, weight 0.25): L3 item struct with required fields
# Checkout API L3 items need commodity_code, unit_of_measure, unit_price
# (from instruction.md order_details examples).
# ============================================================
g3=0
echo "=== Gate 3 (F2P): L3 item struct ==="
has_commodity=$(echo "$FILE_CONTENT" | grep -c 'commodity_code')
has_uom=$(echo "$FILE_CONTENT" | grep -c 'unit_of_measure')
has_up=$(echo "$FILE_CONTENT" | grep -c 'unit_price')
if [ "$has_commodity" -ge 1 ] && [ "$has_uom" -ge 1 ] && [ "$has_up" -ge 1 ]; then
    g3=1
fi
if [ "$g3" -eq 1 ]; then
    score=$((score + 25))
    echo "PASS (0.25): L3 item struct with commodity_code/unit_of_measure/unit_price"
else
    echo "FAIL (0.25): L3 item struct with commodity_code/unit_of_measure/unit_price"
fi

# ============================================================
# Gate 4 (F2P, weight 0.20): PaymentsRequest has processing + items fields
# The PaymentsRequest struct must include both a processing field (for L2)
# and an items/line_items field (for L3) to send them in the API request.
# ============================================================
g4=0
echo "=== Gate 4 (F2P): PaymentsRequest processing+items ==="
# Check for processing field (not processing_channel_id) in PaymentsRequest
proc_not_channel=$(echo "$req_block" | grep '\bprocessing\b' | grep -cv 'processing_channel')
has_items=$(echo "$req_block" | grep -cE '\bitems\b|\bline_items\b')
if [ "$proc_not_channel" -ge 1 ] && [ "$has_items" -ge 1 ]; then
    g4=1
fi
if [ "$g4" -eq 1 ]; then
    score=$((score + 20))
    echo "PASS (0.20): PaymentsRequest has processing and items fields"
else
    echo "FAIL (0.20): PaymentsRequest has processing and items fields"
fi

# ============================================================
# Gate 5 (F2P, weight 0.20): Conversion logic maps L2/L3 data
# The TryFrom/conversion must access L2/L3 data from the request
# (l2_l3_data, order_tax_amount, order_details) and construct
# the processing and items fields for the Checkout API.
# ============================================================
g5=0
echo "=== Gate 5 (F2P): Conversion logic ==="
# Check for L2 data references
has_l2_ref=$(echo "$FILE_CONTENT" | grep -cE 'l2_l3_data|order_tax_amount|L2L3Data')
# Check for order_details/items mapping
has_items_ref=$(echo "$FILE_CONTENT" | grep -cE 'order_details|line_items.*map|\.map\(.*item')
# Check for Processing struct construction
has_proc_construct=$(echo "$FILE_CONTENT" | grep -cE 'Processing\s*\{|processing.*=.*Some')

if [ "$has_l2_ref" -ge 1 ] || [ "$has_items_ref" -ge 1 ]; then
    if [ "$has_proc_construct" -ge 1 ]; then
        g5=1
    fi
fi
# Alternative: accept if processing is populated from any request data
if [ "$g5" -eq 0 ]; then
    if echo "$FILE_CONTENT" | grep -qE 'processing.*tax|processing.*discount|processing.*shipping'; then
        g5=1
    fi
fi
if [ "$g5" -eq 1 ]; then
    score=$((score + 20))
    echo "PASS (0.20): Conversion logic maps L2/L3 data"
else
    echo "FAIL (0.20): Conversion logic maps L2/L3 data"
fi

# ============================================================
# Calculate final reward
# ============================================================
reward=$(awk "BEGIN {printf \"%.2f\", $score / 100}")

echo ""
echo "====================================="
echo "Score: ${score}/100"
echo "Reward: $reward"
echo "====================================="

echo "$reward" > "$REWARD_FILE"
