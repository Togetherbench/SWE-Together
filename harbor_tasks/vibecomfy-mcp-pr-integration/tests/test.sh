#!/usr/bin/env bash
#
# Verification script for vibecomfy-mcp-pr-integration task.
#
# Tests: shared search module, MCP analysis tool wiring, skill reorganization,
# .mcp.json config, test suite creation, prescriptive descriptions, requirements.txt.
#
# Scoring: 78% behavioral, 22% structural. Total = 1.0.
# P2P: analysis functions (find_upstream/find_downstream) at base commit (Check 9).
# No upstream test suite at base commit.
#
# Anti-gaming:
#   - TASK_ALIASES requires >=10 entries with ComfyUI domain terms
#   - MCP tools must CALL analysis functions (regex for call expressions, not names)
#   - Test suite needs asserts + function calls (not just variable assignments)
#   - Skills counted by distinct definitions (not all .md files recursively)
#   - Analysis functions called with real workflow fixture
#
# Writes a reward between 0.0 and 1.0 to /logs/verifier/reward.txt.
#
set +e

REWARD=0.0
WORKSPACE="/workspace/VibeComfy"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, $REWARD + $1))")
}

cd "$WORKSPACE"

# ---------------------------------------------------------------------------
# Check 1 (0.10): Shared search module — BEHAVIORAL
#   TASK_ALIASES must be a dict with >=10 entries (original has 30), at least
#   5 with list values of >=2 items. >=3 keys must be ComfyUI domain terms
#   (anti-gaming). expand_query must be callable, return >=2 terms, differentiate
#   across keys, and handle non-alias input without crashing.
# ---------------------------------------------------------------------------
echo "=== Check 1: Shared search module (0.10, behavioral) ==="
python3 << 'PYEOF' && { echo "PASS: Shared search module"; add_reward 0.10; } || echo "FAIL: Shared search module"
import sys, ast, importlib, glob, importlib.util, textwrap, inspect
sys.path.insert(0, ".")

# Find shared search module (flexible path)
found = None
for mod_path in ["cli_tools.search", "cli_tools.registry.search", "cli_tools.utils.search",
                 "cli_tools.shared", "cli_tools.registry.shared"]:
    try:
        m = importlib.import_module(mod_path)
        if hasattr(m, 'TASK_ALIASES') and hasattr(m, 'expand_query'):
            found = m; break
    except Exception:
        pass

if not found:
    for pyfile in glob.glob("cli_tools/**/*.py", recursive=True):
        mod_name = pyfile.replace("/", ".").replace(".py", "")
        try:
            spec = importlib.util.spec_from_file_location(mod_name, pyfile)
            m = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(m)
            if hasattr(m, 'TASK_ALIASES') and hasattr(m, 'expand_query'):
                found = m; break
        except Exception:
            pass

if not found:
    print("  No module with TASK_ALIASES + expand_query found", file=sys.stderr); sys.exit(1)

aliases = found.TASK_ALIASES
if not isinstance(aliases, dict) or len(aliases) < 10:
    print(f"  TASK_ALIASES needs >=10 entries, got {len(aliases) if isinstance(aliases, dict) else 0}", file=sys.stderr)
    sys.exit(1)

# At least 5 entries must have list values with >=2 items
list_vals = [v for v in aliases.values() if isinstance(v, (list, tuple)) and len(v) >= 2]
if len(list_vals) < 5:
    print(f"  Only {len(list_vals)} entries have >=2 items (need 5+)", file=sys.stderr); sys.exit(1)

# Anti-gaming: >=3 keys must be recognized ComfyUI domain terms
domain = {"upscale", "controlnet", "lora", "flux", "inpaint", "depth", "pose",
          "video", "audio", "face", "segmentation", "style", "sdxl", "sd15",
          "animatediff", "wan", "latent", "vae", "clip", "dither", "glitch",
          "deforum", "klein", "t2v", "i2v", "v2v", "fft", "reactive", "ltx",
          "interpolation", "sampling", "denoise", "conditioning", "beat"}
matched = sum(1 for k in aliases if any(d in k.lower() for d in domain))
if matched < 3:
    print(f"  Only {matched} domain-term keys (need >=3, anti-gaming)", file=sys.stderr); sys.exit(1)

# Anti-stub: expand_query body >=3 non-trivial stmts
try:
    src = inspect.getsource(found.expand_query)
    tree = ast.parse(textwrap.dedent(src))
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef):
            body = [s for s in node.body
                    if not isinstance(s, ast.Pass)
                    and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))]
            if len(body) < 3:
                print(f"  expand_query stub ({len(body)} stmts, need >=3)", file=sys.stderr); sys.exit(1)
            break
except Exception:
    pass

# Behavioral: call expand_query with first alias key
k1 = list(aliases.keys())[0]
r1 = found.expand_query(k1)
if r1 is None or (isinstance(r1, (list, str)) and len(r1) == 0):
    print("  expand_query returned empty", file=sys.stderr); sys.exit(1)
r_len = len(r1) if isinstance(r1, (list, tuple)) else len(str(r1).split())
if r_len < 2:
    print(f"  expand_query returned only {r_len} term(s), need >=2", file=sys.stderr); sys.exit(1)

# Different keys -> different results
if len(aliases) >= 2:
    k2 = list(aliases.keys())[1]
    r2 = found.expand_query(k2)
    if str(r1) == str(r2):
        print("  expand_query returns identical results for different keys (stub)", file=sys.stderr)
        sys.exit(1)

# Non-alias input must not crash
try:
    found.expand_query("nonexistent_xyz_query_12345")
except Exception as e:
    print(f"  Crashes on non-alias input: {e}", file=sys.stderr); sys.exit(1)

print(f"  {len(aliases)} aliases, {matched} domain keys, expand_query works")
PYEOF

# ---------------------------------------------------------------------------
# Check 2 (0.20): MCP analysis tools + wiring — BEHAVIORAL (core)
#   MCP server must have >=9 tools (was 7), >=2 with analysis keywords.
#   mcp_server.py source must contain >=2 CALL expressions to analysis functions
#   (regex for func_name\( pattern, not just function names).
#   find_upstream must be callable with real workflow and return a dict.
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 2: MCP analysis tools + wiring (0.20, behavioral, core) ==="
python3 << 'PYEOF' && { echo "PASS: MCP analysis tools"; add_reward 0.20; } || echo "FAIL: MCP analysis tools"
import ast, sys, re, importlib, json
sys.path.insert(0, ".")

# Both must import
try:
    mcp_mod = importlib.import_module("cli_tools.registry.mcp_server")
except Exception as e:
    print(f"  mcp_server import failed: {e}", file=sys.stderr); sys.exit(1)
try:
    analysis_mod = importlib.import_module("cli_tools.analysis")
except Exception as e:
    print(f"  analysis import failed: {e}", file=sys.stderr); sys.exit(1)

# AST: count Tool definitions
with open(mcp_mod.__file__) as f:
    source = f.read()
tree = ast.parse(source)

tool_names = set()
# Pattern 1: Tool(name="...")
for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        func = node.func
        if (isinstance(func, ast.Name) and func.id == 'Tool') or \
           (isinstance(func, ast.Attribute) and func.attr == 'Tool'):
            for kw in node.keywords:
                if kw.arg == 'name' and isinstance(kw.value, ast.Constant):
                    tool_names.add(kw.value.value)
            if node.args and isinstance(node.args[0], ast.Constant):
                tool_names.add(node.args[0].value)

# Pattern 2: @server.tool() / @app.tool() decorated functions
for node in ast.walk(tree):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        for dec in node.decorator_list:
            if isinstance(dec, ast.Call) and isinstance(dec.func, ast.Attribute) and dec.func.attr == 'tool':
                name = dec.args[0].value if dec.args and isinstance(dec.args[0], ast.Constant) else node.name
                tool_names.add(name)
            elif isinstance(dec, ast.Attribute) and dec.attr == 'tool':
                tool_names.add(node.name)

if len(tool_names) < 9:
    print(f"  Only {len(tool_names)} tools (need >=9, was 7 originally)", file=sys.stderr); sys.exit(1)

# >=2 analysis-related tool names
analysis_kw = ['trace', 'upstream', 'downstream', 'path', 'orphan',
               'subgraph', 'dependency', 'signal', 'flow', 'graph', 'analyze']
analysis_tools = [t for t in tool_names if any(k in t.lower() for k in analysis_kw)]
if len(analysis_tools) < 2:
    print(f"  Only {len(analysis_tools)} analysis tools: {analysis_tools}", file=sys.stderr); sys.exit(1)

# Anti-gaming: mcp_server.py must CALL analysis functions (function_name\( pattern)
# This rejects stubs that merely name functions without calling them
call_pattern = r'(?:analysis\.)?(?:find_upstream|find_downstream|find_path|find_subgraph|find_orphans|find_dangling|analyze_workflow|trace_node|trace_signal)\s*\('
calls = re.findall(call_pattern, source)
if len(calls) < 2:
    print(f"  Only {len(calls)} analysis function calls in mcp_server (need >=2)", file=sys.stderr)
    sys.exit(1)

# BEHAVIORAL: call find_upstream with real workflow fixture
fn_up = getattr(analysis_mod, 'find_upstream', None)
if not fn_up:
    print("  analysis.find_upstream missing", file=sys.stderr); sys.exit(1)

wf = None
try:
    with open("workflows/workflow_fixed_node.json") as f:
        wf = json.load(f)
except Exception:
    pass

if wf and wf.get("nodes"):
    target_id = wf["nodes"][-1].get("id")
    try:
        result = fn_up(wf, target_id)
        if not isinstance(result, dict):
            print(f"  find_upstream returned {type(result).__name__}, expected dict", file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        print(f"  find_upstream call error: {e}", file=sys.stderr); sys.exit(1)

print(f"  {len(tool_names)} tools, {len(analysis_tools)} analysis tools, {len(calls)} analysis calls")
PYEOF

# ---------------------------------------------------------------------------
# Check 3 (0.23): Integration end-to-end — BEHAVIORAL
#   All 4 core modules import. MCP server calls analysis functions.
#   >7 tools. expand_query works via knowledge module.
#   Knowledge search_nodes still works (P2P behavioral).
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 3: Integration E2E (0.23, behavioral) ==="
python3 << 'PYEOF' && { echo "PASS: Integration works"; add_reward 0.23; } || echo "FAIL: Integration"
import sys, ast, re
sys.path.insert(0, ".")

# All 4 modules must import
errors = []
for mod in ["cli_tools.analysis", "cli_tools.registry.knowledge",
            "cli_tools.registry.mcp_server", "cli_tools.descriptions"]:
    try:
        __import__(mod)
    except Exception as e:
        errors.append(f"{mod}: {e}")
if errors:
    for e in errors: print(f"  Import error: {e}", file=sys.stderr)
    sys.exit(1)

# MCP server must call analysis functions
import cli_tools.registry.mcp_server as mcp_mod
with open(mcp_mod.__file__) as f:
    mcp_src = f.read()
call_pat = r'(?:analysis\.)?(?:find_upstream|find_downstream|find_path|find_subgraph|find_orphans|analyze_workflow)\s*\('
if not re.search(call_pat, mcp_src):
    print("  MCP server doesn't call analysis functions", file=sys.stderr); sys.exit(1)

# >7 tools
tree = ast.parse(mcp_src)
tool_count = 0
seen = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        func = node.func
        if (isinstance(func, ast.Name) and func.id == 'Tool') or \
           (isinstance(func, ast.Attribute) and func.attr == 'Tool'):
            for kw in node.keywords:
                if kw.arg == 'name' and isinstance(kw.value, ast.Constant) and kw.value.value not in seen:
                    seen.add(kw.value.value); tool_count += 1
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        for dec in node.decorator_list:
            if (isinstance(dec, ast.Call) and isinstance(dec.func, ast.Attribute) and dec.func.attr == 'tool') or \
               (isinstance(dec, ast.Attribute) and dec.attr == 'tool'):
                if node.name not in seen:
                    seen.add(node.name); tool_count += 1
if tool_count <= 7:
    print(f"  Only {tool_count} tools (need >7)", file=sys.stderr); sys.exit(1)

# expand_query works via knowledge module
import cli_tools.registry.knowledge as knowledge
if hasattr(knowledge, 'expand_query'):
    ta = getattr(knowledge, 'TASK_ALIASES', {})
    key = list(ta.keys())[0] if ta else "upscale"
    r = knowledge.expand_query(key)
    if r is None or (isinstance(r, (list, str)) and len(r) == 0):
        print("  expand_query via knowledge returned empty", file=sys.stderr); sys.exit(1)
elif hasattr(knowledge, 'ComfyKnowledge'):
    ck = knowledge.ComfyKnowledge()
    if hasattr(ck, 'search_nodes'):
        r = ck.search_nodes("upscale")
        if not r:
            print("  search_nodes returned empty", file=sys.stderr); sys.exit(1)
    else:
        print("  No search capability", file=sys.stderr); sys.exit(1)
else:
    print("  knowledge has no expand_query or ComfyKnowledge", file=sys.stderr); sys.exit(1)

# Knowledge search_nodes still works (P2P)
ck = knowledge.ComfyKnowledge()
if hasattr(ck, 'search_nodes'):
    results = ck.search_nodes("controlnet", 5)
    if not results or len(results) == 0:
        print("  search_nodes('controlnet') broken", file=sys.stderr); sys.exit(1)

print(f"  All imports OK, {tool_count} tools, search works")
PYEOF

# ---------------------------------------------------------------------------
# Check 4 (0.12): Test suite — BEHAVIORAL
#   Agent must create test_*.py with >=5 tests importing cli_tools.
#   Anti-stub: >=3 test functions must have project references + >=4
#   non-trivial stmts + assert statements + actual function calls.
#   At least 3 tests must pass with pytest.
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 4: Test suite (0.12, behavioral) ==="
python3 << 'PYEOF' && { echo "PASS: Tests pass"; add_reward 0.12; } || echo "FAIL: Test suite"
import subprocess, ast, re, sys, os

# Find test files
test_files = []
for root, dirs, files in os.walk("."):
    if ".git" in root or "__pycache__" in root: continue
    for f in files:
        if f.startswith("test_") and f.endswith(".py"):
            test_files.append(os.path.join(root, f))

if not test_files:
    print("  No test files found", file=sys.stderr); sys.exit(1)

# Find file with most test functions
max_tests = 0; best_file = None
for tf in test_files:
    with open(tf) as f: src = f.read()
    count = len(re.findall(r'def\s+test_\w+', src))
    if count > max_tests: max_tests = count; best_file = tf

if max_tests < 5:
    print(f"  Best file has only {max_tests} tests (need 5+)", file=sys.stderr); sys.exit(1)

with open(best_file) as f:
    tree = ast.parse(f.read())

# Must import from cli_tools
has_cli_import = False
for node in ast.walk(tree):
    if isinstance(node, ast.ImportFrom) and node.module and 'cli_tools' in node.module:
        has_cli_import = True; break
    if isinstance(node, ast.Import):
        for alias in node.names:
            if 'cli_tools' in alias.name: has_cli_import = True; break
if not has_cli_import:
    print("  Tests don't import from cli_tools (stubs rejected)", file=sys.stderr); sys.exit(1)

# Anti-stub: >=3 tests with project refs + >=4 stmts + assert + function calls
project_refs = {'analysis', 'search', 'knowledge', 'mcp_server',
                'expand_query', 'trace_node', 'find_upstream', 'find_downstream',
                'TASK_ALIASES', 'trace_signal', 'trace_flow', 'ComfyKnowledge',
                'search_nodes', 'get_node_spec', 'simplify_workflow', 'find_path'}
substantive = 0
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name.startswith('test_'):
        body_dump = ast.dump(node)
        has_ref = any(ref in body_dump for ref in project_refs)
        body_stmts = [s for s in node.body
                      if not isinstance(s, ast.Pass)
                      and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))]
        has_assert = any(isinstance(s, ast.Assert) for s in ast.walk(node))
        has_call = any(isinstance(s, ast.Call) for s in ast.walk(node))
        if has_ref and len(body_stmts) >= 4 and has_assert and has_call:
            substantive += 1

if substantive < 3:
    print(f"  Only {substantive} substantive tests (need 3+ with refs+stmts+assert+calls)", file=sys.stderr)
    sys.exit(1)

# Run with pytest
env = os.environ.copy()
env["PYTHONPATH"] = "."
result = subprocess.run(
    ["python3", "-m", "pytest", best_file, "-v", "--tb=short", "-q"],
    capture_output=True, text=True, timeout=60, cwd="/workspace/VibeComfy", env=env
)
output = result.stdout + result.stderr

passed_match = re.search(r'(\d+)\s+passed', output)
failed_match = re.search(r'(\d+)\s+failed', output)

if passed_match:
    passed = int(passed_match.group(1))
    failed = int(failed_match.group(1)) if failed_match else 0
else:
    # Fallback: unittest
    test_dir = os.path.dirname(best_file) or "."
    result = subprocess.run(
        ["python3", "-m", "unittest", "discover", "-s", test_dir, "-p", "test_*.py", "-v"],
        capture_output=True, text=True, timeout=60, cwd="/workspace/VibeComfy", env=env
    )
    output = result.stdout + result.stderr
    passed = len(re.findall(r'\.\.\. ok', output))
    ran_match = re.search(r'Ran (\d+) test', output)
    if ran_match and passed == 0 and result.returncode == 0:
        passed = int(ran_match.group(1))
    failed = len(re.findall(r'\.\.\. (FAIL|ERROR)', output))

if passed < 3:
    print(f"  Only {passed} tests passed ({failed} failed)", file=sys.stderr)
    print(f"  Output tail: {output[-300:]}", file=sys.stderr); sys.exit(1)

print(f"  {passed} tests passed, {substantive} substantive")
PYEOF

# ---------------------------------------------------------------------------
# Check 5 (0.07): TASK_ALIASES extracted from knowledge.py — STRUCTURAL
#   knowledge.py should import TASK_ALIASES/expand_query from shared module,
#   not define a large inline dict (>10 entries). Must still import successfully.
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 5: TASK_ALIASES extracted (0.07, structural) ==="
python3 << 'PYEOF' && { echo "PASS: TASK_ALIASES extracted"; add_reward 0.07; } || echo "FAIL: TASK_ALIASES extraction"
import ast, sys, importlib

with open("cli_tools/registry/knowledge.py") as f:
    source = f.read()
tree = ast.parse(source)

# TASK_ALIASES should NOT be a large inline dict (>10 keys)
for node in ast.walk(tree):
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == 'TASK_ALIASES':
                if isinstance(node.value, ast.Dict) and len(node.value.keys) > 10:
                    print(f"  TASK_ALIASES still inline ({len(node.value.keys)} entries)", file=sys.stderr)
                    sys.exit(1)

# Must import from shared module
has_import = False
for node in ast.walk(tree):
    if isinstance(node, ast.ImportFrom):
        for alias in node.names:
            if alias.name in ('TASK_ALIASES', 'expand_query', '*'):
                has_import = True; break
        if node.module and ('search' in node.module or 'shared' in node.module):
            has_import = True
    if has_import: break

if not has_import:
    print("  knowledge.py doesn't import from shared module", file=sys.stderr); sys.exit(1)

# Verify knowledge.py imports successfully
try:
    importlib.import_module("cli_tools.registry.knowledge")
except Exception as e:
    print(f"  knowledge.py import failed: {e}", file=sys.stderr); sys.exit(1)

print("  Extracted, shared module imported")
PYEOF

# ---------------------------------------------------------------------------
# Check 6a (0.03): .mcp.json auto-config — STRUCTURAL
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 6a: .mcp.json (0.03, structural) ==="
python3 << 'PYEOF' && { echo "PASS: .mcp.json"; add_reward 0.03; } || echo "FAIL: .mcp.json"
import json, sys, os

mcp_path = None
for c in [".mcp.json", "mcp.json"]:
    if os.path.exists(c): mcp_path = c; break
if not mcp_path:
    print("  Not found", file=sys.stderr); sys.exit(1)

with open(mcp_path) as f:
    config = json.load(f)

servers = config.get("mcpServers", config.get("servers", {}))
if not servers:
    print("  No servers defined", file=sys.stderr); sys.exit(1)

found = any("mcp_server" in (sc.get("command", "") + " " + " ".join(str(a) for a in sc.get("args", [])))
            or "registry" in (sc.get("command", "") + " " + " ".join(str(a) for a in sc.get("args", [])))
            for sc in servers.values())
if not found:
    print("  No server entry references mcp_server", file=sys.stderr); sys.exit(1)
print(f"  {mcp_path}: {len(servers)} server(s)")
PYEOF

# ---------------------------------------------------------------------------
# Check 6b (0.02): requirements.txt — STRUCTURAL
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 6b: requirements.txt (0.02, structural) ==="
python3 << 'PYEOF' && { echo "PASS: requirements.txt"; add_reward 0.02; } || echo "FAIL: requirements.txt"
import sys, os
if not os.path.exists("requirements.txt"):
    print("  Not found", file=sys.stderr); sys.exit(1)
with open("requirements.txt") as f:
    content = f.read().lower()
if "mcp" not in content:
    print("  Missing mcp dependency", file=sys.stderr); sys.exit(1)
print("  OK")
PYEOF

# ---------------------------------------------------------------------------
# Check 7 (0.05): Skills reorganized — STRUCTURAL
#   Need >=3 distinct skill definitions under .claude/skills/.
#   A skill is either a direct .md file or a subdirectory with .md content.
#   Each must have >=100 chars and >=2 project keywords.
#   (Base commit has only 1 skill dir "comfy-nodes" — fails this check.)
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 7: Skills reorganized (0.05, structural) ==="
python3 << 'PYEOF' && { echo "PASS: Skills reorganized"; add_reward 0.05; } || echo "FAIL: Skills reorganization"
import os, sys

skills_dir = ".claude/skills"
if not os.path.isdir(skills_dir):
    print("  .claude/skills/ not found", file=sys.stderr); sys.exit(1)

project_kw = ['comfy', 'node', 'workflow', 'mcp', 'registry', 'analysis', 'tool', 'search']

# Count distinct skills: direct .md files + subdirectories
valid_skills = 0
for item in os.listdir(skills_dir):
    path = os.path.join(skills_dir, item)
    content = ""
    if os.path.isfile(path) and item.endswith(".md"):
        content = open(path).read().strip()
    elif os.path.isdir(path):
        # Find primary .md in subdirectory (prefer SKILL.md)
        for f in sorted(os.listdir(path), key=lambda x: (0 if 'skill' in x.lower() else 1, x)):
            fp = os.path.join(path, f)
            if os.path.isfile(fp) and f.endswith(".md"):
                c = open(fp).read().strip()
                if len(c) >= 100:
                    content = c; break
    else:
        continue

    if len(content) < 100:
        continue
    lc = content.lower()
    if sum(1 for kw in project_kw if kw in lc) >= 2:
        valid_skills += 1

if valid_skills < 3:
    print(f"  Only {valid_skills} valid skill(s) (need 3+)", file=sys.stderr); sys.exit(1)

print(f"  {valid_skills} skills, all substantive")
PYEOF

# ---------------------------------------------------------------------------
# Check 8 (0.05): MCP tool descriptions prescriptive — STRUCTURAL
#   >=9 tool descriptions, >=4 with prescriptive language.
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 8: Prescriptive descriptions (0.05, structural) ==="
python3 << 'PYEOF' && { echo "PASS: Descriptions prescriptive"; add_reward 0.05; } || echo "FAIL: Descriptions"
import ast, re, sys

with open("cli_tools/registry/mcp_server.py") as f:
    source = f.read()
tree = ast.parse(source)

descriptions = []

# Tool(description="...") keyword
for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        func = node.func
        if (isinstance(func, ast.Name) and func.id == 'Tool') or \
           (isinstance(func, ast.Attribute) and func.attr == 'Tool'):
            for kw in node.keywords:
                if kw.arg == 'description' and isinstance(kw.value, ast.Constant):
                    descriptions.append(kw.value.value)
                if kw.arg == 'description' and isinstance(kw.value, ast.JoinedStr):
                    parts = [v.value for v in kw.value.values if isinstance(v, ast.Constant)]
                    descriptions.append(" ".join(parts))

# @server.tool() docstrings
for node in ast.walk(tree):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        for dec in node.decorator_list:
            is_tool = (isinstance(dec, ast.Call) and isinstance(dec.func, ast.Attribute) and dec.func.attr == 'tool') or \
                      (isinstance(dec, ast.Attribute) and dec.attr == 'tool')
            if is_tool:
                ds = ast.get_docstring(node)
                if ds and len(ds) > 10:
                    descriptions.append(ds)
                break

# Dict-style
for node in ast.walk(tree):
    if isinstance(node, ast.Dict):
        for i, key in enumerate(node.keys):
            if isinstance(key, ast.Constant) and key.value == 'description':
                val = node.values[i]
                if isinstance(val, ast.Constant) and isinstance(val.value, str):
                    descriptions.append(val.value)

descriptions = list(dict.fromkeys(descriptions))
if len(descriptions) < 9:
    print(f"  Only {len(descriptions)} descriptions (need 9+)", file=sys.stderr); sys.exit(1)

patterns = [
    r'\b(start|begin|first)\b',
    r'\b(use|run|call)\s+(this|after|before|when|for)\b',
    r'\b(after|before|once)\b',
    r'\b(when|if)\s+you\b',
    r'\b(recommended|prefer|best|ideal)\b',
    r'\b(e\.g\.|for example|such as)\b',
]
prescriptive = sum(1 for d in descriptions
                   if any(re.search(p, d, re.I) for p in patterns))
if prescriptive < 4:
    print(f"  Only {prescriptive}/{len(descriptions)} prescriptive", file=sys.stderr); sys.exit(1)

print(f"  {prescriptive}/{len(descriptions)} prescriptive descriptions")
PYEOF

# ---------------------------------------------------------------------------
# Check 9 (0.13): Analysis functions callable — BEHAVIORAL (P2P)
#   find_upstream and find_downstream must still work with the real workflow
#   fixture after integration changes. Returns must be dicts with expected
#   structure. Different node IDs must produce different results.
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 9: Analysis functions P2P (0.13, behavioral) ==="
python3 << 'PYEOF' && { echo "PASS: Analysis functions work"; add_reward 0.13; } || echo "FAIL: Analysis functions"
import sys, json
sys.path.insert(0, ".")
import cli_tools.analysis as analysis

# Load real workflow fixture
wf = None
try:
    with open("workflows/workflow_fixed_node.json") as f:
        wf = json.load(f)
except Exception:
    pass

if not wf or not wf.get("nodes"):
    # Minimal fallback
    wf = {
        "nodes": [
            {"id": 1, "type": "CLIPTextEncode", "inputs": [], "outputs": [{"links": [1]}]},
            {"id": 2, "type": "KSampler", "inputs": [{"link": 1}], "outputs": [{"links": [2]}]},
            {"id": 3, "type": "SaveImage", "inputs": [{"link": 2}], "outputs": []}
        ],
        "links": [[1, 1, 0, 2, 0, "CONDITIONING"], [2, 2, 0, 3, 0, "IMAGE"]]
    }

nodes = wf["nodes"]
node_ids = [n.get("id") for n in nodes if n.get("id") is not None]

# find_upstream
fn_up = getattr(analysis, 'find_upstream', None)
if not fn_up:
    print("  find_upstream missing", file=sys.stderr); sys.exit(1)

result_up = fn_up(wf, node_ids[-1])
if not isinstance(result_up, dict):
    print(f"  find_upstream returned {type(result_up).__name__}, expected dict", file=sys.stderr)
    sys.exit(1)
if 'nodes' not in result_up:
    print(f"  find_upstream missing 'nodes' key: {list(result_up.keys())}", file=sys.stderr)
    sys.exit(1)

# find_downstream
fn_down = getattr(analysis, 'find_downstream', None)
if not fn_down:
    print("  find_downstream missing", file=sys.stderr); sys.exit(1)

result_down = fn_down(wf, node_ids[0])
if not isinstance(result_down, dict):
    print(f"  find_downstream returned {type(result_down).__name__}, expected dict", file=sys.stderr)
    sys.exit(1)

# Different inputs -> different results (anti-static-return stub)
if len(node_ids) >= 5:
    r1 = fn_up(wf, node_ids[0])
    r2 = fn_up(wf, node_ids[-1])
    if r1.get('nodes') == r2.get('nodes'):
        print("  Identical results for different nodes (stub)", file=sys.stderr); sys.exit(1)

# find_path exists and is callable
fn_path = getattr(analysis, 'find_path', None)
if fn_path:
    try:
        fn_path(wf, node_ids[0], node_ids[-1])
    except Exception:
        pass  # Format mismatch OK for P2P

print(f"  find_upstream/find_downstream work ({len(node_ids)} nodes)")
PYEOF

# ---------------------------------------------------------------------------
# Write final reward
# ---------------------------------------------------------------------------
echo ""
echo "================================"
echo "Final reward: $REWARD"
echo "================================"
echo "$REWARD" > "$LOG_DIR/reward.txt"
