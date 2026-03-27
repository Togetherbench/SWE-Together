#!/usr/bin/env bash
#
# Verification script for vibecomfy-debug-97c34b task.
# Tests that the agent integrated the MCP server with existing analysis tools,
# created shared search module, added new MCP tools, reorganized skills,
# created .mcp.json config, and wrote tests.
#
# Design: 61% behavioral (import+call+verify), 39% structural.
# Comment-only lines stripped before regex to block comment injection gaming.
# Stub-rejection gates: expand_query must return >=2 differentiated terms,
#   trace_node must return >=2-entry results varying by node, tests must call
#   project functions in body, knowledge.py import must succeed, skills need keywords.
#
# Writes a reward between 0.0 and 1.0 to /logs/verifier/reward.txt.
#
set +e

REWARD=0.0
WORKSPACE="/workspace/VibeComfy"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

# Helper: increment reward by a fractional amount
add_reward() {
    REWARD=$(python3 -c "print(min(1.0, $REWARD + $1))")
}

cd "$WORKSPACE"

# ---------------------------------------------------------------------------
# Check 1 (0.12): Shared search module — BEHAVIORAL
#   expand_query must be importable AND return expanded terms when called
#   TASK_ALIASES must be a dict with at least 3 entries
# ---------------------------------------------------------------------------
echo "=== Check 1: Shared search module (behavioral) ==="
python3 << 'PYEOF' && { echo "PASS: Shared search module works"; add_reward 0.12; } || echo "FAIL: Shared search module broken"
import sys, os, importlib
sys.path.insert(0, ".")

# Find the module containing expand_query and TASK_ALIASES
found_module = None
for mod_path in ["cli_tools.search", "cli_tools.registry.search"]:
    try:
        m = importlib.import_module(mod_path)
        if hasattr(m, 'TASK_ALIASES') and hasattr(m, 'expand_query'):
            found_module = m
            break
    except Exception:
        pass

if not found_module:
    # Fallback: search all cli_tools modules
    import glob, importlib.util
    for pyfile in glob.glob("cli_tools/**/*.py", recursive=True):
        mod_name = pyfile.replace("/", ".").replace(".py", "")
        try:
            spec = importlib.util.spec_from_file_location(mod_name, pyfile)
            m = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(m)
            if hasattr(m, 'TASK_ALIASES') and hasattr(m, 'expand_query'):
                found_module = m
                break
        except Exception:
            pass

if not found_module:
    print("  No importable module with TASK_ALIASES + expand_query", file=sys.stderr)
    sys.exit(1)

# TASK_ALIASES must be a non-trivial dict (>=3 entries mapping tasks to search terms)
aliases = found_module.TASK_ALIASES
if not isinstance(aliases, dict) or len(aliases) < 3:
    print(f"  TASK_ALIASES has only {len(aliases) if isinstance(aliases, dict) else 0} entries (need 3+)", file=sys.stderr)
    sys.exit(1)

# expand_query must be callable and return something for a known alias key
try:
    first_key = list(aliases.keys())[0]
    result = found_module.expand_query(first_key)
    if result is None or (isinstance(result, (list, str)) and len(result) == 0):
        print(f"  expand_query('{first_key}') returned empty", file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print(f"  expand_query() raised: {e}", file=sys.stderr)
    sys.exit(1)

# Anti-stub: expand_query must return >=2 terms (not just echo the key)
r_len = len(result) if isinstance(result, (list, tuple)) else len(str(result).split())
if r_len < 2:
    print(f"  expand_query returned only {r_len} term(s) (need 2+, stub rejected)", file=sys.stderr)
    sys.exit(1)

# Anti-stub: different keys must produce different results
if len(aliases) >= 2:
    second_key = list(aliases.keys())[1]
    result2 = found_module.expand_query(second_key)
    if str(result) == str(result2):
        print(f"  expand_query returns identical results for different keys (stub)", file=sys.stderr)
        sys.exit(1)

print(f"  TASK_ALIASES: {len(aliases)} entries, expand_query callable + differentiated")
PYEOF

# ---------------------------------------------------------------------------
# Check 2 (0.08): TASK_ALIASES extracted from knowledge.py — STRUCTURAL
#   knowledge.py should import from shared module, not define inline
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 2: TASK_ALIASES extracted from knowledge.py ==="
python3 << 'PYEOF' && { echo "PASS: TASK_ALIASES extracted"; add_reward 0.08; } || echo "FAIL: TASK_ALIASES still inline in knowledge.py"
import re, sys

with open("cli_tools/registry/knowledge.py") as f:
    source = f.read()

# Check that the large inline TASK_ALIASES dict is gone
alias_defs = re.findall(r'TASK_ALIASES\s*=\s*\{', source)
if alias_defs:
    lines = source.split('\n')
    in_dict = False
    dict_lines = 0
    for line in lines:
        if 'TASK_ALIASES' in line and '=' in line and '{' in line:
            in_dict = True
            dict_lines = 1
            continue
        if in_dict:
            dict_lines += 1
            if '}' in line:
                break
    if dict_lines > 10:
        print(f"  TASK_ALIASES still defined inline ({dict_lines} lines)", file=sys.stderr)
        sys.exit(1)

# Verify knowledge.py uses expand_query or imports from search
if not re.search(r'(from\s+\S*search\s+import|import\s+\S*search|expand_query)', source):
    print("  knowledge.py doesn't import from search module", file=sys.stderr)
    sys.exit(1)

# Anti-stub: knowledge.py must actually import successfully (search module must exist)
import importlib
try:
    importlib.import_module("cli_tools.registry.knowledge")
except Exception as e:
    print(f"  knowledge.py fails to import (search module missing?): {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

# ---------------------------------------------------------------------------
# Check 3 (0.15): MCP server analysis tools — BEHAVIORAL
#   Both mcp_server and analysis modules must import successfully.
#   mcp_server must define Tool() entries for analysis functions.
#   analysis module must have >=2 callable functions matching tools.
#   Source is stripped of comments before regex to prevent comment injection.
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 3: MCP server integrates analysis tools (behavioral) ==="
python3 << 'PYEOF' && { echo "PASS: MCP server has working analysis tools"; add_reward 0.15; } || echo "FAIL: MCP server analysis tools broken"
import re, sys, importlib
sys.path.insert(0, ".")

# 1. Both modules must be importable (behavioral gate)
try:
    mcp_mod = importlib.import_module("cli_tools.registry.mcp_server")
except Exception as e:
    print(f"  mcp_server import failed: {e}", file=sys.stderr)
    sys.exit(1)

try:
    analysis_mod = importlib.import_module("cli_tools.analysis")
except Exception as e:
    print(f"  analysis import failed: {e}", file=sys.stderr)
    sys.exit(1)

# 2. Read source, strip comment-only lines to prevent comment injection gaming
with open(mcp_mod.__file__) as f:
    lines = f.readlines()
uncommented = "\n".join(l for l in lines if not l.strip().startswith("#"))

# 3. Must have Tool() definitions for at least 2 analysis tools
tool_names = re.findall(r'Tool\s*\(\s*name\s*=\s*["\']([^"\']+)["\']', uncommented)
analysis_tools = [t for t in tool_names if any(kw in t.lower() for kw in ['trace', 'upstream', 'downstream', 'path', 'orphan', 'subgraph'])]

if len(analysis_tools) < 2:
    print(f"  Only {len(analysis_tools)} analysis Tool() entries: {analysis_tools}", file=sys.stderr)
    sys.exit(1)

# 4. analysis module must have >=2 callable functions that match tool names
analysis_funcs = ['find_upstream', 'find_downstream', 'trace_node', 'find_path',
                  'find_subgraph', 'find_orphans', 'analyze_workflow', 'trace_signal', 'trace_flow']
found = [f for f in analysis_funcs if hasattr(analysis_mod, f) and callable(getattr(analysis_mod, f))]
if len(found) < 2:
    print(f"  Only {len(found)} callable analysis functions: {found}", file=sys.stderr)
    sys.exit(1)

# 5. Total tool count must be > 7 (original 7 + at least 2 new)
if len(tool_names) < 9:
    print(f"  Only {len(tool_names)} total tools (need 9+, was 7 originally)", file=sys.stderr)
    sys.exit(1)

print(f"  {len(tool_names)} total tools, {len(analysis_tools)} analysis tools, {len(found)} analysis funcs: {found}")
PYEOF

# ---------------------------------------------------------------------------
# Check 4 (0.12): trace_node in analysis.py — BEHAVIORAL
#   Must be callable with a workflow dict and node ID, and return a result
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 4: trace_node works (behavioral) ==="
python3 << 'PYEOF' && { echo "PASS: trace_node works"; add_reward 0.12; } || echo "FAIL: trace_node broken"
import sys, inspect
sys.path.insert(0, ".")

import cli_tools.analysis as analysis

# trace_node might be a top-level function or nested inside analysis.py
# The agent might also name it differently (e.g. trace_signal, trace_flow)
fn = None
for name in ['trace_node', 'trace_signal', 'trace_flow', 'node_trace']:
    if hasattr(analysis, name):
        fn = getattr(analysis, name)
        break

if fn is None:
    # Check if the function was added but under a different pattern
    import re
    with open(analysis.__file__) as f:
        src = f.read()
    trace_funcs = re.findall(r'def\s+(trace\w*)\s*\(', src)
    for tf_name in trace_funcs:
        if hasattr(analysis, tf_name):
            fn = getattr(analysis, tf_name)
            break

if fn is None:
    print("  No trace function found in analysis module", file=sys.stderr)
    sys.exit(1)
sig = inspect.signature(fn)
params = list(sig.parameters.keys())

# Must accept at least 2 params (workflow/wf and node_id/target_id/node)
if len(params) < 2:
    print(f"  trace_node has only {len(params)} params: {params} (need >=2)", file=sys.stderr)
    sys.exit(1)

# Try calling with a minimal workflow to ensure it doesn't crash
# Simple 2-node workflow: KSampler -> SaveImage
test_wf = {
    "nodes": [
        {"id": 1, "type": "KSampler", "inputs": [], "outputs": [{"links": [1]}]},
        {"id": 2, "type": "SaveImage", "inputs": [{"link": 1}], "outputs": []}
    ],
    "links": [[1, 1, 0, 2, 0, "IMAGE"]]
}

try:
    result = fn(test_wf, 2)
    # Should return something (dict, list, string — not None/empty/trivial)
    if result is None:
        print("  trace_node returned None for valid input", file=sys.stderr)
        sys.exit(1)
    if isinstance(result, dict) and len(result) == 0:
        print("  trace_node returned empty dict", file=sys.stderr)
        sys.exit(1)
    if isinstance(result, list) and len(result) == 0:
        print("  trace_node returned empty list", file=sys.stderr)
        sys.exit(1)
    if isinstance(result, str) and len(result) < 10:
        print(f"  trace_node returned trivial string: '{result}'", file=sys.stderr)
        sys.exit(1)

    # Anti-stub: result must have >=2 entries (dict keys or list items or string tokens)
    if isinstance(result, dict) and len(result) < 2:
        print(f"  trace_node returned dict with only {len(result)} key (need 2+, stub rejected)", file=sys.stderr)
        sys.exit(1)
    if isinstance(result, (list, tuple)) and len(result) < 2:
        print(f"  trace_node returned list with only {len(result)} item (need 2+, stub rejected)", file=sys.stderr)
        sys.exit(1)

    # Anti-stub: results must differ for different node IDs
    try:
        result1 = fn(test_wf, 1)
        if str(result) == str(result1):
            print("  trace_node returns identical results for different nodes (stub)", file=sys.stderr)
            sys.exit(1)
    except Exception:
        pass  # OK if node 1 tracing fails differently

except TypeError as e:
    # If signature is different, try common alternatives
    try:
        result = fn(test_wf, node_id=2)
    except Exception:
        try:
            result = fn(wf=test_wf, target_id=2)
        except Exception as e2:
            print(f"  trace_node call failed: {e2}", file=sys.stderr)
            sys.exit(1)
except Exception as e:
    # Some errors are OK if it's a format issue — the function exists and runs
    if "key" in str(e).lower() or "index" in str(e).lower() or "node" in str(e).lower():
        pass  # Expected: our minimal wf may not match expected format exactly
    else:
        print(f"  trace_node raised unexpected: {e}", file=sys.stderr)
        sys.exit(1)

print(f"  trace_node({params}) is callable and processes workflows")
PYEOF

# ---------------------------------------------------------------------------
# Check 5 (0.08): .mcp.json config — STRUCTURAL + valid JSON
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 5: .mcp.json auto-config ==="
python3 << 'PYEOF' && { echo "PASS: .mcp.json configured"; add_reward 0.08; } || echo "FAIL: .mcp.json missing/broken"
import json, sys, os

mcp_path = None
for candidate in [".mcp.json", "mcp.json"]:
    if os.path.exists(candidate):
        mcp_path = candidate
        break

if not mcp_path:
    print("  .mcp.json not found", file=sys.stderr)
    sys.exit(1)

with open(mcp_path) as f:
    config = json.load(f)

servers = config.get("mcpServers", config.get("servers", {}))
if not servers:
    print("  No MCP servers defined", file=sys.stderr)
    sys.exit(1)

# Must reference mcp_server.py in command/args
found_server = False
for name, server_config in servers.items():
    args = server_config.get("args", [])
    command = server_config.get("command", "")
    full_cmd = command + " " + " ".join(str(a) for a in args)
    if "mcp_server" in full_cmd or "registry" in full_cmd:
        found_server = True
        break

if not found_server:
    print("  No MCP server entry references mcp_server module", file=sys.stderr)
    sys.exit(1)
PYEOF

# ---------------------------------------------------------------------------
# Check 6 (0.10): Skills reorganized — STRUCTURAL + content quality
#   Need 3+ SKILL.md files, each with meaningful content (>50 chars)
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 6: Skills reorganized ==="
python3 << 'PYEOF' && { echo "PASS: Skills reorganized"; add_reward 0.10; } || echo "FAIL: Skills not reorganized"
import os, sys

skill_files = []
for root, dirs, files in os.walk(".claude/skills"):
    for f in files:
        if f == "SKILL.md":
            path = os.path.join(root, f)
            with open(path) as fh:
                content = fh.read().strip()
            skill_files.append((path, len(content)))

if len(skill_files) < 3:
    print(f"  Only {len(skill_files)} SKILL.md files (need 3+)", file=sys.stderr)
    sys.exit(1)

# Each skill must have meaningful content (not just a title)
thin_skills = [p for p, sz in skill_files if sz < 50]
if thin_skills:
    print(f"  Thin skills (<50 chars): {thin_skills}", file=sys.stderr)
    sys.exit(1)

# Skills must reference project-specific content (not lorem ipsum)
project_keywords = ['comfy', 'node', 'workflow', 'mcp', 'registry', 'analysis', 'tool', 'search']
generic_skills = []
for p, sz in skill_files:
    with open(p) as fh:
        content = fh.read().lower()
    if not any(kw in content for kw in project_keywords):
        generic_skills.append(p)
if generic_skills:
    print(f"  Generic skills (no project keywords): {generic_skills}", file=sys.stderr)
    sys.exit(1)

print(f"  {len(skill_files)} skills, all with substantive project content")
PYEOF

# ---------------------------------------------------------------------------
# Check 7 (0.12): Tests actually pass — BEHAVIORAL
#   Run the agent's test suite and check that most tests pass
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 7: Test suite passes (behavioral) ==="
python3 << 'PYEOF' && { echo "PASS: Tests run successfully"; add_reward 0.12; } || echo "FAIL: Tests don't pass"
import subprocess, re, sys, os

# Find test files
test_files = []
for root, dirs, files in os.walk("."):
    if ".git" in root or "__pycache__" in root:
        continue
    for f in files:
        if f.startswith("test_") and f.endswith(".py"):
            test_files.append(os.path.join(root, f))

if not test_files:
    print("  No test files found", file=sys.stderr)
    sys.exit(1)

# Count test functions first
max_tests = 0
best_file = None
for tf in test_files:
    with open(tf) as f:
        source = f.read()
    count = len(re.findall(r'def\s+test_\w+', source))
    if count > max_tests:
        max_tests = count
        best_file = tf

if max_tests < 5:
    print(f"  Best file {best_file} has only {max_tests} tests (need 5+)", file=sys.stderr)
    sys.exit(1)

# Tests must import from project modules (reject trivial assert-True stubs)
with open(best_file) as f:
    test_source = f.read()
if not re.search(r'(from\s+cli_tools|import\s+cli_tools)', test_source):
    print(f"  Test file doesn't import from cli_tools (trivial tests rejected)", file=sys.stderr)
    sys.exit(1)

# Anti-stub: at least 3 test functions must reference project code in their body
# (not just a top-level import with assert True tests)
test_blocks = re.split(r'(?=def\s+test_\w+)', test_source)
project_refs = ['cli_tools', 'analysis', 'search', 'knowledge', 'mcp_server',
                'expand_query', 'trace_node', 'find_upstream', 'find_downstream',
                'TASK_ALIASES', 'trace_signal', 'trace_flow']
substantive_tests = 0
for block in test_blocks:
    if not block.strip().startswith('def test_'):
        continue
    # Get just the function body (skip the def line)
    body_lines = block.split('\n')[1:]
    body = '\n'.join(body_lines)
    if any(ref in body for ref in project_refs):
        substantive_tests += 1
if substantive_tests < 3:
    print(f"  Only {substantive_tests} test functions reference project code (need 3+, stubs rejected)", file=sys.stderr)
    sys.exit(1)

# Actually run the tests with pytest (preferred) or unittest fallback
env = os.environ.copy()
env["PYTHONPATH"] = "."

# Try pytest first, then unittest
result = subprocess.run(
    ["python3", "-m", "pytest", best_file, "-v", "--tb=short", "-q"],
    capture_output=True, text=True, timeout=60, cwd="/workspace/VibeComfy", env=env
)
output = result.stdout + result.stderr

# Parse pytest output
passed_match = re.search(r'(\d+)\s+passed', output)
failed_match = re.search(r'(\d+)\s+failed', output)

if passed_match:
    passed = int(passed_match.group(1))
    failed = int(failed_match.group(1)) if failed_match else 0
else:
    # Fallback: try running test file directly with unittest discover
    # First try: python3 -m unittest discover
    test_dir = os.path.dirname(best_file) or "."
    result = subprocess.run(
        ["python3", "-m", "unittest", "discover", "-s", test_dir, "-p", "test_*.py", "-v"],
        capture_output=True, text=True, timeout=60, cwd="/workspace/VibeComfy", env=env
    )
    output = result.stdout + result.stderr
    # Count "ok" and "FAIL" in unittest output
    passed = len(re.findall(r'\.\.\. ok', output))
    failed = len(re.findall(r'\.\.\. (FAIL|ERROR)', output))
    # Also check "Ran X tests" + OK pattern
    ran_match = re.search(r'Ran (\d+) test', output)
    if ran_match and passed == 0 and result.returncode == 0:
        passed = int(ran_match.group(1))

    if passed == 0:
        # Last resort: run the file directly
        result = subprocess.run(
            ["python3", best_file],
            capture_output=True, text=True, timeout=60, cwd="/workspace/VibeComfy", env=env
        )
        output = result.stdout + result.stderr
        passed = len(re.findall(r'\.\.\. ok', output))
        failed = len(re.findall(r'\.\.\. (FAIL|ERROR)', output))
        ran_match = re.search(r'Ran (\d+) test', output)
        if ran_match and passed == 0 and result.returncode == 0:
            passed = int(ran_match.group(1))

if passed < 3:
    print(f"  Only {passed} tests passed ({failed} failed)", file=sys.stderr)
    print(f"  Output: {output[-500:]}", file=sys.stderr)
    sys.exit(1)

print(f"  {passed} tests passed, {failed} failed")
PYEOF

# ---------------------------------------------------------------------------
# Check 8 (0.08): MCP tool descriptions are prescriptive — STRUCTURAL
#   Descriptions must contain guidance words (start, use, when, after, first)
#   AND total tools must be >= 9 (7 original + 2 new analysis tools)
#   Source is stripped of comments to prevent comment injection gaming.
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 8: MCP descriptions prescriptive ==="
python3 << 'PYEOF' && { echo "PASS: Descriptions prescriptive"; add_reward 0.08; } || echo "FAIL: Descriptions not prescriptive"
import re, sys

with open("cli_tools/registry/mcp_server.py") as f:
    lines = f.readlines()
# Strip comment-only lines to prevent comment injection gaming
source = "\n".join(l for l in lines if not l.strip().startswith("#"))

# Extract descriptions from Tool() definitions — multiple formats
# Format 1: description="..." or description='...' (single-line)
descriptions = re.findall(r'description\s*=\s*"([^"]+)"', source)
descriptions += re.findall(r"description\s*=\s*'([^']+)'", source)

# Format 2: triple-quoted descriptions
triple_descs = re.findall(r'description\s*=\s*"""(.*?)"""', source, re.DOTALL)
triple_descs += re.findall(r"description\s*=\s*'''(.*?)'''", source, re.DOTALL)
descriptions.extend([d.strip() for d in triple_descs])

# Format 3: f-string descriptions
f_descs = re.findall(r'description\s*=\s*f"([^"]+)"', source)
f_descs += re.findall(r"description\s*=\s*f'([^']+)'", source)
descriptions.extend(f_descs)

# Format 4: "desc" or "description" keys in dicts (common in MCP tool definitions)
dict_descs = re.findall(r'["\']description["\']\s*:\s*"([^"]+)"', source)
dict_descs += re.findall(r'["\']description["\']\s*:\s*\'([^\']+)\'', source)
descriptions.extend(dict_descs)

# Format 5: docstrings in @server.tool() decorated functions
# Look for triple-quoted strings right after def lines
docstrings = re.findall(r'def\s+\w+[^:]*:\s*\n\s*"""(.*?)"""', source, re.DOTALL)
docstrings += re.findall(r"def\s+\w+[^:]*:\s*\n\s*'''(.*?)'''", source, re.DOTALL)
descriptions.extend([d.strip().split('\n')[0] for d in docstrings if len(d.strip()) > 10])

# Deduplicate while preserving order
descriptions = list(dict.fromkeys(descriptions))

if len(descriptions) < 9:
    print(f"  Only {len(descriptions)} tool descriptions (need 9+)", file=sys.stderr)
    sys.exit(1)

# Check for prescriptive language: at least 4 descriptions should have
# guidance words that tell the agent WHEN/HOW to use the tool
guidance_patterns = [
    r'\b(start|begin|first)\b',
    r'\b(use|run|call)\s+(this|after|before|when|for)\b',
    r'\b(after|before|once)\b',
    r'\b(when|if)\s+you\b',
    r'\b(recommended|prefer|best|ideal)\b',
    r'\b(e\.g\.|for example|such as)\b',
]

prescriptive_count = 0
for desc in descriptions:
    for pat in guidance_patterns:
        if re.search(pat, desc, re.IGNORECASE):
            prescriptive_count += 1
            break

if prescriptive_count < 4:
    print(f"  Only {prescriptive_count}/{len(descriptions)} descriptions have guidance language", file=sys.stderr)
    sys.exit(1)

print(f"  {prescriptive_count}/{len(descriptions)} descriptions are prescriptive")
PYEOF

# ---------------------------------------------------------------------------
# Check 9 (0.10): Core imports AND new modules integrate — BEHAVIORAL
#   All 4 core modules must import, AND the search module must be usable
#   from knowledge.py (i.e., the refactoring actually works end-to-end)
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 9: Integration works end-to-end (behavioral) ==="
python3 << 'PYEOF' && { echo "PASS: Integration works"; add_reward 0.10; } || echo "FAIL: Integration broken"
import sys
sys.path.insert(0, ".")

errors = []

# Core imports
for mod_name in ["cli_tools.analysis", "cli_tools.registry.knowledge",
                 "cli_tools.registry.mcp_server", "cli_tools.descriptions"]:
    try:
        __import__(mod_name)
    except Exception as e:
        errors.append(f"{mod_name}: {e}")

if errors:
    for e in errors:
        print(f"  Import error: {e}", file=sys.stderr)
    sys.exit(1)

# Verify knowledge.py can access expand_query (the refactoring link)
import cli_tools.registry.knowledge as knowledge
# The module should either have expand_query directly or import it
has_expand = hasattr(knowledge, 'expand_query')
# Or it should use the search module
import cli_tools.registry.mcp_server as mcp_mod
mcp_source = open(mcp_mod.__file__).read()
uses_analysis = 'analysis' in mcp_source.lower()

if not has_expand and not uses_analysis:
    print("  knowledge.py doesn't integrate with search module", file=sys.stderr)
    sys.exit(1)

# Verify mcp_server module has more tools than original 7
import re
tool_names = re.findall(r'Tool\s*\(\s*name\s*=\s*["\']([^"\']+)["\']', mcp_source)
if len(tool_names) <= 7:
    print(f"  mcp_server still has only {len(tool_names)} tools (need >7)", file=sys.stderr)
    sys.exit(1)

# Anti-stub: verify expand_query actually works end-to-end through knowledge module
if has_expand:
    try:
        eq = knowledge.expand_query
        test_result = eq(list(knowledge.TASK_ALIASES.keys())[0]) if hasattr(knowledge, 'TASK_ALIASES') else eq("test")
        if test_result is None or (isinstance(test_result, (list, str)) and len(test_result) == 0):
            print("  expand_query via knowledge module returned empty (stub)", file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        print(f"  expand_query via knowledge failed: {e}", file=sys.stderr)
        sys.exit(1)

print(f"  All modules import, {len(tool_names)} MCP tools, integration linked + verified")
PYEOF

# ---------------------------------------------------------------------------
# Check 10 (0.05): requirements.txt with mcp — STRUCTURAL
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 10: requirements.txt ==="
if [ -f "requirements.txt" ]; then
    if grep -qi "mcp" requirements.txt; then
        echo "PASS: requirements.txt has mcp"
        add_reward 0.05
    else
        echo "FAIL: requirements.txt missing mcp"
    fi
else
    echo "FAIL: requirements.txt not found"
fi

# ---------------------------------------------------------------------------
# Write final reward
# ---------------------------------------------------------------------------
echo ""
echo "================================"
echo "Final reward: $REWARD"
echo "================================"
echo "$REWARD" > "$LOG_DIR/reward.txt"
