You are working on the hyperswitch repository (Rust payment processing system).

REPOSITORY SETUP:
- Repository: juspay/hyperswitch
- Working directory: ./repos/hyperswitch_pool_9 (already cloned)
- Base commit: 8446ffbf5992a97d79d129cade997effc60fcd85
- Task ID: juspay__hyperswitch-9063
- Version: v1.116.0

TASK DESCRIPTION:
Bug: Change Underscore(_) to hyphen(-) in payment link locale.



Change Underscore(_) to hyphen(-) in payment link locale.

DETAILED CONTEXT & HINTS:
## Type of Change
<!-- Put an `x` in the boxes that apply -->

- [x] Bugfix
- [ ] New feature
- [ ] Enhancement
- [ ] Refactoring
- [ ] Dependency updates
- [ ] Documentation
- [ ] CI/CD

## Description
<!-- Describe your changes in detail -->
Change Underscore(_) to hyphen(-) in payment link locale according to ISO standards.

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
We need to follow ISO standards when accepting the locale for payment links.


## How did you test it?
<!--
Did you write an integration/unit/API test to verify the code changes?
Or did you test this change manually (provide relevant screenshots)?
-->
```
curl --location 'http://localhost:8080/payments' \
--header 'Content-Type: application/json' \
--header 'Accept: application/json' \
--header 'api-key: **' \
--header 'Accept-Language: zh-hant' \
--data '{
    "amount": 10,
    "setup_future_usage": "off_session",
    "currency": "EUR",
    "payment_link": true,
    "session_expiry": 60,
    "return_url": "https://google.com",
    "payment_link_config": {
        "theme": "#14356f",
        "logo": "https://logo.com/wp-content/uploads/2020/08/zurich.svg",
        "seller_name": "Zurich Inc."
    }
}'
```
```
zh-hant - should see traditional chinese
zh_hant - english
zh-hant-abcdef - traditional chinese
zh - simplified chinese
Zh - simplified chinese
ZH-HANT - traditional chinese
zh-abcdef - simplified chinese
```
<img width="2560" height="1440" alt="image" src="https://github.com/user-attachments/assets/a1c25820-6e50-480f-96f6-5a831a856bfd" />
<img width="2560" height="1440" alt="image" src="https://github.com/user-attachments/assets/1db9322d-601e-49df-bf2f-6e5f1911d4cd" />
<img width="2560" height="1440" alt="image" src="https://github.com/user-attachments/assets/d934116c-a24a-479d-86e6-9f0b25028400" />


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
   - All repo files: './repos/hyperswitch_pool_9/<path>'
   - Use targeted edits over whole file rewrites

4. COMMIT YOUR WORK BEFORE FINISHING:
   - Stage meaningful changes with `git add -A`
   - Create a single commit using `git commit -m "task juspay__hyperswitch-9063"`
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
