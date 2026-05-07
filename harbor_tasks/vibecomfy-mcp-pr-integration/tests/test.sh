#!/bin/bash
set +e

REWARD=0.0
WORKSPACE="/workspace/VibeComfy"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

add_reward() {
    REWARD=$(awk -v r="$REWARD" -v a="$1" 'BEGIN{s=r+a; if(s>1.0)s=1.0; printf "%.4f", s}')
}

cd "$WORKSPACE" 2>/dev/null || { echo "0.0" > "$LOG_DIR/reward.txt"; exit 0; }

export PYTHONPATH="$WORKSPACE:$PYTHONPATH"

# ============================================================================
# P2P-1 (0.08): Core imports still work
# ============================================================================
echo "=== P2P-1: Core imports (0.08) ==="
python3 - << 'PYEOF'
import sys
sys.path.insert(0, ".")
errors = []
for mod in ["cli_tools.analysis", "cli_tools.registry.knowledge",
            "cli_tools.registry.mcp_server", "cli_tools.descriptions"]:
    try:
        __import__(mod)
    except Exception as e:
        errors.append(f"{mod}: {e}")
if errors:
    for e in errors: print(f"  {e}", file=sys.stderr)
    sys.exit(1)
print("  OK")
PYEOF
[ $? -eq 0 ] && { echo "PASS"; add_reward 0.08; } || echo "FAIL"

# ============================================================================
# P2P-2 (0.07): ComfyKnowledge instantiates and search_nodes works
# ============================================================================
echo ""
echo "=== P2P-2: ComfyKnowledge.search_nodes still works (0.07) ==="
python3 - << 'PYEOF'
import sys, json, os, tempfile
sys.path.insert(0, ".")
from cli_tools.registry.knowledge import ComfyKnowledge

# Build a minimal cache so the class can load
fake_cache = {
    "nodes": {
        "ESRGAN_Upscale": {"name": "ESRGAN_Upscale", "category": "upscale",
                           "description": "4x super resolution upscaler",
                           "inputs": {}, "outputs": []},
        "KSampler": {"name": "KSampler", "category": "sampling",
                     "description": "Sample latent", "inputs": {}, "outputs": []},
        "WANVideoSampler": {"name": "WANVideoSampler", "category": "video",
                            "description": "wan video sampler", "inputs": {}, "outputs": []},
    },
    "packs": {}
}

# Try to use real cache, else inject one
import cli_tools.registry.knowledge as km
real_cache = km.CACHE_FILE
tmp = None
try:
    if not real_cache.exists():
        tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False)
        json.dump(fake_cache, tmp)
        tmp.close()
        kb = ComfyKnowledge(cache_path=tmp.name)
    else:
        kb = ComfyKnowledge()
    # Run a search — must return without crashing
    res = kb.search_nodes("upscale", limit=5)
    assert res is not None, "search_nodes returned None"
    print(f"  OK (got {len(res) if hasattr(res,'__len__') else '?'} results)")
except Exception as e:
    print(f"  FAIL: {e}", file=sys.stderr)
    sys.exit(1)
finally:
    if tmp:
        os.unlink(tmp.name)
PYEOF
[ $? -eq 0 ] && { echo "PASS"; add_reward 0.07; } || echo "FAIL"

# ============================================================================
# F2P-1 (0.10): Shared alias module exists outside knowledge.py and is used
# ============================================================================
echo ""
echo "=== F2P-1: Shared alias module discovered & imported by knowledge.py (0.10) ==="
SHARED_MOD=""
SHARED_PATH=""
python3 - << 'PYEOF' > /tmp/shared_mod.txt
import sys, importlib, glob, importlib.util, os
sys.path.insert(0, ".")
candidates = ["cli_tools.search", "cli_tools.registry.search",
              "cli_tools.aliases", "cli_tools.registry.aliases",
              "cli_tools.task_aliases", "cli_tools.registry.task_aliases",
              "cli_tools.shared", "cli_tools.common"]
found = None
for mp in candidates:
    try:
        m = importlib.import_module(mp)
        if hasattr(m, 'TASK_ALIASES') and 'knowledge' not in (m.__file__ or ''):
            found = (mp, m.__file__); break
    except Exception:
        pass
if not found:
    for pyfile in glob.glob("cli_tools/**/*.py", recursive=True):
        if 'knowledge' in pyfile or '__init__' in pyfile: continue
        try:
            spec = importlib.util.spec_from_file_location("_probe", pyfile)
            m = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(m)
            if hasattr(m, 'TASK_ALIASES') and isinstance(m.TASK_ALIASES, dict) and len(m.TASK_ALIASES) >= 20:
                rel = pyfile.replace("/", ".").replace(".py","").lstrip(".")
                found = (rel, pyfile); break
        except Exception:
            continue
if found:
    print(found[0])
    print(found[1])
PYEOF
SHARED_MOD=$(sed -n '1p' /tmp/shared_mod.txt)
SHARED_PATH=$(sed -n '2p' /tmp/shared_mod.txt)

if [ -n "$SHARED_MOD" ] && [ -n "$SHARED_PATH" ]; then
    python3 - << PYEOF
import sys
sys.path.insert(0, ".")
import importlib
m = importlib.import_module("$SHARED_MOD")
aliases = m.TASK_ALIASES
assert isinstance(aliases, dict), "TASK_ALIASES must be a dict"
assert len(aliases) >= 25, f"Only {len(aliases)} aliases (need 25+)"
# Module must be focused, not a copy of ComfyKnowledge
with open("$SHARED_PATH") as f:
    src = f.read()
assert 'class ComfyKnowledge' not in src, "Shared module contains ComfyKnowledge class"
assert len(src.splitlines()) <= 250, f"Shared module too large: {len(src.splitlines())} lines"

# knowledge.py must import from shared module
with open("cli_tools/registry/knowledge.py") as f:
    ksrc = f.read()
import re
shared_short = "$SHARED_MOD".split(".")[-1]
if not re.search(rf'(from\s+\S*{shared_short}\s+import|import\s+\S*{shared_short})', ksrc):
    print(f"  knowledge.py doesn't import from {shared_short}", file=sys.stderr); sys.exit(1)

# Count remaining inline alias entries in knowledge.py — should be drastically reduced
inline = len(re.findall(r'^\s+"[a-z][a-z0-9 _/-]*":\s*\[', ksrc, re.MULTILINE))
assert inline <= 8, f"knowledge.py still has {inline} inline alias entries (expected <=8)"
print(f"  OK: {len(aliases)} aliases in $SHARED_MOD, knowledge.py inline entries={inline}")
PYEOF
    [ $? -eq 0 ] && { echo "PASS"; add_reward 0.10; } || echo "FAIL"
else
    echo "FAIL: no shared alias module found"
fi

# ============================================================================
# F2P-2 (0.12): expand_query function — behavioral test
# ============================================================================
echo ""
echo "=== F2P-2: expand_query behavior (0.12) ==="
if [ -n "$SHARED_MOD" ]; then
    python3 - << PYEOF
import sys
sys.path.insert(0, ".")
import importlib
m = importlib.import_module("$SHARED_MOD")
expand = None
for name in ['expand_query','expand_aliases','resolve_query','expand_terms',
             'resolve_aliases','expand_search','expand','get_search_terms']:
    fn = getattr(m, name, None)
    if callable(fn):
        expand = fn; break
if not expand:
    print("  No expand function", file=sys.stderr); sys.exit(1)

def to_set(r):
    if r is None: return None
    if isinstance(r, set): return r
    return set(r)

score = 0
total = 6

# 1) Original query word preserved
r = to_set(expand("custom_unique_word_xyz"))
if r and "custom_unique_word_xyz" in r:
    score += 1
else:
    print("  T1 FAIL: original word not preserved", file=sys.stderr)

# 2) Known alias key expands to its synonym list
upscale_key = next((k for k in m.TASK_ALIASES if 'upscale' in k.lower()), None)
if upscale_key:
    r = to_set(expand(upscale_key))
    expected = set(m.TASK_ALIASES[upscale_key])
    overlap = expected & r if r else set()
    if len(overlap) >= max(1, len(expected)//2):
        score += 1
    else:
        print(f"  T2 FAIL: upscale expansion lacks aliases ({overlap})", file=sys.stderr)
else:
    score += 1

# 3) Different keys → different results
keys = list(m.TASK_ALIASES.keys())
if len(keys) >= 3:
    r1 = to_set(expand(keys[0])); r2 = to_set(expand(keys[2]))
    if r1 != r2 and r1 and r2:
        score += 1
    else:
        print("  T3 FAIL: same expansion for distinct keys", file=sys.stderr)
else:
    score += 1

# 4) Doesn't crash on empty / unknown
try:
    expand("")
    expand("zzzz_nothing_matches_anywhere")
    score += 1
except Exception as e:
    print(f"  T4 FAIL: crashes on edge: {e}", file=sys.stderr)

# 5) Alias-value match in free text triggers expansion
# Pick an alias whose value list contains a distinctive single word
trigger = None
for k, vals in m.TASK_ALIASES.items():
    for v in vals:
        if isinstance(v, str) and ' ' not in v and len(v) >= 4 and v.isalpha():
            trigger = (k, v); break
    if trigger: break
if trigger:
    k, v = trigger
    r = to_set(expand(v))
    if r and len(r) >= 2:
        score += 1
    else:
        print(f"  T5 FAIL: trigger word '{v}' didn't expand", file=sys.stderr)
else:
    score += 1

# 6) ComfyKnowledge.search_nodes uses the shared expansion
# We test by checking that an alias keyword expands search results
import json, tempfile, os
from cli_tools.registry.knowledge import ComfyKnowledge
fake_cache = {
    "nodes": {
        "ESRGAN_4x": {"name":"ESRGAN_4x","category":"upscale",
                      "description":"esrgan upscaler","inputs":{},"outputs":[]},
        "RealESRGAN": {"name":"RealESRGAN","category":"upscale",
                       "description":"realesrgan model","inputs":{},"outputs":[]},
        "Useless": {"name":"Useless","category":"misc",
                    "description":"nothing","inputs":{},"outputs":[]},
    },
    "packs": {}
}
tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False)
json.dump(fake_cache, tmp); tmp.close()
try:
    kb = ComfyKnowledge(cache_path=tmp.name)
    # Searching for "upscale" should now (via expansion) find ESRGAN/RealESRGAN
    res = kb.search_nodes("upscale", limit=10)
    names = []
    if res:
        for r in res:
            if isinstance(r, dict): names.append(r.get('name',''))
            elif isinstance(r, str): names.append(r)
            else: names.append(str(r))
    joined = " ".join(names).lower()
    if 'esrgan' in joined or 'realesrgan' in joined:
        score += 1
    else:
        print(f"  T6 FAIL: search('upscale') didn't expand to esrgan: {names}", file=sys.stderr)
finally:
    os.unlink(tmp.name)

print(f"  Score: {score}/{total}")
sys.exit(0 if score >= 4 else 1)
# Partial credit handled by exit codes 0/1; finer split below
PYEOF
    rc=$?
    if [ $rc -eq 0 ]; then
        # Run again to read score for partial credit
        python3 - << PYEOF > /tmp/eq_score.txt 2>/dev/null
import sys
sys.path.insert(0, ".")
import importlib, json, tempfile, os
m = importlib.import_module("$SHARED_MOD")
expand = None
for name in ['expand_query','expand_aliases','resolve_query','expand_terms','resolve_aliases','expand_search','expand','get_search_terms']:
    fn = getattr(m, name, None)
    if callable(fn): expand = fn; break
def to_set(r):
    if r is None: return None
    return set(r) if not isinstance(r, set) else r
score = 0
try:
    r = to_set(expand("custom_unique_word_xyz"))
    if r and "custom_unique_word_xyz" in r: score += 1
except: pass
try:
    uk = next((k for k in m.TASK_ALIASES if 'upscale' in k.lower()), None)
    if uk:
        r = to_set(expand(uk)); expected = set(m.TASK_ALIASES[uk])
        if r and len(expected & r) >= max(1, len(expected)//2): score += 1
except: pass
try:
    keys = list(m.TASK_ALIASES.keys())
    r1 = to_set(expand(keys[0])); r2 = to_set(expand(keys[2]))
    if r1 != r2 and r1 and r2: score += 1
except: pass
try:
    expand(""); expand("zzzz_unknown"); score += 1
except: pass
trigger = None
for k, vals in m.TASK_ALIASES.items():
    for v in vals:
        if isinstance(v,str) and ' ' not in v and len(v)>=4 and v.isalpha():
            trigger = v; break
    if trigger: break
try:
    if trigger:
        r = to_set(expand(trigger))
        if r and len(r) >= 2: score += 1
except: pass
try:
    from cli_tools.registry.knowledge import ComfyKnowledge
    fc = {"nodes":{
        "ESRGAN_4x":{"name":"ESRGAN_4x","category":"upscale","description":"esrgan upscaler","inputs":{},"outputs":[]},
        "RealESRGAN":{"name":"RealESRGAN","category":"upscale","description":"realesrgan","inputs":{},"outputs":[]},
        "Useless":{"name":"Useless","category":"misc","description":"x","inputs":{},"outputs":[]}},
        "packs":{}}
    tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False)
    json.dump(fc, tmp); tmp.close()
    kb = ComfyKnowledge(cache_path=tmp.name)
    res = kb.search_nodes("upscale", limit=10)
    names = []
    if res:
        for r in res:
            if isinstance(r, dict): names.append(r.get('name',''))
            else: names.append(str(r))
    j = " ".join(names).lower()
    if 'esrgan' in j: score += 1
    os.unlink(tmp.name)
except: pass
print(score)
PYEOF
        SC=$(cat /tmp/eq_score.txt 2>/dev/null | tr -d '[:space:]')
        SC=${SC:-0}
        WT=$(awk -v s="$SC" 'BEGIN{printf "%.4f", (s/6.0)*0.12}')
        add_reward "$WT"
        echo "PASS partial: $SC/6 → +$WT"
    else
        # Even if assertion failed, give partial via re-run
        python3 - << PYEOF > /tmp/eq_score.txt 2>/dev/null
import sys
sys.path.insert(0, ".")
import importlib
try:
    m = importlib.import_module("$SHARED_MOD")
    expand = None
    for name in ['expand_query','expand_aliases','resolve_query','expand_terms','resolve_aliases','expand_search','expand','get_search_terms']:
        fn = getattr(m, name, None)
        if callable(fn): expand = fn; break
    def to_set(r): return set(r) if r and not isinstance(r,set) else (r or set())
    score = 0
    try:
        r = to_set(expand("custom_unique_word_xyz"))
        if "custom_unique_word_xyz" in r: score += 1
    except: pass
    try:
        expand(""); expand("zzz"); score += 1
    except: pass
    print(score)
except:
    print(0)
PYEOF
        SC=$(cat /tmp/eq_score.txt 2>/dev/null | tr -d '[:space:]')
        SC=${SC:-0}
        WT=$(awk -v s="$SC" 'BEGIN{printf "%.4f", (s/6.0)*0.12}')
        add_reward "$WT"
        echo "FAIL but partial: $SC/6 → +$WT"
    fi
else
    echo "FAIL: no shared module"
fi

# ============================================================================
# F2P-3 (0.18): MCP tools wrap analysis.py (signal flow / upstream / downstream)
# ============================================================================
echo ""
echo "=== F2P-3: MCP server exposes analysis capabilities (0.18) ==="
python3 - << 'PYEOF' > /tmp/mcp_score.txt
import sys, re
sys.path.insert(0, ".")
score = 0
total = 6

with open("cli_tools/registry/mcp_server.py") as f:
    msrc = f.read()

# 1) imports analysis module functions
if re.search(r'from\s+cli_tools(\.|\s+import\s+)analysis|from\s+\.\.analysis|from\s+\.\.\s+import\s+analysis', msrc) or \
   re.search(r'import\s+cli_tools\.analysis', msrc) or \
   'analysis' in msrc and ('analyze_workflow' in msrc or 'find_upstream' in msrc or 'find_downstream' in msrc):
    score += 1
else:
    print("  T1 FAIL: mcp_server doesn't import analysis", file=sys.stderr)

# 2) References at least 2 of: analyze_workflow, find_upstream, find_downstream, find_path, find_subgraph
analysis_fns = ['analyze_workflow','find_upstream','find_downstream','find_path','find_subgraph']
hits = sum(1 for fn in analysis_fns if fn in msrc)
if hits >= 2:
    score += 1
else:
    print(f"  T2 FAIL: only {hits} analysis fns referenced", file=sys.stderr)

# 3) Adds new MCP tool names beyond original 7 (search/spec/list_packs/stats/author/category/read)
original = {'comfy_search','comfy_spec','comfy_packs','comfy_pack','comfy_stats','comfy_author','comfy_category','comfy_read','comfy_list'}
tool_names = set(re.findall(r'name="(comfy_[a-z_]+)"', msrc))
if not tool_names:
    tool_names = set(re.findall(r"name='(comfy_[a-z_]+)'", msrc))
new_tools = tool_names - original
if len(new_tools) >= 2:
    score += 1
else:
    print(f"  T3 FAIL: only {len(new_tools)} new tools: {new_tools}", file=sys.stderr)

# 4) Has analysis-flavored tools (upstream/downstream/path/analyze/flow)
analysis_keywords = ['upstream','downstream','path','analyze','flow','subgraph','trace']
analysis_tools = [t for t in tool_names if any(k in t for k in analysis_keywords)]
if len(analysis_tools) >= 2:
    score += 1
else:
    print(f"  T4 FAIL: not enough analysis tools: {analysis_tools}", file=sys.stderr)

# 5) Tool descriptions are actionable (length / "Use when" / "When to use")
desc_blocks = re.findall(r'description="([^"]{20,})"', msrc) + re.findall(r"description='([^']{20,})'", msrc)
actionable = sum(1 for d in desc_blocks if len(d) >= 60 or
                 any(p in d.lower() for p in ['use when','when to','use this','call this','start here','prefer']))
if actionable >= 3:
    score += 1
else:
    print(f"  T5 FAIL: only {actionable} actionable descriptions", file=sys.stderr)

# 6) MCP server module imports cleanly
try:
    import importlib
    mod = importlib.import_module("cli_tools.registry.mcp_server")
    score += 1
except Exception as e:
    print(f"  T6 FAIL: import error: {e}", file=sys.stderr)

print(score)
PYEOF
SC=$(cat /tmp/mcp_score.txt | tail -1 | tr -d '[:space:]')
SC=${SC:-0}
WT=$(awk -v s="$SC" 'BEGIN{printf "%.4f", (s/6.0)*0.18}')
add_reward "$WT"
echo "  Score: $SC/6 → +$WT"

# ============================================================================
# F2P-4 (0.12): Analysis wrappers callable end-to-end on a real workflow
# ============================================================================
echo ""
echo "=== F2P-4: Analysis functions work on a real workflow (0.12) ==="
python3 - << 'PYEOF' > /tmp/anal_score.txt
import sys, json
sys.path.insert(0, ".")
score = 0; total = 4

# Build a simple test workflow
wf = {
  "nodes": [
    {"id":1,"type":"CheckpointLoaderSimple","widgets_values":["model.ckpt"]},
    {"id":2,"type":"CLIPTextEncode","widgets_values":["a cat"]},
    {"id":3,"type":"CLIPTextEncode","widgets_values":["bad"]},
    {"id":4,"type":"EmptyLatentImage","widgets_values":[512,512,1]},
    {"id":5,"type":"KSampler","widgets_values":[42,"randomize",20,7.0,"euler","normal",1.0]},
    {"id":6,"type":"VAEDecode"},
    {"id":7,"type":"SaveImage"},
  ],
  "links": [
    [1,1,0,2,0,"CLIP"],
    [2,1,0,3,0,"CLIP"],
    [3,1,1,5,0,"MODEL"],
    [4,2,0,5,1,"CONDITIONING"],
    [5,3,0,5,2,"CONDITIONING"],
    [6,4,0,5,3,"LATENT"],
    [7,5,0,6,0,"LATENT"],
    [8,1,2,6,1,"VAE"],
    [9,6,0,7,0,"IMAGE"],
  ]
}

import cli_tools.analysis as A

# 1) analyze_workflow callable
try:
    if hasattr(A, 'analyze_workflow'):
        r = A.analyze_workflow(wf)
        assert r is not None
        score += 1
except Exception as e:
    print(f"  T1: {e}", file=sys.stderr)

# 2) find_upstream / find_downstream callable
try:
    fu = getattr(A, 'find_upstream', None) or getattr(A, 'upstream', None)
    fd = getattr(A, 'find_downstream', None) or getattr(A, 'downstream', None)
    if fu and fd:
        u = fu(wf, 5)
        d = fd(wf, 5)
        # 5 (KSampler) should depend on 1,2,3,4 (subset)
        u_set = set()
        if isinstance(u, dict):
            for v in u.values():
                if isinstance(v, (list,set,tuple)): u_set.update(v)
        elif isinstance(u, (list,set,tuple)):
            u_set = set(u)
        if u_set and (1 in u_set or '1' in u_set or any(x in u_set for x in [1,2,3,4])):
            score += 1
        else:
            # less strict — just any non-empty result
            if u_set or u: score += 1
    elif fu or fd:
        score += 0  # need both
except Exception as e:
    print(f"  T2: {e}", file=sys.stderr)

# 3) find_path or path tracing
try:
    fp = getattr(A, 'find_path', None) or getattr(A, 'path', None) or getattr(A, 'shortest_path', None)
    if fp:
        p = fp(wf, 1, 7)
        if p:
            score += 1
except Exception as e:
    print(f"  T3: {e}", file=sys.stderr)

# 4) MCP server exposes these via callable tool handlers (smoke test by importing)
try:
    import cli_tools.registry.mcp_server as M
    src = open("cli_tools/registry/mcp_server.py").read()
    # Must reference at least one analysis function in handler bodies
    if any(fn in src for fn in ['analyze_workflow','find_upstream','find_downstream','find_path','find_subgraph']):
        score += 1
except Exception as e:
    print(f"  T4: {e}", file=sys.stderr)

print(score)
PYEOF
SC=$(cat /tmp/anal_score.txt | tail -1 | tr -d '[:space:]')
SC=${SC:-0}
WT=$(awk -v s="$SC" 'BEGIN{printf "%.4f", (s/4.0)*0.12}')
add_reward "$WT"
echo "  Score: $SC/4 → +$WT"

# ============================================================================
# F2P-5 (0.10): MCP auto-discovery (.mcp.json) and dependency tracking
# ============================================================================
echo ""
echo "=== F2P-5: .mcp.json + mcp dependency (0.10) ==="
python3 - << 'PYEOF' > /tmp/mcp_disc.txt
import sys, json, os, re
score = 0; total = 4

# 1) .mcp.json exists
if os.path.exists(".mcp.json"):
    try:
        with open(".mcp.json") as f:
            cfg = json.load(f)
        if "mcpServers" in cfg and isinstance(cfg["mcpServers"], dict) and len(cfg["mcpServers"]) >= 1:
            score += 1
            # 2) Server entry references the mcp_server module
            srv = next(iter(cfg["mcpServers"].values()))
            cmd_blob = json.dumps(srv).lower()
            if "mcp_server" in cmd_blob or "cli_tools.registry" in cmd_blob:
                score += 1
    except Exception as e:
        print(f"  json error: {e}", file=sys.stderr)
else:
    print("  no .mcp.json", file=sys.stderr)

# 3) mcp listed as dependency in pyproject.toml or requirements.txt
mcp_dep = False
for f in ["pyproject.toml","requirements.txt","setup.py","setup.cfg"]:
    if os.path.exists(f):
        try:
            txt = open(f).read()
            if re.search(r'(^|\s|"|\')mcp(\s|>=|==|>|"|\'|$)', txt, re.MULTILINE):
                mcp_dep = True; break
        except: pass
if mcp_dep:
    score += 1
else:
    print("  mcp not in deps", file=sys.stderr)

# 4) shared module also in pyproject (or at least dependency file is parseable)
if os.path.exists("pyproject.toml"):
    try:
        txt = open("pyproject.toml").read()
        # not corrupt
        if "[project]" in txt or "[tool" in txt or "[build-system]" in txt:
            score += 1
    except: pass
elif os.path.exists("requirements.txt"):
    score += 1

print(score)
PYEOF
SC=$(cat /tmp/mcp_disc.txt | tail -1 | tr -d '[:space:]')
SC=${SC:-0}
WT=$(awk -v s="$SC" 'BEGIN{printf "%.4f", (s/4.0)*0.10}')
add_reward "$WT"
echo "  Score: $SC/4 → +$WT"

# ============================================================================
# F2P-6 (0.13): Skills broken up — multiple focused SKILL.md files with triggers
# ============================================================================
echo ""
echo "=== F2P-6: Focused skills with triggers (0.13) ==="
python3 - << 'PYEOF' > /tmp/skills.txt
import sys, os, glob, re
score = 0; total = 5

skills_dir = ".claude/skills"
if not os.path.isdir(skills_dir):
    print("  no skills dir", file=sys.stderr)
    print(0); sys.exit(0)

skill_files = glob.glob(f"{skills_dir}/*/SKILL.md")
# Filter out clearly placeholder files
real_skills = []
for sf in skill_files:
    try:
        c = open(sf).read()
        if len(c) > 200:  # exclude trivial placeholders
            real_skills.append((sf, c))
    except: pass

# 1) >=2 distinct real skills (broke up the monolith)
if len(real_skills) >= 2:
    score += 1
# 2) >=3 distinct real skills (well-scoped)
if len(real_skills) >= 3:
    score += 1

# 3) Each has a frontmatter `description:` with triggers
trig_count = 0
for sf, c in real_skills:
    fm = re.search(r'^---\s*\n(.*?)\n---', c, re.DOTALL)
    if fm:
        body = fm.group(1)
        desc_m = re.search(r'description:\s*(.+)', body)
        if desc_m and len(desc_m.group(1)) >= 40:
            trig_count += 1
if trig_count >= 2:
    score += 1
if trig_count >= 3:
    score += 1

# 4) At least one skill differentiates from another (different name + non-overlapping topic words)
names = []
for sf, c in real_skills:
    fm = re.search(r'name:\s*([\w\-]+)', c)
    if fm: names.append(fm.group(1))
if len(set(names)) >= 2:
    score += 1

print(score)
PYEOF
SC=$(cat /tmp/skills.txt | tail -1 | tr -d '[:space:]')
SC=${SC:-0}
WT=$(awk -v s="$SC" 'BEGIN{printf "%.4f", (s/5.0)*0.13}')
add_reward "$WT"
echo "  Score: $SC/5 → +$WT"

# ============================================================================
# F2P-7 (0.10): Test coverage added for shared search + analysis wrappers
# ============================================================================
echo ""
echo "=== F2P-7: Test coverage exists & passes (0.10) ==="
python3 - << 'PYEOF' > /tmp/tests_score.txt
import sys, os, glob, re, subprocess
score = 0; total = 4

# 1) Tests directory exists with files
test_files = glob.glob("tests/**/*.py", recursive=True) + glob.glob("test_*.py") + glob.glob("**/test_*.py", recursive=True)
test_files = [f for f in test_files if 'site-packages' not in f and '/.venv/' not in f]
if test_files:
    score += 1

# 2) Some test references TASK_ALIASES or expand_query or analysis functions
ref_search = False
ref_analysis = False
for tf in test_files:
    try:
        c = open(tf).read()
        if 'TASK_ALIASES' in c or 'expand_query' in c or 'expand_aliases' in c:
            ref_search = True
        if any(fn in c for fn in ['analyze_workflow','find_upstream','find_downstream','find_path']):
            ref_analysis = True
    except: pass
if ref_search:
    score += 1
if ref_analysis:
    score += 1

# 3) pytest can collect at least the shared-search / analysis tests without error
try:
    proc = subprocess.run(
        ["python3","-m","pytest","--collect-only","-q","tests/"],
        capture_output=True, text=True, timeout=30
    )
    if proc.returncode == 0 and ("test" in proc.stdout.lower() or "collected" in proc.stdout.lower()):
        score += 1
    elif "no tests ran" not in proc.stdout.lower() and proc.returncode in (0,5):
        score += 1
except Exception as e:
    pass

print(score)
PYEOF
SC=$(cat /tmp/tests_score.txt | tail -1 | tr -d '[:space:]')
SC=${SC:-0}
WT=$(awk -v s="$SC" 'BEGIN{printf "%.4f", (s/4.0)*0.10}')
add_reward "$WT"
echo "  Score: $SC/4 → +$WT"

# ============================================================================
# Final
# ============================================================================
echo ""
echo "=== FINAL REWARD: $REWARD ==="
echo "$REWARD" > "$LOG_DIR/reward.txt"

# ---- inner-claude upstream gates ----
echo ""
echo "=== Upstream gates ==="
mkdir -p "$LOG_DIR"
: > "$LOG_DIR/gates.json"

emit_gate() {
    local gid="$1" passed="$2" detail="$3"
    python3 - "$gid" "$passed" "$detail" <<'EMITPY' >> "$LOG_DIR/gates.json"
import json, sys
print(json.dumps({"id": sys.argv[1], "passed": sys.argv[2] == "true", "detail": sys.argv[3][:200]}))
EMITPY
}

# F2P upstream #1: pytest tests/
echo "-- F2P upstream: pytest tests/ --"
if python3 -m pytest tests/ -q --tb=no --no-header --disable-warnings -p no:cacheprovider > /tmp/upstream_pytest.log 2>&1; then
    emit_gate "f2p_upstream_pytest" "true" "pytest tests/ passed"
    echo "  PASS"
else
    rc=$?
    detail="pytest rc=$rc"
    if [ -s /tmp/upstream_pytest.log ]; then
        detail="$detail; $(tail -1 /tmp/upstream_pytest.log 2>/dev/null)"
    fi
    emit_gate "f2p_upstream_pytest" "false" "$detail"
    echo "  FAIL ($detail)"
fi

# F2P upstream #2: shared task_aliases module behavioral check
echo "-- F2P upstream: shared aliases module behavioral --"
if python3 - <<'PYGATE' > /tmp/upstream_aliases.log 2>&1
import importlib, sys
sys.path.insert(0, '.')
mod = None
for name in ['cli_tools.task_aliases', 'cli_tools.aliases', 'cli_tools.search',
             'cli_tools.shared', 'cli_tools.common',
             'cli_tools.registry.task_aliases', 'cli_tools.registry.aliases',
             'cli_tools.registry.search']:
    try:
        m = importlib.import_module(name)
        if hasattr(m, 'TASK_ALIASES') and isinstance(m.TASK_ALIASES, dict) and len(m.TASK_ALIASES) >= 25:
            mod = m
            break
    except Exception:
        pass
assert mod is not None, "no shared task_aliases module found"
expand_fn = None
for fn_name in ['expand_query', 'expand_aliases', 'resolve_query', 'expand_terms',
                'resolve_aliases', 'expand_search', 'expand', 'get_search_terms']:
    f = getattr(mod, fn_name, None)
    if callable(f):
        expand_fn = f
        break
assert expand_fn, "no expand function in shared module"
r = expand_fn('upscale')
rs = r if isinstance(r, set) else set(r) if r else set()
assert any(t in rs for t in ['esrgan', 'realesrgan', 'super resolution', '4x']), \
    f"upscale didn't expand to upscaler aliases: {rs}"
print("OK")
PYGATE
then
    emit_gate "f2p_upstream_aliases" "true" "shared task_aliases module + expand_query work"
    echo "  PASS"
else
    detail="$(tail -1 /tmp/upstream_aliases.log 2>/dev/null | tr -d '\n')"
    emit_gate "f2p_upstream_aliases" "false" "${detail:-shared aliases gate failed}"
    echo "  FAIL ($detail)"
fi

# P2P upstream: core imports stable
echo "-- P2P upstream: core imports --"
if python3 -c "import sys; sys.path.insert(0, '.'); from cli_tools import analysis; from cli_tools.registry import knowledge, mcp_server" > /tmp/upstream_imports.log 2>&1; then
    emit_gate "p2p_upstream_imports" "true" "core imports OK"
    echo "  PASS"
else
    detail="$(tail -1 /tmp/upstream_imports.log 2>/dev/null | tr -d '\n')"
    emit_gate "p2p_upstream_imports" "false" "${detail:-import failure}"
    echo "  FAIL ($detail)"
fi

# Reward calc tail: hard-zero on P2P fail OR no F2P pass; otherwise add F2P weights.
python3 - <<'REWARDPY'
import json, os
WEIGHTS = {"f2p_upstream_pytest": 0.20, "f2p_upstream_aliases": 0.20}
P2P_REGRESSION = ["p2p_upstream_imports"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            gid = d.get('id')
            if gid:
                verdicts[gid] = bool(d.get('passed'))
except FileNotFoundError:
    pass
existing = 0.0
try:
    with open('/logs/verifier/reward.txt') as f:
        existing = float(f.read().strip() or 0)
except Exception:
    pass
p2p_failed = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS)
if p2p_failed or not f2p_any_pass:
    reward = 0.0
else:
    # weighted-replace formula (c8bc168a standard, replaces additive)
    inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('UPSTREAM_REWARD=%.4f (existing=%.4f, p2p_failed=%s, f2p_any_pass=%s)' % (reward, existing, p2p_failed, f2p_any_pass))
REWARDPY
# ---- end inner-claude upstream gates ----

exit 0