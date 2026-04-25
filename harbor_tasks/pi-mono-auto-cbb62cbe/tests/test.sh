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

PKG_DIR="$REPO/packages/coding-agent"
COMPONENTS_DIR="$PKG_DIR/src/modes/interactive/components"
INTERACTIVE="$PKG_DIR/src/modes/interactive/interactive-mode.ts"
ARMIN_PATH="$COMPONENTS_DIR/armin.ts"
EXTENSIONS_DIR="$REPO/.pi/extensions"
EXAMPLE_EXT_DIR="$PKG_DIR/examples/extensions"

echo "REPO=$REPO"

# ---- P2P gating ----------------------------------------------------
if [ ! -f "$ARMIN_PATH" ]; then
  echo "P2P FAIL: armin.ts missing"; echo "0.0" > "$REWARD_FILE"; exit 0
fi
if ! grep -qE 'export\s+class\s+ArminComponent' "$ARMIN_PATH"; then
  echo "P2P FAIL: ArminComponent missing"; echo "0.0" > "$REWARD_FILE"; exit 0
fi
if [ ! -f "$INTERACTIVE" ]; then
  echo "P2P FAIL: interactive-mode.ts missing"; echo "0.0" > "$REWARD_FILE"; exit 0
fi
imsize=$(wc -c < "$INTERACTIVE")
if [ "$imsize" -lt 5000 ]; then
  echo "P2P FAIL: interactive-mode.ts gutted ($imsize bytes)"; echo "0.0" > "$REWARD_FILE"; exit 0
fi
if ! grep -q 'class InteractiveMode' "$INTERACTIVE"; then
  echo "P2P FAIL: InteractiveMode class missing"; echo "0.0" > "$REWARD_FILE"; exit 0
fi

# ---- Discover candidate easter-egg files ---------------------------
BASE_FILES="armin.ts assistant-message.ts bash-execution.ts bordered-loader.ts branch-summary-message.ts compaction-summary-message.ts config-selector.ts countdown-timer.ts custom-editor.ts custom-message.ts diff.ts dynamic-border.ts extension-editor.ts extension-input.ts extension-selector.ts footer.ts index.ts keybinding-hints.ts login-dialog.ts model-selector.ts oauth-selector.ts scoped-models-selector.ts session-selector-search.ts session-selector.ts settings-selector.ts show-images-selector.ts skill-invocation-message.ts theme-selector.ts thinking-selector.ts tool-execution.ts tree-selector.ts user-message-selector.ts user-message.ts visual-truncate.ts"

is_base_file() {
  local b="$1"
  for f in $BASE_FILES; do [ "$f" = "$b" ] && return 0; done
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
  [ -d "$d" ] || continue
  for f in "$d"/*.ts; do
    [ -f "$f" ] || continue
    CANDIDATES+=("$f")
  done
done

echo "CANDIDATES count=${#CANDIDATES[@]}"
for c in "${CANDIDATES[@]}"; do echo "  cand: $c ($(wc -c < "$c") bytes)"; done

# Filter: must mention opencode AND kimi AND daxnut
EE_FILES=()
for f in "${CANDIDATES[@]}"; do
  if grep -qiE 'opencode' "$f" 2>/dev/null \
     && grep -qiE 'kimi' "$f" 2>/dev/null \
     && grep -qiE 'daxnut' "$f" 2>/dev/null; then
    EE_FILES+=("$f")
  fi
done

PRIMARY_EE=""
best=0
for f in "${EE_FILES[@]}"; do
  sz=$(wc -c < "$f")
  if [ "$sz" -gt "$best" ]; then best=$sz; PRIMARY_EE="$f"; fi
done
echo "PRIMARY_EE=$PRIMARY_EE (size=$best)"
echo "EE_FILES count=${#EE_FILES[@]}"

# Helper: numeric arithmetic with awk for fractional REWARD
REWARD="0.00"
add_reward() {
  REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.4f", a+b}')
}

# ---------------------------------------------------------------------
# GATE 1 (0.15): A non-trivial easter-egg artifact exists with all
# required tokens (kimi, opencode, daxnut) and substantial content.
# ---------------------------------------------------------------------
G1=0
if [ -n "$PRIMARY_EE" ] && [ "$best" -gt 1500 ]; then
  # Must have a real export
  if grep -qE 'export\s+(default|class|function|const)' "$PRIMARY_EE"; then
    G1=1
    echo "GATE 1 PASS: easter-egg artifact with tokens & export ($best bytes)"
  else
    echo "GATE 1 FAIL: no export in $PRIMARY_EE"
  fi
else
  echo "GATE 1 FAIL: no substantial easter-egg artifact"
fi
[ "$G1" = "1" ] && add_reward 0.15

# ---------------------------------------------------------------------
# GATE 2 (0.15): The "powered by daxnuts" brand string actually appears
# as a renderable string (not just in a comment). Must include "powered"
# and "daxnuts" close together (case-insensitive).
# ---------------------------------------------------------------------
G2=0
for f in "${EE_FILES[@]}"; do
  if awk 'BEGIN{IGNORECASE=1}
    { lines[NR]=tolower($0) }
    END {
      for (i=1;i<=NR;i++) {
        # ignore lines that are pure comments (starting with // or *)
        raw=lines[i]
        sub(/^[ \t]*/,"",raw)
        if (raw ~ /^\/\// || raw ~ /^\*/) continue
        if (index(raw,"powered") && index(raw,"daxnut")) { print "Y"; exit }
      }
      # also accept if both appear in same line anywhere
      for (i=1;i<=NR;i++) if (index(lines[i],"powered by daxnut")) { print "Y"; exit }
    }' "$f" 2>/dev/null | grep -q Y; then
    G2=1
    echo "GATE 2 PASS: 'powered by daxnuts' brand in $f"
    break
  fi
done
[ "$G2" = "0" ] && echo "GATE 2 FAIL: no rendered 'powered by daxnuts' string"
[ "$G2" = "1" ] && add_reward 0.15

# ---------------------------------------------------------------------
# GATE 3 (0.20): The trigger predicate is correct: requires the
# opencode provider AND a kimi-k2.5 (or kimi-k2) model id, in a real
# conditional. We check across the easter-egg files AND interactive-mode.ts
# for additions, but reject if it's only the unchanged base interactive
# mode.
# ---------------------------------------------------------------------
G3=0
TRIGGER_FILES=()
for f in "${EE_FILES[@]}"; do TRIGGER_FILES+=("$f"); done
[ -f "$INTERACTIVE" ] && TRIGGER_FILES+=("$INTERACTIVE")

for f in "${TRIGGER_FILES[@]}"; do
  [ -f "$f" ] || continue
  # Must have a comparison/equality referencing "opencode" AND test for kimi-k2
  has_provider_check=$(grep -cE '(provider|provider_id)[^=]*===[[:space:]]*"opencode"|"opencode"[[:space:]]*===[[:space:]]*[a-zA-Z0-9_.]*provider|provider[^=]*==[[:space:]]*"opencode"' "$f" 2>/dev/null)
  has_kimi_check=$(grep -cE 'kimi-k2(\.5)?|"kimi[^"]*"|includes\(\s*"kimi' "$f" 2>/dev/null)
  if [ "${has_provider_check:-0}" -gt 0 ] && [ "${has_kimi_check:-0}" -gt 0 ]; then
    # Within 12 lines of each other?
    if awk '
      BEGIN{IGNORECASE=1}
      { L[NR]=$0 }
      END {
        for (i=1;i<=NR;i++) {
          lo=i; hi=i+12; if (hi>NR) hi=NR
          okp=0; okk=0
          for (j=lo;j<=hi;j++) {
            l=tolower(L[j])
            if (index(l,"\"opencode\"")) okp=1
            if (l ~ /kimi-k2(\.5)?/ || index(l,"\"kimi") || (index(l,"includes") && index(l,"kimi"))) okk=1
          }
          if (okp && okk) { print "Y"; exit }
        }
      }' "$f" | grep -q Y; then
      G3=1
      echo "GATE 3 PASS: trigger predicate (opencode + kimi-k2.5) in $f"
      break
    fi
  fi
done
[ "$G3" = "0" ] && echo "GATE 3 FAIL: no opencode+kimi-k2.5 conditional"
[ "$G3" = "1" ] && add_reward 0.20

# ---------------------------------------------------------------------
# GATE 4 (0.15): Component-shape: the artifact implements a Component
# (render() and dispose()/handleInput()/invalidate()) OR uses extension
# UI hooks (setWidget / sendMessage / ui.custom / showOverlay /
# showExtensionCustom).
# ---------------------------------------------------------------------
G4=0
for f in "${EE_FILES[@]}"; do
  has_render=$(grep -cE 'render\s*\(' "$f" 2>/dev/null)
  has_lifecycle=$(grep -cE 'dispose\s*\(|handleInput\s*\(|invalidate\s*\(' "$f" 2>/dev/null)
  has_uihook=$(grep -cE 'setWidget\(|sendMessage\(|ui\.custom\b|showOverlay\(|showExtensionCustom\(|registerCommand\(' "$f" 2>/dev/null)
  has_component_type=$(grep -cE 'implements\s+Component|:\s*Component\b|Component\s*\{' "$f" 2>/dev/null)

  shape_score=0
  [ "${has_render:-0}" -gt 0 ] && [ "${has_lifecycle:-0}" -gt 0 ] && shape_score=1
  [ "${has_uihook:-0}" -gt 0 ] && shape_score=1
  [ "${has_component_type:-0}" -gt 0 ] && [ "${has_render:-0}" -gt 0 ] && shape_score=1

  if [ "$shape_score" = "1" ]; then
    G4=1
    echo "GATE 4 PASS: component-shape in $f (render=$has_render lifecycle=$has_lifecycle uihook=$has_uihook)"
    break
  fi
done
[ "$G4" = "0" ] && echo "GATE 4 FAIL: no component-shape"
[ "$G4" = "1" ] && add_reward 0.15

# ---------------------------------------------------------------------
# GATE 5 (0.20): Wiring — the trigger actually causes the component
# to be shown. Two acceptable patterns:
#   (a) Extension: registers on "model_select" event AND calls
#       ctx.ui.{custom,setWidget} OR pi.sendMessage with a check for
#       opencode+kimi.
#   (b) Core: interactive-mode.ts has a check method that calls into
#       a Daxnuts component / showExtensionCustom / showOverlay.
# ---------------------------------------------------------------------
G5=0

# Pattern A: extension
for f in "${EE_FILES[@]}"; do
  case "$f" in
    "$EXTENSIONS_DIR"/*|"$EXAMPLE_EXT_DIR"/*) ;;
    *) continue ;;
  esac
  has_event=$(grep -cE 'pi\.on\(\s*"model_select"|on\(\s*"model_select"' "$f" 2>/dev/null)
  has_show=$(grep -cE 'ctx\.ui\.(custom|setWidget|showOverlay)|pi\.sendMessage\(|pi\.appendEntry\(' "$f" 2>/dev/null)
  if [ "${has_event:-0}" -gt 0 ] && [ "${has_show:-0}" -gt 0 ]; then
    G5=1
    echo "GATE 5 PASS (extension wiring) in $f"
    break
  fi
done

# Pattern B: core wiring inside interactive-mode.ts
if [ "$G5" = "0" ]; then
  # check for a method that references kimi+opencode AND adds component / shows overlay
  if grep -qE 'checkDaxnutsEasterEgg|handleDaxnuts|showDaxnuts' "$INTERACTIVE"; then
    if grep -qE 'DaxnutsComponent|showExtensionCustom|showOverlay\(|chatContainer\.addChild\(\s*new\s+Daxnuts' "$INTERACTIVE"; then
      # And the method must be invoked somewhere (not just defined)
      callcount=$(grep -cE 'this\.(checkDaxnutsEasterEgg|handleDaxnuts|showDaxnuts)\(' "$INTERACTIVE")
      if [ "${callcount:-0}" -ge 2 ]; then
        # at least 1 def + 1 call
        G5=1
        echo "GATE 5 PASS (core wiring in interactive-mode.ts, callcount=$callcount)"
      else
        echo "GATE 5 INFO: method defined but not invoked (callcount=$callcount)"
      fi
    fi
  fi
fi
[ "$G5" = "0" ] && echo "GATE 5 FAIL: trigger not wired to UI"
[ "$G5" = "1" ] && add_reward 0.20

# ---------------------------------------------------------------------
# GATE 6 (0.15): Behavioral simulation — synthesize the predicate
# that the patch implements and verify it returns true for
# (provider=opencode, id="kimi-k2.5") and false for unrelated models.
# We extract the predicate region by looking for an if-statement that
# contains both "opencode" and "kimi" within 6 lines, then evaluate it
# in node by stubbing.
# ---------------------------------------------------------------------
G6=0

extract_predicate() {
  local f="$1"
  awk '
    {
      L[NR]=$0
    }
    END {
      for (i=1;i<=NR;i++) {
        line=L[i]
        if (line ~ /^[[:space:]]*if[[:space:]]*\(/ || line ~ /[[:space:]]if[[:space:]]*\(/) {
          # accumulate up to 8 lines
          buf=line
          j=i
          while (j<NR && buf !~ /\)[[:space:]]*\{?[[:space:]]*$/ && j-i < 8) {
            j++
            buf=buf " " L[j]
          }
          low=tolower(buf)
          if (index(low,"opencode") && index(low,"kimi")) {
            print buf
            exit
          }
        }
      }
    }' "$f"
}

PRED=""
for f in "${EE_FILES[@]}" "$INTERACTIVE"; do
  [ -f "$f" ] || continue
  p=$(extract_predicate "$f")
  if [ -n "$p" ]; then
    PRED="$p"
    PRED_FILE="$f"
    break
  fi
done

if [ -n "$PRED" ]; then
  echo "GATE 6 predicate from $PRED_FILE: $PRED"
  # Extract just the boolean expression inside the outer if(...)
  EXPR=$(echo "$PRED" | sed -nE 's/.*if[[:space:]]*\((.*)\).*/\1/p')
  if [ -z "$EXPR" ]; then
    EXPR=$(echo "$PRED" | sed -E 's/.*if[[:space:]]*\(//' | sed -E 's/\)[[:space:]]*\{?[[:space:]]*$//')
  fi
  # Strip any trailing dangling
  EXPR=$(echo "$EXPR" | sed -E 's/[[:space:]]+$//')
  echo "GATE 6 EXPR: $EXPR"

  if command -v node >/dev/null 2>&1 || command -v bun >/dev/null 2>&1; then
    RUNNER="node"
    command -v bun >/dev/null 2>&1 && RUNNER="bun"

    # Build a small JS harness. We replace identifiers with a "model" object.
    # Common forms in patches:
    #   model.provider === "opencode" && model.id.toLowerCase().includes("kimi-k2.5")
    #   event.model.provider === "opencode" && event.model.id....
    #   model.provider !== "opencode" return / model.id.toLowerCase().includes("kimi-k2")
    HARNESS=$(cat <<'JSEOF'
function evalPred(exprStr, model) {
  // Map common refs to `model`
  const e = exprStr
    .replace(/event\.model/g, "model")
    .replace(/this\.model/g, "model")
    .replace(/_event\.model/g, "model");
  try {
    // eslint-disable-next-line no-new-func
    const fn = new Function("model", "return (" + e + ");");
    return !!fn(model);
  } catch (err) {
    return "ERR:" + err.message;
  }
}
const expr = process.argv[2];
const cases = [
  { name: "opencode+kimi-k2.5", model: { provider: "opencode", id: "kimi-k2.5" }, expect: true },
  { name: "opencode+kimi-k2", model: { provider: "opencode", id: "kimi-k2" }, expect: true },
  { name: "anthropic+claude", model: { provider: "anthropic", id: "claude-sonnet-4" }, expect: false },
  { name: "openai+gpt4", model: { provider: "openai", id: "gpt-4o" }, expect: false },
  { name: "opencode+gpt", model: { provider: "opencode", id: "gpt-5" }, expect: false },
];
let pass = 0, total = cases.length;
for (const c of cases) {
  const got = evalPred(expr, c.model);
  const ok = got === c.expect;
  console.log(`${ok ? "OK" : "FAIL"} ${c.name}: got=${got} expect=${c.expect}`);
  if (ok) pass++;
}
console.log(`SUMMARY ${pass}/${total}`);
process.exit(pass === total ? 0 : 1);
JSEOF
)
    HARNESS_FILE=$(mktemp /tmp/daxnuts_harness_XXXXXX.js)
    echo "$HARNESS" > "$HARNESS_FILE"
    OUT=$("$RUNNER" "$HARNESS_FILE" "$EXPR" 2>&1)
    echo "$OUT" | tail -8
    if echo "$OUT" | grep -qE 'SUMMARY 5/5'; then
      G6=1
      echo "GATE 6 PASS: predicate behaves correctly on all 5 cases"
    elif echo "$OUT" | grep -qE 'SUMMARY [34]/5'; then
      echo "GATE 6 PARTIAL: predicate partially correct"
    else
      echo "GATE 6 FAIL: predicate incorrect"
    fi
    rm -f "$HARNESS_FILE"
  else
    echo "GATE 6 SKIP: no node/bun available"
  fi
else
  echo "GATE 6 FAIL: no predicate extractable"
fi
[ "$G6" = "1" ] && add_reward 0.15

# ---- Final reward --------------------------------------------------
# Cap at 1.0 (sum of weights = 0.15+0.15+0.20+0.15+0.20+0.15 = 1.00)
echo "GATES: G1=$G1 G2=$G2 G3=$G3 G4=$G4 G5=$G5 G6=$G6"
echo "FINAL REWARD=$REWARD"
echo "$REWARD" > /logs/verifier/reward.txt