#!/bin/bash
set +e

# ============================================================
# Verifier for pi-mono parallel tool stall investigation task
# ============================================================
# The agent should produce an investigation + design memo about
# parallel tool execution vs interactive tools stalling.
# ============================================================
# Gate manifest (9 gates, weights sum to 1.00):
#   add_reward 0.05  Gate 1 [P2P] existing tests pass
#   add_reward 0.07  Gate 2 [F2P] document structure
#   add_reward 0.10  Gate 3 [F2P] root cause concepts
#   add_reward 0.10  Gate 4 [F2P] code reference accuracy
#   add_reward 0.07  Gate 5 [F2P] solution options
#   add_reward 0.10  Gate 6 [F2P] reproduction plan
#   add_reward 0.06  Gate 7 [F2P] section completeness
#   add_reward 0.25  Gate 8 [F2P] oracle consultation
#   add_reward 0.20  Gate 9 [F2P] recommendation quality
# Nop score: 0.00

REWARD=0
mkdir -p /logs/verifier

# Handle git safe.directory for any user context
git config --global --add safe.directory /workspace/pi-mono 2>/dev/null || true

# Helper: add to reward (capped at 1.0)
add_reward() {
  REWARD=$(node -e "console.log(Math.round(Math.min(1, $REWARD + $1) * 100) / 100)")
}

# ============================================================
# Gate 1 (P2P, weight 0.05): Existing agent-loop tests pass
# Verifies the agent did not break existing code.
# ============================================================
echo "=== Gate 1 [P2P]: Existing agent-loop tests ==="
cd /workspace/pi-mono
VITEST_OUT=$(npx vitest --run packages/agent/test/agent-loop.test.ts 2>&1)
echo "$VITEST_OUT" | tail -5
if echo "$VITEST_OUT" | grep -q "Tests.*passed"; then
  echo "PASS: agent-loop tests pass"
  add_reward 0.05
else
  echo "FAIL: agent-loop tests broken"
fi

# ============================================================
# Locate the agent's investigation document
# Only consider NEW files created by the agent.
# ============================================================
echo ""
echo "=== Locating investigation document ==="

cd /workspace/pi-mono
MEMO_CONTENT=""

# Find new/modified files via git status
NEW_FILES=$(git status --porcelain 2>/dev/null | grep -E '^\?\?|^ M|^M ' | awk '{print $NF}' | grep -vE 'node_modules/|\.git/|dist/|models\.generated' | head -20)
# Check /workspace root for files outside the repo
WORKSPACE_FILES=$(find /workspace -maxdepth 1 \( -name "*.md" -o -name "*.txt" \) ! -name "instruction.md" 2>/dev/null | head -10)

BEST_FILE=""
BEST_SIZE=0

for f in $NEW_FILES; do
  FULL_PATH="/workspace/pi-mono/$f"
  if [ -f "$FULL_PATH" ]; then
    SIZE=$(wc -c < "$FULL_PATH" 2>/dev/null || echo 0)
    if grep -qiE "parallel|interactive|tool|stall|execution|investigation|memo|design" "$FULL_PATH" 2>/dev/null; then
      if [ "$SIZE" -gt "$BEST_SIZE" ]; then
        BEST_SIZE=$SIZE
        BEST_FILE=$FULL_PATH
      fi
    fi
  fi
done

for f in $WORKSPACE_FILES; do
  if [ -f "$f" ]; then
    SIZE=$(wc -c < "$f" 2>/dev/null || echo 0)
    if grep -qiE "parallel|interactive|tool|stall|execution|investigation|memo|design" "$f" 2>/dev/null; then
      if [ "$SIZE" -gt "$BEST_SIZE" ]; then
        BEST_SIZE=$SIZE
        BEST_FILE=$f
      fi
    fi
  fi
done

# Fallback: check git diff for substantial added content
if [ -z "$BEST_FILE" ] || [ "$BEST_SIZE" -lt 500 ]; then
  echo "No standalone memo found, checking git diff..."
  ADDED_CONTENT=$(git diff HEAD 2>/dev/null | grep "^+" | grep -v "^+++" | sed 's/^+//')
  ADDED_SIZE=${#ADDED_CONTENT}
  if [ "$ADDED_SIZE" -gt "$BEST_SIZE" ]; then
    echo "$ADDED_CONTENT" > /tmp/agent_output.txt
    BEST_FILE="/tmp/agent_output.txt"
    BEST_SIZE=$ADDED_SIZE
  fi
fi

# Fallback 2: Extract from Claude Code session files (agent response text)
if [ -z "$BEST_FILE" ] || [ "$BEST_SIZE" -lt 500 ]; then
  echo "Checking Claude Code session files..."
  CLAUDE_SESSION=$(find /home -path '*/.claude/projects/*' -name '*.jsonl' 2>/dev/null | head -5)
  for sf in $CLAUDE_SESSION; do
    # Extract the last/largest assistant text block
    EXTRACTED=$(node -e "
      const fs = require('fs');
      const lines = fs.readFileSync('$sf', 'utf8').split('\n').filter(Boolean);
      let bestText = '';
      for (const line of lines) {
        try {
          const d = JSON.parse(line);
          if (d.type === 'assistant' && d.message && Array.isArray(d.message.content)) {
            for (const c of d.message.content) {
              if (c.type === 'text' && c.text && c.text.length > bestText.length) {
                bestText = c.text;
              }
            }
          }
        } catch(e) {}
      }
      process.stdout.write(bestText);
    " 2>/dev/null)
    EXTRACTED_SIZE=${#EXTRACTED}
    if [ "$EXTRACTED_SIZE" -gt "$BEST_SIZE" ]; then
      echo "$EXTRACTED" > /tmp/agent_session_output.txt
      BEST_FILE="/tmp/agent_session_output.txt"
      BEST_SIZE=$EXTRACTED_SIZE
    fi
  done
fi

if [ -n "$BEST_FILE" ]; then
  echo "Found document: $BEST_FILE ($BEST_SIZE bytes)"
  MEMO_CONTENT=$(cat "$BEST_FILE" 2>/dev/null)
else
  echo "No investigation document found"
  MEMO_CONTENT=""
fi

# Write memo to temp file for reliable reading in node scripts
echo "$MEMO_CONTENT" > /tmp/memo_content.txt

# ============================================================
# Gate 2 (F2P, weight 0.07): Document structure and substance
# Requires >=5000 chars, >=5 section headings, structured content
# ============================================================
echo ""
echo "=== Gate 2 [F2P]: Document structure and substance ==="
GATE2_SCORE=$(node -e "
const content = require('fs').readFileSync('/tmp/memo_content.txt', 'utf8');
const len = content.length;
const headings = (content.match(/^#{1,4}\s+\S/gm) || []).length;
const hasCodeBlocks = (content.match(/\`\`\`/g) || []).length >= 2;
const hasTable = /\|.*\|.*\|/m.test(content);

let score = 0;
if (len >= 10000) score += 0.03;
else if (len >= 5000) score += 0.02;
else if (len >= 2000) score += 0.01;

if (headings >= 8) score += 0.02;
else if (headings >= 5) score += 0.01;

if (hasCodeBlocks && hasTable) score += 0.02;
else if (hasCodeBlocks || hasTable) score += 0.01;

console.log(Math.min(0.07, score));
" 2>/dev/null)
echo "Length: ${#MEMO_CONTENT}, gate2 score: $GATE2_SCORE"
add_reward "${GATE2_SCORE:-0}"

# ============================================================
# Gate 3 (F2P, weight 0.10): Root cause identification
# Must identify parallel execution + interactive + stall mechanism
# with specific function/file references.
# ============================================================
echo ""
echo "=== Gate 3 [F2P]: Root cause identification ==="
GATE3_SCORE=$(node -e "
const content = require('fs').readFileSync('/tmp/memo_content.txt', 'utf8').toLowerCase();
if (content.length < 200) { console.log(0); process.exit(0); }

const concepts = [
  /parallel/,
  /sequential/,
  /interactive/,
  /concurren|stall|hang|block|race|deadlock/,
  /executetoolcall/,
  /agent-loop|agent\.loop/,
];

let matched = 0;
for (const re of concepts) {
  if (re.test(content)) matched++;
}

if (matched >= 6) console.log(0.10);
else if (matched >= 5) console.log(0.08);
else if (matched >= 4) console.log(0.06);
else if (matched >= 3) console.log(0.04);
else console.log(0);
" 2>/dev/null)
echo "Gate3 score: $GATE3_SCORE"
add_reward "${GATE3_SCORE:-0}"

# ============================================================
# Gate 4 (F2P, weight 0.10): Code reference accuracy
# Verify the agent cited real line numbers that match actual code.
# Check executeToolCallsParallel location and default mode location.
# ============================================================
echo ""
echo "=== Gate 4 [F2P]: Code reference accuracy ==="
GATE4_SCORE=$(node -e "
const fs = require('fs');
const content = fs.readFileSync('/tmp/memo_content.txt', 'utf8');
if (content.length < 200) { console.log(0); process.exit(0); }

let score = 0;

// Check 1: Does document reference the correct default mode location?
// The actual code: agent.ts line 169: this._toolExecution = opts.toolExecution ?? 'parallel'
const agentTs = fs.readFileSync('/workspace/pi-mono/packages/agent/src/agent.ts', 'utf8');
const agentLines = agentTs.split('\n');

// Find actual line of toolExecution default
let actualDefaultLine = -1;
for (let i = 0; i < agentLines.length; i++) {
  if (agentLines[i].includes('toolExecution') && agentLines[i].includes('parallel')) {
    actualDefaultLine = i + 1;
    break;
  }
}

// Check if document mentions this line (within ±5 lines tolerance)
// Support multiple formats: agent.ts:169, agent.ts#169, agent.ts | 169, agent.ts line 169
const agentTsRefs = [];
const agentTsPattern = /agent\.ts[\`\s\|:#]*(?:line\s*)?(\d+)/gi;
let agentMatch;
while ((agentMatch = agentTsPattern.exec(content)) !== null) {
  agentTsRefs.push(parseInt(agentMatch[1]));
}
for (const num of agentTsRefs) {
  if (Math.abs(num - actualDefaultLine) <= 5) {
    score += 0.04;
    break;
  }
}

// Check 2: Does document reference executeToolCallsParallel location?
const loopTs = fs.readFileSync('/workspace/pi-mono/packages/agent/src/agent-loop.ts', 'utf8');
const loopLines = loopTs.split('\n');
let actualParallelLine = -1;
for (let i = 0; i < loopLines.length; i++) {
  if (loopLines[i].includes('function executeToolCallsParallel')) {
    actualParallelLine = i + 1;
    break;
  }
}

const loopTsRefs = [];
const loopTsPattern = /agent-loop\.ts[\`\s\|:#]*(?:line\s*)?(\d+)/gi;
let loopMatch;
while ((loopMatch = loopTsPattern.exec(content)) !== null) {
  loopTsRefs.push(parseInt(loopMatch[1]));
}
for (const num of loopTsRefs) {
  if (Math.abs(num - actualParallelLine) <= 10) {
    score += 0.04;
    break;
  }
}

// Check 3: Does document correctly identify the tool execution mode concept?
// Accept: ToolExecutionMode type name, toolExecution property, or sequential|parallel type
if (/toolexecutionmode/i.test(content) || /toolexecution/i.test(content) || /\"sequential\"\s*\|\s*\"parallel\"/i.test(content)) {
  score += 0.02;
}

console.log(Math.min(0.10, score));
" 2>/dev/null)
echo "Gate4 score: $GATE4_SCORE"
add_reward "${GATE4_SCORE:-0}"

# ============================================================
# Gate 5 (F2P, weight 0.07): Solution options (>=4 distinct,
# each with tradeoff analysis)
# ============================================================
echo ""
echo "=== Gate 5 [F2P]: Solution options with tradeoffs ==="
GATE5_SCORE=$(node -e "
const content = require('fs').readFileSync('/tmp/memo_content.txt', 'utf8');
if (content.length < 200) { console.log(0); process.exit(0); }

const lower = content.toLowerCase();

// Detect distinct solution concepts
const solutionConcepts = [
  /mutex|queue|semaphore|serialize.*dialog|dialog.*queue|global.*serial/i,
  /mark.*interactive|interactive.*metadata|tag.*interactive|interactive.*flag/i,
  /hybrid.*schedul|parallel.*non.*interactive|selective.*serial/i,
  /fallback|error.*strateg|timeout|detect.*concurrent|auto.*answer|reject.*concurrent/i,
  /sequential.*all|force.*sequential|disable.*parallel/i,
];
let conceptCount = 0;
for (const re of solutionConcepts) {
  if (re.test(content)) conceptCount++;
}

// Also count explicit option labels
const optionLabels = new Set();
const labelPatterns = [
  /option\s*[a-e1-5]/gi,
  /solution\s*[1-5]/gi,
  /approach\s*[1-5]/gi,
];
for (const pat of labelPatterns) {
  const matches = content.match(pat) || [];
  for (const m of matches) optionLabels.add(m.toLowerCase().replace(/\s+/g, ''));
}

const distinctOptions = Math.max(optionLabels.size, conceptCount);

// Check for tradeoff analysis
const tradeoffTerms = [
  /complexity|complex/i,
  /backward.*compat|breaking.*change|compat/i,
  /risk|correctness/i,
  /ux|user.*experience/i,
  /test.*strateg|testab/i,
];
let tradeoffCount = 0;
for (const re of tradeoffTerms) {
  if (re.test(content)) tradeoffCount++;
}

let score = 0;
// Options scoring
if (distinctOptions >= 4) score += 0.04;
else if (distinctOptions >= 3) score += 0.03;
else if (distinctOptions >= 2) score += 0.02;

// Tradeoff scoring
if (tradeoffCount >= 4) score += 0.03;
else if (tradeoffCount >= 3) score += 0.02;
else if (tradeoffCount >= 2) score += 0.01;

console.log(Math.min(0.07, score));
" 2>/dev/null)
echo "Gate5 score: $GATE5_SCORE"
add_reward "${GATE5_SCORE:-0}"

# ============================================================
# Gate 6 (F2P, weight 0.10): Reproduction plan with actual code
# Must include TypeScript code for a reproducible scenario.
# ============================================================
echo ""
echo "=== Gate 6 [F2P]: Reproduction plan ==="
GATE6_SCORE=$(node -e "
const content = require('fs').readFileSync('/tmp/memo_content.txt', 'utf8');
if (content.length < 200) { console.log(0); process.exit(0); }

let score = 0;

// Check for reproduction section
const hasReproSection = /repro/i.test(content);

// Check for TypeScript code blocks with tool registration or UI calls
const codeBlocks = content.match(/\`\`\`(?:typescript|ts|javascript|js)?\n([\s\S]*?)\`\`\`/g) || [];
let hasReproCode = false;
let hasUICall = false;
let hasToolRegistration = false;

for (const block of codeBlocks) {
  const code = block.toLowerCase();
  if (/registertool|registerextension/i.test(code)) hasToolRegistration = true;
  if (/ctx\.ui\.|\.confirm\(|\.select\(|\.input\(|\.editor\(/i.test(code)) hasUICall = true;
  if (hasToolRegistration && hasUICall) {
    hasReproCode = true;
    break;
  }
}

if (hasReproSection) score += 0.03;
if (hasReproCode) score += 0.07;
else if (hasToolRegistration || hasUICall) score += 0.03;

// Check for manual repro steps
if (/step\s*\d|1\.\s|run.*pi|launch/i.test(content) && hasReproSection) {
  score += 0.05;
}

console.log(Math.min(0.10, score));
" 2>/dev/null)
echo "Gate6 score: $GATE6_SCORE"
add_reward "${GATE6_SCORE:-0}"

# ============================================================
# Gate 7 (F2P, weight 0.06): Output section completeness
# The instruction requires: executive summary, evidence,
# reproduction, option matrix, oracle feedback, recommendation,
# unresolved questions.
# ============================================================
echo ""
echo "=== Gate 7 [F2P]: Output section completeness ==="
GATE7_SCORE=$(node -e "
const content = require('fs').readFileSync('/tmp/memo_content.txt', 'utf8').toLowerCase();
if (content.length < 200) { console.log(0); process.exit(0); }

const requiredSections = [
  /executive.*summary|summary/,
  /evidence/,
  /repro/,
  /option.*matrix|solution.*option|option.*compar/,
  /oracle/,
  /recommend/,
  /unresolved|open.*question|outstanding|future.*work/,
];

let found = 0;
for (const re of requiredSections) {
  if (re.test(content)) found++;
}

if (found >= 7) console.log(0.06);
else if (found >= 6) console.log(0.05);
else if (found >= 5) console.log(0.04);
else if (found >= 4) console.log(0.03);
else console.log(0);
" 2>/dev/null)
echo "Gate7 score: $GATE7_SCORE"
add_reward "${GATE7_SCORE:-0}"

# ============================================================
# Gate 8 (F2P, weight 0.25): Oracle consultation with substance
# The instruction says: consult oracle, include verbatim-ish summary,
# and state whether you agree/disagree.
# ============================================================
echo ""
echo "=== Gate 8 [F2P]: Oracle consultation ==="
cat > /tmp/gate8.js << 'GATE8EOF'
const content = require('fs').readFileSync('/tmp/memo_content.txt', 'utf8');
if (content.length < 200) { console.log(0); process.exit(0); }

const lower = content.toLowerCase();
const oracleIdx = lower.indexOf('oracle');
if (oracleIdx === -1) { console.log(0); process.exit(0); }

const afterOracle = content.substring(oracleIdx);
const nextHeading = afterOracle.search(/\n#{1,3}\s+(?!.*oracle)/i);
const oracleSection = nextHeading > 0 ? afterOracle.substring(0, nextHeading) : afterOracle;

let score = 0;

// Tier 1 (0.03): Basic oracle mention
score += 0.03;

// Tier 2 (0.04/0.02): Oracle section has substance
if (oracleSection.length >= 1500) score += 0.04;
else if (oracleSection.length >= 500) score += 0.02;

// Check for placeholder — blocks tiers 3-5
const hasPlaceholder = /awaiting|to be inserted|pending|TBD|placeholder/i.test(oracleSection);
if (hasPlaceholder) {
  // Placeholder means oracle was NOT actually consulted — cap score here
  console.log(Math.min(0.25, score));
  process.exit(0);
}

// Tier 3 (0.06/0.02): Real consultation evidence
const blockquoteLines = (oracleSection.match(/^>\s*.{20,}/gm) || []);
const hasResponseIndicators = /response|feedback|said|reply|review|consult|verbatim/i.test(oracleSection);
if (blockquoteLines.length >= 3 && hasResponseIndicators) score += 0.06;
else if (blockquoteLines.length >= 1 || hasResponseIndicators) score += 0.02;

// Tier 4 (0.06/0.02): Multiple distinct oracle feedback topics
const distinctTopics = new Set();
for (const line of blockquoteLines) {
  if (/root.cause|source|origin|correct|verified/i.test(line)) distinctTopics.add('cause');
  if (/option|solution|approach|fix|mutex|queue/i.test(line)) distinctTopics.add('solution');
  if (/rank|prefer|recommend|winner|A\s*>/i.test(line)) distinctTopics.add('ranking');
  if (/implement|detail|specific|must|abort|flush|signal/i.test(line)) distinctTopics.add('detail');
  if (/where|location|file|module|interactive-mode/i.test(line)) distinctTopics.add('location');
}
if (distinctTopics.size >= 3) score += 0.06;
else if (distinctTopics.size >= 1) score += 0.02;

// Tier 5 (0.06/0.03): Agent's own agree/disagree assessment
const nonQuoteText = oracleSection.replace(/^>.*$/gm, '');
if (/\b(i agree|i disagree|i concur|my assessment|i believe)\b/i.test(nonQuoteText)) score += 0.06;
else if (/agree|disagree|concur/i.test(content)) score += 0.03;

console.log(Math.min(0.25, score));
GATE8EOF
GATE8_SCORE=$(node /tmp/gate8.js 2>/dev/null)
echo "Gate8 score: $GATE8_SCORE"
add_reward "${GATE8_SCORE:-0}"

# ============================================================
# Gate 9 (F2P, weight 0.20): Recommendation quality
# The instruction specifically asks for:
# - Ranked recommendation (1st/2nd choice) with rationale
# - Phased rollout plan and safety checks
# - Oracle-informed recommendation (not just pre-oracle guess)
# - Unresolved questions
# ============================================================
echo ""
echo "=== Gate 9 [F2P]: Recommendation quality ==="
cat > /tmp/gate9.js << 'GATE9EOF'
const content = require('fs').readFileSync('/tmp/memo_content.txt', 'utf8');
if (content.length < 200) { console.log(0); process.exit(0); }

const lower = content.toLowerCase();
let score = 0;

// Check 1 (0.06/0.03): Ranked recommendation (1st/2nd choice)
const hasRanked = /1st.*choice|2nd.*choice|first.*choice|second.*choice/i.test(content);
const hasExplicitRank = /\b(rank|prefer|winner|primary)\b/i.test(content);
if (hasRanked) score += 0.06;
else if (hasExplicitRank) score += 0.03;

// Check 2 (0.05): Phased rollout plan
const hasPhased = /phase\s*[1-3d]|rollout|phased|incremental.*deploy|staged/i.test(content);
if (hasPhased) score += 0.05;

// Check 3 (0.04/0.02): Safety/risk mitigation
const safetyTerms = [
  /safety|guard.*rail|safeguard/i,
  /rollback|revert|feature.*flag/i,
  /monitor|metric|alert|observ/i,
  /test.*coverage|regression.*test/i,
];
let safetyCount = 0;
for (const re of safetyTerms) {
  if (re.test(content)) safetyCount++;
}
if (safetyCount >= 3) score += 0.04;
else if (safetyCount >= 2) score += 0.03;
else if (safetyCount >= 1) score += 0.02;

// Check 4 (0.05): Oracle-informed recommendation
// The final recommendation must reference oracle's actual input
// (not just "awaiting oracle" or "pre-oracle")
const recIdx = lower.indexOf('recommend');
const recSection = recIdx >= 0 ? content.substring(recIdx) : '';
const oracleShapedRec = /oracle.*(?:confirm|agreed|independently|arrived|validated|same.*conclusion|supported|verified|corroborate)/i.test(recSection);
const agreeWithOracle = /(?:agree|concur|consistent|aligned).*(?:with|the).*oracle/i.test(recSection);
if (oracleShapedRec || agreeWithOracle) score += 0.05;

console.log(Math.min(0.20, score));
GATE9EOF
GATE9_SCORE=$(node /tmp/gate9.js 2>/dev/null)
echo "Gate9 score: $GATE9_SCORE"
add_reward "${GATE9_SCORE:-0}"

# ============================================================
# Write final reward
# ============================================================
echo ""
echo "=== Final Score ==="
echo "Total reward: $REWARD"
echo "$REWARD" > /logs/verifier/reward.txt
