You are working on the hyperswitch repository (Rust payment processing system).

REPOSITORY SETUP:
- Repository: juspay/hyperswitch
- Working directory: ./repos/hyperswitch_pool_1 (already cloned)
- Base commit: 8930e1ed289bb4c128da664849af1095bafd45a7
- Task ID: juspay__hyperswitch-9437
- Version: v1.117.0

TASK DESCRIPTION:
Bug: [FEATURE] L2-l3 data for checkout



### Feature Description

Add l2-l3 data for checkout

### Possible Implementation

https://www.checkout.com/docs/payments/manage-payments/submit-level-2-or-level-3-data

### Have you spent some time checking if this feature request has been raised before?

- [x] I checked and didn't find a similar issue

### Have you read the Contributing Guidelines?

- [x] I have read the [Contributing Guidelines](https://github.com/juspay/hyperswitch/blob/main/docs/CONTRIBUTING.md)

### Are you willing to submit a PR?

None

DETAILED CONTEXT & HINTS:
## Type of Change
<!-- Put an `x` in the boxes that apply -->

- [ ] Bugfix
- [x] New feature
- [ ] Enhancement
- [ ] Refactoring
- [ ] Dependency updates
- [ ] Documentation
- [ ] CI/CD

## Description
- Add l2l3 data for checkout
- Note : checkout recommends some checks like line_items should sum up proper total and discount amount. But it doesn't throw any errors for this. Hence in this pr we are not adding any such validations .

## Request

```json
{
    "amount": 30000,
    "capture_method": "automatic",
    "currency": "USD",
    "confirm": true,
    "payment_method": "card",
    "payment_method_type": "credit",
    "billing": {
        "address": {
            "zip": "560095",
            "country": "AT",
            "first_name": "Sakil",
            "last_name": "Mostak",
            "line1": "Fasdf",
            "line2": "Fasdf",
            "city": "Fasdf"
        }
    },
    "payment_method_data": {
        "card": {
            "card_number": "4000000000009995",
            "card_exp_month": "01",
            "card_exp_year": "2026",
            "card_holder_name": "John Smith",
            "card_cvc": "100"
        }
    },

    //l2l3 data
    "merchant_order_reference_id":"fasdfasfasf",
    "customer_id": "nithxxinn",
    "order_tax_amount": 10000,
    "shipping_cost": 21,
    "discount_amount": 1,
    "duty_amount": 2,
    "shipping_amount_tax":22,
    "order_details": [ //l2 l3data
        {
            "commodity_code": "8471",
            "unit_discount_amount": 1200,
            "product_name": "Laptop",
            "quantity": 1,
            "product_id":"fafasdfasdfdasdfsadfsadfrewfdscrwefdscerwfdasewfdsacxzfdsasdf",
            "total_tax_amount": 5000,
            "amount": 8000,
            "unit_of_measure": "EA",
            "unit_price": 8000
        },
            {
            "commodity_code": "471",
            "unit_discount_amount": 34,
            "product_name": "Laptop",
            "quantity": 1,
            "product_id":"fas22df",
            "total_tax_amount": 3000,
            "amount": 4000,
            "unit_of_measure": "EA",
            "unit_price": 8500
        }
        
    ]
}
```

## Response

```json
{
    "payment_id": "pay_v01RncbYqwx0ZtB6x7yV",
    "merchant_id": "merchant_1758258316",
    "status": "succeeded",
    "amount": 30000,
    "net_amount": 40021,
    "shipping_cost": 21,
    "amount_capturable": 0,
    "amount_received": 40021,
    "connector": "checkout",
    "client_secret": "pay_v01RncbYqwx0ZtB6x7yV_secret_iolJ5SxVFNsQljPaO42C",
    "created": "2025-09-19T06:18:02.547Z",
    "currency": "USD",
    "customer_id": "nithxxinn",
    "customer": {
        "id": "nithxxinn",
        "name": null,
        "email": null,
        "phone": null,
        "phone_country_code": null
    },
    "description": null,
    "refunds": null,
    "disputes": null,
    "mandate_id": null,
    "mandate_data": null,
    "setup_future_usage": null,
    "off_session": null,
    "capture_on": null,
    "capture_method": "automatic",
    "payment_method": "card",
    "payment_method_data": {
        "card": {
            "last4": "9995",
            "card_type": null,
            "card_network": null,
            "card_issuer": null,
            "card_issuing_country": null,
            "card_isin": "400000",
            "card_extended_bin": null,
            "card_exp_month": "01",
            "card_exp_year": "2026",
            "card_holder_name": "John Smith",
            "payment_checks": {
                "avs_result": "G",
                "card_validation_result": "Y"
            },
            "authentication_data": null
        },
        "billing": null
    },
    "payment_token": null,
    "shipping": null,
    "billing": {
        "address": {
            "city": "Fasdf",
            "country": "AT",
            "line1": "Fasdf",
            "line2": "Fasdf",
            "line3": null,
            "zip": "560095",
            "state": null,
            "first_name": "Sakil",
            "last_name": "Mostak",
            "origin_zip": null
        },
        "phone": null,
        "email": null
    },
    "order_details": [
        {
            "sku": null,
            "upc": null,
            "brand": null,
            "amount": 8000,
            "category": null,
            "quantity": 1,
            "tax_rate": null,
            "product_id": "fafasdfasdfdasdfsadfsadfrewfdscrwefdscerwfdasewfdsacxzfdsasdf",
            "description": null,
            "product_name": "Laptop",
            "product_type": null,
            "sub_category": null,
            "total_amount": null,
            "commodity_code": "8471",
            "unit_of_measure": "EA",
            "product_img_link": null,
            "product_tax_code": null,
            "total_tax_amount": 5000,
            "requires_shipping": null,
            "unit_discount_amount": 1200
        },
        {
            "sku": null,
            "upc": null,
            "brand": null,
            "amount": 4000,
            "category": null,
            "quantity": 1,
            "tax_rate": null,
            "product_id": "fas22df",
            "description": null,
            "product_name": "Laptop",
            "product_type": null,
            "sub_category": null,
            "total_amount": null,
            "commodity_code": "471",
            "unit_of_measure": "EA",
            "product_img_link": null,
            "product_tax_code": null,
            "total_tax_amount": 3000,
            "requires_shipping": null,
            "unit_discount_amount": 34
        }
    ],
    "email": null,
    "name": null,
    "phone": null,
    "return_url": null,
    "authentication_type": "no_three_ds",
    "statement_descriptor_name": null,
    "statement_descriptor_suffix": null,
    "next_action": null,
    "cancellation_reason": null,
    "error_code": null,
    "error_message": null,
    "unified_code": null,
    "unified_message": null,
    "payment_experience": null,
    "payment_method_type": "credit",
    "connector_label": null,
    "business_country": null,
    "business_label": "default",
    "business_sub_label": null,
    "allowed_payment_method_types": null,
    "ephemeral_key": {
        "customer_id": "nithxxinn",
        "created_at": 1758262682,
        "expires": 1758266282,
        "secret": "epk_e62d911ac98c4ccea72189e40ad83af4"
    },
    "manual_retry_allowed": null,
    "connector_transaction_id": "pay_2667htrzd3qu7bx4fk36nkiva4",
    "frm_message": null,
    "metadata": null,
    "connector_metadata": null,
    "feature_metadata": {
        "redirect_response": null,
        "search_tags": null,
        "apple_pay_recurring_details": null,
        "gateway_system": "direct"
    },
    "reference_id": "pay_v01RncbYqwx0ZtB6x7yV_1",
    "payment_link": null,
    "profile_id": "pro_tqppxjNXH3TckLuEmhDJ",
    "surcharge_details": null,
    "attempt_count": 1,
    "merchant_decision": null,
    "merchant_connector_id": "mca_z4uydERX9Y3VqfGMXeuh",
    "incremental_authorization_allowed": false,
    "authorization_count": null,
    "incremental_authorizations": null,
    "external_authentication_details": null,
    "external_3ds_authentication_attempted": false,
    "expires_on": "2025-09-19T06:33:02.547Z",
    "fingerprint": null,
    "browser_info": null,
    "payment_channel": null,
    "payment_method_id": null,
    "network_transaction_id": "716806996896398",
    "payment_method_status": null,
    "updated": "2025-09-19T06:18:04.255Z",
    "split_payments": null,
    "frm_metadata": null,
    "extended_authorization_applied": null,
    "capture_before": null,
    "merchant_order_reference_id": "fasdfasfasf",
    "order_tax_amount": 10000,
    "connector_mandate_id": null,
    "card_discovery": "manual",
    "force_3ds_challenge": false,
    "force_3ds_challenge_trigger": false,
    "issuer_error_code": null,
    "issuer_error_message": null,
    "is_iframe_redirection_enabled": null,
    "whole_connector_response": null,
    "enable_partial_authorization": null,
    "enable_overcapture": null,
    "is_overcapture_enabled": null,
    "network_details": null
}
```

## connector mapping

```json
{
  "source": {
    "type": "card",
    "number": "4000000000009995",
    "expiry_month": "01",
    "expiry_year": "2026",
    "cvv": "100"
  },
  "amount": 40021,
  "currency": "USD",
  "processing_channel_id": "pc_jx5lvimg4obe7nhoqnhptm6xoq",
  "3ds": {
    "enabled": false,
    "force_3ds": false,
    "eci": null,
    "cryptogram": null,
    "xid": null,
    "version": null,
    "challenge_indicator": "no_preference"
  },
  "success_url": "http://localhost:8080/payments/pay_v01RncbYqwx0ZtB6x7yV/merchant_1758258316/redirect/response/checkout?status=success",
  "failure_url": "http://localhost:8080/payments/pay_v01RncbYqwx0ZtB6x7yV/merchant_1758258316/redirect/response/checkout?status=failure",
  "capture": true,
  "reference": "pay_v01RncbYqwx0ZtB6x7yV_1",
  "payment_type": "Regular",
  "merchant_initiated": false,
  "customer": {
    "name": "nithxxinn"
  },
  "processing": {
    "order_id": "fasdfasfasf",
    "tax_amount": 10000,
    "discount_amount": 1,
    "duty_amount": 2,
    "shipping_amount": 21,
    "shipping_tax_amount": 22
  },
  "shipping": {
    "address": {}
  },
  "items": [
    {
      "commodity_code": "8471",
      "discount_amount": 1200,
      "name": "Laptop",
      "quantity": 1,
      "reference": "fafasdfasdfdasdfsadfsadfrewfdscrwefdscerwfdasewfdsacxzfdsasdf",
      "tax_amount": 5000,
      "unit_of_measure": "EA",
      "unit_price": 8000
    },
    {
      "commodity_code": "471",
      "discount_amount": 34,
      "name": "Laptop",
      "quantity": 1,
      "reference": "fas22df",
      "tax_amount": 3000,
      "unit_of_measure": "EA",
      "unit_price": 4000
    }
  ]
}
```

### Additional Changes

- [ ] This PR modifies the API contract
- [ ] This PR modifies the database schema
- [ ] This PR modifies application configuration/environment variables

<!--
Provide links to the files with corresponding changes.

Following are the paths where you can find config files:
1. `config`
2. `crates/router/src/configs`
3. `loadtest/config`
-->


## Motivation and Context
<!--
Why is this change required? What problem does it solve?
If it fixes an open issue, please link to the issue here.

If you don't have an issue, we'd recommend starting with one first so the PR
can focus on the implementation (unless it is an obvious bug or documentation fix
that will have little conversation).
-->


## How did you test it?
<!--
Did you write an integration/unit/API test to verify the code changes?
Or did you test this change manually (provide relevant screenshots)?
-->


## Checklist
<!-- Put an `x` in the boxes that apply -->

- [x] I formatted the code `cargo +nightly fmt --all`
- [ ] I addressed lints thrown by `cargo clippy`
- [ ] I reviewed the submitted code
- [ ] I added unit tests for my changes where possible


CRITICAL INSTRUCTIONS - WORK FAST AND EFFICIENTLY:

1. Create DENSE, ACTION-FOCUSED todos IMMEDIATELY
   - Make todos specific and actionable
   - Focus on HIGH-IMPACT actions only
   - 5-8 todos maximum - be surgical, not exhaustive

2. Execute aggressively:
   - Use bash commands to search efficiently
   - Read multiple related files in quick succession
   - Make ALL related changes in one edit
   - Skip unnecessary exploration

3. File operations:
   - All repo files: './repos/hyperswitch_pool_1/<path>'
   - Use targeted edits over whole file rewrites

4. COMMIT YOUR WORK BEFORE FINISHING:
   - Stage meaningful changes with `git add -A`
   - Create a single commit using `git commit -m "task juspay__hyperswitch-9437"`
   - Do NOT push changes
   - If no changes were required, explicitly state that and skip the commit

5. NO TESTING UNLESS CRITICAL:
   - Focus on making the actual code changes
   - Only test if explicitly required

6. Maximize information density:
   - Each turn should accomplish significant work
   - Batch file reads when examining related code
   - Use search commands to locate code quickly

EFFICIENCY IS CRITICAL. Make substantial progress every turn. REMEMBER YOU CAN MAKE EDITS AND USE THE EDIT TOOL SO PLEASE MAKE EDITS
AND YOU CAN USE BASH TOOLS SO PLS DO USE IT
