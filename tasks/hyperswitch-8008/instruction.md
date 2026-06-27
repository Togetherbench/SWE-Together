You are working on the hyperswitch repository (Rust payment processing system).

REPOSITORY SETUP:
- Repository: juspay/hyperswitch
- Working directory: ./repos/hyperswitch_pool_0 (already cloned)
- Base commit: 9d78c583f6c299ab9f63e551b887d1cb080106b4
- Task ID: juspay__hyperswitch-8008
- Version: v1.114.0

TASK DESCRIPTION:
Bug: refactor(connector): move stripe connector from router crate to hyperswitch_connectors



Move code related to stripe connector from router crate to hyperswitch_connectors

DETAILED CONTEXT & HINTS:
## Type of Change
<!-- Put an `x` in the boxes that apply -->

- [ ] Bugfix
- [ ] New feature
- [ ] Enhancement
- [x] Refactoring
- [ ] Dependency updates
- [ ] Documentation
- [ ] CI/CD

## Description
<!-- Describe your changes in detail -->
Move stripe connector code form `router` crate to `hyperswitch_connectors` crate
- issue : https://github.com/juspay/hyperswitch/issues/8008
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

- Create a stripe Connector account
```sh 
curl --location 'http://localhost:8080/account/merchant_1747113313/connectors' \
--header 'Content-Type: application/json' \
--header 'Accept: application/json' \
--header 'x-feature: integ-custom' \
--header 'api-key: ******* ' \
--data '{
    "connector_type": "payment_processor",
    "connector_account_details": {
        "auth_type": "HeaderKey",
        "api_key": "************"
    },
    "connector_name": "stripe",
    "test_mode": false,
    "disabled": false,
    "payment_methods_enabled": [
        {
            "payment_method": "card",
            "payment_method_types": [
                {
                    "payment_method_type": "credit",
                    "card_networks": [
                        "Visa",
                        "Mastercard"
                    ],
                    "minimum_amount": 1,
                    "maximum_amount": 68607706,
                    "recurring_enabled": true,
                    "installment_payment_enabled": true
                },
                {
                    "payment_method_type": "debit",
                    "card_networks": [
                        "Visa",
                        "Mastercard"
                    ],
                    "minimum_amount": 1,
                    "maximum_amount": 68607706,
                    "recurring_enabled": true,
                    "installment_payment_enabled": true
                }
            ]
        },
        {
            "payment_method": "pay_later",
            "payment_method_types": [
                {
                    "payment_method_type": "klarna",
                    "payment_experience": "redirect_to_url",
                    "minimum_amount": 1,
                    "maximum_amount": 68607706,
                    "recurring_enabled": true,
                    "installment_payment_enabled": true
                },
                {
                    "payment_method_type": "affirm",
                    "payment_experience": "redirect_to_url",
                    "minimum_amount": 1,
                    "maximum_amount": 68607706,
                    "recurring_enabled": true,
                    "installment_payment_enabled": true
                },
                {
                    "payment_method_type": "afterpay_clearpay",
                    "payment_experience": "redirect_to_url",
                    "minimum_amount": 1,
                    "maximum_amount": 68607706,
                    "recurring_enabled": true,
                    "installment_payment_enabled": true
                }
            ]
        }
    ],
    "metadata": {
        "city": "NY",
        "unit": "245"
    },
    "connector_webhook_details": {
        "merchant_secret": "MyWebhookSecret"
    },
    "business_country": "US",
    "business_label": "default"
    
}'
```
Response : 
```json
{
    "connector_type": "payment_processor",
    "connector_name": "stripe",
    "connector_label": "stripe_US_default",
    "merchant_connector_id": "mca_8qleoiztV9FBwkaNf0Rm",
    "profile_id": "pro_t33gfLUkrUO76eylTYK4",
    "connector_account_details": {
        "auth_type": "HeaderKey",
        "api_key": "****************************************************************************************"
    },
    "payment_methods_enabled": [
        {
            "payment_method": "card",
            "payment_method_types": [
                {
                    "payment_method_type": "credit",
                    "payment_experience": null,
                    "card_networks": [
                        "Visa",
                        "Mastercard"
                    ],
                    "accepted_currencies": null,
                    "accepted_countries": null,
                    "minimum_amount": 1,
                    "maximum_amount": 68607706,
                    "recurring_enabled": true,
                    "installment_payment_enabled": true
                },
                {
                    "payment_method_type": "debit",
                    "payment_experience": null,
                    "card_networks": [
                        "Visa",
                        "Mastercard"
                    ],
                    "accepted_currencies": null,
                    "accepted_countries": null,
                    "minimum_amount": 1,
                    "maximum_amount": 68607706,
                    "recurring_enabled": true,
                    "installment_payment_enabled": true
                }
            ]
        },
        {
            "payment_method": "pay_later",
            "payment_method_types": [
                {
                    "payment_method_type": "klarna",
                    "payment_experience": "redirect_to_url",
                    "card_networks": null,
                    "accepted_currencies": null,
                    "accepted_countries": null,
                    "minimum_amount": 1,
                    "maximum_amount": 68607706,
                    "recurring_enabled": true,
                    "installment_payment_enabled": true
                },
                {
                    "payment_method_type": "affirm",
                    "payment_experience": "redirect_to_url",
                    "card_networks": null,
                    "accepted_currencies": null,
                    "accepted_countries": null,
                    "minimum_amount": 1,
                    "maximum_amount": 68607706,
                    "recurring_enabled": true,
                    "installment_payment_enabled": true
                },
                {
                    "payment_method_type": "afterpay_clearpay",
                    "payment_experience": "redirect_to_url",
                    "card_networks": null,
                    "accepted_currencies": null,
                    "accepted_countries": null,
                    "minimum_amount": 1,
                    "maximum_amount": 68607706,
                    "recurring_enabled": true,
                    "installment_payment_enabled": true
                }
            ]
        }
    ],
    "connector_webhook_details": {
        "merchant_secret": "MyWebhookSecret",
        "additional_secret": null
    },
    "metadata": {
        "city": "NY",
        "unit": "245"
    },
    "test_mode": false,
    "disabled": false,
    "frm_configs": null,
    "business_country": "US",
    "business_label": "default",
    "business_sub_label": null,
    "applepay_verified_domains": null,
    "pm_auth_config": null,
    "status": "active",
    "additional_merchant_data": null,
    "connector_wallets_details": null
}
```

### make successful payment
```sh
curl --location 'http://localhost:8080/payments' \
--header 'Content-Type: application/json' \
--header 'Accept: application/json' \
--header 'api-key: dev_Li4eaVL1tG5lV2lVmj3vP6BBwvxQ19KIWwp7V2zbw1rhithkA5HxCr02paARBlCz' \
--data-raw '{
    "amount": 10000000,
    "currency": "USD",
    "confirm": true,
    "capture_method": "automatic",
    "capture_on": "2022-09-10T10:11:12Z",
    "customer_id": "CustomerX",
    "email": "<EMAIL>",
    "name": "John Doe",
    "phone": "999999999",
    "phone_country_code": "+65",
    "description": "Its my first payment request",
    "authentication_type": "no_three_ds",
    "return_url": "https://google.com",
    "billing": {
        "address": {
            "line1": "1467",
            "line2": "Harrison Street",
            "line3": "Harrison Street",
            "city": "San Fransico",
            "state": "California",
            "zip": "94122",
            "country": "HK",
            "first_name": "John",
            "last_name": "Doe"
        }
    },
    "browser_info": {
        "user_agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.110 Safari/537.36",
        "accept_header": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8",
        "language": "nl-NL",
        "color_depth": 24,
        "screen_height": 723,
        "screen_width": 1536,
        "time_zone": 0,
        "java_enabled": true,
        "java_script_enabled": true,
        "ip_address": "13.232.74.226"
    },
    "shipping": {
        "address": {
            "line1": "1467",
            "line2": "Harrison Street",
            "line3": "Harrison Street",
            "city": "San Fransico",
            "state": "California",
            "zip": "94122",
            "country": "HK",
            "first_name": "John",
            "last_name": "Doe"
        }
    },
    "statement_descriptor_name": "joseph",
    "statement_descriptor_suffix": "JS",
    "payment_method": "card",
    "payment_method_data": {
        "card": {
            "card_number": "4111111111111111", 
            "card_exp_month": "10",
            "card_exp_year": "25",
            "card_holder_name": "joseph Doe",
            "card_cvc": "123"
        }
    },
    "connector_metadata": {
        "noon": {
            "order_category": "pay"
        }
    },
    
    "setup_future_usage": "off_session",
    "customer_acceptance": {
        "acceptance_type": "offline",
        "accepted_at": "1963-05-03T04:07:52.723Z",
        "online": {
            "ip_address": "13.232.74.226",
            "user_agent": "amet irure esse"
        }
    }
}'
```
response

```json
{
    "payment_id": "pay_q6e0Q412V5XBmVTfFvoe",
    "merchant_id": "merchant_1747113313",
    "status": "succeeded",
    "amount": 10000000,
    "net_amount": 10000000,
    "shipping_cost": null,
    "amount_capturable": 0,
    "amount_received": 10000000,
    "connector": "stripe",
    "client_secret": "pay_q6e0Q412V5XBmVTfFvoe_secret_EbWpc8loQOn0naXMfEgZ",
    "created": "2025-05-13T05:15:28.338Z",
    "currency": "USD",
    "customer_id": "CustomerX",
    "customer": {
        "id": "CustomerX",
        "name": "John Doe",
        "email": "<EMAIL>",
        "phone": "999999999",
        "phone_country_code": "+65"
    },
    "description": "Its my first payment request",
    "refunds": null,
    "disputes": null,
    "mandate_id": null,
    "mandate_data": null,
    "setup_future_usage": "on_session",
    "off_session": null,
    "capture_on": null,
    "capture_method": "automatic",
    "payment_method": "card",
    "payment_method_data": {
        "card": {
            "last4": "1111",
            "card_type": null,
            "card_network": null,
            "card_issuer": null,
            "card_issuing_country": null,
            "card_isin": "411111",
            "card_extended_bin": null,
            "card_exp_month": "10",
            "card_exp_year": "25",
            "card_holder_name": "joseph Doe",
            "payment_checks": {
                "cvc_check": "pass",
                "address_line1_check": "pass",
                "address_postal_code_check": "pass"
            },
            "authentication_data": null
        },
        "billing": null
    },
    "payment_token": null,
    "shipping": {
        "address": {
            "city": "San Fransico",
            "country": "HK",
            "line1": "1467",
            "line2": "Harrison Street",
            "line3": "Harrison Street",
            "zip": "94122",
            "state": "California",
            "first_name": "John",
            "last_name": "Doe"
        },
        "phone": null,
        "email": null
    },
    "billing": {
        "address": {
            "city": "San Fransico",
            "country": "HK",
            "line1": "1467",
            "line2": "Harrison Street",
            "line3": "Harrison Street",
            "zip": "94122",
            "state": "California",
            "first_name": "John",
            "last_name": "Doe"
        },
        "phone": null,
        "email": null
    },
    "order_details": null,
    "email": "<EMAIL>",
    "name": "John Doe",
    "phone": "999999999",
    "return_url": "https://google.com/",
    "authentication_type": "no_three_ds",
    "statement_descriptor_name": "joseph",
    "statement_descriptor_suffix": "JS",
    "next_action": null,
    "cancellation_reason": null,
    "error_code": null,
    "error_message": null,
    "unified_code": null,
    "unified_message": null,
    "payment_experience": null,
    "payment_method_type": null,
    "connector_label": null,
    "business_country": null,
    "business_label": "default",
    "business_sub_label": null,
    "allowed_payment_method_types": null,
    "ephemeral_key": {
        "customer_id": "CustomerX",
        "created_at": 1747113328,
        "expires": 1747116928,
        "secret": "epk_2f16f9167ee34c60a28130b51275b9d3"
    },
    "manual_retry_allowed": false,
    "connector_transaction_id": "pi_3ROBBdD5R7gDAGff02wZ2nM2",
    "frm_message": null,
    "metadata": null,
    "connector_metadata": {
        "apple_pay": null,
        "airwallex": null,
        "noon": {
            "order_category": "pay"
        },
        "braintree": null,
        "adyen": null
    },
    "feature_metadata": null,
    "reference_id": "pi_3ROBBdD5R7gDAGff02wZ2nM2",
    "payment_link": null,
    "profile_id": "pro_t33gfLUkrUO76eylTYK4",
    "surcharge_details": null,
    "attempt_count": 1,
    "merchant_decision": null,
    "merchant_connector_id": "mca_8qleoiztV9FBwkaNf0Rm",
    "incremental_authorization_allowed": null,
    "authorization_count": null,
    "incremental_authorizations": null,
    "external_authentication_details": null,
    "external_3ds_authentication_attempted": false,
    "expires_on": "2025-05-13T05:30:28.338Z",
    "fingerprint": null,
    "browser_info": {
        "language": "nl-NL",
        "time_zone": 0,
        "ip_address": "13.232.74.226",
        "user_agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.110 Safari/537.36",
        "color_depth": 24,
        "java_enabled": true,
        "screen_width": 1536,
        "accept_header": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8",
        "screen_height": 723,
        "java_script_enabled": true
    },
    "payment_method_id": null,
    "payment_method_status": null,
    "updated": "2025-05-13T05:15:30.957Z",
    "split_payments": null,
    "frm_metadata": null,
    "extended_authorization_applied": null,
    "capture_before": null,
    "merchant_order_reference_id": null,
    "order_tax_amount": null,
    "connector_mandate_id": null,
    "card_discovery": "manual",
    "force_3ds_challenge": false,
    "force_3ds_challenge_trigger": false,
    "issuer_error_code": null,
    "issuer_error_message": null
}
```
## Checklist
<!-- Put an `x` in the boxes that apply -->

- [x] I formatted the code `cargo +nightly fmt --all`
- [x] I addressed lints thrown by `cargo clippy`
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
   - All repo files: './repos/hyperswitch_pool_0/<path>'
   - Use targeted edits over whole file rewrites

4. COMMIT YOUR WORK BEFORE FINISHING:
   - Stage meaningful changes with `git add -A`
   - Create a single commit using `git commit -m "task juspay__hyperswitch-8008"`
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
