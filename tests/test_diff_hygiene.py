"""Graded-diff hygiene: run-generated module caches are stripped from the patch,
the per-turn diff shown to the user simulator is bounded, and patches recorded
before a filter change can be repaired and re-judged instead of scored as-is.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))
sys.path.insert(0, str(REPO_ROOT / "external" / "harbor" / "src"))

from user_agent import repo_diff  # noqa: E402
import repair_polluted_patches as repair  # noqa: E402


def _block(path: str, body: str = "+x\n") -> str:
    return f"diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n@@ -1 +1 @@\n{body}"


SOURCE = _block("cmd/entire/cli/strategy/manual_commit.go", "+fixed := true\n")
TEST = _block("cmd/entire/cli/strategy/manual_commit_test.go")


# ── junk filter ───────────────────────────────────────────────────────────

@pytest.mark.parametrize("junk", [
    ".go/pkg/mod/github.com/spf13/cobra@v1.8.0/command.go",   # in-repo GOPATH (cli-fix-2026-0)
    "vendor/pkg/mod/cache/download/golang.org/x/sys/list",
    ".cargo/registry/src/index/serde-1.0.0/lib.rs",
    ".npm/_cacache/index-v5/aa/bb",
    ".pnpm-store/v3/files/00/abc",
    ".m2/repository/org/apache/foo.jar",
    "node_modules/left-pad/index.js",                          # pre-existing rule still holds
])
def test_module_caches_are_stripped(junk):
    diff = "\n".join([SOURCE, _block(junk), TEST])
    out = repo_diff._strip_junk(diff)
    assert junk not in out
    assert "manual_commit.go" in out and "manual_commit_test.go" in out


@pytest.mark.parametrize("keep", [
    "main.go",                       # `.go` the extension, not the directory
    "cmd/entire/cli/hooks.go",
    "pkg/models/user.go",            # `pkg/` alone is a normal source dir; only pkg/mod is junk
    "internal/cargo/loader.py",      # `cargo` without the dot
    "docs/go/README.md",             # `go/` without the dot
])
def test_source_files_survive_the_filter(keep):
    diff = "\n".join([_block(keep), _block(".go/pkg/mod/x/y.go")])
    out = repo_diff._strip_junk(diff)
    assert keep in out and ".go/pkg/mod" not in out


def test_real_polluted_patch_shape():
    """36k-file cumulative diff → only the handful of source files remain."""
    files = [f".go/pkg/mod/golang.org/x/tools@v0.1.{i}/file{i}.go" for i in range(3000)]
    diff = "\n".join([SOURCE] + [_block(f) for f in files] + [TEST])
    out = repo_diff._strip_junk(diff)
    assert out.count("diff --git ") == 2


# ── user-sim diff cap ─────────────────────────────────────────────────────

def test_small_diff_passes_through_untouched():
    assert repo_diff.truncate_diff_for_user_sim(SOURCE) == SOURCE


def test_huge_diff_is_cut_on_a_line_boundary_with_marker():
    big = "\n".join(_block(f"src/f{i}.py", "+" + "y" * 200 + "\n") for i in range(5000))
    assert len(big) > repo_diff.USER_SIM_DIFF_MAX_CHARS
    out = repo_diff.truncate_diff_for_user_sim(big)
    assert len(out) < repo_diff.USER_SIM_DIFF_MAX_CHARS + 300
    body, marker = out.rsplit("\n", 1)
    assert marker.startswith("[... diff truncated for the user simulator:")
    assert "across 5000 files" in marker
    assert body.endswith("\n") is False and body.split("\n")[-1] in big.split("\n")  # whole line kept


# ── repair tool ───────────────────────────────────────────────────────────

def _trial(root: Path, name: str, patch: str, *, verdict: dict | None, flag: int | None) -> Path:
    t = root / name
    (t / "agent" / "patches").mkdir(parents=True)
    (t / "agent" / "final.patch").write_text(patch + "\n")
    if flag is not None:
        (t / "agent" / "diff_polluted.flag").write_text(f"{flag}\n")
    if verdict is not None:
        (t / "judge_verdict.json").write_text(json.dumps(verdict))
    return t


def test_repair_rewrites_patch_and_retires_verdict(tmp_path):
    polluted = "\n".join([SOURCE] + [_block(f".go/pkg/mod/m{i}/a.go") for i in range(50)])
    t = _trial(tmp_path, "cli-fix-2026-0__abc", polluted, verdict={"judge_score": 0.0, "verdict": "incorrect"}, flag=51)
    rec = repair.repair_trial(t)
    assert rec and rec["before_files"] == 51 and rec["after_files"] == 1 and rec["verdict_retired"]
    assert (t / "agent" / "final.patch").read_text().count("diff --git") == 1
    assert (t / "agent" / "final.patch.unfiltered").read_text().count("diff --git") == 51
    assert not (t / "judge_verdict.json").exists() and (t / "judge_verdict.polluted-1.json").exists()
    assert not (t / "agent" / "diff_polluted.flag").exists() and (t / "agent" / "diff_polluted.repaired").exists()
    # idempotent: a second pass finds nothing to do
    assert repair.repair_trial(t) is None


def test_repair_leaves_clean_trials_alone(tmp_path):
    t = _trial(tmp_path, "task__clean", "\n".join([SOURCE, TEST]), verdict={"judge_score": 0.9}, flag=None)
    assert repair.repair_trial(t, dry_run=False) is None
    assert (t / "judge_verdict.json").exists() and not (t / "agent" / "final.patch.unfiltered").exists()


def test_repair_dry_run_changes_nothing(tmp_path):
    t = _trial(tmp_path, "task__dry", "\n".join([SOURCE, _block(".go/pkg/mod/z/z.go")]), verdict={"judge_score": 0.0}, flag=2)
    rec = repair.repair_trial(t, dry_run=True)
    assert rec and rec["after_files"] == 1
    assert (t / "judge_verdict.json").exists() and (t / "agent" / "diff_polluted.flag").exists()


# ── evaluator guards ──────────────────────────────────────────────────────

def test_judge_batch_skips_flagged_patch():
    src = (REPO_ROOT / "eval" / "correctness" / "run_batch.py").read_text()
    assert 'result["status"] = "skipped_polluted_patch"' in src
    assert src.index("skipped_polluted_patch") < src.index("skipped_empty_patch")


def test_aggregator_refuses_flagged_patch(tmp_path):
    # eval/run_eval.py shares its module name with src/run_eval.py — load by path.
    import importlib.util
    spec = importlib.util.spec_from_file_location("swt_eval_run_eval", REPO_ROOT / "eval" / "run_eval.py")
    run_eval = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(run_eval)
    t = tmp_path / "task__x"
    (t / "agent").mkdir(parents=True)
    (t / "agent" / "final.patch").write_text(SOURCE)
    (t / "agent" / "diff_polluted.flag").write_text("1466\n")
    with pytest.raises(SystemExit, match="diff_polluted.flag"):
        run_eval._effective_judge_score(t, {"judge_score": 0.0})
    (t / "agent" / "diff_polluted.flag").unlink()
    assert run_eval._effective_judge_score(t, {"judge_score": 0.7}) == 0.7
