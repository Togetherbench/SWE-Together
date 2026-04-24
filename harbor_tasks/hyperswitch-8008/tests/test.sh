#!/bin/bash
# Test script for hyperswitch-8008: Move stripe connector from router to hyperswitch_connectors
#
# Verifies structural correctness of the refactoring:
# - Stripe code moved to hyperswitch_connectors crate
# - Module declarations and re-exports updated
# - Import patterns adapted for new crate
# - Old code removed from router crate

set +e

REPO="/workspace/hyperswitch"
HC_CONNECTORS="$REPO/crates/hyperswitch_connectors/src/connectors"
ROUTER_CONNECTOR="$REPO/crates/router/src/connector"
REWARD_FILE="/logs/verifier/reward.txt"

mkdir -p /logs/verifier

total_tests=0
passed_tests=0

pass() {
    passed_tests=$((passed_tests + 1))
    total_tests=$((total_tests + 1))
    echo "PASS: $1"
}

fail() {
    total_tests=$((total_tests + 1))
    echo "FAIL: $1"
}

# ========================================================================
# TEST 1: stripe.rs exists in hyperswitch_connectors (weight: high)
# ========================================================================
if [ -f "$HC_CONNECTORS/stripe.rs" ]; then
    # Check it has substantial content (not just a stub)
    line_count=$(wc -l < "$HC_CONNECTORS/stripe.rs")
    if [ "$line_count" -gt 100 ]; then
        pass "T1: stripe.rs exists in hyperswitch_connectors with $line_count lines"
    else
        fail "T1: stripe.rs in hyperswitch_connectors is too small ($line_count lines), likely a stub"
    fi
else
    fail "T1: stripe.rs does not exist in hyperswitch_connectors"
fi

# ========================================================================
# TEST 2: stripe transformers exist in hyperswitch_connectors
# ========================================================================
if [ -f "$HC_CONNECTORS/stripe/transformers.rs" ] || [ -d "$HC_CONNECTORS/stripe" ]; then
    # Check for substantial transformers content
    if [ -f "$HC_CONNECTORS/stripe/transformers.rs" ]; then
        tl=$(wc -l < "$HC_CONNECTORS/stripe/transformers.rs")
        if [ "$tl" -gt 500 ]; then
            pass "T2: stripe/transformers.rs exists in hyperswitch_connectors ($tl lines)"
        else
            fail "T2: stripe/transformers.rs too small ($tl lines), expected 500+"
        fi
    elif [ -d "$HC_CONNECTORS/stripe" ]; then
        # Maybe transformers is a module with subfiles
        total_stripe_lines=$(find "$HC_CONNECTORS/stripe" -name "*.rs" -exec cat {} + | wc -l)
        if [ "$total_stripe_lines" -gt 500 ]; then
            pass "T2: stripe/ directory in hyperswitch_connectors has $total_stripe_lines lines total"
        else
            fail "T2: stripe/ directory too small ($total_stripe_lines lines)"
        fi
    fi
else
    fail "T2: No stripe transformers found in hyperswitch_connectors"
fi

# ========================================================================
# TEST 3: Module declaration in hyperswitch_connectors/src/connectors.rs
# ========================================================================
connectors_rs="$REPO/crates/hyperswitch_connectors/src/connectors.rs"
if grep -q 'pub mod stripe;' "$connectors_rs" 2>/dev/null || grep -q 'pub mod stripe$' "$connectors_rs" 2>/dev/null; then
    # Make sure it's 'stripe' not just 'stripebilling'
    if grep -qE '^\s*pub\s+mod\s+stripe\s*;' "$connectors_rs" 2>/dev/null; then
        pass "T3: 'pub mod stripe;' declared in hyperswitch_connectors connectors.rs"
    else
        fail "T3: Only found stripebilling, not stripe module declaration"
    fi
else
    fail "T3: No 'pub mod stripe;' in hyperswitch_connectors connectors.rs"
fi

# ========================================================================
# TEST 4: Stripe struct re-exported from hyperswitch_connectors
# ========================================================================
if grep -qE 'stripe::Stripe' "$connectors_rs" 2>/dev/null; then
    pass "T4: Stripe struct re-exported from hyperswitch_connectors"
else
    fail "T4: Stripe struct not re-exported from hyperswitch_connectors connectors.rs"
fi

# ========================================================================
# TEST 5: Router crate no longer has stripe as local module (or greatly reduced)
# ========================================================================
router_connector_rs="$REPO/crates/router/src/connector.rs"
router_stripe_rs="$ROUTER_CONNECTOR/stripe.rs"

if [ -f "$router_stripe_rs" ]; then
    old_lines=$(wc -l < "$router_stripe_rs")
    if [ "$old_lines" -lt 100 ]; then
        pass "T5: Router stripe.rs reduced to $old_lines lines (likely re-export stub)"
    else
        fail "T5: Router stripe.rs still has $old_lines lines — code not moved"
    fi
else
    # File doesn't exist — good, it's been moved
    pass "T5: Router stripe.rs removed (code moved to hyperswitch_connectors)"
fi

# ========================================================================
# TEST 6: Router connector.rs updated — stripe re-exported from hyperswitch_connectors
# ========================================================================
if grep -qE 'hyperswitch_connectors.*stripe.*Stripe|stripe,\s*stripe::Stripe' "$router_connector_rs" 2>/dev/null; then
    pass "T6: Router connector.rs re-exports Stripe from hyperswitch_connectors"
elif ! [ -f "$router_stripe_rs" ] || [ "$(wc -l < "$router_stripe_rs" 2>/dev/null || echo 0)" -lt 50 ]; then
    # If stripe.rs was fully removed and there's a re-export in connector.rs
    if grep -q 'stripe' "$router_connector_rs" 2>/dev/null; then
        pass "T6: Router connector.rs references stripe (likely re-exported)"
    else
        fail "T6: Router connector.rs has no stripe reference"
    fi
else
    fail "T6: Router connector.rs doesn't re-export Stripe from hyperswitch_connectors"
fi

# ========================================================================
# TEST 7: New stripe.rs uses hyperswitch_interfaces imports (not crate:: router imports)
# ========================================================================
new_stripe="$HC_CONNECTORS/stripe.rs"
if [ -f "$new_stripe" ]; then
    # Check for hyperswitch_interfaces or hyperswitch_domain_models imports
    if grep -qE 'hyperswitch_interfaces|hyperswitch_domain_models' "$new_stripe" 2>/dev/null; then
        pass "T7: New stripe.rs uses hyperswitch_interfaces/domain_models imports"
    else
        fail "T7: New stripe.rs does not use expected hyperswitch crate imports"
    fi
else
    fail "T7: Cannot check imports — new stripe.rs doesn't exist"
fi

# ========================================================================
# TEST 8: New stripe.rs does NOT have router-specific crate:: imports
# ========================================================================
if [ -f "$new_stripe" ]; then
    # Check for router-specific imports that should have been adapted
    bad_imports=$(grep -cE 'use crate::(configs|core|services|consts|headers|types::self|utils::crypto)' "$new_stripe" 2>/dev/null || true)
    bad_imports=$(echo "$bad_imports" | tr -d '[:space:]')
    bad_imports=${bad_imports:-0}
    if [ "$bad_imports" -eq 0 ]; then
        pass "T8: No router-specific crate:: imports found in new stripe.rs"
    else
        fail "T8: Found $bad_imports router-specific crate:: imports in new stripe.rs (not adapted)"
    fi
else
    fail "T8: Cannot check imports — new stripe.rs doesn't exist"
fi

# ========================================================================
# TEST 9: Stripe struct definition exists in new location
# ========================================================================
if [ -f "$new_stripe" ]; then
    if grep -qE 'pub struct Stripe' "$new_stripe" 2>/dev/null; then
        pass "T9: 'pub struct Stripe' found in new stripe.rs"
    else
        fail "T9: 'pub struct Stripe' not found in new stripe.rs"
    fi
else
    fail "T9: Cannot check struct — new stripe.rs doesn't exist"
fi

# ========================================================================
# TEST 10: Transformers moved — check connect.rs submodule
# ========================================================================
if [ -f "$HC_CONNECTORS/stripe/transformers/connect.rs" ]; then
    cl=$(wc -l < "$HC_CONNECTORS/stripe/transformers/connect.rs")
    if [ "$cl" -gt 50 ]; then
        pass "T10: connect.rs submodule moved to hyperswitch_connectors ($cl lines)"
    else
        fail "T10: connect.rs too small ($cl lines)"
    fi
elif [ -d "$HC_CONNECTORS/stripe" ]; then
    # Maybe the transformers structure was flattened, check total content
    if find "$HC_CONNECTORS/stripe" -name "*.rs" | xargs grep -l 'connect\|Connect' 2>/dev/null | head -1 | grep -q '.'; then
        pass "T10: Connect-related code found in stripe directory"
    else
        fail "T10: No connect submodule/code found in hyperswitch_connectors stripe directory"
    fi
else
    fail "T10: No stripe directory in hyperswitch_connectors"
fi

# ========================================================================
# TEST 11: Router's stripe/transformers removed or greatly reduced
# ========================================================================
old_transformers="$ROUTER_CONNECTOR/stripe/transformers.rs"
if [ -f "$old_transformers" ]; then
    ot_lines=$(wc -l < "$old_transformers")
    if [ "$ot_lines" -lt 100 ]; then
        pass "T11: Router stripe/transformers.rs reduced to $ot_lines lines"
    else
        fail "T11: Router stripe/transformers.rs still has $ot_lines lines — not moved"
    fi
else
    pass "T11: Router stripe/transformers.rs removed"
fi

# ========================================================================
# TEST 12: New code implements ConnectorCommon trait
# ========================================================================
if [ -f "$new_stripe" ]; then
    if grep -qE 'impl\s+ConnectorCommon\s+for\s+Stripe' "$new_stripe" 2>/dev/null; then
        pass "T12: ConnectorCommon implemented for Stripe in new location"
    else
        fail "T12: ConnectorCommon not implemented for Stripe in new stripe.rs"
    fi
else
    fail "T12: Cannot check trait impl — new stripe.rs doesn't exist"
fi

# ========================================================================
# Compute final reward
# ========================================================================
if [ "$total_tests" -gt 0 ]; then
    reward=$(awk "BEGIN {printf \"%.2f\", $passed_tests / $total_tests}")
else
    reward="0.00"
fi

echo ""
echo "========================================"
echo "RESULTS: $passed_tests / $total_tests tests passed"
echo "REWARD: $reward"
echo "========================================"

echo "$reward" > "$REWARD_FILE"
