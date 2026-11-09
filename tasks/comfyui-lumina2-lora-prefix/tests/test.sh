#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${REPO_DIR:-/workspace/ComfyUI}"
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
VENV_PY="${VENV_PY:-/workspace/venv/bin/python3}"
mkdir -p "$LOGS_DIR"
# Remove stale success before imports; setup failures must leave no numeric reward.
rm -f "$LOGS_DIR/reward.txt" "$LOGS_DIR/gates.json" "$LOGS_DIR/behavior.json"
cd "$REPO_DIR"
PYTHONPATH="$REPO_DIR${PYTHONPATH:+:$PYTHONPATH}" "$VENV_PY" "$TESTS_DIR/verify_behavior.py" --logs "$LOGS_DIR"
