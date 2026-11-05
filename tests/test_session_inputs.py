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
            {"role": "user", "content": "Commit the fix"},
        ]
    }
    (tmp_path / "original_session.json").write_text(json.dumps(session))
    assert _load_user_messages(tmp_path) == [
        "Fix this", "Please don't filter sessions by UUID", "Commit the fix",
    ]


def test_original_cli_corrections_are_present_and_ordered() -> None:
    first = _load_user_messages(ROOT / "tasks/cli-task-b3d2dd")
    assert len(first) == 4
    assert "sceptical about the uuid filtering" in first[1]
    assert first[-1] == "commit, push"

    second = _load_user_messages(ROOT / "tasks/cli-task-c01017")
    assert len(second) == 20
    assert [i for i, text in enumerate(second) if "randomisation thing" in text] == [7]
    assert [i for i, text in enumerate(second) if "before we push anything" in text] == [8]
    assert second[-1] == "also update the review comment"
    assert all("This session is being continued" not in text for text in second)
