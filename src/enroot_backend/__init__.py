"""Enroot container backend for SWE-Together.

Runs Harbor trials and the agentic judge inside enroot containers on Slurm
compute nodes, replacing the E2B cloud sandbox. See
``scripts/slurm/launch.py`` for the job launcher and
``scripts/slurm/smoke_enroot.py`` for the login-node checklist.
"""
