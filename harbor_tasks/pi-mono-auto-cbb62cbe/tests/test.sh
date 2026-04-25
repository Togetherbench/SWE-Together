#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
echo "0.0" > "$REWARD_FILE"

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
command -v bun >/dev/null 2>&1 || export PATH="$HOME/.bun/bin:$PATH"

REPO="/workspace/pi-mono"
if [ ! -d "$REPO" ]; then
  for cand in /workspace/*/packages/coding-agent; do
    if [ -d "$cand" ]; then REPO="$(dirname "$(dirname "$cand")")"; break; fi
  done
fi

COMPONENTS_DIR="$REPO/packages/coding-agent/src/modes/interactive/components"
INTERACTIVE="$REPO/packages/coding-agent/src/modes/interactive/interactive-mode.ts"
EXTENSIONS_DIR="$REPO/.pi/extensions"
EXAMPLE_EXT_DIR="$REPO/packages/coding-agent/examples/extensions"

REWARD=0

# ---- P2P gating: regression guard ----------------------------------
# armin.ts is the reference component that ships in base; if missing or
# gutted the agent broke pre-existing state.
ARMIN_PATH="$COMPONENTS_DIR/armin.ts"
if [ ! -f "$ARMIN_PATH" ]; then
  echo "P2P FAIL: armin.ts missing"
  echo "0.0" > "$REWARD_FILE"; exit 0
fi
if ! grep -qE 'export\s+class\s+ArminComponent' "$ARMIN_PATH"; then
  echo "P2P FAIL: ArminComponent export missing"
  echo "0.0" > "$REWARD_FILE"; exit 0
fi

if [ ! -f "$INTERACTIVE" ]; then
  echo "P2P FAIL: interactive-mode.ts missing"
  echo "0.0" > "$REWARD_FILE"; exit 0
fi
imsize=$(wc -c < "$INTERACTIVE")
if [ "$imsize" -lt 5000 ]; then
  echo "P2P FAIL: interactive-mode.ts gutted ($imsize bytes)"
  echo "0.0" > "$REWARD_FILE"; exit 0
fi
if ! grep -q 'InteractiveMode' "$INTERACTIVE"; then
  echo "P2P FAIL: InteractiveMode missing"
  echo "0.0" > "$REWARD_FILE"; exit 0
fi

# ---- Discover any new "easter egg" file added by the agent ---------
# Base files at start commit (everything else in components/ is new).
BASE_FILES="armin.ts assistant-message.ts bash-execution.ts bordered-loader.ts branch-summary-message.ts compaction-summary-message.ts config-selector.ts countdown-timer.ts custom-editor.ts custom-message.ts diff.ts dynamic-border.ts extension-editor.ts extension-input.ts extension-selector.ts footer.ts index.ts keybinding-hints.ts login-dialog.ts model-selector.ts oauth-selector.ts scoped-models-selector.ts session-selector-search.ts session-selector.ts settings-selector.ts show-images-selector.ts skill-invocation-message.ts theme-selector.ts thinking-selector.ts tool-execution.ts tree-selector.ts user-message-selector.ts user-message.ts visual-truncate.ts"

is_base_file() {
  local b="$1"
  for f in $BASE_FILES; do
    [ "$f" = "$b" ] && return 0
  done
  return 1
}

CANDIDATES=()
if [ -d "$COMPONENTS_DIR" ]; then
  for f in "$COMPONENTS_DIR"/*.ts; do
    [ -f "$f" ] || continue
    bn=$(basename "$f")
    is_base_file "$bn" && continue
    CANDIDATES+=("$f")
  done
fi
for d in "$EXTENSIONS_DIR" "$EXAMPLE_EXT_DIR"; do
  if [ -d "$d" ]; then
    for f in "$d"/*.ts; do
      [ -f "$f" ] || continue
      CANDIDATES+=("$f")
    done
  fi
done

echo "REPO=$REPO"
echo "CANDIDATES count=${#CANDIDATES[@]}"
for c in "${CANDIDATES[@]}"; do echo "  cand: $c ($(wc -c < "$c") bytes)"; done

# Filter to "easter egg" files: must mention both opencode and kimi (case-insensitive).
EE_FILES=()
for f in "${CANDIDATES[@]}"; do
  if grep -qiE 'opencode' "$f" 2>/dev/null && grep -qiE 'kimi' "$f" 2>/dev/null; then
    EE_FILES+=("$f")
  fi
done

# Pick a primary file: largest among EE_FILES.
PRIMARY_EE=""
best=0
for f in "${EE_FILES[@]}"; do
  sz=$(wc -c < "$f")
  if [ "$sz" -gt "$best" ]; then
    best=$sz
    PRIMARY_EE="$f"
  fi
done

echo "PRIMARY_EE=$PRIMARY_EE"

# ---------------------------------------------------------------------
# F2P GATE A (0.20): A new easter-egg source file exists, mentioning the
# trigger pair (opencode + kimi) AND the daxnuts brand. None of these
# files exist on base, so this gate is 0 on no-op.
# ---------------------------------------------------------------------
GATE_A=0
if [ -n "$PRIMARY_EE" ]; then
  if grep -qiE 'daxnut' "$PRIMARY_EE" && \
     grep -qiE 'opencode' "$PRIMARY_EE" && \
     grep -qiE 'kimi' "$PRIMARY_EE"; then
    sz=$(wc -c < "$PRIMARY_EE")
    if [ "$sz" -gt 800 ]; then
      GATE_A=20
      echo "F2P A: PASS — easter egg file with trigger+brand ($sz bytes)"
    else
      echo "F2P A: FAIL — file too small ($sz bytes)"
    fi
  else
    echo "F2P A: FAIL — missing daxnut/opencode/kimi tokens"
  fi
else
  echo "F2P A: FAIL — no easter egg file"
fi
REWARD=$((REWARD + GATE_A))

# ---------------------------------------------------------------------
# F2P GATE B (0.20): Easter-egg file is a real component-like artifact:
# has an export and exposes a render or component-shaped surface.
# This is structural but the FILE didn't exist on base, so still F2P.
# ---------------------------------------------------------------------
GATE_B=0
if [ -n "$PRIMARY_EE" ]; then
  has_export=0
  has_component_shape=0
  if grep -qE 'export\s+(default|class|function|const)' "$PRIMARY_EE"; then
    has_export=1
  fi
  if grep -qE 'render\s*\(|implements\s+Component|: *Component\b|Component\s*\{|registerCommand|setWidget|sendMessage|showOverlay|ui\.custom|registerMessageRenderer' "$PRIMARY_EE"; then
    has_component_shape=1
  fi
  echo "F2P B detail: export=$has_export shape=$has_component_shape"
  if [ "$has_export" -eq 1 ] && [ "$has_component_shape" -eq 1 ]; then
    GATE_B=20
    echo "F2P B: PASS — exported component-shaped artifact"
  fi
fi
REWARD=$((REWARD + GATE_B))

# ---------------------------------------------------------------------
# F2P GATE C (0.25): Trigger logic exists somewhere (easter-egg file or
# interactive-mode.ts) — predicate references opencode AND kimi within a
# small window AND uses an actual conditional comparison. None of this
# is in base files.
# ---------------------------------------------------------------------
GATE_C=0
TRIGGER_FILES=()
[ -n "$PRIMARY_EE" ] && TRIGGER_FILES+=("$PRIMARY_EE")
[ -f "$INTERACTIVE" ] && TRIGGER_FILES+=("$INTERACTIVE")
for f in "${EE_FILES[@]}"; do
  TRIGGER_FILES+=("$f")
done

# Verify base interactive-mode.ts does NOT already have this predicate.
# (Sanity: this is the F2P-on-base property.)
BASE_HAS_TRIGGER=0
if grep -qiE 'kimi' "$INTERACTIVE" 2>/dev/null && grep -qiE 'opencode' "$INTERACTIVE" 2>/dev/null; then
  # If both appear together within 30 lines, predicate is plausibly already there.
  if awk '
    { lines[NR]=tolower($0) }
    END {
      for (i=1;i<=NR;i++) {
        lo=i; hi=i+30; if (hi>NR) hi=NR
        ok=0; ki=0
        for (j=lo;j<=hi;j++) {
          if (index(lines[j],"opencode")) ok=1
          if (index(lines[j],"kimi")) ki=1
        }
        if (ok && ki) { print "Y"; exit }
      }
    }' "$INTERACTIVE" | grep -q Y; then
    BASE_HAS_TRIGGER=1
  fi
fi

HAS_TRIGGER=0
for f in "${TRIGGER_FILES[@]}"; do
  [ -f "$f" ] || continue
  # Reject the "trigger" being only in interactive-mode.ts if it was already there in base.
  if [ "$f" = "$INTERACTIVE" ] && [ "$BASE_HAS_TRIGGER" -eq 1 ] && [ "${#EE_FILES[@]}" -eq 0 ]; then
    continue
  fi
  if awk '
    { lines[NR]=tolower($0) }
    END {
      for (i=1;i<=NR;i++) {
        lo=i; hi=i+25; if (hi>NR) hi=NR
        ocguard=0; kimiguard=0
        for (j=lo;j<=hi;j++) {
          l=lines[j]
          if (index(l,"opencode") && (l ~ /===|==|includes|provider|match/)) ocguard=1
          if (index(l,"kimi") && (l ~ /===|==|includes|tolowercase|match|test\(/)) kimiguard=1
        }
        if (ocguard && kimiguard) { print "OK"; exit }
      }
    }' "$f" | grep -q OK; then
    HAS_TRIGGER=1
    echo "F2P C: trigger predicate found in $f"
    break
  fi
done

if [ "$HAS_TRIGGER" -eq 1 ]; then
  GATE_C=25
  echo "F2P C: PASS — provider/model trigger predicate present"
else
  echo "F2P C: FAIL — no opencode+kimi trigger predicate"
fi
REWARD=$((REWARD + GATE_C))

# ---------------------------------------------------------------------
# F2P GATE D (0.20): Behavioral simulation — extract the predicate idea
# and verify it (a) accepts opencode+kimi-k2.5 and (b) rejects mismatched
# combos. We do this by writing a tiny JS that mirrors the conditions we
# can detect in the source: provider check + model id check.
# To avoid hardcoding to one solution, we just reproduce a minimal logic
# that the agent's predicate must satisfy in spirit, then ensure the
# source file CONTAINS each of those constituent checks textually.
# Specifically: must have something that constrains provider to
# "opencode" AND something that matches "kimi" (case-insensitively, by
# includes/===/regex). Both already required in Gate C; Gate D upgrades:
# also require that the predicate is NEGATIVE on at least one mismatched
# branch — i.e. an `if (...)` or guard that gates the easter egg, rather
# than firing unconditionally.
# ---------------------------------------------------------------------
GATE_D=0
if [ "$HAS_TRIGGER" -eq 1 ]; then
  guard_seen=0
  for f in "${TRIGGER_FILES[@]}"; do
    [ -f "$f" ] || continue
    # Look for an if-guard within 8 lines of a kimi mention that references provider/opencode
    if awk '
      { lines[NR]=$0 }
      END {
        for (i=1;i<=NR;i++) {
          if (tolower(lines[i]) ~ /kimi/) {
            lo=i-10; if (lo<1) lo=1
            hi=i+10; if (hi>NR) hi=NR
            saw_if=0; saw_oc=0
            for (j=lo;j<=hi;j++) {
              l=tolower(lines[j])
              if (l ~ /\bif\s*\(|return\s+|&&|\?\s*/) saw_if=1
              if (index(l,"opencode")) saw_oc=1
            }
            if (saw_if && saw_oc) { print "G"; exit }
          }
        }
      }' "$f" | grep -q G; then
      guard_seen=1
      echo "F2P D: guard form found in $f"
      break
    fi
  done
  if [ "$guard_seen" -eq 1 ]; then
    GATE_D=20
    echo "F2P D: PASS — predicate is a real conditional guard"
  else
    echo "F2P D: FAIL — no proper if-guard around kimi/opencode"
  fi
fi
REWARD=$((REWARD + GATE_D))

# ---------------------------------------------------------------------
# F2P GATE E (0.15): Easter egg renders/sends actual content with the
# "powered by daxnuts" / "DAXNUTS" branding the user explicitly asked
# for. Pure base has no such string anywhere.
# ---------------------------------------------------------------------
GATE_E=0
brand_hit=0
search_files=()
[ -n "$PRIMARY_EE" ] && search_files+=("$PRIMARY_EE")
for f in "${EE_FILES[@]}"; do search_files+=("$f"); done
[ -f "$INTERACTIVE" ] && search_files+=("$INTERACTIVE")

for f in "${search_files[@]}"; do
  [ -f "$f" ] || continue
  # Need both "daxnuts" branding AND the verb "powered by" or similar
  # AND a thanks/free-access reference.
  if grep -qiE 'daxnut' "$f" && \
     grep -qiE 'powered\s*by|p\W*o\W*w\W*e\W*r\W*e\W*d' "$f"; then
    if grep -qiE 'free|thank|kimi|opencode' "$f"; then
      brand_hit=1
      echo "F2P E: brand+message found in $f"
      break
    fi
  fi
done

# Sanity: make sure base files do NOT already contain "daxnut".
# Scan all base component files + interactive-mode.ts for the brand.
base_has_brand=0
if grep -riE 'daxnut' "$COMPONENTS_DIR" 2>/dev/null | grep -vE '/(daxnuts?|kimi[^/]*|.*easter[^/]*)\.ts:' >/dev/null; then
  # any base file containing daxnut -> brand was pre-existing, neutralize gate
  base_has_brand=1
fi

if [ "$brand_hit" -eq 1 ] && [ "$base_has_brand" -eq 0 ]; then
  GATE_E=15
  echo "F2P E: PASS — DAXNUTS branding + thank-you context"
else
  echo "F2P E: FAIL — brand_hit=$brand_hit base_has_brand=$base_has_brand"
fi
REWARD=$((REWARD + GATE_E))

# ---------------------------------------------------------------------
# Convert to 0..1
# Total possible: 20 + 20 + 25 + 20 + 15 = 100
# ---------------------------------------------------------------------
FINAL=$(awk -v r="$REWARD" 'BEGIN { printf "%.3f", r/100.0 }')
echo "RAW=$REWARD FINAL=$FINAL"
echo "$FINAL" > "$REWARD_FILE"