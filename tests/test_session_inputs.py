"""Regression checks for human turns embedded in tool-result records."""

import ast
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def _load_user_messages(task_dir: Path) -> list[str]:
    # The loader is pure, but importing runner initializes optional Harbor
    # clients. Execute only this function as the production adapter does.
    tree = ast.parse((ROOT / "src/runner.py").read_text())
    function = next(
        node for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name == "load_user_messages"
    )
    module = ast.fix_missing_locations(ast.Module(body=[function], type_ignores=[]))
    scope = {"json": json, "Path": Path}
    exec(compile(module, "src/runner.py", "exec"), scope)
    return scope["load_user_messages"](task_dir, {})


def test_mixed_tool_result_keeps_only_real_user_text(tmp_path: Path) -> None:
    session = {
        "messages": [
            {"role": "user", "content": "Fix this"},
            {"role": "user", "content": [
                {"type": "tool_result", "content": "secret tool output"},
                {"type": "text", "text": "Tool loaded."},
                {"type": "text", "text": "Please don't filter sessions by UUID"},
            ]},
            {"role": "user", "content": "This session is being continued from a previous conversation ..."},
            {"role": "user", "content": [{"type": "tool_result", "content": "tool only"}]},
            {"role": "user", "content": [{"type": "tool_result", "content": (
                "The tool use was rejected. To tell you how to proceed, the user said:\n"
                "Create a branch first"
            )}]},
            {"role": "user", "content": "Commit the fix"},
        ]
    }
    (tmp_path / "original_session.json").write_text(json.dumps(session))
    assert _load_user_messages(tmp_path) == [
        "Fix this", "Please don't filter sessions by UUID", "Create a branch first", "Commit the fix",
    ]


def test_original_cli_corrections_are_present_and_ordered() -> None:
    first = _load_user_messages(ROOT / "tasks/cli-task-b3d2dd")
    assert len(first) == 4
    assert "sceptical about the uuid filtering" in first[1]
    assert first[-1] == "commit, push"

    second = _load_user_messages(ROOT / "tasks/cli-task-c01017")
    assert len(second) == 22
    assert [i for i, text in enumerate(second) if "randomisation thing" in text] == [8]
    assert [i for i, text in enumerate(second) if "before we push anything" in text] == [9]
    assert second[-1] == "also update the review comment"
    assert all("This session is being continued" not in text for text in second)

    branch = _load_user_messages(ROOT / "tasks/cli-task-70c88c")
    assert branch == [
        "need a little patch for `entire explain` that prints the help text if a parameter is passed without any qualifier flags",
        "let's cut a branch first",
        "let's do the hint if it's small",
    ]


def _render_guidance(source: str, function_name: str, count: int) -> str:
    tree = ast.parse((ROOT / "src" / source).read_text())
    function = next(
        node for node in tree.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        and node.name == function_name
    )
    assignment = next(
        node for node in ast.walk(function)
        if isinstance(node, ast.Assign)
        and any(
            isinstance(target, ast.Name) and target.id == "guidance_note"
            for target in node.targets
        )
    )
    module = ast.fix_missing_locations(ast.Module(body=[assignment], type_ignores=[]))
    scope = {"gt_count": count}
    exec(compile(module, source, "exec"), scope)
    return scope["guidance_note"]


def test_both_launchers_require_actual_trigger_and_do_not_target_message_count() -> None:
    for source, function in (("runner.py", "run_single_task"), ("run_eval.py", "build_trial_config")):
        guidance = _render_guidance(source, function, 4)
        assert "including the opening task" in guidance
        assert "not a target for simulated follow-ups" in guidance
        assert "historical, not a quota" in guidance
        assert "trigger actually occurred" in guidance
        assert "If that context is absent, choose no-op" in guidance
        assert "even if the trigger condition is not a perfect match" not in guidance
        assert "Aim for" not in guidance
