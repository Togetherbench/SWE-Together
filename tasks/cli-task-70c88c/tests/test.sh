#!/usr/bin/env bash
set -euo pipefail

# Use the task's independent behavior check; submitted test names are irrelevant.
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
REPO_DIR="${REPO_DIR:-/workspace/cli}"

python3 "$TESTS_DIR/verify_behavior.py" --repo "$REPO_DIR" --logs "$LOGS_DIR"
cat "$LOGS_DIR/reward.txt"
