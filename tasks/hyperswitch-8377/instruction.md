You are working on the hyperswitch repository (Rust payment processing system).

REPOSITORY SETUP:
- Repository: juspay/hyperswitch
- Working directory: ./repos/hyperswitch_pool_2 (already cloned)
- Base commit: 305ca9bda9d3c5bf3cc97458b7ed07b79e894154
- Task ID: juspay__hyperswitch-8377
- Version: v1.114.0

TASK DESCRIPTION:
Bug: feat(router): Add v2 endpoint to list payment attempts by intent_id



In payment flows that involve retries—such as smart , cascading retires —a single payment intent may result in multiple attempts. Previously, there was no clean way to retrieve all these attempts together.

### API Flow:
Adds a new endpoint: GET /v2/payments/{intent_id}/attempts
Validates the request and ensures merchant authorization
Retrieves all associated payment attempts linked to that intent_id

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
<!-- Describe your changes in detail -->
This PR introduces an API to list all payment attempts associated with a given intent_id.
#### Why this is needed:
In payment flows that involve retries—such as smart , cascading retires —a single payment intent may result in multiple attempts. Previously, there was no clean way to retrieve all these attempts together.
#### Implemented API Flow:
- Adds a new endpoint: GET /v2/payments/{intent_id}/list_attempts
- Validates the request and ensures merchant authorization
- Retrieves all associated payment attempts linked to that intent_id

### Additional Changes

- [x] This PR modifies the API contract
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
I inserted two payment attempts for a payment intent as part of testing.
### Curl 
```
curl --location 'http://localhost:8080/v2/payments/12345_pay_01978809316e7850b05ab92288ed7746/list_attempts' \
--header 'Content-Type: application/json' \
--header 'x-profile-id: pro_pF6sS2TBfhg0Vdp6N04E' \
--header 'api-key: dev_bzJEoDI7SlTyV0M7Vq6VdtCtbKGwOPphw39wD1mYdu8rY3GoydtnymDbkkMxDopB' \
--header 'Authorization: api-key=dev_bzJEoDI7SlTyV0M7Vq6VdtCtbKGwOPphw39wD1mYdu8rY3GoydtnymDbkkMxDopB'
```
### Response
```
{
    "payment_attempts": [
        {
            "id": "12345_att_01975ae7bf32760282f479794fbf810c",
            "status": "failure",
            "amount": {
                "net_amount": 10000,
                "amount_to_capture": null,
                "surcharge_amount": null,
                "tax_on_surcharge": null,
                "amount_capturable": 10000,
                "shipping_cost": null,
                "order_tax_amount": null
            },
            "connector": "stripe",
            "error": null,
            "authentication_type": "no_three_ds",
            "created_at": "2025-06-17T13:50:49.173Z",
            "modified_at": "2025-06-17T13:50:49.173Z",
            "cancellation_reason": null,
            "payment_token": null,
            "connector_metadata": null,
            "payment_experience": null,
            "payment_method_type": "card",
            "connector_reference_id": null,
            "payment_method_subtype": "credit",
            "connector_payment_id": {
                "TxnId": "ch_3RYW3N06IkU6uKNZ01mrX2tD"
            },
            "payment_method_id": null,
            "client_source": null,
            "client_version": null,
            "feature_metadata": {
                "revenue_recovery": {
                    "attempt_triggered_by": "external"
                }
            }
        },
        {
            "id": "12345_att_01975ae7bf32760282f479794fbf810d",
            "status": "failure",
            "amount": {
                "net_amount": 10000,
                "amount_to_capture": null,
                "surcharge_amount": null,
                "tax_on_surcharge": null,
                "amount_capturable": 10000,
                "shipping_cost": null,
                "order_tax_amount": null
            },
            "connector": "stripe",
            "error": null,
            "authentication_type": "no_three_ds",
            "created_at": "2025-06-17T13:51:16.812Z",
            "modified_at": "2025-06-17T13:51:16.812Z",
            "cancellation_reason": null,
            "payment_token": null,
            "connector_metadata": null,
            "payment_experience": null,
            "payment_method_type": "card",
            "connector_reference_id": null,
            "payment_method_subtype": "credit",
            "connector_payment_id": {
                "TxnId": "ch_3RYW3N06IkU6uKNZ01mrX2tD"
            },
            "payment_method_id": null,
            "client_source": null,
            "client_version": null,
            "feature_metadata": {
                "revenue_recovery": {
                    "attempt_triggered_by": "external"
                }
            }
        }
    ]
}
```

## Checklist
<!-- Put an `x` in the boxes that apply -->

- [x] I formatted the code `cargo +nightly fmt --all`
- [x] I addressed lints thrown by `cargo clippy`
- [x] I reviewed the submitted code
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
   - All repo files: './repos/hyperswitch_pool_2/<path>'
   - Use targeted edits over whole file rewrites

4. COMMIT YOUR WORK BEFORE FINISHING:
   - Stage meaningful changes with `git add -A`
   - Create a single commit using `git commit -m "task juspay__hyperswitch-8377"`
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
