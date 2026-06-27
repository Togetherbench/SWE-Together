You are working on the hyperswitch repository (Rust payment processing system).

REPOSITORY SETUP:
- Repository: juspay/hyperswitch
- Working directory: ./repos/hyperswitch_pool_5 (already cloned)
- Base commit: 2553780051e3a2fe54fcb99384e4bd8021d52048
- Task ID: juspay__hyperswitch-9465
- Version: v1.117.0

TASK DESCRIPTION:
Bug: DB changes for split payments (v2)



The following DB changes need to be made to support split payments:

In PaymentIntent:
- Add `active_attempts_group_id` column
- Add `active_attempt_id_type` column

In PaymentAttempt:
- Add `attempts_group_id` column


While currently a `payment_intent` can have only a single `active_attempt`, For split payments case, a `payment_intent` will have a group of active attempts. These attempts will be linked together by the `attempts_group_id`.

This `attempts_group_id` will be stored in the payment intent as the `active_attempts_group_id`. The `active_attempt_id` will be ignored in split payments case.

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
Added DB changes for split payments

In PaymentIntent:
- Add `active_attempts_group_id` column
- Add `active_attempt_id_type` column

In PaymentAttempt:
- Add `attempts_group_id` column

While currently a payment_intent can have only a single active_attempt, For split payments case, a payment_intent will have a group of active attempts. These attempts will be linked together by the `attempts_group_id`.

This `attempts_group_id` will be stored in the payment intent as the `active_attempts_group_id`. The active_attempt_id will be ignored in split payments case.

### Additional Changes

- [ ] This PR modifies the API contract
- [x] This PR modifies the database schema
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
Closes #9465 

## How did you test it?
<!--
Did you write an integration/unit/API test to verify the code changes?
Or did you test this change manually (provide relevant screenshots)?
-->
This PR only contains DB changes. No API changes are done

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
   - All repo files: './repos/hyperswitch_pool_5/<path>'
   - Use targeted edits over whole file rewrites

4. COMMIT YOUR WORK BEFORE FINISHING:
   - Stage meaningful changes with `git add -A`
   - Create a single commit using `git commit -m "task juspay__hyperswitch-9465"`
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
