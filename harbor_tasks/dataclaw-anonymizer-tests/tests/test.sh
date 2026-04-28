#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
LOGFILE="/logs/verifier/details.txt"
mkdir -p /logs/verifier
chmod 777 /logs/verifier 2>/dev/null || true
> "$LOGFILE" 2>/dev/null || true

log() {
    echo "$1" | tee -a "$LOGFILE" 2>/dev/null || echo "$1"
}

REWARD=0.0
echo "$REWARD" > "$REWARD_FILE"

# Locate the repo
REPO=""
for cand in /workspace/repo /workspace/repo-anonymizer; do
    if [ -d "$cand" ] && [ -f "$cand/dataclaw/anonymizer.py" ]; then
        REPO="$cand"
        break
    fi
done
if [ -z "$REPO" ]; then
    REPO=$(find /workspace -maxdepth 4 -type f -name "anonymizer.py" -path "*/dataclaw/*" 2>/dev/null | head -n1 | xargs -I{} dirname {} 2>/dev/null | xargs -I{} dirname {} 2>/dev/null)
fi
if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then
    log "FATAL: could not locate repo"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi
cd "$REPO"
log "Using repo: $REPO"

run_py() {
    python3 -c "$1" 2>&1
}

# ---------------------------------------------------------------
# GATE: importable (no reward, just sanity)
# ---------------------------------------------------------------
log "--- GATE: import ---"
if ! run_py "from dataclaw.anonymizer import anonymize_text, Anonymizer, _hash_username, _replace_username" >/dev/null 2>&1; then
    log "FATAL: cannot import core symbols"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi
log "  GATE import: PASS"

# ---------------------------------------------------------------
# GATE: P2P regression guards.
# These MUST pass on the buggy base (and fix). If they fail, the agent broke
# something pre-existing — set REWARD=0 and exit.
# ---------------------------------------------------------------
log "--- GATE: P2P regression guards ---"

p2p_guard() {
    local name="$1"
    local code="$2"
    local out
    out=$(run_py "$code")
    if ! echo "$out" | grep -q "^PASS$"; then
        log "  P2P GUARD FAIL ($name): regression — exiting 0.0"
        log "    $out"
        echo "0.0" > "$REWARD_FILE"
        exit 0
    fi
    log "  P2P guard $name: PASS"
}

# Hash determinism is a baseline behavior.
p2p_guard "hash_determinism" "
from dataclaw.anonymizer import _hash_username
h1 = _hash_username('alice'); h2 = _hash_username('alice'); h3 = _hash_username('bob')
assert h1 == h2 and h1 != h3
assert h1.startswith('user_') and len(h1) == 13
print('PASS')
"

# Plain long-username replacement works on base.
p2p_guard "long_basic" "
from dataclaw.anonymizer import anonymize_text
r = anonymize_text('hello alice', 'alice', 'HASH')
assert r == 'hello HASH', r
print('PASS')
"

# Posix-path short-username replacement works on base.
p2p_guard "short_posix_path" "
from dataclaw.anonymizer import anonymize_text
r = anonymize_text('/Users/bo/file.py', 'bo', 'HASH')
assert 'HASH' in r and '/Users/bo/' not in r, r
print('PASS')
"

# ---------------------------------------------------------------
# F2P behavioral gates. Each FAILS on buggy base (windows branch),
# PASSES on the correct fix. Weights sum to 1.0.
# ---------------------------------------------------------------

# Track score with awk to avoid bc dependency.
SCORE=0.0
add_score() {
    local pts="$1"
    SCORE=$(awk -v a="$SCORE" -v b="$pts" 'BEGIN{printf "%.4f", a+b}')
}

f2p() {
    local pts="$1"
    local name="$2"
    local code="$3"
    local out
    out=$(run_py "$code")
    if echo "$out" | grep -q "^PASS$"; then
        add_score "$pts"
        log "  F2P $name: PASS (+$pts)"
    else
        log "  F2P $name: FAIL"
        log "    $out"
    fi
}

# F2P-1 (0.15): underscore-adjacent long username.
# Buggy base uses \b which treats _ as word char → 'alice' inside
# 'config_alice_settings' is NOT replaced. Fix uses lookarounds.
f2p 0.15 "underscore_adjacent" "
from dataclaw.anonymizer import anonymize_text
r = anonymize_text('config_alice_settings = True', 'alice', 'HASH')
assert 'alice' not in r and 'HASH' in r, r
print('PASS')
"

# F2P-2 (0.00): underscore prefix — actually P2P (passes on buggy base too).
f2p 0.00 "underscore_prefix" "
from dataclaw.anonymizer import _replace_username
r = _replace_username('Found in _alice folder', 'alice', 'HASH')
assert 'alice' not in r.lower() and 'HASH' in r, r
print('PASS')
"

# F2P-3 (0.10): substring safety — 'alex' must not match inside 'alexis'.
# Buggy base may use str.replace for _replace_username → corrupts 'alexis'.
f2p 0.10 "substring_safety" "
from dataclaw.anonymizer import _replace_username
r1 = _replace_username('alexis is a good name', 'alex', 'HASH')
assert 'alexis' in r1, 'r1=' + r1
print('PASS')
"

# F2P-4 (0.10): case-insensitive long username via _replace_username.
# Buggy windows branch dropped re.IGNORECASE.
f2p 0.10 "case_insensitive" "
from dataclaw.anonymizer import _replace_username
r = _replace_username('Hello ALICE and Alice', 'alice', 'HASH')
assert 'ALICE' not in r and 'Alice' not in r, r
assert r.count('HASH') == 2, r
print('PASS')
"

# F2P-5 (0.15): Windows backslash path, short username.
# Buggy base only handles forward slashes / hyphens — \\Users\\bo\\ stays.
f2p 0.15 "windows_backslash_short" "
from dataclaw.anonymizer import anonymize_text
r = anonymize_text(r'C:\\Users\\bo\\Documents\\file.txt', 'bo', 'HASH')
assert 'HASH' in r, r
low = r.lower()
assert '\\\\users\\\\bo\\\\' not in low and '\\\\users\\\\bo' not in low.split('\\\\documents')[0]+'\\\\', r
print('PASS')
"

# F2P-6 (0.15): Custom home directory for short username.
# Buggy base only matches /Users/<name>/ or /home/<name>/ patterns.
f2p 0.15 "custom_home_short" "
from dataclaw.anonymizer import anonymize_text
r = anonymize_text('/opt/data/joe/project/file.py', 'joe', 'HASH', home='/opt/data/joe')
assert 'joe' not in r and 'HASH' in r, r
print('PASS')
"

# F2P-7 (0.00): Anonymizer end-to-end — actually P2P (buggy str.replace also replaces extras).
f2p 0.00 "anonymizer_extras_underscore" "
import dataclaw.anonymizer as mod
from dataclaw.anonymizer import Anonymizer, _hash_username
mod._detect_home_dir = lambda: ('/Users/owner', 'owner')
a = Anonymizer(extra_usernames=['alice', 'bob'])
out = a.text('hi alice and config_bob_settings, plus owner')
assert 'alice' not in out, out
assert 'bob' not in out, out
assert 'owner' not in out, out
assert _hash_username('alice') in out
assert _hash_username('bob') in out
print('PASS')
"

# F2P-8 (0.00): regex caching — actually P2P (Python's internal re._cache masks the bug).
f2p 0.00 "compile_caching" "
import re
import dataclaw.anonymizer as mod
mod._detect_home_dir = lambda: ('/Users/alice', 'alice')

from dataclaw.anonymizer import Anonymizer, anonymize_text

# Warm up so any one-time compilation is done.
a = Anonymizer(extra_usernames=['bob', 'carol'])
a.text('hello alice and bob')
anonymize_text('hi alice', 'alice', 'HASH')
anonymize_text('/Users/bo/x', 'bo', 'HASH')

orig = re.compile
counter = {'n': 0}
def spy(*args, **kwargs):
    counter['n'] += 1
    return orig(*args, **kwargs)
re.compile = spy
try:
    for _ in range(50):
        a.text('alice did something with bob and carol in /Users/alice/x')
        anonymize_text('the user alice came by', 'alice', 'HASH')
        anonymize_text('/Users/bo/file', 'bo', 'HASH')
finally:
    re.compile = orig

# Allow a tiny constant; reject linear-in-N recompilation.
assert counter['n'] <= 5, 'compile count too high: ' + str(counter['n'])
print('PASS')
"

# ---------------------------------------------------------------
# Finalize. Correct F2P: 0.15+0.00+0.10+0.10+0.15+0.15+0.00+0.00 = 0.65
# Upstream F2P adds up to 0.40 via tail script, total capped at 1.0.
# ---------------------------------------------------------------
REWARD=$(awk -v s="$SCORE" 'BEGIN{ if (s>1.0) s=1.0; printf "%.4f", s }')
log "Final reward: $REWARD"
echo "$REWARD" > "$REWARD_FILE"

# ---- inner-claude upstream gates ----
log "--- Upstream gates ---"
GATES_FILE="/logs/verifier/gates.json"
> "$GATES_FILE" 2>/dev/null || true

# F2P: case-insensitive long username matching
if python3 -c "from dataclaw.anonymizer import anonymize_text; r = anonymize_text('Hello Alice!', 'alice', 'HASH'); assert 'Alice' not in r and 'HASH' in r" 2>/dev/null; then
    echo '{"id": "f2p_upstream_case_insensitive", "passed": true, "detail": "case-insensitive replacement works"}' >> "$GATES_FILE"
    log "  upstream f2p_upstream_case_insensitive: PASS"
else
    echo '{"id": "f2p_upstream_case_insensitive", "passed": false, "detail": "case-insensitive replacement failed"}' >> "$GATES_FILE"
    log "  upstream f2p_upstream_case_insensitive: FAIL"
fi

# F2P: substring safety in _replace_username
if python3 -c "from dataclaw.anonymizer import _replace_username; r = _replace_username('alexis is here', 'alex', 'HASH'); assert r == 'alexis is here'" 2>/dev/null; then
    echo '{"id": "f2p_upstream_substring_safety", "passed": true, "detail": "substring safety preserved"}' >> "$GATES_FILE"
    log "  upstream f2p_upstream_substring_safety: PASS"
else
    echo '{"id": "f2p_upstream_substring_safety", "passed": false, "detail": "substring replacement corrupted alexis"}' >> "$GATES_FILE"
    log "  upstream f2p_upstream_substring_safety: FAIL"
fi

# P2P: basic anonymize_text and hash functionality
if python3 -c "from dataclaw.anonymizer import anonymize_text, _hash_username; assert anonymize_text('hello alice', 'alice', 'HASH') == 'hello HASH'; assert _hash_username('test').startswith('user_')" 2>/dev/null; then
    echo '{"id": "p2p_upstream_basic_functionality", "passed": true, "detail": "basic functionality intact"}' >> "$GATES_FILE"
    log "  upstream p2p_upstream_basic_functionality: PASS"
else
    echo '{"id": "p2p_upstream_basic_functionality", "passed": false, "detail": "basic functionality broken"}' >> "$GATES_FILE"
    log "  upstream p2p_upstream_basic_functionality: FAIL"
fi

# P2P: import all public symbols
if python3 -c "from dataclaw.anonymizer import anonymize_text, anonymize_path, Anonymizer, _hash_username, _replace_username" 2>/dev/null; then
    echo '{"id": "p2p_upstream_import", "passed": true, "detail": "all symbols importable"}' >> "$GATES_FILE"
    log "  upstream p2p_upstream_import: PASS"
else
    echo '{"id": "p2p_upstream_import", "passed": false, "detail": "import failed"}' >> "$GATES_FILE"
    log "  upstream p2p_upstream_import: FAIL"
fi

# Run upstream reward tail
python3 /workspace/task/upstream_reward_tail.py 2>&1 | tee -a "$LOGFILE"
# ---- end ----