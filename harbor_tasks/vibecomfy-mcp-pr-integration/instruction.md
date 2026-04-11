We have a PR on this repo (#1) that adds an MCP server for node discovery. It has 7 MCP tools and covers 8400+ ComfyUI nodes. The code lives in `cli_tools/registry/mcp_server.py` and `cli_tools/registry/knowledge.py`.

There's significant overlap between the PR's `knowledge.py` and our existing `cli_tools/analysis.py` — both do node search and analysis. The knowledge module has a large task alias mapping embedded in the class that maps common tasks to search terms. Here's what I need:

1. **Deduplicate and integrate.** The MCP tools should wrap `analysis.py` functions, not reimplement them. The task alias mapping in knowledge.py should be extracted into a shared module that both MCP and CLI code can import. That module should also provide a query expansion function that resolves aliases into search terms.

2. **Expose analysis capabilities through MCP.** The analysis module has functions for tracing signal flow, finding upstream/downstream dependencies, and analyzing workflow structure. These should be available as MCP tools so agents can use them for workflow analysis.

3. **Set up MCP auto-discovery** so Claude Code finds the server without manual configuration.

4. **Break up the monolithic skill** under `.claude/skills/` into focused, well-scoped skills with appropriate triggers for different use cases.

5. **Make tool descriptions actionable** — they should guide agents on when and how to use each tool, not just describe what it does.

6. **Add test coverage** for the integrated tool functions — both the shared search module and the analysis wrappers.

7. **Track the MCP framework as a project dependency.**

Make sure core imports (`cli_tools.analysis`, `cli_tools.registry.knowledge`, `cli_tools.registry.mcp_server`, `cli_tools.descriptions`) all work after your changes.
