#!/bin/bash
set +e

REPO="/workspace/pi-mono"
LOG="/logs/verifier/details.log"
GATES_FILE=/logs/verifier/gates.json
mkdir -p /logs/verifier
echo "=== Verifier Start ===" > "$LOG"
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail=$(printf '%s' "$detail" | sed 's/"/\\"/g')
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

write_reward() {
    local r="$1"
    awk -v r="$r" 'BEGIN { printf "%.4f\n", r }' > /logs/verifier/reward.txt
}

write_reward 0.0

if [ ! -d "$REPO" ]; then
    echo "FATAL: $REPO not found" >> "$LOG"
    emit p2p_pkg_json_valid false "repo missing"
    exit 0
fi

cd "$REPO"

export PATH="/usr/local/bin:/usr/bin:/bin:/root/.bun/bin:$PATH"
if ! command -v node >/dev/null 2>&1; then
    for cand in /usr/local/bin/node /usr/bin/node /root/.nvm/versions/node/*/bin/node; do
        if [ -x "$cand" ]; then
            export PATH="$(dirname $cand):$PATH"
            break
        fi
    done
fi

if ! command -v node >/dev/null 2>&1; then
    echo "FATAL: node missing" >> "$LOG"
    emit p2p_pkg_json_valid false "node missing"
    exit 0
fi

# -----------------------------------------------------------------------------
# Enumerate package.json files
# -----------------------------------------------------------------------------
PKG_JSONS=()
for pj in "$REPO"/packages/*/package.json "$REPO"/package.json; do
    [ -f "$pj" ] && PKG_JSONS+=("$pj")
done
echo "Found ${#PKG_JSONS[@]} package.json files" >> "$LOG"

# -----------------------------------------------------------------------------
# P2P GATING: all package.json valid + retain name field
# -----------------------------------------------------------------------------
P2P_OK=true
for pj in "${PKG_JSONS[@]}"; do
    OK=$(node -e "
        try {
            const d = JSON.parse(require('fs').readFileSync('$pj','utf8'));
            if (typeof d.name === 'string' && d.name.length > 0) console.log('ok');
        } catch(e) {}
    " 2>/dev/null)
    if [ "$OK" != "ok" ]; then
        P2P_OK=false
        echo "P2P FAIL: $pj invalid or missing name" >> "$LOG"
        emit p2p_pkg_json_valid false "$pj invalid"
        break
    fi
done
if [ "$P2P_OK" = true ]; then
    emit p2p_pkg_json_valid true ""
fi

# Expected publishable packages in pi-mono workspace (from observed strong fixes)
EXPECTED_PKGS=(agent ai coding-agent mom pods tui web-ui)
CRITICAL_PKGS=(coding-agent ai agent)

# -----------------------------------------------------------------------------
# Build baseline: which packages already had pi-package or pi-style keyword
# -----------------------------------------------------------------------------
declare -A BASELINE_HAS
declare -A BASELINE_KW_COUNT
declare -A BASELINE_PRIVATE

for name in "${EXPECTED_PKGS[@]}"; do
    REL="packages/$name/package.json"
    if [ -d "$REPO/.git" ] && command -v git >/dev/null 2>&1; then
        ORIG=$(git -C "$REPO" show "HEAD:$REL" 2>/dev/null)
    else
        ORIG=""
    fi
    if [ -z "$ORIG" ]; then
        BASELINE_HAS[$name]="no"
        BASELINE_KW_COUNT[$name]=0
        BASELINE_PRIVATE[$name]="no"
        continue
    fi
    INFO=$(echo "$ORIG" | node -e "
        let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{
            try {
                const d = JSON.parse(s);
                const kw = Array.isArray(d.keywords) ? d.keywords.map(x=>String(x).toLowerCase()) : [];
                const has = kw.includes('pi-package') ? 'yes' : 'no';
                const priv = d.private ? 'yes' : 'no';
                console.log(has + ' ' + kw.length + ' ' + priv);
            } catch(e) { console.log('no 0 no'); }
        });
    " 2>/dev/null)
    BASELINE_HAS[$name]=$(echo "$INFO" | awk '{print $1}')
    BASELINE_KW_COUNT[$name]=$(echo "$INFO" | awk '{print $2}')
    BASELINE_PRIVATE[$name]=$(echo "$INFO" | awk '{print $3}')
done

# -----------------------------------------------------------------------------
# Inspect current state for each expected package
# -----------------------------------------------------------------------------
declare -A NOW_HAS
declare -A NOW_KW_COUNT
declare -A NOW_PRIVATE

for name in "${EXPECTED_PKGS[@]}"; do
    pj="$REPO/packages/$name/package.json"
    if [ ! -f "$pj" ]; then
        NOW_HAS[$name]="no"
        NOW_KW_COUNT[$name]=0
        NOW_PRIVATE[$name]="no"
        continue
    fi
    INFO=$(node -e "
        try {
            const d = JSON.parse(require('fs').readFileSync('$pj','utf8'));
            const kw = Array.isArray(d.keywords) ? d.keywords.map(x=>String(x).toLowerCase()) : [];
            const has = kw.includes('pi-package') ? 'yes' : 'no';
            const priv = d.private ? 'yes' : 'no';
            console.log(has + ' ' + kw.length + ' ' + priv);
        } catch(e) { console.log('no 0 no'); }
    " 2>/dev/null)
    NOW_HAS[$name]=$(echo "$INFO" | awk '{print $1}')
    NOW_KW_COUNT[$name]=$(echo "$INFO" | awk '{print $2}')
    NOW_PRIVATE[$name]=$(echo "$INFO" | awk '{print $3}')
done

# -----------------------------------------------------------------------------
# Compute newly added (not in baseline) + publishable (not private) keyword adds
# Also require keyword preservation: new kw count >= baseline kw count + 1
# -----------------------------------------------------------------------------
NEW_PUB_COUNT=0
NEW_PUB_PRESERVED_COUNT=0
NEEDED=0
NEW_PKGS=""

for name in "${EXPECTED_PKGS[@]}"; do
    [ "${BASELINE_HAS[$name]}" = "no" ] && [ "${NOW_PRIVATE[$name]}" = "no" ] && NEEDED=$((NEEDED + 1))
    if [ "${NOW_HAS[$name]}" = "yes" ] \
       && [ "${BASELINE_HAS[$name]}" = "no" ] \
       && [ "${NOW_PRIVATE[$name]}" = "no" ]; then
        NEW_PUB_COUNT=$((NEW_PUB_COUNT + 1))
        NEW_PKGS="$NEW_PKGS $name"
        baseline_kw=${BASELINE_KW_COUNT[$name]:-0}
        new_kw=${NOW_KW_COUNT[$name]:-0}
        min_expected=$((baseline_kw + 1))
        if [ "$new_kw" -ge "$min_expected" ]; then
            NEW_PUB_PRESERVED_COUNT=$((NEW_PUB_PRESERVED_COUNT + 1))
        fi
    fi
done

echo "Expected publishable needing keyword: $NEEDED" >> "$LOG"
echo "New publishable adds: $NEW_PUB_COUNT [$NEW_PKGS]" >> "$LOG"
echo "New publishable adds with preserved kws: $NEW_PUB_PRESERVED_COUNT" >> "$LOG"

# -----------------------------------------------------------------------------
# GATE t4_f2p_keyword_added_to_publishable_pkg
# At least one in-scope publishable package gained pi-package
# -----------------------------------------------------------------------------
if [ "$NEW_PUB_COUNT" -ge 1 ]; then
    emit t4_f2p_keyword_added_to_publishable_pkg true ""
    G_T4_ADDED=1
else
    emit t4_f2p_keyword_added_to_publishable_pkg false "no publishable in-scope package gained pi-package"
    G_T4_ADDED=0
fi

# -----------------------------------------------------------------------------
# GATE t4_f2p_keyword_breadth
# Majority (>=50%) of needed packages got pi-package AND keywords were preserved
# -----------------------------------------------------------------------------
G_T4_BREADTH=0
if [ "$NEEDED" -gt 0 ]; then
    HALF=$(( (NEEDED + 1) / 2 ))
    if [ "$NEW_PUB_PRESERVED_COUNT" -ge "$HALF" ] && [ "$NEW_PUB_PRESERVED_COUNT" -ge 3 ]; then
        emit t4_f2p_keyword_breadth true ""
        G_T4_BREADTH=1
    else
        emit t4_f2p_keyword_breadth false "preserved-add count $NEW_PUB_PRESERVED_COUNT below threshold (need >=$HALF and >=3)"
    fi
else
    emit t4_f2p_keyword_breadth false "no packages needed updating"
fi

# -----------------------------------------------------------------------------
# GATE t4_f2p_critical_pkgs_covered
# coding-agent, ai, agent must include pi-package (newly added, not baseline)
# -----------------------------------------------------------------------------
CRIT_HITS=0
for name in "${CRITICAL_PKGS[@]}"; do
    if [ "${NOW_HAS[$name]}" = "yes" ] && [ "${BASELINE_HAS[$name]}" = "no" ]; then
        CRIT_HITS=$((CRIT_HITS + 1))
    fi
done
echo "Critical pkg hits: $CRIT_HITS/3" >> "$LOG"
if [ "$CRIT_HITS" -ge 3 ]; then
    emit t4_f2p_critical_pkgs_covered true ""
    G_T4_CRIT=1
else
    emit t4_f2p_critical_pkgs_covered false "only $CRIT_HITS/3 critical pkgs got pi-package"
    G_T4_CRIT=0
fi

# -----------------------------------------------------------------------------
# Build helper: extract content added in current vs baseline for a doc file
# -----------------------------------------------------------------------------
get_added_content() {
    local rel="$1"
    local full="$REPO/$rel"
    [ ! -f "$full" ] && { echo ""; return; }
    local orig=""
    if [ -d "$REPO/.git" ]; then
        orig=$(git -C "$REPO" show "HEAD:$rel" 2>/dev/null)
    fi
    local cur
    cur=$(cat "$full" 2>/dev/null)
    diff <(printf '%s' "$orig") <(printf '%s' "$cur") 2>/dev/null | grep -E '^>' | sed 's/^> //'
}

# -----------------------------------------------------------------------------
# GATE t6_f2p_doc_keyword_mention
# extensions.md AND README.md under packages/coding-agent mention pi-package
# (newly added content, beyond what was in baseline)
# -----------------------------------------------------------------------------
DOC_REL_EXT="packages/coding-agent/docs/extensions.md"
DOC_REL_README="packages/coding-agent/README.md"

EXT_NEW=$(get_added_content "$DOC_REL_EXT")
README_NEW=$(get_added_content "$DOC_REL_README")

EXT_HAS_KW=0
README_HAS_KW=0
if echo "$EXT_NEW" | grep -qiE 'pi-package'; then EXT_HAS_KW=1; fi
if echo "$README_NEW" | grep -qiE 'pi-package'; then README_HAS_KW=1; fi
echo "Doc kw mentions: extensions=$EXT_HAS_KW readme=$README_HAS_KW" >> "$LOG"

if [ "$EXT_HAS_KW" -eq 1 ] && [ "$README_HAS_KW" -eq 1 ]; then
    emit t6_f2p_doc_keyword_mention true ""
    G_T6_KW=1
else
    emit t6_f2p_doc_keyword_mention false "extensions.md=$EXT_HAS_KW README.md=$README_HAS_KW"
    G_T6_KW=0
fi

# -----------------------------------------------------------------------------
# GATE t6_f2p_doc_search_mechanic
# At least one doc explicitly explains `npm search keywords:pi-package`
# (or equivalent: 'npm search pi-package' as a discovery mechanic)
# -----------------------------------------------------------------------------
DOC_FILES=(
    "packages/coding-agent/docs/extensions.md"
    "packages/coding-agent/docs/packages.md"
    "packages/coding-agent/README.md"
    "README.md"
)

DOC_MECHANIC_COUNT=0
for rel in "${DOC_FILES[@]}"; do
    NEW_CONTENT=$(get_added_content "$rel")
    [ -z "$NEW_CONTENT" ] && continue
    if echo "$NEW_CONTENT" | grep -qiE 'npm[[:space:]]+search[[:space:]]+(keywords:)?[`"'"'"']?pi-package'; then
        DOC_MECHANIC_COUNT=$((DOC_MECHANIC_COUNT + 1))
        echo "  doc mechanic in: $rel" >> "$LOG"
    fi
done
echo "Doc mechanic count: $DOC_MECHANIC_COUNT" >> "$LOG"

if [ "$DOC_MECHANIC_COUNT" -ge 1 ]; then
    emit t6_f2p_doc_search_mechanic true ""
    G_T6_MECH=1
else
    emit t6_f2p_doc_search_mechanic false "no doc adds 'npm search [keywords:]pi-package'"
    G_T6_MECH=0
fi

# -----------------------------------------------------------------------------
# GATE t7_f2p_search_returns_hits
# Simulate npm registry search by scanning package.json keywords across the
# workspace and asserting >=3 hits for keyword=pi-package.
# -----------------------------------------------------------------------------
SEARCH_HITS=$(node -e "
const fs=require('fs');
const path=require('path');
const root='$REPO';
function search(keyword) {
    const hits = [];
    const pkgsDir = path.join(root,'packages');
    if (!fs.existsSync(pkgsDir)) return hits;
    for (const dir of fs.readdirSync(pkgsDir)) {
        const pj = path.join(pkgsDir, dir, 'package.json');
        if (!fs.existsSync(pj)) continue;
        try {
            const d = JSON.parse(fs.readFileSync(pj,'utf8'));
            const kw = Array.isArray(d.keywords)?d.keywords.map(x=>String(x).toLowerCase()):[];
            if (kw.includes(keyword.toLowerCase()) && d.name && !d.private) {
                hits.push(d.name);
            }
        } catch(e) {}
    }
    return hits;
}
const hits = search('pi-package');
console.error('Search hits:', JSON.stringify(hits));
console.log(hits.length);
" 2>>"$LOG")
SEARCH_HITS=${SEARCH_HITS:-0}
echo "Search-sim hit count: $SEARCH_HITS" >> "$LOG"

if [ "$SEARCH_HITS" -ge 3 ]; then
    emit t7_f2p_search_returns_hits true ""
    G_T7_HITS=1
else
    emit t7_f2p_search_returns_hits false "only $SEARCH_HITS hits (<3)"
    G_T7_HITS=0
fi

# -----------------------------------------------------------------------------
# GATE t7_f2p_search_distinct_from_baseline
# At least one hit was not present in the baseline (i.e. agent added it)
# -----------------------------------------------------------------------------
if [ "$NEW_PUB_COUNT" -ge 1 ] && [ "$SEARCH_HITS" -ge 1 ]; then
    emit t7_f2p_search_distinct_from_baseline true ""
    G_T7_DIST=1
else
    emit t7_f2p_search_distinct_from_baseline false "new_pub=$NEW_PUB_COUNT hits=$SEARCH_HITS"
    G_T7_DIST=0
fi

# -----------------------------------------------------------------------------
# Reward computation
# F2P weights: 0.20 + 0.25 + 0.15 + 0.10 + 0.15 + 0.10 + 0.05 = 1.00
# -----------------------------------------------------------------------------
REWARD=$(awk -v a=$G_T4_ADDED -v b=$G_T4_BREADTH -v c=$G_T4_CRIT \
             -v d=$G_T6_KW -v e=$G_T6_MECH -v f=$G_T7_HITS -v g=$G_T7_DIST \
             'BEGIN { printf "%.4f", a*0.20 + b*0.25 + c*0.15 + d*0.10 + e*0.15 + f*0.10 + g*0.05 }')

# Apply P2P_GATING
if [ "$P2P_OK" != true ]; then
    REWARD="0.0000"
fi

echo "" >> "$LOG"
echo "=== Gate Results ===" >> "$LOG"
echo "  t4 added(0.20):     $G_T4_ADDED" >> "$LOG"
echo "  t4 breadth(0.25):   $G_T4_BREADTH" >> "$LOG"
echo "  t4 critical(0.15):  $G_T4_CRIT" >> "$LOG"
echo "  t6 doc kw(0.10):    $G_T6_KW" >> "$LOG"
echo "  t6 doc mech(0.15):  $G_T6_MECH" >> "$LOG"
echo "  t7 hits(0.10):      $G_T7_HITS" >> "$LOG"
echo "  t7 distinct(0.05):  $G_T7_DIST" >> "$LOG"
echo "  REWARD: $REWARD" >> "$LOG"

write_reward "$REWARD"
# ---- v042 upstream CI gates (auto-injected) ----
# v043 upstream gates: prelude(s) + per-gate execution.
(
    set +e
    # prelude 0
    echo 'c2V0ICtlOyBjZCAvd29ya3NwYWNlL3BpLW1vbm8gJiYgY29tbWFuZCAtdiBucHggPi9kZXYvbnVsbCAmJiBlY2hvIE9L' | base64 -d | bash 2>&1 | tail -2
) 2>/dev/null

run_v043_gate() {
    local id="$1" label="$2"; shift 2
    local cmd="$*"
    local rc out tail
    out=$(timeout 240 bash -c "$cmd" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        emit "$id" true ""
    else
        tail="${out: -180}"
        tail="${tail//\"/\'}"
        tail="${tail//$'\n'/ }"
        emit "$id" false "rc=$rc; $tail"
    fi
}
run_v043_gate p2p_upstream_9dadbbf2 'npm_typecheck_agent' 'cd /workspace/pi-mono && CHANGED=$((git diff --name-only HEAD~1 HEAD 2>/dev/null; git diff --name-only HEAD 2>/dev/null) | grep -E "^packages/agent/.*\.tsx?$" | sort -u | tr "\n" " "); if [ -z "$CHANGED" ]; then echo "no agent .ts/.tsx changes in packages/agent — gate skipped"; exit 0; fi; cd /workspace/pi-mono && timeout 120 npx tsgo --noEmit $CHANGED 2>&1 | tail -5; rc=$?; if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then exit $rc; fi'
run_v043_gate p2p_upstream_8548d166 'vitest_session_manager_agent' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/agent && timeout 120 npx vitest run test/path-utils.test.ts --reporter=basic 2>&1 | tail -10'
run_v043_gate p2p_upstream_771580d1 'npm_typecheck_ai' 'cd /workspace/pi-mono && CHANGED=$((git diff --name-only HEAD~1 HEAD 2>/dev/null; git diff --name-only HEAD 2>/dev/null) | grep -E "^packages/ai/.*\.tsx?$" | sort -u | tr "\n" " "); if [ -z "$CHANGED" ]; then echo "no agent .ts/.tsx changes in packages/ai — gate skipped"; exit 0; fi; cd /workspace/pi-mono && timeout 120 npx tsgo --noEmit $CHANGED 2>&1 | tail -5; rc=$?; if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then exit $rc; fi'
run_v043_gate p2p_upstream_816994b6 'vitest_session_manager_ai' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/ai && timeout 120 npx vitest run test/path-utils.test.ts --reporter=basic 2>&1 | tail -10'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"t4_f2p_critical_pkgs_covered": 0.15, "t4_f2p_keyword_added_to_publishable_pkg": 0.2, "t4_f2p_keyword_breadth": 0.25, "t6_f2p_doc_keyword_mention": 0.1, "t6_f2p_doc_search_mechanic": 0.15, "t7_f2p_search_distinct_from_baseline": 0.05, "t7_f2p_search_returns_hits": 0.1}
P2P_GATING = ["p2p_pkg_json_valid"]
P2P_REGRESSION = ["p2p_upstream_9dadbbf2", "p2p_upstream_8548d166", "p2p_upstream_771580d1", "p2p_upstream_816994b6"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                gid = d.get('id')
                if gid: verdicts[gid] = bool(d.get('passed'))
            except Exception: pass
except FileNotFoundError: pass
hard_zero = False
# P2P_REGRESSION_INFORMATIONAL: only P2P_GATING items hard-zero. P2P_REGRESSION is informational.
p2p_reg_failed = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)
for gid in P2P_GATING:
    if not verdicts.get(gid, False):
        hard_zero = True; break
if hard_zero: reward = 0.0
else:
    reward = 0.0
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid, False): reward += w
    if reward > 1.0: reward = 1.0
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('V043_REWARD=%.4f' % reward)
V043_PY
# ---- v042 end upstream CI gates ----

exit 0