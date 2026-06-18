"""Shared .env loader for the correctness eval.

Moved out of the now-removed legacy single-pass `judge_one.py` so the canonical
pipeline (`run_batch.py`) can load `.env` without pulling in the deprecated
single-pass judge.
"""
from __future__ import annotations

import os
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def load_dotenv() -> None:
    """Load .env into os.environ.setdefault — process env wins."""
    env_file = REPO_ROOT / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip())
