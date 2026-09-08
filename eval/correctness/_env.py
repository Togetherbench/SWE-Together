"""Shared .env loader for the correctness eval.

Moved out of the now-removed legacy single-pass `judge_one.py` so the canonical
pipeline (`run_batch.py`) can load `.env` without pulling in the deprecated
single-pass judge. Delegates to the repo-wide loader in ``src/sandbox_config.py``
so quoting rules are identical everywhere (values like
``SWT_AWS_CREDENTIAL_CMD="... -d {lease} ..."`` must lose their quotes).
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT / "src") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "src"))

from sandbox_config import load_dotenv as _load_dotenv  # noqa: E402


def load_dotenv() -> None:
    """Load .env into os.environ.setdefault — process env wins."""
    _load_dotenv(REPO_ROOT / ".env")
