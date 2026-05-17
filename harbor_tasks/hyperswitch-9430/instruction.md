You are working on the hyperswitch repository (Rust payment processing system).

REPOSITORY SETUP:
- Repository: juspay/hyperswitch
- Working directory: ./repos/hyperswitch_pool_7 (already cloned)
- Base commit: e410af26ffffc63273f9a83ae28c982f37f47484
- Task ID: juspay__hyperswitch-9430
- Version: v1.117.0

TASK DESCRIPTION:
Bug: Add support to configure default billing processor for a profile





DETAILED CONTEXT & HINTS:
## Type of Change
<!-- Put an `x` in the boxes that apply -->

- [ ] Bugfix
- [X] New feature
- [ ] Enhancement
- [ ] Refactoring
- [ ] Dependency updates
- [ ] Documentation
- [ ] CI/CD

## Description
<!-- Describe your changes in detail -->
As part of the subscription, a billing processor need to be configured at profile level to route the subscription creation and other related activities. 

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
Adding billing_processor_id in the profile table to use it during subscription operations.

## How did you test it?
<!--
Did you write an integration/unit/API test to verify the code changes?
Or did you test this change manually (provide relevant screenshots)?
-->
1. Create merchant account

Request

  ```
  curl --location 'http://localhost:8080/accounts' \
  --header 'Content-Type: application/json' \
  --header 'Accept: application/json' \
  --header 'x-feature: router-custom' \
  --header 'api-key: test_admin' \
  --data-raw '{
    "merchant_id": "merchant_1758189685",
    "locker_id": "m0010",
    "merchant_name": "NewAge Retailer",
    "merchant_details": {
      "primary_contact_person": "John Test",
      "primary_email": "<EMAIL>",
      "primary_phone": "sunt laborum",
      "secondary_contact_person": "John Test2",
      "secondary_email": "<EMAIL>",
      "secondary_phone": "cillum do dolor id",
      "website": "www.example.com",
      "about_business": "Online Retail with a wide selection of organic products for North America",
      "address": {
        "line1": "1467",
        "line2": "Harrison Street",
        "line3": "Harrison Street",
        "city": "San Fransico",
        "state": "California",
        "zip": "94122",
        "country": "US"
      }
    },
    "return_url": "https://google.com/success",
    "webhook_details": {
      "webhook_version": "1.0.1",
      "webhook_username": "ekart_retail",
      "webhook_password": "password_ekart@123",
      "payment_created_enabled": true,
      "payment_succeeded_enabled": true,
      "payment_failed_enabled": true
    },
    "sub_merchants_enabled": false,
    "metadata": {
      "city": "NY",
      "unit": "245"
    },
    "primary_business_details": [
      {
        "country": "US",
        "business": "default"
      }
    ]
  }'
  ```
Response
```
{
    "merchant_id": "merchant_1758189675",
    "merchant_name": "NewAge Retailer",
    "return_url": "https://google.com/success",
    "enable_payment_response_hash": true,
    "payment_response_hash_key": "xn1iJ8FBkwGYVJbo4BIIndl2zIE8p8pNpksCA6r764i9xD8LD3WvkRNC5hq8bYON",
    "redirect_to_merchant_with_http_post": false,
    "merchant_details": {
        "primary_contact_person": "John Test",
        "primary_phone": "sunt laborum",
        "primary_email": "<EMAIL>",
        "secondary_contact_person": "John Test2",
        "secondary_phone": "cillum do dolor id",
        "secondary_email": "<EMAIL>",
        "website": "www.example.com",
        "about_business": "Online Retail with a wide selection of organic products for North America",
        "address": {
            "city": "San Fransico",
            "country": "US",
            "line1": "1467",
            "line2": "Harrison Street",
            "line3": "Harrison Street",
            "zip": "94122",
            "state": "California",
            "first_name": null,
            "last_name": null,
            "origin_zip": null
        },
        "merchant_tax_registration_id": null
    },
    "webhook_details": {
        "webhook_version": "1.0.1",
        "webhook_username": "ekart_retail",
        "webhook_password": "password_ekart@123",
        "webhook_url": null,
        "payment_created_enabled": true,
        "payment_succeeded_enabled": true,
        "payment_failed_enabled": true,
        "payment_statuses_enabled": null,
        "refund_statuses_enabled": null,
        "payout_statuses_enabled": null
    },
    "payout_routing_algorithm": null,
    "sub_merchants_enabled": false,
    "parent_merchant_id": null,
    "publishable_key": "pk_dev_2250d33a4b344663846c41c8b058546c",
    "metadata": {
        "city": "NY",
        "unit": "245",
        "compatible_connector": null
    },
    "locker_id": "m0010",
    "primary_business_details": [
        {
            "country": "US",
            "business": "default"
        }
    ],
    "frm_routing_algorithm": null,
    "organization_id": "org_zNQexFZeBIibQLnmfMOf",
    "is_recon_enabled": false,
    "default_profile": "pro_UCU7YbjjS89XQ9vch5hi",
    "recon_status": "not_requested",
    "pm_collect_link_config": null,
    "product_type": "orchestration",
    "merchant_account_type": "standard"
}
```
2. Create API key
Request
```
curl --location 'http://localhost:8080/api_keys/merchant_1758189675' \
--header 'Content-Type: application/json' \
--header 'Accept: application/json' \
--header 'api-key: test_admin' \
--data '{
  "name": "API Key 1",
  "description": null,
  "expiration": "2038-01-19T03:14:08.000Z"
}'
```
Response
```
{
    "key_id": "dev_lc3LHo3Q8FWQautTIDy8",
    "merchant_id": "merchant_1758189675",
    "name": "API Key 1",
    "description": null,
    "api_key": "dev_nKpWbedawCxOo4fCSnIWHKT5lr6cxBR0qkiquexf2hZjfhcf6UGzbXAl3HFE2AJL",
    "created": "2025-09-18T10:02:31.552Z",
    "expiration": "2038-01-19T03:14:08.000Z"
}
```
3. Create billing connector
Request
```
curl --location 'http://localhost:8080/account/merchant_1758189675/connectors' \
--header 'Content-Type: application/json' \
--header 'Accept: application/json' \
--header 'api-key: dev_nKpWbedawCxOo4fCSnIWHKT5lr6cxBR0qkiquexf2hZjfhcf6UGzbXAl3HFE2AJL' \
--data '{
    "connector_type": "billing_processor",
    "connector_name": "chargebee",
    "connector_account_details": {
        "auth_type": "HeaderKey",
        "api_key": "test_MK",
        "site": ""
    },
    "business_country": "US",
    "business_label": "default",
    "connector_webhook_details": {
        "merchant_secret": "hyperswitch", 
        "additional_secret": "hyperswitch" 
    },
    "metadata": {
        "site": "nish-test"
    }
}'
```
Response
```
{
    "connector_type": "billing_processor",
    "connector_name": "chargebee",
    "connector_label": "chargebee_US_default",
    "merchant_connector_id": "mca_LJR3NoCsDKbYFTKnTGek",
    "profile_id": "pro_UCU7YbjjS89XQ9vch5hi",
    "connector_account_details": {
        "auth_type": "HeaderKey",
        "api_key": "te**********************************MK"
    },
    "payment_methods_enabled": null,
    "connector_webhook_details": {
        "merchant_secret": "hyperswitch",
        "additional_secret": "hyperswitch"
    },
    "metadata": {
        "site": "nish-test"
    },
    "test_mode": null,
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
4. Update billing processor id in the profile
Request
```
curl --location 'http://localhost:8080/account/merchant_1758189675/business_profile/pro_UCU7YbjjS89XQ9vch5hi' \
--header 'Content-Type: application/json' \
--header 'api-key: dev_nKpWbedawCxOo4fCSnIWHKT5lr6cxBR0qkiquexf2hZjfhcf6UGzbXAl3HFE2AJL' \
--data '{
  "billing_processor_id": "mca_LJR3NoCsDKbYFTKnTGek"
}'
```
Response
```
{
    "merchant_id": "merchant_1758189675",
    "profile_id": "pro_UCU7YbjjS89XQ9vch5hi",
    "profile_name": "US_default",
    "return_url": "https://google.com/success",
    "enable_payment_response_hash": true,
    "payment_response_hash_key": "xn1iJ8FBkwGYVJbo4BIIndl2zIE8p8pNpksCA6r764i9xD8LD3WvkRNC5hq8bYON",
    "redirect_to_merchant_with_http_post": false,
    "webhook_details": {
        "webhook_version": "1.0.1",
        "webhook_username": "ekart_retail",
        "webhook_password": "password_ekart@123",
        "webhook_url": null,
        "payment_created_enabled": true,
        "payment_succeeded_enabled": true,
        "payment_failed_enabled": true,
        "payment_statuses_enabled": null,
        "refund_statuses_enabled": null,
        "payout_statuses_enabled": null
    },
    "metadata": null,
    "routing_algorithm": null,
    "intent_fulfillment_time": 900,
    "frm_routing_algorithm": null,
    "payout_routing_algorithm": null,
    "applepay_verified_domains": null,
    "session_expiry": 900,
    "payment_link_config": null,
    "authentication_connector_details": null,
    "use_billing_as_payment_method_billing": true,
    "extended_card_info_config": null,
    "collect_shipping_details_from_wallet_connector": false,
    "collect_billing_details_from_wallet_connector": false,
    "always_collect_shipping_details_from_wallet_connector": false,
    "always_collect_billing_details_from_wallet_connector": false,
    "is_connector_agnostic_mit_enabled": false,
    "payout_link_config": null,
    "outgoing_webhook_custom_http_headers": null,
    "tax_connector_id": null,
    "is_tax_connector_enabled": false,
    "is_network_tokenization_enabled": false,
    "is_auto_retries_enabled": false,
    "max_auto_retries_enabled": null,
    "always_request_extended_authorization": null,
    "is_click_to_pay_enabled": false,
    "authentication_product_ids": null,
    "card_testing_guard_config": {
        "card_ip_blocking_status": "disabled",
        "card_ip_blocking_threshold": 3,
        "guest_user_card_blocking_status": "disabled",
        "guest_user_card_blocking_threshold": 10,
        "customer_id_blocking_status": "disabled",
        "customer_id_blocking_threshold": 5,
        "card_testing_guard_expiry": 3600
    },
    "is_clear_pan_retries_enabled": false,
    "force_3ds_challenge": false,
    "is_debit_routing_enabled": false,
    "merchant_business_country": null,
    "is_pre_network_tokenization_enabled": false,
    "acquirer_configs": null,
    "is_iframe_redirection_enabled": null,
    "merchant_category_code": null,
    "merchant_country_code": null,
    "dispute_polling_interval": null,
    "is_manual_retry_enabled": null,
    "always_enable_overcapture": null,
    "billing_processor_id": "mca_LJR3NoCsDKbYFTKnTGek"
}
```
## Checklist
<!-- Put an `x` in the boxes that apply -->

- [ ] I formatted the code `cargo +nightly fmt --all`
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
   - All repo files: './repos/hyperswitch_pool_7/<path>'
   - Use targeted edits over whole file rewrites

4. COMMIT YOUR WORK BEFORE FINISHING:
   - Stage meaningful changes with `git add -A`
   - Create a single commit using `git commit -m "task juspay__hyperswitch-9430"`
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
