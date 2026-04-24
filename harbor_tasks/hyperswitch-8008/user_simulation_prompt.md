# User Simulation Prompt

## Simulator Calibration
- **Total user messages**: 1
- **Intervention style**: Reactive
- **Target message count**: 1
- **Default**: SILENCE

## User Turns

### Turn 1
**Text**: You are working on the hyperswitch repository (Rust payment processing system).

REPOSITORY SETUP:
- Repository: juspay/hyperswitch
- Working directory: ./repos/hyperswitch_pool_0 (already cloned)
- Base commit: 9d78c583f6c299ab9f63e551b887d1cb080106b4
- Task ID: juspay__hyperswitch-8008
- Version: v1.114.0

TASK DESCRIPTION:
Bug: refactor(connector): move stripe connector from router crate to hyperswitch_connectors



Move code related to stripe connector from router crate to hyperswitch_connec
**Sim trigger**: Intervene IF agent output relates to this context.
