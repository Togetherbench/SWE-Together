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
         
