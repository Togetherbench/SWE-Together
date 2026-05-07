"""Vendored from SWE-rebench-V2 (MIT license, Copyright 2026 SWE-rebench).

Source: https://github.com/SWE-rebench/SWE-rebench-V2/blob/main/lib/agent/log_parsers.py
Verified at sha (the commit at clone time) — pinned for reproducibility.

We use these to extract test_name → status mappings from test runner stdout
(pytest, vitest, cargo, gotest, etc.). Each task's `install_config.log_parser`
field names which parser to use.
"""

from . import log_parsers
from .log_parsers import NAME_TO_PARSER
from .swe_constants import TestStatus

__all__ = ["log_parsers", "NAME_TO_PARSER", "TestStatus"]
