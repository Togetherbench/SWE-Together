"""Graded-diff hygiene: run-generated module caches are stripped from the patch,
the per-turn diff shown to the user simulator is bounded, and patches recorded
before a filter change can be repaired and re-judged instead of scored as-is.
"""
from __future__ import annotations

import json
import os
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
        # verdicts without the provenance marker stand for pre-fix judge output
        os.utime(t / "judge_verdict.json", (repair.NORMALISED_JUDGE_SINCE - 86400,) * 2)
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


# ── trailing blank context line ───────────────────────────────────────────

# A hunk whose last line is an empty source line: its context line is a lone " ".
HUNK_ENDING_BLANK = ("diff --git a/x.go b/x.go\n--- a/x.go\n+++ b/x.go\n@@ -1,3 +1,3 @@\n"
                     " a\n-b\n+c\n ")


def test_trim_keeps_final_blank_context_line():
    raw = f"===HARBOR_DIFF_BEGIN_CUM===\n{HUNK_ENDING_BLANK}\n===HARBOR_DIFF_END_CUM===\n"
    cum, _ = repo_diff.split_diff_output(raw)
    assert cum.endswith("\n ")                      # str.strip() would have removed it
    assert repo_diff._strip_junk(cum).endswith("\n ")
    assert repo_diff._trim_diff("\n\n" + HUNK_ENDING_BLANK + "\n\n") == HUNK_ENDING_BLANK


# What old builds wrote: the trailing " " context line is gone, header still says 3/3.
HUNK_EATEN = HUNK_ENDING_BLANK.rstrip()
# The repaired form: the unknowable whitespace line is dropped and the header shrunk to match.
HUNK_SHRUNK = HUNK_EATEN.replace("@@ -1,3 +1,3 @@", "@@ -1,2 +1,2 @@")


def test_restore_trailing_context_shrinks_header_only_when_it_proves_a_loss():
    assert patch_normalize.restore_trailing_context(HUNK_EATEN) == HUNK_SHRUNK
    assert patch_normalize.restore_trailing_context(HUNK_SHRUNK) == HUNK_SHRUNK                 # idempotent
    assert patch_normalize.restore_trailing_context(HUNK_ENDING_BLANK) == HUNK_ENDING_BLANK     # intact hunk untouched
    assert patch_normalize.restore_trailing_context(SOURCE) == SOURCE.rstrip("\n")             # complete hunk: nothing changed


def test_repair_keeps_original_headers_and_sound_verdict_for_short_hunk(tmp_path):
    """A short last hunk is the judge's cue to try both reconstructions, so the
    stored text is left byte-for-byte (only junk gets stripped); a sound verdict stands."""
    t = _trial(tmp_path, "task__ctx", HUNK_EATEN, verdict={"judge_score": 0.9, "judge_notes": "all goals met"}, flag=None)
    assert repair.repair_trial(t) is None
    assert (t / "agent" / "final.patch").read_text() == HUNK_EATEN + "\n"
    assert (t / "judge_verdict.json").exists()


def test_repair_retires_verdict_when_judge_stumbled_on_corrupt_patch(tmp_path):
    t = _trial(tmp_path, "task__stumble", HUNK_EATEN,
               verdict={"judge_score": 0.0, "judge_notes": "The agent.patch was NOT applied to the workspace; HEAD is still the base commit."}, flag=None)
    rec = repair.repair_trial(t)
    assert rec and rec["short_last_hunk"] and rec["verdict_retired"] and (t / "judge_verdict.polluted-1.json").exists()
    assert not (t / "agent" / "final.patch.unfiltered").exists()          # text unchanged: no backup needed


# ── judge-side normalisation ──────────────────────────────────────────────

import patch_normalize  # noqa: E402


def test_normalize_strips_banner_and_restores_context():
    recorded = "=== /workspace/repo (cumulative vs harbor-base) ===\n" + HUNK_EATEN
    out = patch_normalize.normalize_for_git_apply(recorded)
    assert "===" not in out and "@@ -1,2 +1,2 @@" in out and out.endswith("\n")
    assert patch_normalize.normalize_for_git_apply("") == ""
    assert patch_normalize.normalize_for_git_apply(SOURCE) == SOURCE.rstrip("\n") + "\n"


def _git_repo(tmp_path, content: str):
    import subprocess
    repo = tmp_path / "r"; repo.mkdir()
    def git(*a, **kw): return subprocess.run(["git", "-C", str(repo), *a], check=kw.pop("check", True), capture_output=True, text=True, **kw)
    git("init", "-q"); git("config", "user.email", "t@t"); git("config", "user.name", "t")
    (repo / "x.go").write_text(content); git("add", "."); git("commit", "-qm", "base")
    return repo, git


def _first_applicable(git, recorded: str) -> int | None:
    """Mimic the judge sandbox: try candidates in order, return the index that applies."""
    for i, cand in enumerate(patch_normalize.apply_candidates(recorded)):
        if git("apply", "--check", "--whitespace=nowarn", "-", input=cand, check=False).returncode == 0:
            return i
    return None


def test_candidates_apply_when_the_lost_line_was_mid_file(tmp_path):
    repo, git = _git_repo(tmp_path, "a\nb\n\nz\n")          # blank line followed by more content
    (repo / "x.go").write_text("a\nc\n\nz\n")
    full = git("diff").stdout; git("checkout", "--", "x.go")
    recorded = "=== /workspace/repo (cumulative vs harbor-base) ===\n" + full.rstrip("\n")
    # nothing lost here (the last line is " z", not whitespace) → a single candidate that applies
    assert patch_normalize.apply_candidates(recorded) == [patch_normalize.strip_banners(recorded) + "\n"]
    assert _first_applicable(git, recorded) == 0


def test_candidates_apply_when_the_lost_line_was_the_last_line_of_the_file(tmp_path):
    repo, git = _git_repo(tmp_path, "a\nb\n\n")               # file ends with an empty line
    (repo / "x.go").write_text("a\nc\n\n")
    full = git("diff").stdout; git("checkout", "--", "x.go")
    recorded = "=== /workspace/repo (cumulative vs harbor-base) ===\n" + full.strip()   # strip() ate the " " line
    assert git("apply", "--check", "-", input=recorded + "\n", check=False).returncode != 0   # reproduces the corrupt-patch rejection
    cands = patch_normalize.apply_candidates(recorded)
    assert len(cands) == 2 and "@@ -1,2 +1,2 @@" in cands[0] and cands[1].endswith("\n \n")
    assert _first_applicable(git, recorded) == 1                 # header-shrink cannot anchor at EOF; the re-added blank line can


def test_judge_sandbox_tries_candidates_and_does_not_swallow_apply_failure():
    src = (REPO_ROOT / "eval" / "correctness" / "sandbox.py").read_text()
    assert "_patch_apply_candidates(patch_to_apply)" in src
    assert 'apply --check --whitespace=nowarn "/tmp/agent.patch.$i"' in src
    assert 'if [ -z "$APPLIED" ]; then' in src and "exit 1; fi;" in src      # no candidate fits → hard failure
    assert 'apply --whitespace=nowarn /tmp/agent.patch && \'\n                \'chmod -R a+rwX "$REPO" 2>/dev/null || true\'' not in src
    # repo choice: recorder's hint first, then shallowest .git (never `find | head -1`)
    assert '_patch_main_repo(patch_to_apply)' in src and 'REPO="$HINT"' in src
    assert 'name .git \\\\( -type d -o -type f \\\\) 2>/dev/null | head -1' not in src


# ── multi-repo, submodule and binary blocks ───────────────────────────────

SUBMODULE_BLOCK = ("diff --git a/nunchaku b/nunchaku\nindex f86ad470..edd50864 160000\n--- a/nunchaku\n+++ b/nunchaku\n"
                   "@@ -1 +1 @@\n-Subproject commit f86ad47001de7b7f48e0ff592a19ac5d3a2d7f09\n+Subproject commit edd50864c3e62d495886851056fc90e1e08d872f\n")
BINARY_BLOCK = "diff --git a/voyager-1.3.2-chrome.zip b/voyager-1.3.2-chrome.zip\nnew file mode 100644\nindex 0000000..8ec8e26\nBinary files /dev/null and b/voyager-1.3.2-chrome.zip differ\n"
MULTI_REPO = ("=== /workspace (cumulative vs harbor-base) ===\n" + SUBMODULE_BLOCK + _block("quantize.py", "+fixed\n") + BINARY_BLOCK +
              "=== /workspace/nunchaku (cumulative vs harbor-base) ===\n" + _block("src/kernel.cu", "+scratch\n"))


def test_main_repo_section_and_repo_path():
    assert patch_normalize.banner_repos(MULTI_REPO) == ["/workspace", "/workspace/nunchaku"]
    assert patch_normalize.main_repo_path(MULTI_REPO) == "/workspace"
    sec = patch_normalize.main_repo_section(MULTI_REPO)
    assert "quantize.py" in sec and "src/kernel.cu" not in sec
    assert patch_normalize.main_repo_section(SOURCE) == SOURCE                        # single section: untouched
    assert patch_normalize.main_repo_path(SOURCE) is None


def test_scratch_clones_under_tmp_never_win():
    # older recordings sort sections alphabetically, so /tmp/... scratch clones precede the task repo
    diff = ("=== /tmp/tmp5css_dsc (cumulative vs harbor-base) ===\n" + _block("scratch.txt") +
            "=== /tmp/opencode/x (cumulative vs harbor-base) ===\n" + _block("y.txt") +
            "=== /workspace/cli (cumulative vs harbor-base) ===\n" + _block("cmd/main.go", "+real\n"))
    assert patch_normalize.main_repo_path(diff) == "/workspace/cli"
    sec = patch_normalize.main_repo_section(diff)
    assert "cmd/main.go" in sec and "scratch.txt" not in sec and "y.txt" not in sec
    only_tmp = "=== /tmp/only (cumulative vs harbor-base) ===\n" + _block("a.txt")
    assert patch_normalize.main_repo_path(only_tmp) == "/tmp/only"                    # nothing better: keep it


def test_multi_line_trailing_context_loss():
    # two whitespace-only lines lost at the end of the last hunk (header 3/3, body 1/1)
    eaten = "diff --git a/x.py b/x.py\n--- a/x.py\n+++ b/x.py\n@@ -1,3 +1,3 @@\n-a\n+b"
    fixed = patch_normalize.restore_trailing_context(eaten)
    assert "@@ -1,1 +1,1 @@" in fixed
    cands = patch_normalize.apply_candidates(eaten)
    assert len(cands) == 2 and cands[1].endswith("\n \n \n")                          # k=2 blank lines re-added


def test_unapplyable_blocks_are_dropped_but_source_kept():
    trimmed, dropped = patch_normalize.drop_unapplyable_blocks(patch_normalize.strip_banners(MULTI_REPO))
    assert dropped == {"submodule": 1, "binary": 1}
    assert "Subproject commit" not in trimmed and "Binary files" not in trimmed
    assert "quantize.py" in trimmed and "src/kernel.cu" in trimmed                    # (section trimming is a separate step)


def test_apply_candidates_use_main_repo_without_unapplyable_blocks():
    cands = patch_normalize.apply_candidates(MULTI_REPO)
    assert len(cands) == 1
    c = cands[0]
    assert "quantize.py" in c and "Subproject" not in c and "Binary files" not in c and "kernel.cu" not in c and "===" not in c
    assert patch_normalize.apply_candidates("=== /workspace (cumulative vs harbor-base) ===\n" + BINARY_BLOCK) == []   # nothing gradable left


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


def test_repair_retires_verdicts_the_old_judge_could_not_have_applied(tmp_path):
    # /tmp scratch clone listed first: the old judge applied the wrong section → 0.0 on an untouched workspace
    diff = ("=== /tmp/tmp.abc/repo (cumulative vs harbor-base) ===\n" + _block("arr-monitor.py", "+conflict\n") +
            "=== /workspace (cumulative vs harbor-base) ===\n" + _block("arr-monitor.py", "+real fix\n"))
    t = _trial(tmp_path, "arr-monitor-add-processes-flag__x", diff, verdict={"judge_score": 0.0, "judge_notes": "the /workspace tree is completely unchanged"}, flag=None)
    rec = repair.repair_trial(t)
    assert rec and rec["unapplyable_as_recorded"] == "tmp-first" and rec["verdict_retired"]
    assert (t / "judge_verdict.polluted-1.json").exists() and not (t / "judge_verdict.json").exists()
    assert not (t / "agent" / "final.patch.unfiltered").exists()          # the patch text itself was fine
    # submodule pointer block → same treatment
    t2 = _trial(tmp_path, "nunchaku-quantize-bugfix__y", "=== /workspace (cumulative vs harbor-base) ===\n" + SUBMODULE_BLOCK + _block("quantize.py"),
                verdict={"judge_score": 0.1}, flag=None)
    rec2 = repair.repair_trial(t2)
    assert rec2 and rec2["unapplyable_as_recorded"] == "submodule" and rec2["verdict_retired"]
    # a clean single-repo patch with a sound verdict is untouched
    t3 = _trial(tmp_path, "task__clean2", "=== /workspace/repo (cumulative vs harbor-base) ===\n" + SOURCE, verdict={"judge_score": 0.9}, flag=None)
    assert repair.repair_trial(t3) is None


def test_repair_is_idempotent_and_respects_fresh_verdicts(tmp_path):
    diff = ("=== /tmp/scratch (cumulative vs harbor-base) ===\n" + _block("s.txt") +
            "=== /workspace (cumulative vs harbor-base) ===\n" + _block("arr-monitor.py", "+fix\n"))
    t = _trial(tmp_path, "arr-monitor-add-processes-flag__z", diff, verdict={"judge_score": 0.0, "judge_notes": "unchanged tree"}, flag=None)
    assert repair.repair_trial(t)["verdict_retired"]                       # stale verdict retired
    assert repair.repair_trial(t) is None                                  # nothing left to do
    # a judge pass on the fixed code writes a fresh verdict on the normalised patch: it must stand
    (t / "judge_verdict.json").write_text(json.dumps({"judge_score": 0.9, "judge_notes": "all goals met"}))
    assert repair.repair_trial(t) is None
    assert (t / "judge_verdict.json").exists()


def test_verdict_on_normalised_patch_is_never_retired_structurally(tmp_path):
    diff = "=== /workspace (cumulative vs harbor-base) ===\n" + SUBMODULE_BLOCK + _block("quantize.py", "+fix\n")
    t = _trial(tmp_path, "nunchaku-quantize-bugfix__q", diff,
               verdict={"judge_score": 0.7, "judge_notes": "3 of 4 goals", "patch_applied_candidate": 0, "patch_applied_repo": "/workspace"}, flag=None)
    assert repair.repair_trial(t) is None                                  # fixed judge already applied the normalised patch
    assert (t / "judge_verdict.json").exists()
