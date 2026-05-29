"""Per-turn git diff capture, shared by every user-enabled agent wrapper.

Background: ~10-20% of task Dockerfiles mutate the working tree
post-checkout (`rm -f AGENTS.md`, `sed -i`, etc.) without committing.
~29 of the v0.5.1 tasks also clone repos outside `/workspace`. Both
issues silently produce empty per-turn patches unless we (a) snapshot
the working tree as `harbor-base` before the agent runs and (b)
discover every repo across a fixed allowlist of roots.

`_repo_discovery_cmd(action="tag")` writes the baseline tag in every
repo found. `_repo_discovery_cmd(action="diff", turn=N, prev_turn=N-1)`
emits cumulative (vs `harbor-base`) + incremental (vs `harbor-turn-N-1`)
diffs framed by HARBOR_DIFF markers. `split_diff_output()` parses the
framed output. `capture_git_diff()` runs the diff cmd, writes the
patches under `<logs_dir>/patches/`, and returns the incremental diff
so the caller can hand it to the user simulator.
"""

from __future__ import annotations

import logging
from pathlib import Path

log = logging.getLogger(__name__)

# Allowlist of roots searched for `.git` dirs during per-turn patch
# capture. Tasks that need additional paths can set
# HARBOR_REPO_PATHS=/a:/b:/c (colon-separated) in the Dockerfile/runtime env.
DEFAULT_REPO_ROOTS = (
    "/workspace /opt /home /app /repo /tmp "
    "/entire-cli /entireio-cli /no-magic"
)


def _repo_discovery_cmd(
    *, action: str, turn: int | None = None, prev_turn: int | None = None
) -> str:
    """Build a bash command that discovers git repos and runs `action`.

    Discovery: union of DEFAULT_REPO_ROOTS and HARBOR_REPO_PATHS
    (colon-separated env var). For each existing root, `find -maxdepth 3`
    locates `.git` dirs/files (the latter for worktrees). Per-repo git
    ops use `-c safe.directory="$PWD"` to tolerate ownership mismatches.
    """
    if action == "tag":
        per_repo = (
            '  (cd "$d" && \\\n'
            '     git -c safe.directory="$PWD" add -A 2>/dev/null && \\\n'
            '     git -c safe.directory="$PWD" -c user.email=harbor@base -c user.name=harbor \\\n'
            '       commit --allow-empty --no-verify -m "harbor-base" --quiet 2>/dev/null && \\\n'
            '     git -c safe.directory="$PWD" tag -f harbor-base HEAD 2>/dev/null) || true\n'
        )
        return (
            'set +e\n'
            f'ROOTS="{DEFAULT_REPO_ROOTS}"\n'
            'if [ -n "${HARBOR_REPO_PATHS:-}" ]; then\n'
            '  ROOTS="$ROOTS $(echo "$HARBOR_REPO_PATHS" | tr ":" " ")"\n'
            'fi\n'
            'EXISTING=""\n'
            'for r in $ROOTS; do [ -e "$r" ] && EXISTING="$EXISTING $r"; done\n'
            '[ -z "$EXISTING" ] && exit 0\n'
            'REPOS=$(find $EXISTING -maxdepth 3 \\( -type d -o -type f \\) -name .git 2>/dev/null | sort -u)\n'
            'for gitdir in $REPOS; do\n'
            '  d=$(dirname "$gitdir")\n'
            f'{per_repo}'
            'done\n'
        )

    assert action == "diff" and turn is not None and prev_turn is not None
    per_repo = (
        '  d=$(dirname "$gitdir")\n'
        '  cd "$d" || continue\n'
        '  HEAD_BEFORE=$(git -c safe.directory="$PWD" rev-parse --verify HEAD 2>/dev/null)\n'
        '  if [ "$PREV_TURN" -ge 0 ] && git -c safe.directory="$PWD" rev-parse --verify "harbor-turn-$PREV_TURN" >/dev/null 2>&1; then\n'
        '    PREV_REF="harbor-turn-$PREV_TURN"\n'
        '  elif git -c safe.directory="$PWD" rev-parse --verify harbor-base >/dev/null 2>&1; then\n'
        '    PREV_REF=harbor-base\n'
        '  elif [ -n "$HEAD_BEFORE" ]; then\n'
        '    PREV_REF="$HEAD_BEFORE"\n'
        '  else\n'
        '    PREV_REF=HEAD\n'
        '  fi\n'
        '  git -c safe.directory="$PWD" add -A 2>/dev/null\n'
        # --no-verify skips pre-commit hooks. Repos with husky/lint-staged
        # (e.g. comfyui-frontend-autoscale-layout, anywhere with prettier/eslint
        # on commit) fail the hook in the sandbox (no pnpm install for hook deps),
        # the commit silently fails, HEAD stays at harbor-base, and
        # `git diff harbor-base HEAD` returns empty — masking real agent edits.
        '  git -c safe.directory="$PWD" -c user.email=harbor@base -c user.name=harbor \\\n'
        '    commit --allow-empty --no-verify -m "harbor-turn-$TURN" --quiet 2>/dev/null\n'
        '  git -c safe.directory="$PWD" tag -f "harbor-turn-$TURN" HEAD 2>/dev/null\n'
        '  if git -c safe.directory="$PWD" rev-parse --verify harbor-base >/dev/null 2>&1; then\n'
        '    printf "=== %s (cumulative vs harbor-base) ===\\n" "$d" >> /tmp/harbor_cum.diff\n'
        '    git -c safe.directory="$PWD" --no-pager diff harbor-base HEAD 2>/dev/null >> /tmp/harbor_cum.diff\n'
        '    printf "\\n" >> /tmp/harbor_cum.diff\n'
        '  fi\n'
        '  printf "=== %s (incremental vs %s) ===\\n" "$d" "$PREV_REF" >> /tmp/harbor_inc.diff\n'
        '  git -c safe.directory="$PWD" --no-pager diff "$PREV_REF" HEAD 2>/dev/null >> /tmp/harbor_inc.diff\n'
        '  printf "\\n" >> /tmp/harbor_inc.diff\n'
    )
    return (
        'set +e\n'
        f'TURN={turn}\n'
        f'PREV_TURN={prev_turn}\n'
        f'ROOTS="{DEFAULT_REPO_ROOTS}"\n'
        'if [ -n "${HARBOR_REPO_PATHS:-}" ]; then\n'
        '  ROOTS="$ROOTS $(echo "$HARBOR_REPO_PATHS" | tr ":" " ")"\n'
        'fi\n'
        ': > /tmp/harbor_cum.diff\n'
        ': > /tmp/harbor_inc.diff\n'
        'EXISTING=""\n'
        'for r in $ROOTS; do [ -e "$r" ] && EXISTING="$EXISTING $r"; done\n'
        'if [ -n "$EXISTING" ]; then\n'
        '  REPOS=$(find $EXISTING -maxdepth 3 \\( -type d -o -type f \\) -name .git 2>/dev/null | sort -u)\n'
        '  for gitdir in $REPOS; do\n'
        f'{per_repo}'
        '    cd - >/dev/null\n'
        '  done\n'
        'fi\n'
        'echo "===HARBOR_DIFF_BEGIN_CUM==="\n'
        'cat /tmp/harbor_cum.diff 2>/dev/null\n'
        'echo "===HARBOR_DIFF_END_CUM==="\n'
        'echo "===HARBOR_DIFF_BEGIN_INC==="\n'
        'cat /tmp/harbor_inc.diff 2>/dev/null\n'
        'echo "===HARBOR_DIFF_END_INC==="\n'
        'rm -f /tmp/harbor_cum.diff /tmp/harbor_inc.diff\n'
    )


def split_diff_output(raw: str) -> tuple[str, str]:
    """Split the dual-section _repo_discovery_cmd("diff") stdout into (cum, inc)."""
    cum_lines, inc_lines = [], []
    mode = None
    for line in raw.split("\n"):
        stripped = line.rstrip("\r")
        if stripped == "===HARBOR_DIFF_BEGIN_CUM===":
            mode = "cum"
            continue
        if stripped == "===HARBOR_DIFF_END_CUM===":
            mode = None
            continue
        if stripped == "===HARBOR_DIFF_BEGIN_INC===":
            mode = "inc"
            continue
        if stripped == "===HARBOR_DIFF_END_INC===":
            mode = None
            continue
        if mode == "cum":
            cum_lines.append(line)
        elif mode == "inc":
            inc_lines.append(line)
    return "\n".join(cum_lines).strip(), "\n".join(inc_lines).strip()


async def tag_harbor_base(environment) -> None:
    """Snapshot every repo's working tree as `harbor-base` for diff baselines."""
    try:
        await environment.exec(
            command=_repo_discovery_cmd(action="tag"),
            cwd="/",
            env={},
            timeout_sec=30,
        )
        log.debug("harbor-base tagged in discovered git repos")
    except Exception as e:
        log.debug("harbor-base tagging failed (best-effort): %s", e)


async def capture_git_diff(
    environment, *, logs_dir: Path, turn: int
) -> str:
    """Snapshot per-turn git state for every discovered repo.

    Writes two artifacts:
      - <logs_dir>/patches/turn-<N>.patch — cumulative vs `harbor-base`
      - <logs_dir>/patches/turn-<N>.incremental.patch — vs the previous turn
        (or `harbor-base` for turn 0).

    Also overwrites <logs_dir>/final.patch with the cumulative diff so
    it always reflects the most recent state.

    Returns the incremental diff string ("" if nothing changed) so the
    caller can stash it for the next user-sim consultation. Returning
    "" on no-change is intentional — the sim prompt suppresses the
    diff section when the string is empty.
    """
    prev_turn = turn - 1
    cmd = _repo_discovery_cmd(action="diff", turn=turn, prev_turn=prev_turn)
    try:
        result = await environment.exec(
            command=cmd,
            cwd="/",
            env={},
            timeout_sec=90,
        )
    except Exception as e:
        log.debug("git diff capture failed at turn %d: %s", turn, e)
        return ""

    if not result.stdout:
        return ""

    cumulative, incremental = split_diff_output(result.stdout)
    patches_dir = logs_dir / "patches"

    if cumulative:
        patches_dir.mkdir(parents=True, exist_ok=True)
        (patches_dir / f"turn-{turn}.patch").write_text(cumulative + "\n")
        (logs_dir / "final.patch").write_text(cumulative + "\n")

    if incremental:
        patches_dir.mkdir(parents=True, exist_ok=True)
        (patches_dir / f"turn-{turn}.incremental.patch").write_text(
            incremental + "\n"
        )

    return incremental
