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

