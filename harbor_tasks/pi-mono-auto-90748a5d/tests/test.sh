#!/bin/bash
# Verifier for PR review task (pi-mono PR #1112)
# Evaluates the quality of a structured code review output
#
# Gate classification:
#   P2P = pass-to-pass (passes on unmodified base AND on correct fix)
#   F2P = fail-to-pass (should fail on empty/nop agent, pass on good review)
set +e

REWARD_FILE="/logs/verifier/reward.txt"
OUTPUT_FILE="/workspace/agent_output.json"
TEXT_FILE="/tmp/review_text.txt"

mkdir -p /logs/verifier

##############################
# Extract agent output text
##############################
if [ ! -f "$OUTPUT_FILE" ]; then
    echo "No agent output found at $OUTPUT_FILE"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# Try to extract 'result' field from JSON; fall back to raw text (node execution gate)
if command -v node &>/dev/null; then
    node -e "
      const fs = require('fs');
      try {
        const d = JSON.parse(fs.readFileSync('$OUTPUT_FILE', 'utf8'));
        process.stdout.write(typeof d.result === 'string' ? d.result : JSON.stringify(d));
      } catch(e) {
        process.stdout.write(fs.readFileSync('$OUTPUT_FILE', 'utf8'));
      }
    " > "$TEXT_FILE" 2>/dev/null
else
    cp "$OUTPUT_FILE" "$TEXT_FILE"
fi

# Fallback if extraction produced empty file
if [ ! -s "$TEXT_FILE" ]; then
    cp "$OUTPUT_FILE" "$TEXT_FILE"
fi

# Show preview
echo "=== Review preview (first 800 chars) ==="
head -c 800 "$TEXT_FILE"
echo ""
echo "=== End preview ==="
echo ""

# Also check for any git changes the agent made
echo "=== Git changes ==="
cd /workspace/pi-mono 2>/dev/null && git diff --stat 2>/dev/null || echo "(no repo changes)"
echo ""

##############################
# Scoring — all gates use node -e execution
##############################
TOTAL=0
PASSED=0

##############################
# Gate 1 (P2P): Repo clone is intact — pi-mono exists with expected files
# Passes on unmodified base AND after correct agent work
# Weight: 2
##############################
G1_WEIGHT=2
TOTAL=$((TOTAL + G1_WEIGHT))
G1_RESULT=$(node -e "
const fs = require('fs');
const repoExists = fs.existsSync('/workspace/pi-mono/package.json');
const hasPackages = fs.existsSync('/workspace/pi-mono/packages');
console.log(repoExists && hasPackages ? 'PASS' : 'FAIL');
" 2>/dev/null)
if [ "$G1_RESULT" = "PASS" ]; then
    echo "PASS [w=$G1_WEIGHT] (P2P): Repo clone intact with expected structure"
    PASSED=$((PASSED + G1_WEIGHT))
else
    echo "FAIL [w=$G1_WEIGHT] (P2P): Repo structure missing or corrupted"
fi

##############################
# Gate 2 (F2P): Review output is substantial and contains required sections
# Uses node -e to programmatically validate structure
# Weight: 3
##############################
G2_WEIGHT=3
TOTAL=$((TOTAL + G2_WEIGHT))
G2_RESULT=$(node -e "
const fs = require('fs');
try {
    const text = fs.readFileSync('$TEXT_FILE', 'utf8');
    if (text.length < 200) { console.log(0); process.exit(0); }
    let score = 0;
    const requiredSections = ['Good:', 'Bad:', 'Ugly:'];
    const optionalSections = ['Change summary', 'Changelog', 'Tests:'];
    const reqFound = requiredSections.filter(s => text.toLowerCase().includes(s.toLowerCase())).length;
    const optFound = optionalSections.filter(s => text.toLowerCase().includes(s.toLowerCase())).length;
    if (reqFound >= 3) score += 1;
    if (optFound >= 2) score += 1;
    if (/github\.com\/badlogic\/pi-mono\/pull\/1112/i.test(text)) score += 1;
    console.log(score);
} catch(e) { console.log(0); }
" 2>/dev/null)
G2_RESULT=${G2_RESULT:-0}
if [ "$G2_RESULT" -ge 3 ]; then
    echo "PASS [w=$G2_WEIGHT] (F2P): Review has all required sections + PR URL"
    PASSED=$((PASSED + G2_WEIGHT))
elif [ "$G2_RESULT" -ge 2 ]; then
    echo "PARTIAL [w=$G2_WEIGHT] (F2P): Review has most sections ($G2_RESULT/3)"
    PASSED=$((PASSED + G2_WEIGHT * 2 / 3))
else
    echo "FAIL [w=$G2_WEIGHT] (F2P): Review missing required sections"
fi

##############################
# Gate 3 (F2P): Technical content — identifies key PR aspects
# BMP, clipboard, WSL/Wayland, PNG, conversion, issue #1109, contributor
# Weight: 4
##############################
G3_WEIGHT=4
TOTAL=$((TOTAL + G3_WEIGHT))
G3_RESULT=$(node -e "
const fs = require('fs');
try {
    const text = fs.readFileSync('$TEXT_FILE', 'utf8');
    let hits = 0;
    const checks = [
        /\bbmp\b|bitmap/i,
        /clipboard/i,
        /wsl|wayland/i,
        /\bpng\b/i,
        /convert|conversion/i,
        /1109/,
        /lightningRalf|lightning.?Ralf/i,
    ];
    for (const rx of checks) { if (rx.test(text)) hits++; }
    console.log(hits);
} catch(e) { console.log(0); }
" 2>/dev/null)
G3_RESULT=${G3_RESULT:-0}
if [ "$G3_RESULT" -ge 6 ]; then
    echo "PASS [w=$G3_WEIGHT] (F2P): Technical content covers key PR aspects ($G3_RESULT/7)"
    PASSED=$((PASSED + G3_WEIGHT))
elif [ "$G3_RESULT" -ge 4 ]; then
    echo "PARTIAL [w=$G3_WEIGHT] (F2P): Partial technical content ($G3_RESULT/7)"
    PASSED=$((PASSED + G3_WEIGHT / 2))
else
    echo "FAIL [w=$G3_WEIGHT] (F2P): Insufficient technical content ($G3_RESULT/7)"
fi

##############################
# Gate 4 (F2P): Identifies base64 round-trip or encoding overhead
# Weight: 3
##############################
G4_WEIGHT=3
TOTAL=$((TOTAL + G4_WEIGHT))
G4_RESULT=$(node -e "
const fs = require('fs');
try {
    const text = fs.readFileSync('$TEXT_FILE', 'utf8');
    const patterns = [
        /base64.{0,40}round.?trip/i,
        /unnecessary.{0,30}base64/i,
        /needless.{0,30}base64/i,
        /encode.{0,60}decode.{0,40}(again|cycle|redundant|unnecessary|inefficien)/i,
        /base64.{0,40}encod.{0,40}decod/i,
        /two.{0,20}base64/i,
        /double.{0,20}(base64|encod|conver)/i,
        /round.?trip.{0,30}(base64|encod)/i,
        /base64.{0,40}(back|again|twice|redundant)/i,
        /bytes.{0,30}base64.{0,30}(conver|back|bytes)/i,
    ];
    console.log(patterns.some(p => p.test(text)) ? 'PASS' : 'FAIL');
} catch(e) { console.log('FAIL'); }
" 2>/dev/null)
if [ "$G4_RESULT" = "PASS" ]; then
    echo "PASS [w=$G4_WEIGHT] (F2P): Identifies base64 round-trip inefficiency"
    PASSED=$((PASSED + G4_WEIGHT))
else
    echo "FAIL [w=$G4_WEIGHT] (F2P): Did not identify base64 round-trip inefficiency"
fi

##############################
# Gate 5 (F2P): Notes PR state (closed/not merged)
# Weight: 3
##############################
G5_WEIGHT=3
TOTAL=$((TOTAL + G5_WEIGHT))
G5_RESULT=$(node -e "
const fs = require('fs');
try {
    const text = fs.readFileSync('$TEXT_FILE', 'utf8');
    const patterns = [
        /closed.{0,30}(not |un|without )merged/i,
        /(not |un|wasn.t )merged/i,
        /PR.{0,20}(state|status).{0,30}closed/i,
        /closed.{0,40}(favor|different|approach|instead|replaced)/i,
        /was.{0,20}closed/i,
        /PR.{0,10}(is |was |has been )closed/i,
        /status.{0,10}closed/i,
    ];
    console.log(patterns.some(p => p.test(text)) ? 'PASS' : 'FAIL');
} catch(e) { console.log('FAIL'); }
" 2>/dev/null)
if [ "$G5_RESULT" = "PASS" ]; then
    echo "PASS [w=$G5_WEIGHT] (F2P): Notes PR state (closed, not merged)"
    PASSED=$((PASSED + G5_WEIGHT))
else
    echo "FAIL [w=$G5_WEIGHT] (F2P): Did not note PR state"
fi

##############################
# Gate 6 (F2P): Deep analysis — dead code or redundant guard
# Identifies that ?? "png" fallback or similar is now unreachable
# Weight: 7 (key depth discriminator)
##############################
G6_WEIGHT=7
TOTAL=$((TOTAL + G6_WEIGHT))
G6_RESULT=$(node -e "
const fs = require('fs');
try {
    const text = fs.readFileSync('$TEXT_FILE', 'utf8');
    const patterns = [
        /dead.?code/i,
        /redundant.{0,30}(guard|check|condition|if)/i,
        /second.{0,20}(guard|check|if).{0,40}(dead|redundant|unnecessary|unreachable)/i,
        /double.{0,20}(guard|check|if)/i,
        /never.{0,20}(reach|trigger|hit|execute)/i,
        /unreachable.{0,20}(code|branch|path)/i,
        /duplicate.{0,20}(check|guard|condition)/i,
        /now.{0,20}(redundant|unreachable|dead|unnecessary)/i,
    ];
    console.log(patterns.some(p => p.test(text)) ? 'PASS' : 'FAIL');
} catch(e) { console.log('FAIL'); }
" 2>/dev/null)
if [ "$G6_RESULT" = "PASS" ]; then
    echo "PASS [w=$G6_WEIGHT] (F2P): Identifies dead code or redundant guard"
    PASSED=$((PASSED + G6_WEIGHT))
else
    echo "FAIL [w=$G6_WEIGHT] (F2P): Did not identify dead code or redundant guard"
fi

##############################
# Gate 7 (F2P): Deep analysis — silent failure / removed warning concern
# When Photon is unavailable, user gets no feedback (warning was removed
# during refactoring). Requires reading both the PR diff and final code.
# Weight: 7 (key depth discriminator)
##############################
G7_WEIGHT=7
TOTAL=$((TOTAL + G7_WEIGHT))
G7_RESULT=$(node -e "
const fs = require('fs');
try {
    const text = fs.readFileSync('$TEXT_FILE', 'utf8');
    const patterns = [
        /silent(ly)?.{0,30}(fail|swallow|return|drop|discard|ignore)/i,
        /user.{0,30}sees? nothing/i,
        /user.{0,30}no (feedback|indication|notification|message)/i,
        /user.{0,30}gets? (zero|no) feedback/i,
        /(removed|lost|dropped|omitted).{0,30}warning/i,
        /warning.{0,30}(removed|lost|dropped|omitted|replaced|gone)/i,
        /swallow.{0,30}(error|failure|null|it)/i,
        /return.{0,10}null.{0,30}(no|without).{0,20}(warning|feedback|message)/i,
        /no.{0,10}(user.?facing|user ).{0,10}(feedback|indication|message|error)/i,
        /zero feedback/i,
        /invisible.{0,10}(to the |to )user/i,
    ];
    console.log(patterns.some(p => p.test(text)) ? 'PASS' : 'FAIL');
} catch(e) { console.log('FAIL'); }
" 2>/dev/null)
if [ "$G7_RESULT" = "PASS" ]; then
    echo "PASS [w=$G7_WEIGHT] (F2P): Identifies silent failure / removed warning concern"
    PASSED=$((PASSED + G7_WEIGHT))
else
    echo "FAIL [w=$G7_WEIGHT] (F2P): Did not identify silent failure concern"
fi

##############################
# Gate 8 (F2P): Photon library + dependency context + changelog
# Weight: 4
##############################
G8_WEIGHT=4
TOTAL=$((TOTAL + G8_WEIGHT))
G8_RESULT=$(node -e "
const fs = require('fs');
try {
    const text = fs.readFileSync('$TEXT_FILE', 'utf8');
    let score = 0;
    // Mentions photon library
    if (/photon|@silvia-odwyer|photon[._-]node/i.test(text)) score++;
    // Dependency context
    const depPats = [
        /no new.{0,20}depend/i,
        /existing.{0,30}depend/i,
        /already.{0,30}(depend|present|available|included)/i,
        /reuse|re-?uses?/i,
        /not.{0,20}add.{0,20}(a |any )?new/i,
        /already.{0,20}(uses?|using|has|have)/i,
        /existing.{0,30}(photon|library|infra|util)/i,
        /leverag/i,
    ];
    if (depPats.some(p => p.test(text))) score++;
    // Changelog missing
    const clPats = [
        /missing.{0,30}changelog/i,
        /changelog.{0,30}missing/i,
        /no.{0,20}changelog.{0,20}entry/i,
        /changelog.{0,20}(required|needed|absent|not found)/i,
        /needs?.{0,20}changelog/i,
        /add.{0,20}changelog/i,
        /changelog.{0,30}(should|must|need)/i,
    ];
    if (clPats.some(p => p.test(text))) score++;
    console.log(score);
} catch(e) { console.log(0); }
" 2>/dev/null)
G8_RESULT=${G8_RESULT:-0}
if [ "$G8_RESULT" -ge 3 ]; then
    echo "PASS [w=$G8_WEIGHT] (F2P): Photon + dependency + changelog analysis"
    PASSED=$((PASSED + G8_WEIGHT))
elif [ "$G8_RESULT" -ge 2 ]; then
    echo "PARTIAL [w=$G8_WEIGHT] (F2P): Partial Photon/dep/changelog ($G8_RESULT/3)"
    PASSED=$((PASSED + G8_WEIGHT * 2 / 3))
elif [ "$G8_RESULT" -ge 1 ]; then
    echo "PARTIAL [w=$G8_WEIGHT] (F2P): Minimal Photon/dep/changelog ($G8_RESULT/3)"
    PASSED=$((PASSED + G8_WEIGHT / 3))
else
    echo "FAIL [w=$G8_WEIGHT] (F2P): Did not identify Photon/dep/changelog"
fi

##############################
# Gate 9 (F2P): Code-level details (interactive-mode.ts, ?? png fallback, AGENTS.md)
# Weight: 6 (depth discriminator)
##############################
G9_WEIGHT=6
TOTAL=$((TOTAL + G9_WEIGHT))
G9_RESULT=$(node -e "
const fs = require('fs');
try {
    const text = fs.readFileSync('$TEXT_FILE', 'utf8');
    let score = 0;
    // interactive-mode.ts identification
    if (/interactive[._-]mode\.ts/i.test(text)) score++;
    // ?? png fallback mechanism
    const fbPats = [
        /\?\?\s*['\"]?png['\"]?/i,
        /fallback.{0,20}(extension|ext|format).{0,30}png/i,
        /default.{0,20}(to |extension|format).{0,20}png/i,
        /png.{0,20}(fallback|default)/i,
    ];
    if (fbPats.some(p => p.test(text))) score++;
    // AGENTS.md reference
    if (/AGENTS\.md|agents\.md/i.test(text)) score++;
    console.log(score);
} catch(e) { console.log(0); }
" 2>/dev/null)
G9_RESULT=${G9_RESULT:-0}
if [ "$G9_RESULT" -ge 3 ]; then
    echo "PASS [w=$G9_WEIGHT] (F2P): Identifies code-level details ($G9_RESULT/3)"
    PASSED=$((PASSED + G9_WEIGHT))
elif [ "$G9_RESULT" -ge 2 ]; then
    echo "PARTIAL [w=$G9_WEIGHT] (F2P): Some code detail identification ($G9_RESULT/3)"
    PASSED=$((PASSED + G9_WEIGHT * 2 / 3))
elif [ "$G9_RESULT" -ge 1 ]; then
    echo "PARTIAL [w=$G9_WEIGHT] (F2P): Minimal code detail identification ($G9_RESULT/3)"
    PASSED=$((PASSED + G9_WEIGHT / 3))
else
    echo "FAIL [w=$G9_WEIGHT] (F2P): Did not identify code-level details"
fi

##############################
# Gate 10 (F2P): Missing test coverage for error/failure paths
# Identifies that tests only cover happy path, missing PowerShell/xclip/Photon-unavailable
# Weight: 6 (depth discriminator)
##############################
G10_WEIGHT=6
TOTAL=$((TOTAL + G10_WEIGHT))
G10_RESULT=$(node -e "
const fs = require('fs');
try {
    const text = fs.readFileSync('$TEXT_FILE', 'utf8');
    let score = 0;
    // Missing error/failure tests
    const testPats = [
        /no.{0,20}test.{0,40}(fail|error|unavailable|null)/i,
        /missing.{0,30}test/i,
        /test.{0,30}(miss|lack|absent)/i,
        /test.{0,30}(only|just|happy).{0,20}(path|case|success)/i,
        /no.{0,20}(unit |integration )?test.{0,20}(for|cover)/i,
        /untested/i,
    ];
    if (testPats.some(p => p.test(text))) score++;
    // Identifies specific missing test scenarios (powershell, xclip, photon unavailable)
    const specificPats = [
        /power.?shell.{0,30}(test|path|cover|miss)/i,
        /xclip.{0,30}(test|path|cover|miss)/i,
        /photon.{0,30}(unavailable|not loaded|fail|absent).{0,40}(test|path|cover)/i,
        /(test|path|cover).{0,40}photon.{0,30}(unavailable|not loaded|fail|absent)/i,
        /wsl.{0,30}(test|path|cover|miss)/i,
        /no test.{0,40}(photon|powershell|wsl|xclip)/i,
    ];
    if (specificPats.some(p => p.test(text))) score++;
    console.log(score);
} catch(e) { console.log(0); }
" 2>/dev/null)
G10_RESULT=${G10_RESULT:-0}
if [ "$G10_RESULT" -ge 2 ]; then
    echo "PASS [w=$G10_WEIGHT] (F2P): Notes missing test coverage with specific gaps"
    PASSED=$((PASSED + G10_WEIGHT))
elif [ "$G10_RESULT" -ge 1 ]; then
    echo "PARTIAL [w=$G10_WEIGHT] (F2P): Notes some test coverage gaps ($G10_RESULT/2)"
    PASSED=$((PASSED + G10_WEIGHT / 2))
else
    echo "FAIL [w=$G10_WEIGHT] (F2P): Did not note missing test coverage"
fi

##############################
# Gate 11 (F2P): Deep insight — get_bytes() implicit behavior or implementation divergence
# Identifies that get_bytes() returning PNG is undocumented, or that two
# convertToPng implementations diverge (EXIF orientation skipped), or
# WASM heap memory concern
# Weight: 6 (key depth discriminator — only strong models catch this)
##############################
G11_WEIGHT=6
TOTAL=$((TOTAL + G11_WEIGHT))
G11_RESULT=$(node -e "
const fs = require('fs');
try {
    const text = fs.readFileSync('$TEXT_FILE', 'utf8');
    const patterns = [
        /get_bytes.{0,40}(implicit|undocumented|non.obvious|assume|assumption)/i,
        /implicit.{0,30}(PNG|format|encod|behav)/i,
        /EXIF.{0,30}(orient|skip|miss|diverg)/i,
        /(orient|EXIF).{0,30}(skip|miss|diverg|absent|omit)/i,
        /two.{0,20}(convert|implementation).{0,30}(diverg|differ|inconsist)/i,
        /diverge.{0,30}(convert|implementation)/i,
        /(clipboard|second).{0,20}convert.{0,30}(skip|miss|lack|without)/i,
        /WASM.{0,20}(heap|memory|leak|free)/i,
        /memory.{0,20}(free|leak|dispose).{0,20}(finally|proper)/i,
        /PhotonImage.{0,30}(free|dispose|memory)/i,
        /finally.{0,20}(block|clause).{0,30}(free|clean|dispose)/i,
        /maintainab.{0,20}(hazard|risk|concern|issue)/i,
    ];
    console.log(patterns.some(p => p.test(text)) ? 'PASS' : 'FAIL');
} catch(e) { console.log('FAIL'); }
" 2>/dev/null)
if [ "$G11_RESULT" = "PASS" ]; then
    echo "PASS [w=$G11_WEIGHT] (F2P): Deep insight on implementation subtlety"
    PASSED=$((PASSED + G11_WEIGHT))
else
    echo "FAIL [w=$G11_WEIGHT] (F2P): Did not identify implementation subtlety"
fi

##############################
# Compute reward
##############################
if [ "$TOTAL" -gt 0 ]; then
    REWARD=$(node -e "console.log(Math.round(($PASSED / $TOTAL) * 100) / 100)")
else
    REWARD="0.0"
fi

echo ""
echo "========================================="
echo "Final score: $PASSED / $TOTAL = $REWARD"
echo "========================================="
echo "$REWARD" > "$REWARD_FILE"
