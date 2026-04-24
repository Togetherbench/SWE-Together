#!/bin/bash
# Verifier for dataclaw anonymizer task
# Tests behavioral correctness of bug fixes and optimizations
set +e

REWARD_FILE="/logs/verifier/reward.txt"
LOGFILE="/logs/verifier/details.txt"
mkdir -p /logs/verifier
chmod 777 /logs/verifier 2>/dev/null || true

SCORE=0
TOTAL=100

log() {
    echo "$1" | tee -a "$LOGFILE" 2>/dev/null || echo "$1"
}

> "$LOGFILE" 2>/dev/null || true
log "=== Verifier Start ==="

cd /workspace/repo

# ---------------------------------------------------------------
# P2P Gate: code must be importable (passes on unmodified base AND fixed code)
# Weight: 0 (gate only — if this fails, nothing else can run)
# ---------------------------------------------------------------
log "--- P2P Gate: import check ---"
if ! python3 -c "from dataclaw.anonymizer import anonymize_text, anonymize_path, Anonymizer, _replace_username, _hash_username" 2>&1; then
    log "FATAL: Cannot import anonymizer"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi
log "  Gate: PASS"

# ---------------------------------------------------------------
# P2P Test: hash function determinism (passes on base AND fixed code)
# Weight: 5 points
# ---------------------------------------------------------------
log "--- P2P: _hash_username determinism ---"
RESULT=$(python3 -c "
from dataclaw.anonymizer import _hash_username
h1 = _hash_username('alice')
h2 = _hash_username('alice')
h3 = _hash_username('bob')
if h1 == h2 and h1 != h3 and h1.startswith('user_') and len(h1) == 13:
    print('PASS')
else:
    print('FAIL')
" 2>&1)
if echo "$RESULT" | grep -q "^PASS"; then
    SCORE=$((SCORE + 5))
    log "  P2P: PASS (+5)"
else
    log "  P2P: FAIL ($RESULT)"
fi

# ---------------------------------------------------------------
# P2P Test: basic long-username path anonymization (passes on both)
# Weight: 5 points
# ---------------------------------------------------------------
log "--- P2P: basic long username path ---"
RESULT=$(python3 -c "
from dataclaw.anonymizer import anonymize_text
r = anonymize_text('File at /Users/alice/project/main.py', 'alice', 'HASH')
if 'alice' not in r and 'HASH' in r:
    print('PASS')
else:
    print('FAIL: ' + r)
" 2>&1)
if echo "$RESULT" | grep -q "^PASS"; then
    SCORE=$((SCORE + 5))
    log "  P2P: PASS (+5)"
else
    log "  P2P: FAIL ($RESULT)"
fi

# ---------------------------------------------------------------
# F2P T1: Word boundary fix — underscore-adjacent username (12 points)
# Bug: \b treats underscore as word char, so \balice\b fails between underscores
# ---------------------------------------------------------------
log "--- F2P T1: Word boundary (underscore-adjacent) ---"
RESULT=$(python3 -c "
from dataclaw.anonymizer import anonymize_text
r = anonymize_text('config_alice_settings = True', 'alice', 'HASH')
if 'alice' not in r and 'HASH' in r:
    print('PASS')
else:
    print('FAIL: ' + r)
" 2>&1)
if echo "$RESULT" | grep -q "^PASS"; then
    SCORE=$((SCORE + 12))
    log "  F2P T1: PASS (+12)"
else
    log "  F2P T1: FAIL ($RESULT)"
fi

# ---------------------------------------------------------------
# F2P T2: Word boundary fix — underscore prefix (8 points)
# ---------------------------------------------------------------
log "--- F2P T2: Word boundary (underscore prefix) ---"
RESULT=$(python3 -c "
from dataclaw.anonymizer import anonymize_text
r = anonymize_text('Found in _alice folder', 'alice', 'HASH')
if 'alice' not in r.lower() and 'HASH' in r:
    print('PASS')
else:
    print('FAIL: ' + r)
" 2>&1)
if echo "$RESULT" | grep -q "^PASS"; then
    SCORE=$((SCORE + 8))
    log "  F2P T2: PASS (+8)"
else
    log "  F2P T2: FAIL ($RESULT)"
fi

# ---------------------------------------------------------------
# F2P T3: Windows backslash path for short username (12 points)
# Bug: only /Users/ is handled, not \Users\ for short usernames
# ---------------------------------------------------------------
log "--- F2P T3: Windows backslash (short username) ---"
RESULT=$(python3 -c "
from dataclaw.anonymizer import anonymize_text
r = anonymize_text(r'C:\Users\bo\Documents\file.txt', 'bo', 'HASH')
if 'HASH' in r:
    print('PASS')
else:
    print('FAIL: ' + r)
" 2>&1)
if echo "$RESULT" | grep -q "^PASS"; then
    SCORE=$((SCORE + 12))
    log "  F2P T3: PASS (+12)"
else
    log "  F2P T3: FAIL ($RESULT)"
fi

# ---------------------------------------------------------------
# F2P T4: _replace_username uses word boundaries (10 points)
# Bug: substring match replaces "alex" inside "alexis"
# ---------------------------------------------------------------
log "--- F2P T4: _replace_username boundaries ---"
RESULT=$(python3 -c "
from dataclaw.anonymizer import _replace_username
r1 = _replace_username('alexis is a good name', 'alex', 'HASH')
r2 = _replace_username('Hello alex, hi Alex!', 'alex', 'HASH')
# Accept any approach that preserves 'alexis' and replaces standalone 'alex'
if 'alexis' in r1 and 'HASH' in r2:
    print('PASS')
else:
    print('FAIL: r1=' + str(r1) + ' r2=' + str(r2))
" 2>&1)
if echo "$RESULT" | grep -q "^PASS"; then
    SCORE=$((SCORE + 10))
    log "  F2P T4: PASS (+10)"
else
    log "  F2P T4: FAIL ($RESULT)"
fi

# ---------------------------------------------------------------
# F2P T5a: Regex compilation — basic use of re.compile (6 points)
# ---------------------------------------------------------------
log "--- F2P T5a: Regex compilation (basic) ---"
RESULT=$(python3 -c "
import inspect
import dataclaw.anonymizer as mod
from dataclaw.anonymizer import anonymize_text

# First verify correctness
r = anonymize_text('Hello alice in /Users/alice/dir', 'alice', 'HASH')
if 'alice' in r:
    print('FAIL: broken after refactor: ' + r)
else:
    source = inspect.getsource(mod)
    if 're.compile' in source or 'lru_cache' in source or 'functools.cache' in source:
        print('PASS')
    else:
        print('FAIL: no regex compilation found')
" 2>&1)
if echo "$RESULT" | grep -q "^PASS"; then
    SCORE=$((SCORE + 6))
    log "  F2P T5a: PASS (+6)"
else
    log "  F2P T5a: FAIL ($RESULT)"
fi

# ---------------------------------------------------------------
# F2P T5b: Regex caching — patterns cached across calls (15 points)
# ---------------------------------------------------------------
log "--- F2P T5b: Regex caching (performance) ---"
RESULT=$(python3 -c "
import inspect, re as re_mod
import dataclaw.anonymizer as mod

source = inspect.getsource(mod)
# Check for genuine caching: lru_cache decorator, functools.cache, module-level Pattern,
# or a dict cache storing compiled patterns
has_caching = (
    'lru_cache' in source
    or 'functools.cache' in source
    or bool(re_mod.search(r'^_\w+\s*[=:]\s*re\.compile', source, re_mod.MULTILINE))
    or bool(re_mod.search(r'_\w+_cache', source, re_mod.IGNORECASE))
)
if has_caching:
    print('PASS')
else:
    print('FAIL: patterns compiled but not cached across calls')
" 2>&1)
if echo "$RESULT" | grep -q "^PASS"; then
    SCORE=$((SCORE + 15))
    log "  F2P T5b: PASS (+15)"
else
    log "  F2P T5b: FAIL ($RESULT)"
fi

# ---------------------------------------------------------------
# F2P T6: Custom home directory for short username (12 points)
# Bug: home parameter is accepted but never used for non-standard homes
# ---------------------------------------------------------------
log "--- F2P T6: Custom home directory ---"
RESULT=$(python3 -c "
from dataclaw.anonymizer import anonymize_text
r = anonymize_text('/opt/data/joe/project/file.py', 'joe', 'HASH', home='/opt/data/joe')
if 'joe' not in r and 'HASH' in r:
    print('PASS')
else:
    print('FAIL: ' + r)
" 2>&1)
if echo "$RESULT" | grep -q "^PASS"; then
    SCORE=$((SCORE + 12))
    log "  F2P T6: PASS (+12)"
else
    log "  F2P T6: FAIL ($RESULT)"
fi

# ---------------------------------------------------------------
# F2P T7: Windows mixed-case path for short username (15 points)
# Tests case-insensitive matching of \USERS\ pattern
# ---------------------------------------------------------------
log "--- F2P T7: Windows mixed-case path ---"
RESULT=$(python3 -c "
from dataclaw.anonymizer import anonymize_text
r = anonymize_text(r'File at C:\USERS\bo\docs\report.txt', 'bo', 'HASH')
if 'HASH' in r:
    print('PASS')
else:
    print('FAIL: ' + r)
" 2>&1)
if echo "$RESULT" | grep -q "^PASS"; then
    SCORE=$((SCORE + 15))
    log "  F2P T7: PASS (+15)"
else
    log "  F2P T7: FAIL ($RESULT)"
fi

# ---------------------------------------------------------------
# Calculate final reward
# ---------------------------------------------------------------
log "=== Final Score: $SCORE / $TOTAL ==="
REWARD=$(python3 -c "print(round($SCORE / $TOTAL, 2))")
log "Reward: $REWARD"
echo "$REWARD" > "$REWARD_FILE"
