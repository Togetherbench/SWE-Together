#!/usr/bin/env python3
"""One-time E2B template build for scaffold workers.

Bakes claude-code@2.1.108 into a custom template with 8 vCPU + 4 GB RAM.
Run once; subsequent run_e2b.py invocations reuse the alias.

Usage:
    python data-pipeline/scaffold/build_template.py
    python data-pipeline/scaffold/build_template.py --rebuild  # bust cache
"""

import argparse
import asyncio
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ALIAS = "harbor-scaffold-cc2-1-108-8c-4g"
CC_VERSION = "2.1.108"
CPU_COUNT = 8
MEMORY_MB = 4096


def _load_env():
    env_path = ROOT / ".env"
    parents = [ROOT.parent, ROOT.parent.parent, ROOT.parent.parent.parent, ROOT.parent.parent.parent.parent]
    candidates = [env_path] + [p / ".env" for p in parents]
    for c in candidates:
        if c.exists():
            for line in c.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
            break


async def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--rebuild", action="store_true", help="Skip cache, force fresh build")
    args = p.parse_args()

    _load_env()
    if not (os.environ.get("E2B_API_KEY") or os.environ.get("e2b_api_key")):
        print("ERROR: E2B_API_KEY missing"); return 2
    os.environ["E2B_API_KEY"] = os.environ.get("E2B_API_KEY") or os.environ["e2b_api_key"]

    from e2b import Template, AsyncTemplate

    print(f"Checking if alias '{ALIAS}' already exists...")
    try:
        exists = await AsyncTemplate.alias_exists(ALIAS)
    except Exception as e:
        print(f"  alias_exists check failed: {e}; assuming not exists")
        exists = False
    if exists and not args.rebuild:
        print(f"✓ Template '{ALIAS}' already exists. Use --rebuild to force.")
        return 0

    print(f"Building template '{ALIAS}' ({CPU_COUNT} vCPU, {MEMORY_MB} MB RAM, claude-code@{CC_VERSION})...")
    # Start from the standard node image (claude-code is npm-installed; node20 matches default base).
    # `npm install -g` needs root; the from_node_image default user is `user`. Use user="root"
    # for the install step so the global npm dir is writable.
    builder = (
        Template()
        .from_node_image("20")
        .run_cmd(f"npm install -g @anthropic-ai/claude-code@{CC_VERSION}", user="root")
        .run_cmd("claude --version")
        .run_cmd("mkdir -p /home/user/work && chown -R user:user /home/user/work", user="root")
    )

    def on_log(line):
        print(f"  [build] {line}")

    try:
        await AsyncTemplate.build(
            template=builder,
            alias=ALIAS,
            cpu_count=CPU_COUNT,
            memory_mb=MEMORY_MB,
            skip_cache=args.rebuild,
            on_build_logs=on_log,
        )
    except Exception as e:
        print(f"BUILD FAILED: {type(e).__name__}: {e}")
        return 1

    print(f"\n✓ Built template alias='{ALIAS}' (cpu={CPU_COUNT}, mem={MEMORY_MB} MB)")
    print(f"  Use in run_e2b.py via: AsyncSandbox.create(template='{ALIAS}', ...)")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
