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

# Locate the repo
REPO=""
for cand in /workspace/repo /workspace/repo /workspace/repo-anonymizer; do
    if [ -d "$cand" ] && [ -f "$cand/dataclaw/anonymizer.py" ]; then
        REPO="$cand"
        break
    fi
done
if [ -z "$REPO" ]; then
    REPO=$(find /workspace -maxdepth 3 -type f -name "anonymizer.py" -path "*/dataclaw/*" 2>/dev/null | head -n1 | xargs -I{} dirname {} 2>/dev/null | xargs -I{} dirname {} 2>/dev/null)
fi
if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then
    log "FATAL: could not locate repo"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi
cd "$REPO"
log "Using repo: $REPO"

SCORE=0
TOTAL=100

run_py() {
    python3 -c "$1" 2>&1
}

# ---------------------------------------------------------------
# Gate: importable
# ---------------------------------------------------------------
log "--- Gate: import ---"
if ! run_py "from dataclaw.anonymizer import anonymize_text, anonymize_path, Anonymizer, _replace_username, _hash_username" >/dev/null 2>&1; then
    log "FATAL: cannot import core symbols"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi
log "  Gate: PASS"

# Helper: award points if python snippet prints PASS
award() {
    local pts="$1"
    local name="$2"
    local code="$3"
    local out
    out=$(run_py "$code")
    if echo "$out" | grep -q "^PASS$"; then
        SCORE=$((SCORE + pts))
        log "  $name: PASS (+$pts)"
    else
        log "  $name: FAIL"
        log "    $out"
    fi
}

# ---------------------------------------------------------------
# P2P (regression guards) — 15 points
# ---------------------------------------------------------------
log "--- P2P: hash determinism (5) ---"
award 5 "P2P hash" "
from dataclaw.anonymizer import _hash_username
h1 = _hash_username('alice'); h2 = _hash_username('alice'); h3 = _hash_username('bob')
assert h1 == h2 and h1 != h3
assert h1.startswith('user_') and len(h1) == 13
print('PASS')
"

log "--- P2P: long username basic (5) ---"
award 5 "P2P long basic" "
from dataclaw.anonymizer import anonymize_text
r = anonymize_text('File at /Users/alice/project/main.py', 'alice', 'HASH')
assert 'alice' not in r and 'HASH' in r, r
print('PASS')
"

log "--- P2P: short username posix path (5) ---"
award 5 "P2P short posix" "
from dataclaw.anonymizer import anonymize_text
r = anonymize_text('/Users/bo/file.py', 'bo', 'HASH')
assert 'HASH' in r, r
# bo should be replaced in path context
assert '/Users/bo/' not in r, r
print('PASS')
"

# ---------------------------------------------------------------
# F2P Behavioral (60 points total)
# ---------------------------------------------------------------

# T1: word boundary, underscore-adjacent (10)
log "--- F2P T1: underscore-adjacent (10) ---"
award 10 "F2P T1" "
from dataclaw.anonymizer import anonymize_text
r = anonymize_text('config_alice_settings = True', 'alice', 'HASH')
assert 'alice' not in r and 'HASH' in r, r
print('PASS')
"

# T2: word boundary, underscore prefix (5)
log "--- F2P T2: underscore prefix (5) ---"
award 5 "F2P T2" "
from dataclaw.anonymizer import anonymize_text
r = anonymize_text('Found in _alice folder', 'alice', 'HASH')
assert 'alice' not in r.lower() and 'HASH' in r, r
print('PASS')
"

# T3: substring safety - 'alex' must not match inside 'alexis' (10)
log "--- F2P T3: substring safety (10) ---"
award 10 "F2P T3" "
from dataclaw.anonymizer import _replace_username
r1 = _replace_username('alexis is a good name', 'alex', 'HASH')
r2 = _replace_username('Hello alex, hi Alex!', 'alex', 'HASH')
assert 'alexis' in r1, 'r1=' + r1
assert 'HASH' in r2, 'r2=' + r2
# both 'alex' and 'Alex' should be replaced (case-insensitive)
assert 'alex' not in r2.lower() or r2.count('HASH') == 2, 'r2=' + r2
print('PASS')
"

# T4: case-insensitive long username (5)
log "--- F2P T4: case-insensitive long (5) ---"
award 5 "F2P T4" "
from dataclaw.anonymizer import _replace_username
r = _replace_username('Hello ALICE and Alice', 'alice', 'HASH')
assert 'ALICE' not in r and 'Alice' not in r, r
assert r.count('HASH') == 2, r
print('PASS')
"

# T5: Windows backslash path for short username (10)
log "--- F2P T5: windows backslash short (10) ---"
award 10 "F2P T5" "
from dataclaw.anonymizer import anonymize_text
r = anonymize_text(r'C:\\Users\\bo\\Documents\\file.txt', 'bo', 'HASH')
assert 'HASH' in r, r
assert '\\\\Users\\\\bo\\\\' not in r and '\\\\users\\\\bo\\\\' not in r.lower(), r
print('PASS')
"

# T6: Custom home directory for short username (10)
log "--- F2P T6: custom home short (10) ---"
award 10 "F2P T6" "
from dataclaw.anonymizer import anonymize_text
r = anonymize_text('/opt/data/joe/project/file.py', 'joe', 'HASH', home='/opt/data/joe')
assert 'joe' not in r and 'HASH' in r, r
print('PASS')
"

# T7: Anonymizer class end-to-end with extras and underscore-adjacent (10)
log "--- F2P T7: Anonymizer extras + underscore (10) ---"
award 10 "F2P T7" "
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

# ---------------------------------------------------------------
# F2P Performance / Caching (15 points)
# ---------------------------------------------------------------

# T8: Patterns are cached across calls — measure call count via re.compile spy (8)
log "--- F2P T8: re.compile not called per text() (8) ---"
award 8 "F2P T8" "
import re
import dataclaw.anonymizer as mod
mod._detect_home_dir = lambda: ('/Users/alice', 'alice')

from dataclaw.anonymizer import Anonymizer, anonymize_text

# Warm up (let module-level / lru_cache compilation happen)
a = Anonymizer(extra_usernames=['bob', 'carol'])
a.text('hello alice and bob')
anonymize_text('hi alice', 'alice', 'HASH')

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
finally:
    re.compile = orig

# Tolerate a small constant; reject linear-in-N recompilation.
assert counter['n'] <= 5, 'compile count too high: ' + str(counter['n'])
print('PASS')
"

# T9: lru_cache or module-level compiled pattern present (4)
log "--- F2P T9: caching mechanism present (4) ---"
award 4 "F2P T9" "
import inspect, re as rmod
import dataclaw.anonymizer as mod
src = inspect.getsource(mod)
has = ('lru_cache' in src
       or 'functools.cache' in src
       or bool(rmod.search(r'^_\w+\s*=\s*re\.compile', src, rmod.MULTILINE)))
assert has, 'no caching mechanism detected'
print('PASS')
"

# T10: Performance smoke — 200 calls finishes promptly (3)
log "--- F2P T10: perf smoke (3) ---"
award 3 "F2P T10" "
import time
import dataclaw.anonymizer as mod
mod._detect_home_dir = lambda: ('/Users/alice', 'alice')
from dataclaw.anonymizer import Anonymizer
a = Anonymizer(extra_usernames=['bob','carol','dave'])
t0 = time.time()
for _ in range(500):
    a.text('alice and bob met carol at /Users/alice/proj/file.py with dave')
dt = time.time() - t0
assert dt < 2.0, 'too slow: ' + str(dt)
print('PASS')
"

# ---------------------------------------------------------------
# Structural / repo health (10 points)
# ---------------------------------------------------------------

# S1: re.compile actually used in source (3)
log "--- S1: re.compile in source (3) ---"
award 3 "S1" "
import inspect, dataclaw.anonymizer as mod
assert 're.compile' in inspect.getsource(mod)
print('PASS')
"

# S2: existing repo tests still pass (7)
log "--- S2: repo pytest (7) ---"
if [ -d "tests" ] || [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
    PYTEST_OUT=$(python3 -m pytest -x -q --no-header 2>&1)
    PYTEST_RC=$?
    if [ $PYTEST_RC -eq 0 ]; then
        SCORE=$((SCORE + 7))
        log "  S2: PASS (+7)"
    else
        # partial credit if most tests pass
        FAILED=$(echo "$PYTEST_OUT" | grep -oE "[0-9]+ failed" | head -n1 | grep -oE "[0-9]+")
        PASSED=$(echo "$PYTEST_OUT" | grep -oE "[0-9]+ passed" | head -n1 | grep -oE "[0-9]+")
        FAILED=${FAILED:-0}
        PASSED=${PASSED:-0}
        TOTAL_T=$((FAILED + PASSED))
        if [ "$TOTAL_T" -gt 0 ] && [ "$PASSED" -gt 0 ]; then
            # Award proportional, capped at 5 for non-clean
            PARTIAL=$(awk -v p="$PASSED" -v t="$TOTAL_T" 'BEGIN{printf "%d", (p/t)*5}')
            SCORE=$((SCORE + PARTIAL))
            log "  S2: PARTIAL (+$PARTIAL) [$PASSED/$TOTAL_T]"
        else
            log "  S2: FAIL"
            log "$PYTEST_OUT" | tail -n 30
        fi
    fi
else
    SCORE=$((SCORE + 7))
    log "  S2: no tests dir, skipping (+7)"
fi

# ---------------------------------------------------------------
# Final
# ---------------------------------------------------------------
log "Score: $SCORE / $TOTAL"
REWARD=$(awk -v s="$SCORE" -v t="$TOTAL" 'BEGIN{printf "%.3f", s/t}')
log "Reward: $REWARD"
echo "$REWARD" > "$REWARD_FILE"
exit 0