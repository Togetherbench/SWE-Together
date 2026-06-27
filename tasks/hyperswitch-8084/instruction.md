You are working on the hyperswitch repository (Rust payment processing system).

REPOSITORY SETUP:
- Repository: juspay/hyperswitch
- Working directory: ./repos/hyperswitch_pool_5 (already cloned)
- Base commit: 344dcd6e43022c3e5479629b57bff255b903d5b5
- Task ID: juspay__hyperswitch-8084
- Version: v1.114.0

TASK DESCRIPTION:
Bug: [FEATURE] Add api-key support for routing APIs



### Feature Description

Need to add api-key auth for all routing APIs

### Possible Implementation

Just need to change auth implementation on handler

### Have you spent some time checking if this feature request has been raised before?

- [x] I checked and didn't find a similar issue

### Have you read the Contributing Guidelines?

- [x] I have read the [Contributing Guidelines](https://github.com/juspay/hyperswitch/blob/main/docs/CONTRIBUTING.md)

### Are you willing to submit a PR?

Yes, I am willing to submit a PR!

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
Added api-key auth for routing APIs
Earlier, all routing endpoints were only JWT auth based for release build and (api-key + JWT) for local development build. Have removed the feature flag based distinction and refactored auth for all routing endpoints to be (api-key + JWT) for both builds.


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
Test all routing APIs with api-key auth
1. Create routing config (`/routing`)
2. List routing config  (`/routing`)
3. List active routing config (`/routing/active`)
4. List for profile (`/routing/list/profile`)
5. activate config (`routing/:id/activate`)
6. retrieve config (`routing/:id`)
7. deactivate (`routing/deactivate`)
8. default profile (`routing/default/profile`)
9. update default profile (`routing/default/profile/:profile_id`)
10. update default config (`/routing/default`)


```
curl --location 'http://127.0.0.1:8080/routing' \
--header 'Content-Type: application/json' \
--header 'api-key: dev_nvORdH8glyzL3AyPwkWcb7GsLD7xi7PU7kHZpvRWlPJNnEz1dQPrCN1swXFFjKEk' \
--data '
{
    "name": "advanced config",
    "description": "It is my ADVANCED config",
    "profile_id": "pro_rfW0Fv5J0Cct1Bnw2EuS",
    "algorithm": {
        "type": "advanced",
        "data": {
            "defaultSelection": {
                "type": "priority",
                "data": [
                    {
                        "connector": "stripe",
                        "merchant_connector_id": "mca_aHTJXYcakT5Nlx48kuSh"
                    }
                ]
            },
            "rules": [
                {
                    "name": "cybersource first",
                    "connectorSelection": {
                        "type": "priority",
                        "data": [
                            {
                                "connector": "cybersource",
                                "merchant_connector_id": "mca_rJu5LzTmK2SjYgoRMWZ4"
                            }
                        ]
                    },
                    "statements": [
                        {
                            "condition": [
                                {
                                    "lhs": "upi",
                                    "comparison": "equal",
                                    "value": {
                                        "type": "enum_variant",
                                        "value": "upi_collect"
                                    },
                                    "metadata": {}
                                }
                            ],
                            "nested": [
                                {
                                    "condition": [
                                        {
                                            "lhs": "amount",
                                            "comparison": "greater_than",
                                            "value": {
                                                "type": "number",
                                                "value": 5000
                                            },
                                            "metadata": {}
                                        },
                                        {
                                            "lhs": "currency",
                                            "comparison": "equal",
                                            "value": {
                                                "type": "enum_variant",
                                                "value": "USD"
                                            },
                                            "metadata": {}
                                        }
                                    ]
                                },
                                {
                                    "condition": [
                                        {
                                            "lhs": "amount",
                                            "comparison": "greater_than",
                                            "value": {
                                                "type": "number",
                                                "value": 10000
                                            },
                                            "metadata": {}
                                        }
                                    ]
                                }
                            ]
                        }
                    ]
                }
            ],
            "metadata": {}
        }
    }
}'
```

```
 curl -X GET --location 'http://127.0.0.1:8080/routing' \
--header 'Content-Type: application/json' \
--header 'api-key: dev_Qe471NOXDpSt0z1VFlmFpFrKNZ9vbxKju4iIyBWaJ0iOXwHpvqFDc26LfhF06Rio'
```

```
curl -X GET --location 'http://127.0.0.1:8080/routing' \
--header 'Content-Type: application/json' \
--header 'Authorization: Bearer REDACTED_JWT' \
--cookie "login_token=REDACTED_JWT"
```

```
curl -X GET --location 'http://127.0.0.1:8080/routing/active' \
--header 'Content-Type: application/json' \
--header 'api-key: dev_Qe471NOXDpSt0z1VFlmFpFrKNZ9vbxKju4iIyBWaJ0iOXwHpvqFDc26LfhF06Rio'
```

```
curl -X GET --location 'http://127.0.0.1:8080/routing/active' \
--header 'Content-Type: application/json' \
--header 'Authorization: Bearer REDACTED_JWT' \
--cookie "login_token=REDACTED_JWT"
```

```
 curl --location 'http://127.0.0.1:8080/routing/list/profile' \
--header 'api-key: dev_Qe471NOXDpSt0z1VFlmFpFrKNZ9vbxKju4iIyBWaJ0iOXwHpvqFDc26LfhF06Ri
```

```
 curl --location 'http://127.0.0.1:8080/routing/list/profile' \
--header 'Authorization: Bearer REDACTED_JWT' \
--cookie "login_token=REDACTED_JWT"
```

```
curl --location --request POST 'http://localhost:8080/routing/routing_o7xnnpZ8MtkbuEpsDsjK/activate' \
--header 'api-key: dev_Qe471NOXDpSt0z1VFlmFpFrKNZ9vbxKju4iIyBWaJ0iOXwHpvqFDc26LfhF06Rio'
```

```
curl --location --request POST 'http://localhost:8080/routing/routing_o7xnnpZ8MtkbuEpsDsjK/activate' \
--header 'Authorization: Bearer REDACTED_JWT' \
--cookie "login_token=REDACTED_JWT"
```


```
curl --location 'http://127.0.0.1:8080/routing/routing_WkgC0lnKAnxSkBthgnK9' \
--header 'api-key: dev_Qe471NOXDpSt0z1VFlmFpFrKNZ9vbxKju4iIyBWaJ0iOXwHpvqFDc26LfhF06Rio'
```

```
curl --location 'http://127.0.0.1:8080/routing/routing_WkgC0lnKAnxSkBthgnK9' \
--header 'Authorization: Bearer REDACTED_JWT' \
--cookie "login_token=REDACTED_JWT"

```

```
 curl --location 'http://127.0.0.1:8080/routing/deactivate' \
--header 'Content-Type: application/json' \
--header 'api-key: dev_Qe471NOXDpSt0z1VFlmFpFrKNZ9vbxKju4iIyBWaJ0iOXwHpvqFDc26LfhF06Rio' \
--data '{
    "profile_id": "pro_rfW0Fv5J0Cct1Bnw2EuS"
}'
```

```
curl --location 'http://127.0.0.1:8080/routing/deactivate' \
--header 'Content-Type: application/json' \
--header 'Authorization: Bearer REDACTED_JWT' \
--cookie "login_token=REDACTED_JWT" \
--data '{
    "profile_id": "pro_rfW0Fv5J0Cct1Bnw2EuS"
}'

```

```
 curl --location 'http://127.0.0.1:8080/routing/default/profile' \
--header 'api-key: dev_Qe471NOXDpSt0z1VFlmFpFrKNZ9vbxKju4iIyBWaJ0iOXwHpvqFDc26LfhF06Rio'
```

```
curl --location 'http://127.0.0.1:8080/routing/default/profile' \
--header 'Authorization: Bearer REDACTED_JWT' \
--cookie "login_token=REDACTED_JWT"

```

```
curl --location 'http://127.0.0.1:8080/routing/default/profile/pro_rfW0Fv5J0Cct1Bnw2EuS' \
--header 'Content-Type: application/json' \
--header 'api-key: dev_nvORdH8glyzL3AyPwkWcb7GsLD7xi7PU7kHZpvRWlPJNnEz1dQPrCN1swXFFjKEk' \
--data '[    
    {
        "connector": "paypal",
        "merchant_connector_id": "mca_yHGYuTt4V8DGigmrfwYc"
    }
]'
```
```
curl --location 'http://127.0.0.1:8080/routing/default/profile/pro_rfW0Fv5J0Cct1Bnw2EuS' \
--header 'Content-Type: application/json' \
--header 'Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjoiZDA1ODU2ZWEtYWMxMy00MjcwLTg3NDAtNWFjOTk1NGFlZjhhIiwibWVyY2hhbnRfaWQiOiJtZXJjaGFudF8xNzQ3ODIzMjg1Iiwicm9sZV9pZCI6Im9yZ19hZG1pbiIsImV4cCI6MTc0Nzk5NzIyMCwib3JnX2lkIjoib3JnX1MyU2t6WXRyMUREcF \
--cookie "login_token=REDACTED_JWT" 

```

```
curl --location 'http://127.0.0.1:8080/routing/default' \
--header 'Content-Type: application/json' \
--header 'api-key: dev_Qe471NOXDpSt0z1VFlmFpFrKNZ9vbxKju4iIyBWaJ0iOXwHpvqFDc26LfhF06Rio' \
--data '[    
    
    {
        "connector": "paypal",
        "merchant_connector_id": "mca_yHGYuTt4V8DGigmrfwYc"
    }                         
]'
```

```
curl --location 'http://127.0.0.1:8080/routing/default/profile/pro_rfW0Fv5J0Cct1Bnw2EuS' \
--header 'Content-Type: application/json' \
--header 'Authorization: Bearer REDACTED_JWT' \
--cookie "login_token=REDACTED_JWT" \
--data '[    
    {
        "connector": "paypal",
        "merchant_connector_id": "mca_yHGYuTt4V8DGigmrfwYc"
    }
]'

```

Response in case of incorrect api-key used - 
```
{"error":{"type":"invalid_request","message":"API key not provided or invalid API key used","code":"IR_01"}
```

--> For SR based routing
Hit this curl consecutively two time. earlier it would have errored out saying the specific routing is already enabled, but now it will provide back the `routing_dictionary_record`.
```
curl --location --request POST 'http://localhost:8080/account/merchant_1747754221/business_profile/pro_zynmxiTVItHGAekOFaum/dynamic_routing/success_based/toggle?enable=metrics' \
--header 'api-key: dev_es32CnydqbfAKJTxccqSW25IhfJOjkvAAX5raCzR9BdZjdZ28jQy8uoGMNbwv5Kk'
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
   - All repo files: './repos/hyperswitch_pool_5/<path>'
   - Use targeted edits over whole file rewrites

4. COMMIT YOUR WORK BEFORE FINISHING:
   - Stage meaningful changes with `git add -A`
   - Create a single commit using `git commit -m "task juspay__hyperswitch-8084"`
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
