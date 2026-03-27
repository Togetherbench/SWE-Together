We have a PR on this repo (#1) that adds an MCP server for node discovery. It has 7 MCP tools and covers 8400+ ComfyUI nodes. The code lives in `cli_tools/registry/mcp_server.py` and `cli_tools/registry/knowledge.py`.

There's overlap between the PR's `knowledge.py` and our existing `cli_tools/analysis.py` — both do node search and analysis. Here's what I want:

1. **Integrate the MCP server with existing analysis tools.** MCP tools should be thin wrappers around `analysis.py`, not duplicate implementations. Create a shared search module (e.g., `cli_tools/search.py`) with a `TASK_ALIASES` dict (mapping common tasks to search terms) and an `expand_query()` function. Extract `TASK_ALIASES` out of `knowledge.py` into this shared module so both MCP and CLI can use it.

2. **Add trace_node analysis tools to the MCP server.** Add new MCP tools that wrap `analysis.py` functions — at least `trace_node`, plus upstream/downstream dependency tools. These let agents trace signal flow through ComfyUI workflows.

3. **Set up `.mcp.json` config** at the repo root so Claude Code auto-discovers the MCP server.

4. **Reorganize skills.** The existing monolithic skill under `.claude/skills/` should be split into 3-4 focused skills (e.g., registry, analyze, edit, nodes) with specific triggers for each.

5. **Improve MCP tool descriptions** to be prescriptive — tell agents when to use each tool (e.g., "Start here for node discovery", "Use after tracing to find upstream dependencies").

6. **Create a test suite** covering the tool functions (both CLI and MCP tools). At least 5 test functions in a `test_*.py` file.

7. **Add `mcp` to `requirements.txt`.**

Make sure core imports (`cli_tools.analysis`, `cli_tools.registry.knowledge`, `cli_tools.registry.mcp_server`, `cli_tools.descriptions`) all work after your changes.
