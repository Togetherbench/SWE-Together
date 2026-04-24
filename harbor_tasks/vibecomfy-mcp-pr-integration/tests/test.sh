#!/bin/bash
#
# Verification script for vibecomfy-mcp-pr-integration task.
#
# Scoring (15 sub-checks, total exactly 1.00):
#   Check 1      (0.05) Shared search module           BEHAVIORAL  [F2P]
#   Check 2a     (0.04) MCP analysis tools exist        BEHAVIORAL  [F2P]
#   Check 2b-i   (0.06) MCP dispatch basic              BEHAVIORAL  [F2P]
#   Check 2b-ii  (0.08) MCP dispatch correct results    BEHAVIORAL  [F2P]
#   Check 2b-iii (0.08) MCP dispatch full correctness   BEHAVIORAL  [F2P]
#   Check 4      (0.08) Test suite                      BEHAVIORAL  [F2P]
#   Check 4b     (0.01) Turn 3 coverage                 BEHAVIORAL  [F2P]
#   Check 5      (0.03) TASK_ALIASES extracted           STRUCTURAL  [F2P]
#   Check 6a     (0.01) .mcp.json auto-config           STRUCTURAL  [F2P]
#   Check 6b     (0.01) requirements.txt                STRUCTURAL  [F2P]
#   Check 7      (0.03) Skills reorganized              STRUCTURAL  [F2P]
#   Check 8      (0.02) Prescriptive descriptions       STRUCTURAL  [F2P]
#   Check 9      (0.07) Analysis functions P2P          BEHAVIORAL  [P2P]
#   Check 10     (0.14) Knowledge integration           BEHAVIORAL  [F2P]
#   Check 11-i   (0.07) Cross-module basic              BEHAVIORAL  [F2P]
#   Check 11-ii  (0.09) Cross-module alias correctness  BEHAVIORAL  [F2P]
#   Check 11-iii (0.08) Cross-module e2e chain          BEHAVIORAL  [F2P]
#   Check 12     (0.05) Edge case handling              BEHAVIORAL  [F2P]
#
# Total weight: exactly 1.00 (no cap margin)
# P2P weight: 0.07 (Check 9 only — passes on unmodified base commit)
# F2P weight: 0.93 (all other checks — require agent modifications)
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

# ===========================================================================
# Check 1 (0.05): Shared search module -- BEHAVIORAL
# ===========================================================================
echo "=== Check 1: Shared search module (0.05) ==="
python3 << 'PYEOF' && { echo "PASS: Check 1"; add_reward 0.05; } || echo "FAIL: Check 1"
import sys, ast, importlib, glob, importlib.util, textwrap, inspect
sys.path.insert(0, ".")

found = None
for mod_path in ["cli_tools.search", "cli_tools.registry.search", "cli_tools.utils.search",
                 "cli_tools.shared", "cli_tools.registry.shared", "cli_tools.aliases",
                 "cli_tools.registry.aliases", "cli_tools.common"]:
    try:
        m = importlib.import_module(mod_path)
        if hasattr(m, 'TASK_ALIASES'):
            found = m; break
    except Exception:
        pass

if not found:
    for pyfile in glob.glob("cli_tools/**/*.py", recursive=True):
        if 'knowledge' in pyfile: continue
        mod_name = pyfile.replace("/", ".").replace(".py", "")
        try:
            spec = importlib.util.spec_from_file_location(mod_name, pyfile)
            m = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(m)
            if hasattr(m, 'TASK_ALIASES'):
                found = m; break
        except Exception:
            pass

if not found:
    print("  No module with TASK_ALIASES found", file=sys.stderr); sys.exit(1)

if hasattr(found, '__file__') and found.__file__ and 'knowledge' in found.__file__:
    print("  TASK_ALIASES still in knowledge.py", file=sys.stderr); sys.exit(1)

aliases = found.TASK_ALIASES
if not isinstance(aliases, dict) or len(aliases) < 28:
    print(f"  TASK_ALIASES needs >=28, got {len(aliases) if isinstance(aliases, dict) else 0}", file=sys.stderr); sys.exit(1)

if hasattr(found, '__file__') and found.__file__:
    with open(found.__file__) as _f:
        line_count = len(_f.readlines())
    if line_count > 150:
        print(f"  Shared module {line_count} lines (max 150)", file=sys.stderr); sys.exit(1)
    if hasattr(found, 'ComfyKnowledge'):
        print("  Contains ComfyKnowledge class", file=sys.stderr); sys.exit(1)

list_vals = [v for v in aliases.values() if isinstance(v, (list, tuple)) and len(v) >= 2]
if len(list_vals) < 12:
    print(f"  Only {len(list_vals)} entries with >=2 items", file=sys.stderr); sys.exit(1)

domain = {"upscale", "controlnet", "lora", "flux", "inpaint", "depth", "pose",
          "video", "audio", "face", "segmentation", "style", "sdxl", "sd15",
          "animatediff", "wan", "latent", "vae", "clip", "dither", "glitch",
          "deforum", "klein", "t2v", "i2v", "v2v", "fft", "reactive", "ltx",
          "interpolation", "sampling", "denoise", "conditioning", "beat"}
matched = sum(1 for k in aliases if any(d in k.lower() for d in domain))
if matched < 3:
    print(f"  Only {matched} domain keys", file=sys.stderr); sys.exit(1)

expand_fn = None
expand_fn_name = None
for name in ['expand_query', 'expand_aliases', 'resolve_query', 'get_search_terms',
             'expand_terms', 'resolve_aliases', 'expand_search', 'expand']:
    fn = getattr(found, name, None)
    if fn and callable(fn):
        expand_fn = fn; expand_fn_name = name; break

if not expand_fn:
    for attr_name in dir(found):
        if attr_name.startswith('_') or attr_name == 'TASK_ALIASES': continue
        attr = getattr(found, attr_name)
        if not callable(attr): continue
        try:
            k = list(aliases.keys())[0]
            result = attr(k)
            if isinstance(result, (list, tuple, set)) and len(result) >= 2:
                expand_fn = attr; expand_fn_name = attr_name; break
        except Exception:
            continue

if not expand_fn:
    print("  No expand function found", file=sys.stderr); sys.exit(1)

try:
    src = inspect.getsource(expand_fn)
    tree = ast.parse(textwrap.dedent(src))
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef):
            body = [s for s in node.body if not isinstance(s, ast.Pass)
                    and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))]
            if len(body) < 3:
                print(f"  {expand_fn_name} stub", file=sys.stderr); sys.exit(1)
            break
except Exception:
    pass

k1 = list(aliases.keys())[0]
r1 = expand_fn(k1)
if r1 is None or (isinstance(r1, (list, str)) and len(r1) == 0):
    print("  expand returned empty", file=sys.stderr); sys.exit(1)
if len(aliases) >= 2:
    k2 = list(aliases.keys())[1]
    r2 = expand_fn(k2)
    if str(sorted(str(x) for x in r1)) == str(sorted(str(x) for x in r2)):
        print("  identical for different keys", file=sys.stderr); sys.exit(1)
try:
    expand_fn("nonexistent_xyz_12345")
except Exception as e:
    print(f"  Crashes on non-alias: {e}", file=sys.stderr); sys.exit(1)
print(f"  OK: {len(aliases)} aliases, {expand_fn_name}()")
PYEOF

# ===========================================================================
# Check 2a (0.04): MCP analysis tools exist -- BEHAVIORAL
# ===========================================================================
echo ""
echo "=== Check 2a: MCP analysis tools (0.04) ==="
python3 << 'PYEOF' && { echo "PASS: Check 2a"; add_reward 0.04; } || echo "FAIL: Check 2a"
import ast, sys, re, importlib
sys.path.insert(0, ".")
for mod in ["cli_tools.analysis", "cli_tools.registry.knowledge",
            "cli_tools.registry.mcp_server", "cli_tools.descriptions"]:
    try: __import__(mod)
    except Exception as e:
        print(f"  Import error {mod}: {e}", file=sys.stderr); sys.exit(1)
mcp_mod = importlib.import_module("cli_tools.registry.mcp_server")
with open(mcp_mod.__file__) as f: source = f.read()
tree = ast.parse(source)
tool_names = set()
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
for node in ast.walk(tree):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        for dec in node.decorator_list:
            if isinstance(dec, ast.Call) and isinstance(dec.func, ast.Attribute) and dec.func.attr == 'tool':
                name = dec.args[0].value if dec.args and isinstance(dec.args[0], ast.Constant) else node.name
                tool_names.add(name)
            elif isinstance(dec, ast.Attribute) and dec.attr == 'tool':
                tool_names.add(node.name)
if len(tool_names) < 9:
    print(f"  Only {len(tool_names)} tools", file=sys.stderr); sys.exit(1)
analysis_kw = ['trace', 'upstream', 'downstream', 'path', 'orphan', 'subgraph', 'dependency', 'signal', 'flow', 'graph', 'analyze']
analysis_tools = [t for t in tool_names if any(k in t.lower() for k in analysis_kw)]
if len(analysis_tools) < 2:
    print(f"  Only {len(analysis_tools)} analysis tools", file=sys.stderr); sys.exit(1)
call_pat = r'(?:analysis\.)?(?:find_upstream|find_downstream|find_path|find_subgraph|find_orphans|analyze_workflow|trace_node)\s*\('
calls = re.findall(call_pat, source)
if len(calls) < 2:
    print(f"  Only {len(calls)} analysis calls", file=sys.stderr); sys.exit(1)
has_import = False
for node in ast.walk(tree):
    if isinstance(node, ast.ImportFrom) and node.module and 'analysis' in node.module:
        has_import = True; break
    if isinstance(node, ast.Import):
        for alias in node.names:
            if 'analysis' in alias.name: has_import = True; break
if not has_import and not re.search(r'(?:from|import)\s+\S*analysis', source):
    print("  No analysis import", file=sys.stderr); sys.exit(1)
print(f"  OK: {len(tool_names)} tools, {len(analysis_tools)} analysis")
PYEOF

# ===========================================================================
# Check 2b-i (0.06): MCP dispatch basic -- BEHAVIORAL
# Verifies MCP server wires analysis functions into tool handlers.
# Supports module-level dispatch AND nested (MCP SDK) call_tool patterns.
# ===========================================================================
echo ""
echo "=== Check 2b-i: MCP dispatch basic (0.06) ==="
python3 << 'PYEOF' && { echo "PASS: Check 2b-i"; add_reward 0.06; } || echo "FAIL: Check 2b-i"
import sys, json, importlib, asyncio, ast
sys.path.insert(0, ".")
with open("workflows/workflow_fixed_node.json") as f: wf = json.load(f)
wf_json = json.dumps(wf)
nodes = wf["nodes"]
node_ids = [n.get("id") for n in nodes if n.get("id") is not None]
test_nid = node_ids[len(node_ids) // 2]
mcp_mod = importlib.import_module("cli_tools.registry.mcp_server")
mcp_src = open(mcp_mod.__file__).read()
afns = ['find_upstream', 'find_downstream', 'find_path', 'find_subgraph', 'find_orphans', 'analyze_workflow', 'trace_node']
acalls = sum(1 for fn in afns if fn + '(' in mcp_src)
if acalls < 2:
    print(f"  Only {acalls} analysis calls in source", file=sys.stderr); sys.exit(1)

ok = 0
# Approach 1: module-level dispatch function
dispatch_fn = None
for name in ['_handle_tool', 'call_tool', 'handle_call', 'dispatch', 'handle_tool_call',
             '_dispatch', 'dispatch_tool', 'route_tool', '_route']:
    fn = getattr(mcp_mod, name, None)
    if fn and callable(fn): dispatch_fn = fn; break
if dispatch_fn:
    for tn in ["comfy_upstream", "comfy_downstream", "trace_upstream", "trace_downstream",
               "find_upstream", "find_downstream"]:
        if ok >= 1: break
        try:
            if asyncio.iscoroutinefunction(dispatch_fn):
                r = asyncio.get_event_loop().run_until_complete(dispatch_fn(tn, {"workflow_json": wf_json, "node_id": test_nid}))
            else:
                r = dispatch_fn(tn, {"workflow_json": wf_json, "node_id": test_nid})
            if r and len(str(r)) > 20: ok += 1
        except Exception: pass
    # Dispatch may need a kb object -- try instantiating knowledge and passing
    if ok < 1 and dispatch_fn:
        try:
            km = importlib.import_module("cli_tools.registry.knowledge")
            CK = getattr(km, 'ComfyKnowledge', None)
            if CK:
                kb = CK()
                for lm in ['load_nodes','_load_cache','load','init']:
                    fn = getattr(kb, lm, None)
                    if fn and callable(fn):
                        try: fn(); break
                        except: pass
                for tn in ["comfy_upstream", "comfy_downstream", "trace_upstream", "trace_downstream",
                           "find_upstream", "find_downstream"]:
                    if ok >= 1: break
                    try:
                        if asyncio.iscoroutinefunction(dispatch_fn):
                            r = asyncio.get_event_loop().run_until_complete(dispatch_fn(kb, tn, {"workflow_json": wf_json, "node_id": test_nid}))
                        else:
                            r = dispatch_fn(kb, tn, {"workflow_json": wf_json, "node_id": test_nid})
                        if r and len(str(r)) > 20: ok += 1
                    except Exception: pass
        except Exception: pass
# Approach 2: module-level wrapper functions (including _fmt_ variants)
if ok < 1:
    for fn_name in ['find_upstream', 'find_downstream', 'find_path',
                    '_fmt_upstream', '_fmt_downstream', '_fmt_path',
                    'trace_upstream', 'trace_downstream']:
        if ok >= 1: break
        fn = getattr(mcp_mod, fn_name, None)
        if not fn or not callable(fn): continue
        try:
            r = fn(wf, test_nid) if 'path' not in fn_name else fn(wf, node_ids[0], node_ids[-1])
            if r and len(str(r)) > 20: ok += 1
        except Exception: pass
# Approach 3: nested handlers (MCP SDK pattern -- call_tool inside main())
# The handler may be a single if/elif chain (2 top-level stmts) with many branches
# Accept functions referencing upstream AND downstream (directly or via helpers)
if ok < 1:
    tree = ast.parse(mcp_src)
    nested_handler_found = False
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)): continue
        bd = ast.dump(node)
        has_up = 'upstream' in bd.lower()
        has_down = 'downstream' in bd.lower()
        if has_up and has_down:
            # Count effective branches (if/elif) not just top-level stmts
            branch_count = sum(1 for n in ast.walk(node) if isinstance(n, ast.If))
            stmts = [s for s in node.body if not isinstance(s, ast.Pass)
                      and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))]
            if len(stmts) >= 2 and branch_count >= 3: nested_handler_found = True; break
            if len(stmts) >= 5: nested_handler_found = True; break
    if nested_handler_found:
        # Verify the actual analysis module works (proves wiring is meaningful)
        import cli_tools.analysis as analysis
        try:
            r = analysis.find_upstream(wf, test_nid)
            if isinstance(r, dict) and len(r.get('nodes', {})) > 0: ok = 1
        except: pass
if ok < 1:
    print("  No dispatch works", file=sys.stderr); sys.exit(1)
print(f"  OK: dispatch verified (analysis calls={acalls})")
PYEOF

# ===========================================================================
# Check 2b-ii (0.08): MCP dispatch correct results -- BEHAVIORAL
# Tests that both upstream and downstream produce correct, distinct results
# for a known node (1047). Handles nested MCP SDK handlers.
# ===========================================================================
echo ""
echo "=== Check 2b-ii: MCP dispatch correct (0.08) ==="
python3 << 'PYEOF' && { echo "PASS: Check 2b-ii"; add_reward 0.08; } || echo "FAIL: Check 2b-ii"
import sys, json, importlib, asyncio, ast
sys.path.insert(0, ".")
with open("workflows/workflow_fixed_node.json") as f: wf = json.load(f)
wf_json = json.dumps(wf)
nodes = wf["nodes"]
node_ids = [n.get("id") for n in nodes if n.get("id") is not None]
test_nid = 1047
mcp_mod = importlib.import_module("cli_tools.registry.mcp_server")
mcp_src = open(mcp_mod.__file__).read()

ok = 0; results = []

def _try_dispatch(fn, tool_name, args):
    """Try calling a dispatch function with or without knowledge arg."""
    import asyncio as _aio
    # Try (tool_name, args) signature first
    try:
        if _aio.iscoroutinefunction(fn):
            return _aio.get_event_loop().run_until_complete(fn(tool_name, args))
        return fn(tool_name, args)
    except TypeError:
        pass
    # Try (kb, tool_name, args) signature -- dispatch may need knowledge instance
    try:
        km = importlib.import_module("cli_tools.registry.knowledge")
        CK = getattr(km, 'ComfyKnowledge', None)
        if CK:
            kb = CK()
            for lm in ['load_nodes','_load_cache','load','init']:
                lfn = getattr(kb, lm, None)
                if lfn and callable(lfn):
                    try: lfn(); break
                    except: pass
            if _aio.iscoroutinefunction(fn):
                return _aio.get_event_loop().run_until_complete(fn(kb, tool_name, args))
            return fn(kb, tool_name, args)
    except Exception:
        pass
    return None

# Approach 1: module-level dispatch function
dispatch_fn = None
for name in ['_handle_tool', 'call_tool', 'handle_call', 'dispatch', 'handle_tool_call',
             '_dispatch', 'dispatch_tool', 'route_tool', '_route']:
    fn = getattr(mcp_mod, name, None)
    if fn and callable(fn): dispatch_fn = fn; break
if dispatch_fn:
    for t in ["comfy_upstream", "trace_upstream", "find_upstream"]:
        if ok >= 1: break
        try:
            r = _try_dispatch(dispatch_fn, t, {"workflow_json": wf_json, "node_id": test_nid})
            rs = str(r) if r else ""
            if r and len(rs) > 20: ok += 1; results.append(rs)
        except Exception: pass
    for t in ["comfy_downstream", "trace_downstream", "find_downstream"]:
        if ok >= 2: break
        try:
            r = _try_dispatch(dispatch_fn, t, {"workflow_json": wf_json, "node_id": test_nid})
            rs = str(r) if r else ""
            if r and len(rs) > 20: ok += 1; results.append(rs)
        except Exception: pass

# Approach 2: module-level wrappers (including _fmt_ variants)
if ok < 2:
    for fn_name in ['find_upstream', 'find_downstream', '_fmt_upstream', '_fmt_downstream',
                    'trace_upstream', 'trace_downstream']:
        if ok >= 2: break
        fn = getattr(mcp_mod, fn_name, None)
        if not fn or not callable(fn): continue
        try:
            r = fn(wf, test_nid); rs = str(r)
            if r and len(rs) > 20: ok += 1; results.append(rs)
        except Exception: pass

# Approach 3: nested MCP SDK handlers -- verify via analysis module directly
# Accept functions referencing upstream AND downstream (directly or via helpers)
if ok < 2:
    tree = ast.parse(mcp_src)
    handler_has_both = False
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)): continue
        bd = ast.dump(node)
        has_up = 'upstream' in bd.lower()
        has_down = 'downstream' in bd.lower()
        if has_up and has_down:
            branch_count = sum(1 for n in ast.walk(node) if isinstance(n, ast.If))
            stmts = [s for s in node.body if not isinstance(s, ast.Pass)
                      and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))]
            if (len(stmts) >= 2 and branch_count >= 3) or len(stmts) >= 5:
                handler_has_both = True; break
    if handler_has_both:
        import cli_tools.analysis as analysis
        try:
            ru = analysis.find_upstream(wf, test_nid)
            rd = analysis.find_downstream(wf, test_nid)
            rus = str(ru); rds = str(rd)
            if ru and len(rus) > 20: ok += 1; results.append(rus)
            if rd and len(rds) > 20: ok += 1; results.append(rds)
        except: pass

if ok < 2:
    print(f"  Only {ok} tools work", file=sys.stderr); sys.exit(1)
# Verify results contain node content
nid_strs = set(str(nid) for nid in node_ids[:20])
ntypes = set(n.get("type","") for n in nodes if n.get("type"))
has_content = False
for rs in results:
    if any(ns in rs for ns in nid_strs) or any(nt.lower() in rs.lower() for nt in list(ntypes)[:10] if nt) or any(kw in rs.lower() for kw in ['node','upstream','downstream']):
        has_content = True; break
if not has_content:
    print("  No node content", file=sys.stderr); sys.exit(1)
if len(results) >= 2 and results[0] == results[1]:
    print("  Identical results", file=sys.stderr); sys.exit(1)
if max(len(r) for r in results) < 100:
    print("  Too short", file=sys.stderr); sys.exit(1)
print(f"  OK: {ok} tools correct, distinct results")
PYEOF

# ===========================================================================
# Check 2b-iii (0.08): MCP dispatch full correctness -- BEHAVIORAL
# ===========================================================================
echo ""
echo "=== Check 2b-iii: MCP full correctness (0.08) ==="
python3 << 'PYEOF' && { echo "PASS: Check 2b-iii"; add_reward 0.08; } || echo "FAIL: Check 2b-iii"
import sys, json, importlib, ast
sys.path.insert(0, ".")
with open("workflows/workflow_fixed_node.json") as f: wf = json.load(f)
mcp_mod = importlib.import_module("cli_tools.registry.mcp_server")
mcp_src = open(mcp_mod.__file__).read()
tree = ast.parse(mcp_src)
# Anti-stub: handler >=5 stmts
handler_ok = False
for n in ast.walk(tree):
    if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
        bd = ast.dump(n)
        if any(fn in bd for fn in ['find_upstream','find_downstream','find_path','trace_node','analyze_workflow']):
            stmts = [s for s in n.body if not isinstance(s, ast.Pass) and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))]
            if len(stmts) >= 5: handler_ok = True; break
if not handler_ok:
    print("  Handler <5 stmts", file=sys.stderr); sys.exit(1)
fb = {n.name: ast.dump(n) for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
if not any('find_upstream' in b for b in fb.values()):
    print("  upstream not wired", file=sys.stderr); sys.exit(1)
if not any('find_downstream' in b for b in fb.values()):
    print("  downstream not wired", file=sys.stderr); sys.exit(1)
# Correctness: node 1047
import cli_tools.analysis as analysis
ru = analysis.find_upstream(wf, 1047)
rd = analysis.find_downstream(wf, 1047)
uc = len(ru.get('nodes', {}))
dc = len(rd.get('nodes', {}))
if uc < 25:
    print(f"  upstream(1047)={uc} (need>=25)", file=sys.stderr); sys.exit(1)
if dc < 9:
    print(f"  downstream(1047)={dc} (need>=9)", file=sys.stderr); sys.exit(1)
# Check known upstream IDs
if isinstance(ru.get('nodes'), dict):
    up_ids = set(ru['nodes'].keys())
else:
    up_ids = set(ru.get('nodes', []))
known = {393, 514, 949, 973, 1039}
found = len(known & set(int(x) if isinstance(x, str) else x for x in up_ids))
if found < 2:
    print(f"  Only {found} known upstream IDs", file=sys.stderr); sys.exit(1)
print(f"  OK: up={uc}, down={dc}, handler OK, known IDs found")
PYEOF

# ===========================================================================
# Check 4 (0.08): Test suite -- BEHAVIORAL
# ===========================================================================
echo ""
echo "=== Check 4: Test suite (0.08) ==="
python3 << 'PYEOF' && { echo "PASS: Check 4"; add_reward 0.08; } || echo "FAIL: Check 4"
import subprocess, ast, re, sys, os
test_files = []
for root, dirs, files in os.walk("."):
    if ".git" in root or "__pycache__" in root: continue
    for f in files:
        if f.startswith("test_") and f.endswith(".py"):
            test_files.append(os.path.join(root, f))
if not test_files:
    print("  No test files", file=sys.stderr); sys.exit(1)
# Count total tests across all files
total_tests = 0
for tf in test_files:
    with open(tf) as f: src = f.read()
    total_tests += len(re.findall(r'def\s+test_\w+', src))
if total_tests < 7:
    print(f"  Only {total_tests} tests across all files (need 7+)", file=sys.stderr); sys.exit(1)
# Check substantive tests and module coverage across ALL test files
refs = {'analysis','search','knowledge','mcp_server','expand_query','trace_node',
        'find_upstream','find_downstream','TASK_ALIASES','ComfyKnowledge',
        'search_nodes','find_path','expand_aliases','resolve_query','expand_terms','expand',
        '_fmt_upstream','_fmt_downstream','_fmt_path','_fmt_analyze',
        'analyze_workflow','get_workflow_info','find_orphans','find_subgraph'}
sub = 0; mods = set(); any_cli_imp = False
for tf in test_files:
    with open(tf) as f: tsrc = f.read()
    try: tree = ast.parse(tsrc)
    except Exception: continue
    for n in ast.walk(tree):
        if isinstance(n, ast.ImportFrom) and n.module and 'cli_tools' in n.module: any_cli_imp = True
        if isinstance(n, ast.Import):
            for a in n.names:
                if 'cli_tools' in a.name: any_cli_imp = True
    for n in ast.walk(tree):
        if isinstance(n, ast.FunctionDef) and n.name.startswith('test_'):
            bd = ast.dump(n)
            has_ref = any(r in bd for r in refs)
            stmts = [s for s in n.body if not isinstance(s, ast.Pass) and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))]
            has_assert = False
            for s in ast.walk(n):
                if isinstance(s, ast.Assert):
                    t = s.test
                    if isinstance(t, (ast.Compare, ast.Call, ast.BoolOp)): has_assert = True
                    elif isinstance(t, ast.UnaryOp) and isinstance(t.op, ast.Not): has_assert = True
                    elif isinstance(t, ast.Name): has_assert = True
                    if has_assert: break
            has_call = any(isinstance(s, ast.Call) for s in ast.walk(n))
            if has_ref and len(stmts) >= 2 and has_assert and has_call:
                sub += 1
                for r in refs:
                    if r in bd:
                        if r in ('analysis','find_upstream','find_downstream','find_path','trace_node',
                                 '_fmt_upstream','_fmt_downstream','_fmt_path','_fmt_analyze',
                                 'analyze_workflow','get_workflow_info','find_orphans','find_subgraph'): mods.add('analysis')
                        elif r in ('search','expand_query','TASK_ALIASES','expand_aliases','expand_terms'): mods.add('search')
                        elif r in ('knowledge','ComfyKnowledge','search_nodes'): mods.add('knowledge')
                        elif r == 'mcp_server': mods.add('mcp_server')
if not any_cli_imp:
    print("  No cli_tools import in any test file", file=sys.stderr); sys.exit(1)
if sub < 5:
    print(f"  Only {sub} substantive tests", file=sys.stderr); sys.exit(1)
if len(mods) < 2:
    print(f"  Covers {mods} (need >=2)", file=sys.stderr); sys.exit(1)
# Run pytest across all test directories
env = os.environ.copy(); env["PYTHONPATH"] = "."
test_dirs = list(set(os.path.dirname(tf) or "." for tf in test_files))
passed = 0; failed = 0
for td in test_dirs:
    res = subprocess.run(["python3","-m","pytest",td,"-v","--tb=short","-q"],
        capture_output=True, text=True, timeout=60, cwd="/workspace/VibeComfy", env=env)
    out = res.stdout + res.stderr
    pm = re.search(r'(\d+)\s+passed', out)
    fm = re.search(r'(\d+)\s+failed', out)
    if pm: passed += int(pm.group(1))
    if fm: failed += int(fm.group(1))
if passed < 6:
    print(f"  {passed} passed ({failed} failed), need >=6", file=sys.stderr); sys.exit(1)
if passed + failed > 0 and failed > passed:
    print(f"  More failures than passes", file=sys.stderr); sys.exit(1)
print(f"  OK: {passed} passed, {sub} substantive, {mods}")
PYEOF

# ===========================================================================
# Check 4b (0.02): Turn 3 -- tests MUST cover BOTH shared search AND analysis
# Turn 3 asked explicitly: "Create tests for the tool functions -- both the
# shared search module and the analysis wrappers". Check 4 only requires 3-of-4
# module categories, so an agent could skip 'search' (the shared module).
# This check enforces the specific two-module ask.
# ===========================================================================
echo ""
echo "=== Check 4b: Turn 3 search+analysis coverage (0.01) ==="
python3 << 'PYEOF' && { echo "PASS: Check 4b"; add_reward 0.01; } || echo "FAIL: Check 4b"
import os, ast, sys
test_files = []
for root, dirs, files in os.walk("."):
    if ".git" in root or "__pycache__" in root: continue
    for f in files:
        if f.startswith("test_") and f.endswith(".py"):
            test_files.append(os.path.join(root, f))
if not test_files:
    print("  No test files", file=sys.stderr); sys.exit(1)

search_refs = {'expand_query', 'expand_aliases', 'TASK_ALIASES',
               'expand_terms', 'resolve_query', 'resolve_aliases', 'expand_search',
               'get_search_terms'}
analysis_refs = {'find_upstream', 'find_downstream', 'find_path',
                 'trace_node', 'analyze_workflow', 'find_orphans', 'find_subgraph'}

search_ok = False
analysis_ok = False
for tf in test_files:
    try:
        with open(tf) as f: src = f.read()
        tree = ast.parse(src)
    except Exception:
        continue
    for n in ast.walk(tree):
        if not isinstance(n, ast.FunctionDef) or not n.name.startswith('test_'):
            continue
        bd = ast.dump(n)
        stmts = [s for s in n.body if not isinstance(s, ast.Pass)
                 and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))]
        if len(stmts) < 2: continue
        has_assert = any(isinstance(s, ast.Assert) for s in ast.walk(n))
        has_call = any(isinstance(s, ast.Call) for s in ast.walk(n))
        if not (has_assert and has_call): continue
        if any(r in bd for r in search_refs): search_ok = True
        if any(r in bd for r in analysis_refs): analysis_ok = True
if not search_ok:
    print("  No substantive test covers shared search module (Turn 3)", file=sys.stderr); sys.exit(1)
if not analysis_ok:
    print("  No substantive test covers analysis wrappers (Turn 3)", file=sys.stderr); sys.exit(1)
print("  OK: both search and analysis covered in tests")
PYEOF

# ===========================================================================
# Check 5 (0.03): TASK_ALIASES extracted -- STRUCTURAL
# ===========================================================================
echo ""
echo "=== Check 5: TASK_ALIASES extracted (0.03) ==="
python3 << 'PYEOF' && { echo "PASS: Check 5"; add_reward 0.03; } || echo "FAIL: Check 5"
import ast, sys, importlib, re
sys.path.insert(0, ".")
with open("cli_tools/registry/knowledge.py") as f: src = f.read()
tree = ast.parse(src)
for n in ast.walk(tree):
    if isinstance(n, ast.Assign):
        for t in n.targets:
            if isinstance(t, ast.Name) and t.id == 'TASK_ALIASES':
                if isinstance(n.value, ast.Dict) and len(n.value.keys) > 10:
                    print(f"  Still inline ({len(n.value.keys)} entries)", file=sys.stderr); sys.exit(1)
has_imp = False
for n in ast.walk(tree):
    if isinstance(n, ast.ImportFrom):
        for a in n.names:
            if a.name in ('TASK_ALIASES','expand_query','expand_aliases','resolve_query','expand_terms','*',
                          'search','shared','aliases','common','utils'): has_imp = True; break
        if n.module and any(k in n.module.lower() for k in ('search','shared','alias','common','utils')): has_imp = True
    if isinstance(n, ast.Import):
        for a in n.names:
            if any(k in a.name.lower() for k in ('search','shared','alias','common','utils')): has_imp = True; break
    if has_imp: break
if not has_imp:
    if re.search(r'(?:search|shared|aliases|common|utils)\s*\.\s*(?:TASK_ALIASES|expand_query)', src): has_imp = True
if not has_imp:
    print("  No shared import", file=sys.stderr); sys.exit(1)
try: importlib.import_module("cli_tools.registry.knowledge")
except Exception as e:
    print(f"  Import failed: {e}", file=sys.stderr); sys.exit(1)
print("  OK: extracted")
PYEOF

# ===========================================================================
# Check 6a (0.01): .mcp.json auto-discovery mechanism -- STRUCTURAL+BEHAVIORAL
# Verifies the file exists AND the declared command would actually launch the
# MCP server (auto-discovery mechanism works, not just a placeholder file).
# ===========================================================================
echo ""
echo "=== Check 6a: .mcp.json auto-discovery (0.01) ==="
python3 << 'PYEOF' && { echo "PASS: Check 6a"; add_reward 0.01; } || echo "FAIL: Check 6a"
import json, sys, os, importlib
# Claude Code auto-discovers project-root .mcp.json (exact filename)
if not os.path.exists(".mcp.json"):
    print("  .mcp.json not at project root (auto-discovery requires exact name)", file=sys.stderr); sys.exit(1)
with open(".mcp.json") as f:
    try: cfg = json.load(f)
    except Exception as e: print(f"  Invalid JSON: {e}", file=sys.stderr); sys.exit(1)
srv = cfg.get("mcpServers", cfg.get("servers", {}))
if not isinstance(srv, dict) or not srv:
    print("  No mcpServers entry (auto-discovery needs dict)", file=sys.stderr); sys.exit(1)
# Each entry must have a runnable command + args that point at the MCP server module
valid_entry = None
for name, s in srv.items():
    if not isinstance(s, dict): continue
    cmd = s.get("command", "")
    args = s.get("args", []) or []
    args_str = " ".join(str(a) for a in args)
    full = cmd + " " + args_str
    # Command must be a real launcher (python/uv/uvx/node, not empty or placeholder)
    if not cmd or not isinstance(cmd, str):
        continue
    launcher_ok = any(l in cmd.lower() for l in ("python", "uv", "node"))
    if not launcher_ok:
        continue
    # Args or command must reference the actual server module/file (not a stub string)
    refs_module = (
        "cli_tools.registry.mcp_server" in full or
        "cli_tools/registry/mcp_server" in full or
        "mcp_server.py" in full
    )
    if not refs_module:
        continue
    valid_entry = (name, s); break
if not valid_entry:
    print("  No server entry with runnable command referencing cli_tools.registry.mcp_server", file=sys.stderr); sys.exit(1)
# Verify the referenced mcp_server module is actually importable (mechanism works end-to-end)
sys.path.insert(0, ".")
try:
    importlib.import_module("cli_tools.registry.mcp_server")
except Exception as e:
    print(f"  Declared module not importable — auto-discovery would fail: {e}", file=sys.stderr); sys.exit(1)
print(f"  OK: .mcp.json auto-discovery wired ({valid_entry[0]})")
PYEOF

# ===========================================================================
# Check 6b (0.01): requirements.txt lists real MCP deps -- STRUCTURAL+BEHAVIORAL
# Verifies mcp appears as an actual pip requirement (not in a comment), and
# matches the package actually imported by mcp_server.py.
# ===========================================================================
echo ""
echo "=== Check 6b: requirements.txt MCP deps (0.01) ==="
python3 << 'PYEOF' && { echo "PASS: Check 6b"; add_reward 0.01; } || echo "FAIL: Check 6b"
import sys, os, re
if not os.path.exists("requirements.txt"):
    print("  Not found", file=sys.stderr); sys.exit(1)
with open("requirements.txt") as f:
    raw = f.read()
# Parse pip requirements: skip blank lines, comments, and strip inline comments
pkgs = []
for line in raw.splitlines():
    s = line.strip()
    if not s or s.startswith("#") or s.startswith("-"):
        continue
    # Strip inline comment
    s = s.split("#", 1)[0].strip()
    # Extract package name (before ==, >=, <=, [extras], ;markers, etc.)
    m = re.match(r"^([A-Za-z0-9_.\-]+)", s)
    if m:
        pkgs.append(m.group(1).lower())
if "mcp" not in pkgs:
    print(f"  'mcp' not listed as a pip requirement (found: {pkgs})", file=sys.stderr); sys.exit(1)
# Cross-check: mcp_server.py must actually import from mcp (dependency not unused/mismatched)
mcp_src_path = "cli_tools/registry/mcp_server.py"
if os.path.exists(mcp_src_path):
    with open(mcp_src_path) as f: src = f.read()
    imports_mcp = bool(re.search(r"^\s*(?:from\s+mcp(?:\.[\w.]+)?\s+import|import\s+mcp(?:\.[\w.]+)?)", src, re.M))
    if not imports_mcp:
        print("  mcp_server.py does not import 'mcp' — requirement doesn't match actual usage", file=sys.stderr); sys.exit(1)
print(f"  OK: mcp listed as requirement, matches mcp_server.py imports")
PYEOF

# ===========================================================================
# Check 7 (0.03): Skills reorganized -- STRUCTURAL
# ===========================================================================
echo ""
echo "=== Check 7: Skills (0.03) ==="
python3 << 'PYEOF' && { echo "PASS: Check 7"; add_reward 0.03; } || echo "FAIL: Check 7"
import os, sys, re
sd = ".claude/skills"
if not os.path.isdir(sd): print("  Not found", file=sys.stderr); sys.exit(1)
pkw = ['comfy','node','workflow','mcp','registry','analysis','tool','search']
valid = 0
for item in os.listdir(sd):
    path = os.path.join(sd, item); content = ""
    if os.path.isfile(path) and item.endswith(".md"):
        content = open(path).read().strip()
    elif os.path.isdir(path):
        for f in sorted(os.listdir(path), key=lambda x: (0 if 'skill' in x.lower() else 1, x)):
            fp = os.path.join(path, f)
            if os.path.isfile(fp) and f.endswith(".md"):
                c = open(fp).read().strip()
                if len(c) >= 100: content = c; break
    else: continue
    if len(content) < 200: continue
    lc = content.lower()
    if sum(1 for k in pkw if k in lc) < 2: continue
    if not re.search(r'\b(when|trigger|use this|use for|invoke|run this|start with|before|after|if you|recommended|should|must)\b', lc, re.I): continue
    if len([s.strip() for s in re.split(r'[.\n]', content) if len(s.strip()) > 20]) < 3: continue
    if not re.search(r'(?:\.py|\.json|mcp_server|knowledge|analysis|search_nodes|find_upstream|find_downstream|expand_query|TASK_ALIASES|comfy_search|comfy_spec|comfy_read|trace_node|workflow)', content): continue
    valid += 1
if valid < 3:
    print(f"  Only {valid} skills", file=sys.stderr); sys.exit(1)
print(f"  OK: {valid} skills")
PYEOF

# ===========================================================================
# Check 8 (0.02): Prescriptive descriptions -- STRUCTURAL
# ===========================================================================
echo ""
echo "=== Check 8: Descriptions (0.02) ==="
python3 << 'PYEOF' && { echo "PASS: Check 8"; add_reward 0.02; } || echo "FAIL: Check 8"
import ast, re, sys
with open("cli_tools/registry/mcp_server.py") as f: src = f.read()
tree = ast.parse(src)
descs = []
for n in ast.walk(tree):
    if isinstance(n, ast.Call):
        func = n.func
        if (isinstance(func, ast.Name) and func.id == 'Tool') or (isinstance(func, ast.Attribute) and func.attr == 'Tool'):
            for kw in n.keywords:
                if kw.arg == 'description' and isinstance(kw.value, ast.Constant): descs.append(kw.value.value)
                if kw.arg == 'description' and isinstance(kw.value, ast.JoinedStr):
                    descs.append(" ".join(v.value for v in kw.value.values if isinstance(v, ast.Constant)))
for n in ast.walk(tree):
    if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
        for dec in n.decorator_list:
            it = (isinstance(dec, ast.Call) and isinstance(dec.func, ast.Attribute) and dec.func.attr == 'tool') or \
                 (isinstance(dec, ast.Attribute) and dec.attr == 'tool')
            if it:
                ds = ast.get_docstring(n)
                if ds and len(ds) > 10: descs.append(ds)
                break
for n in ast.walk(tree):
    if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
        for dec in n.decorator_list:
            if isinstance(dec, ast.Call) and isinstance(dec.func, ast.Attribute) and dec.func.attr == 'tool':
                for kw in dec.keywords:
                    if kw.arg == 'description' and isinstance(kw.value, ast.Constant): descs.append(kw.value.value)
descs = list(dict.fromkeys(descs))
if len(descs) < 9: print(f"  Only {len(descs)}", file=sys.stderr); sys.exit(1)
pats = [r'\b(?:start|begin|first)\b', r'\b(?:use|run|call)\s+(?:this|after|before|when|for)\b',
        r'\b(?:after|before|once)\b', r'\b(?:when|if)\s+you\b', r'\b(?:recommended|prefer|best|ideal)\b',
        r'e\.g\.\s', r'\bfor example\b', r'\bsuch as\b']
presc = sum(1 for d in descs if any(re.search(p, d, re.I) for p in pats))
if presc < 8: print(f"  Only {presc}/{len(descs)} prescriptive", file=sys.stderr); sys.exit(1)
print(f"  OK: {presc}/{len(descs)}")
PYEOF

# ===========================================================================
# Check 9 (0.07): Analysis functions P2P -- BEHAVIORAL
# ===========================================================================
echo ""
echo "=== Check 9: Analysis P2P (0.07) ==="
python3 << 'PYEOF' && { echo "PASS: Check 9"; add_reward 0.07; } || echo "FAIL: Check 9"
import sys, json
sys.path.insert(0, ".")
import cli_tools.analysis as analysis
with open("workflows/workflow_fixed_node.json") as f: wf = json.load(f)
nodes = wf["nodes"]
nids = [n.get("id") for n in nodes if n.get("id") is not None]
fu = getattr(analysis, 'find_upstream', None)
if not fu: print("  find_upstream missing", file=sys.stderr); sys.exit(1)
r = fu(wf, nids[-1])
if not isinstance(r, dict) or 'nodes' not in r:
    print("  find_upstream invalid", file=sys.stderr); sys.exit(1)
fd = getattr(analysis, 'find_downstream', None)
if not fd: print("  find_downstream missing", file=sys.stderr); sys.exit(1)
r2 = fd(wf, nids[0])
if not isinstance(r2, dict):
    print("  find_downstream invalid", file=sys.stderr); sys.exit(1)
if len(nids) >= 5:
    a = fu(wf, nids[0]); b = fu(wf, nids[-1])
    if a.get('nodes') == b.get('nodes'):
        print("  Identical for different nodes", file=sys.stderr); sys.exit(1)
# Correctness: node 1047
ru = fu(wf, 1047); rd = fd(wf, 1047)
uc = len(ru.get('nodes',{})); dc = len(rd.get('nodes',{}))
if uc < 25: print(f"  upstream(1047)={uc}", file=sys.stderr); sys.exit(1)
if dc < 9: print(f"  downstream(1047)={dc}", file=sys.stderr); sys.exit(1)
fp = getattr(analysis, 'find_path', None)
if fp:
    try:
        p = fp(wf, 393, 1169)
        if p is not None:
            if not isinstance(p, list) or len(p) < 3:
                print("  find_path invalid", file=sys.stderr); sys.exit(1)
            if p[0] != 393 or p[-1] != 1169:
                print(f"  find_path wrong endpoints", file=sys.stderr); sys.exit(1)
    except Exception: pass
print(f"  OK: up={uc}, down={dc}, path works")
PYEOF

# ===========================================================================
# Check 10 (0.14): Knowledge integration -- BEHAVIORAL
# ===========================================================================
echo ""
echo "=== Check 10: Knowledge integration (0.14) ==="
python3 << 'PYEOF' && { echo "PASS: Check 10"; add_reward 0.14; } || echo "FAIL: Check 10"
import sys, importlib, json, ast, re
sys.path.insert(0, ".")
with open("cli_tools/registry/knowledge.py") as f: ks = f.read()
kt = ast.parse(ks)
for n in ast.walk(kt):
    if isinstance(n, ast.Assign):
        for t in n.targets:
            if isinstance(t, ast.Name) and t.id == 'TASK_ALIASES':
                if isinstance(n.value, ast.Dict) and len(n.value.keys) > 10:
                    print("  Still inline", file=sys.stderr); sys.exit(1)
hi = False
for n in ast.walk(kt):
    if isinstance(n, ast.ImportFrom):
        for a in n.names:
            if a.name in ('TASK_ALIASES','expand_query','expand_aliases','resolve_query','expand_terms','*',
                          'search','shared','aliases','common','utils'): hi = True; break
        if n.module and any(k in (n.module or '').lower() for k in ('search','shared','alias','common','utils')): hi = True
    if isinstance(n, ast.Import):
        for a in n.names:
            if any(k in a.name.lower() for k in ('search','shared','alias')): hi = True; break
    if hi: break
if not hi:
    if re.search(r'(?:search|shared|aliases|common|utils)\s*\.\s*(?:TASK_ALIASES|expand_query)', ks): hi = True
if not hi: print("  No shared import", file=sys.stderr); sys.exit(1)
try: km = importlib.import_module("cli_tools.registry.knowledge")
except Exception as e: print(f"  Import fail: {e}", file=sys.stderr); sys.exit(1)
CK = getattr(km, 'ComfyKnowledge', None)
if not CK: print("  No ComfyKnowledge", file=sys.stderr); sys.exit(1)
try: ck = CK()
except Exception as e: print(f"  Init fail: {e}", file=sys.stderr); sys.exit(1)
for lm in ['load_nodes','_load_cache','load','init']:
    fn = getattr(ck, lm, None)
    if fn and callable(fn):
        try: fn(); break
        except: pass
sf = getattr(ck, 'search_nodes', None)
if not sf: print("  No search_nodes", file=sys.stderr); sys.exit(1)
try: r = sf("upscale", limit=5)
except Exception as e: print(f"  search fail: {e}", file=sys.stderr); sys.exit(1)
if not isinstance(r, list) or len(r) == 0: print("  Empty results", file=sys.stderr); sys.exit(1)
try: cr = sf("controlnet", limit=20)
except Exception as e: print(f"  controlnet fail: {e}", file=sys.stderr); sys.exit(1)
if len(cr) < 3: print(f"  controlnet only {len(cr)}", file=sys.stderr); sys.exit(1)
ta = getattr(ck, 'TASK_ALIASES', None) or getattr(km, 'TASK_ALIASES', None)
if not ta or not isinstance(ta, dict) or len(ta) < 20: print("  No TASK_ALIASES", file=sys.stderr); sys.exit(1)
try:
    r1 = sf("upscale", limit=5); r2 = sf("audio reactive", limit=5)
    if r1 == r2: print("  Identical results", file=sys.stderr); sys.exit(1)
except: pass
aw = False
for ak, ex in [("lora",["lycoris","loha"]),("upscale",["esrgan","4x"]),("face",["insightface","reactor"]),("controlnet",["canny","depth"])]:
    try:
        ar = sf(ak, limit=20); rt = " ".join(str(x) for x in ar).lower()
        if any(e in rt for e in ex): aw = True; break
    except: pass
if not aw: print("  No expansion", file=sys.stderr); sys.exit(1)
uw = False
try:
    lr = sf("ltx", limit=20); lt = " ".join(str(x) for x in lr).lower()
    if any(t in lt for t in ["lightricks","ltxvideo","ltxv"]): uw = True
except: pass
if not uw:
    try:
        br = sf("beat detection", limit=20); bt = " ".join(str(x) for x in br).lower()
        if any(t in bt for t in ["bpm","onset","drum"]): uw = True
    except: pass
if not uw: print("  Uncommon aliases fail", file=sys.stderr); sys.exit(1)
print("  OK: knowledge integrated, expansion works")
PYEOF

# ===========================================================================
# Check 11-i (0.07): Cross-module basic -- BEHAVIORAL
# ===========================================================================
echo ""
echo "=== Check 11-i: Cross-module basic (0.07) ==="
python3 << 'PYEOF' && { echo "PASS: Check 11-i"; add_reward 0.07; } || echo "FAIL: Check 11-i"
import sys, importlib, glob, importlib.util
sys.path.insert(0, ".")
sm = None
for mp in ["cli_tools.search","cli_tools.registry.search","cli_tools.shared",
           "cli_tools.registry.shared","cli_tools.aliases","cli_tools.registry.aliases"]:
    try:
        m = importlib.import_module(mp)
        if hasattr(m,'TASK_ALIASES') and hasattr(m,'__file__') and 'knowledge' not in (m.__file__ or ''):
            sm = m; break
    except: pass
if not sm:
    for pf in glob.glob("cli_tools/**/*.py", recursive=True):
        if 'knowledge' in pf: continue
        mn = pf.replace("/",".").replace(".py","")
        try:
            spec = importlib.util.spec_from_file_location(mn, pf)
            m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
            if hasattr(m,'TASK_ALIASES'): sm = m; break
        except: pass
if not sm: print("  Not found", file=sys.stderr); sys.exit(1)
al = sm.TASK_ALIASES
if not isinstance(al, dict) or len(al) < 28: print("  Too small", file=sys.stderr); sys.exit(1)
if hasattr(sm,'ComfyKnowledge'): print("  Has ComfyKnowledge", file=sys.stderr); sys.exit(1)
ef = None
for n in ['expand_query','expand_aliases','resolve_query','get_search_terms','expand_terms','resolve_aliases','expand_search','expand']:
    fn = getattr(sm, n, None)
    if fn and callable(fn): ef = fn; break
if not ef: print("  No expand fn", file=sys.stderr); sys.exit(1)
rl = 0
for k in list(al.keys())[:5]:
    try:
        r = ef(k)
        if isinstance(r, (list, tuple, set)): rl += 1
    except: pass
if rl < 3: print(f"  Returns list {rl}/5", file=sys.stderr); sys.exit(1)
print(f"  OK: {len(al)} aliases, structured")
PYEOF

# ===========================================================================
# Check 11-ii (0.09): Cross-module alias correctness -- BEHAVIORAL
# ===========================================================================
echo ""
echo "=== Check 11-ii: Alias correctness (0.09) ==="
python3 << 'PYEOF' && { echo "PASS: Check 11-ii"; add_reward 0.09; } || echo "FAIL: Check 11-ii"
import sys, importlib, glob, importlib.util
sys.path.insert(0, ".")
sm = None
for mp in ["cli_tools.search","cli_tools.registry.search","cli_tools.shared",
           "cli_tools.registry.shared","cli_tools.aliases","cli_tools.registry.aliases"]:
    try:
        m = importlib.import_module(mp)
        if hasattr(m,'TASK_ALIASES') and hasattr(m,'__file__') and 'knowledge' not in (m.__file__ or ''):
            sm = m; break
    except: pass
if not sm:
    for pf in glob.glob("cli_tools/**/*.py", recursive=True):
        if 'knowledge' in pf: continue
        mn = pf.replace("/",".").replace(".py","")
        try:
            spec = importlib.util.spec_from_file_location(mn, pf)
            m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
            if hasattr(m,'TASK_ALIASES'): sm = m; break
        except: pass
if not sm: print("  Not found", file=sys.stderr); sys.exit(1)
al = sm.TASK_ALIASES
ef = None
for n in ['expand_query','expand_aliases','resolve_query','get_search_terms','expand_terms','resolve_aliases','expand_search','expand']:
    fn = getattr(sm, n, None)
    if fn and callable(fn): ef = fn; break
if not ef: print("  No expand fn", file=sys.stderr); sys.exit(1)
em = {"upscale":{"upscale","esrgan","4x"},"controlnet":{"controlnet","canny","depth"},
      "animatediff":{"animatediff","animate","motion"},"inpaint":{"inpaint","mask"},
      "lora":{"lora","lycoris"},"face":{"face","insightface","reactor"},
      "segmentation":{"segment","sam","mask"},"flux":{"flux","schnell"},
      "audio reactive":{"audio reactive","amplitude","rms"},"ltx":{"ltx","lightricks","ltxvideo"}}
ver = 0; rl = 0
for ak, et in em.items():
    if ak not in al: continue
    try:
        r = ef(ak)
        if r is None: continue
        if isinstance(r, (list, tuple, set)): rl += 1
        if isinstance(r, str): rt = set(r.lower().split())
        elif isinstance(r, (list, tuple, set)):
            rt = set()
            for x in r: rt.update(str(x).lower().split())
        else: continue
        if sum(1 for e in et if any(e in t for t in rt)) >= 2: ver += 1
    except: pass
if rl < 6: print(f"  List {rl}/10", file=sys.stderr); sys.exit(1)
if ver < 9: print(f"  Verified {ver}/10", file=sys.stderr); sys.exit(1)
# Long alias completeness: ltx
if "ltx" in al:
    try:
        lr = ef("ltx")
        if isinstance(lr, (list, tuple, set)):
            lt = set()
            for x in lr: lt.update(str(x).lower().split())
            ex = {"ltx","lightricks","ltxvideo","ltxv","stg","gemma"}
            mc = sum(1 for e in ex if any(e in t for t in lt))
            if mc < 4: print(f"  ltx incomplete {mc}/6", file=sys.stderr); sys.exit(1)
    except Exception as e: print(f"  ltx fail: {e}", file=sys.stderr); sys.exit(1)
# deforum
if "deforum" in al:
    try:
        dr = ef("deforum")
        if isinstance(dr, (list, tuple, set)):
            dt = set()
            for x in dr: dt.update(str(x).lower().split())
            ex = {"deforum","klein","motion","warp"}
            mc = sum(1 for e in ex if any(e in t for t in dt))
            if mc < 3: print(f"  deforum incomplete {mc}/4", file=sys.stderr); sys.exit(1)
    except: pass
# Knowledge consistency
try:
    km = importlib.import_module("cli_tools.registry.knowledge")
    CK = getattr(km,'ComfyKnowledge',None)
    if CK:
        ck = CK()
        kta = getattr(ck,'TASK_ALIASES',None) or getattr(km,'TASK_ALIASES',None)
        if kta and isinstance(kta, dict):
            sk = set(al.keys()); kk = set(kta.keys())
            ov = len(sk & kk); mn = min(len(sk), len(kk))
            if mn > 0 and ov < mn * 0.95:
                print(f"  Mismatch {ov}/{mn}", file=sys.stderr); sys.exit(1)
except: pass
print(f"  OK: {ver} verified, long aliases OK")
PYEOF

# ===========================================================================
# Check 11-iii (0.08): Cross-module e2e chain -- BEHAVIORAL
# ===========================================================================
echo ""
echo "=== Check 11-iii: E2E chain (0.08) ==="
python3 << 'PYEOF' && { echo "PASS: Check 11-iii"; add_reward 0.08; } || echo "FAIL: Check 11-iii"
import sys, importlib, json, ast, re
sys.path.insert(0, ".")
try: mm = importlib.import_module("cli_tools.registry.mcp_server")
except Exception as e: print(f"  Import fail: {e}", file=sys.stderr); sys.exit(1)
ms = open(mm.__file__).read()
ac = sum(1 for fn in ['find_upstream','find_downstream','find_path'] if fn+'(' in ms)
if ac < 2: print(f"  Only {ac} analysis calls", file=sys.stderr); sys.exit(1)
mt = ast.parse(ms)
mi = False
for n in ast.walk(mt):
    if isinstance(n, ast.ImportFrom):
        if n.module and any(k in (n.module or '').lower() for k in ('search','shared','alias','common')): mi = True; break
        for a in n.names:
            if a.name in ('TASK_ALIASES','expand_query','expand_aliases','resolve_query','expand_terms'): mi = True; break
    if isinstance(n, ast.Import):
        for a in n.names:
            if any(k in a.name.lower() for k in ('search','shared','alias')): mi = True; break
    if mi: break
if not mi:
    if re.search(r'(?:search|shared|aliases)\s*\.\s*(?:TASK_ALIASES|expand_query)', ms): mi = True
    if re.search(r'(?:from|import)\s+\S*knowledge', ms): mi = True
if not mi: print("  No shared/knowledge import", file=sys.stderr); sys.exit(1)
try:
    km = importlib.import_module("cli_tools.registry.knowledge")
    CK = getattr(km,'ComfyKnowledge',None)
    if not CK: print("  No ComfyKnowledge", file=sys.stderr); sys.exit(1)
    ck = CK()
    for lm in ['load_nodes','_load_cache','load','init']:
        fn = getattr(ck, lm, None)
        if fn and callable(fn):
            try: fn(); break
            except: pass
    sf = getattr(ck,'search_nodes',None)
    if not sf: print("  No search_nodes", file=sys.stderr); sys.exit(1)
    r = sf("upscale", limit=10)
    if not isinstance(r, list) or len(r) < 1: print("  No results", file=sys.stderr); sys.exit(1)
    rt = " ".join(str(x) for x in r).lower()
    if not any(k in rt for k in ['upscale','esrgan','super resolution','4x','resize']):
        print("  No upscale content", file=sys.stderr); sys.exit(1)
    fr = sf("fft", limit=10)
    if isinstance(fr, list) and len(fr) > 0:
        ft = " ".join(str(x) for x in fr).lower()
        if not any(k in ft for k in ['frequency','spectral','spectrum','fft','audio']):
            print("  No fft content", file=sys.stderr); sys.exit(1)
except Exception as e: print(f"  E2E fail: {e}", file=sys.stderr); sys.exit(1)
import cli_tools.analysis as analysis
try:
    with open("workflows/workflow_fixed_node.json") as f: wf = json.load(f)
    r = analysis.find_upstream(wf, 1047)
    if not isinstance(r, dict) or len(r.get('nodes',{})) < 20:
        print("  Analysis degraded", file=sys.stderr); sys.exit(1)
except Exception as e: print(f"  Analysis fail: {e}", file=sys.stderr); sys.exit(1)
print("  OK: e2e works, analysis intact")
PYEOF

# ===========================================================================
# Check 12 (0.06): Edge case handling -- BEHAVIORAL
# ===========================================================================
echo ""
echo "=== Check 12: Edge cases (0.05) ==="
python3 << 'PYEOF' && { echo "PASS: Check 12"; add_reward 0.05; } || echo "FAIL: Check 12"
import sys, importlib, json, glob, importlib.util
sys.path.insert(0, ".")
ok = 0; total = 5
sm = None
for mp in ["cli_tools.search","cli_tools.registry.search","cli_tools.shared",
           "cli_tools.registry.shared","cli_tools.aliases","cli_tools.registry.aliases"]:
    try:
        m = importlib.import_module(mp)
        if hasattr(m,'TASK_ALIASES') and hasattr(m,'__file__') and 'knowledge' not in (m.__file__ or ''):
            sm = m; break
    except: pass
if not sm: print("  Not found", file=sys.stderr); sys.exit(1)
ef = None
for n in ['expand_query','expand_aliases','resolve_query','get_search_terms','expand_terms','resolve_aliases','expand_search','expand']:
    fn = getattr(sm, n, None)
    if fn and callable(fn): ef = fn; break
if not ef: print("  No expand fn", file=sys.stderr); sys.exit(1)
# Edge 1: unknown input
try: ef("xyznonexistent_12345"); ok += 1
except: print("  Edge1: crash on unknown", file=sys.stderr)
# Edge 2: empty string
try: ef(""); ok += 1
except: print("  Edge2: crash on empty", file=sys.stderr)
# Edge 3: search_nodes empty
try:
    km = importlib.import_module("cli_tools.registry.knowledge")
    CK = getattr(km,'ComfyKnowledge',None)
    if CK:
        ck = CK()
        for lm in ['load_nodes','_load_cache','load','init']:
            fn = getattr(ck, lm, None)
            if fn and callable(fn):
                try: fn(); break
                except: pass
        sf = getattr(ck,'search_nodes',None)
        if sf:
            try: sf("", limit=5); ok += 1
            except: ok += 1
    else: ok += 1
except: ok += 1
# Edge 4: invalid node ID
try:
    import cli_tools.analysis as analysis
    with open("workflows/workflow_fixed_node.json") as f: wf = json.load(f)
    r = analysis.find_upstream(wf, 99999)
    if isinstance(r, dict): ok += 1
    else: print(f"  Edge4: {type(r).__name__}", file=sys.stderr)
except: ok += 1
# Edge 5: different aliases != same result
try:
    if "video" in sm.TASK_ALIASES and "animatediff" in sm.TASK_ALIASES:
        vr = ef("video"); ar = ef("animatediff")
        if isinstance(vr,(list,tuple,set)) and isinstance(ar,(list,tuple,set)):
            if set(str(x).lower() for x in vr) != set(str(x).lower() for x in ar): ok += 1
            else: print("  Edge5: video==animatediff", file=sys.stderr)
        else: ok += 1
    else: ok += 1
except: print("  Edge5 fail", file=sys.stderr)
if ok < 4: print(f"  {ok}/{total} passed", file=sys.stderr); sys.exit(1)
print(f"  OK: {ok}/{total} edge cases")
PYEOF

# ===========================================================================
# Write final reward
# ===========================================================================
echo ""
echo "================================"
echo "Final reward: $REWARD"
echo "================================"
echo "$REWARD" > "$LOG_DIR/reward.txt"
