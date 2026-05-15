#!/usr/bin/env bash
# Verifier — rudel: stable chart colors + metric-sorted legends.
# Behavioral structural gates checked against the patched repo using python3
# regex/AST checks. Each gate writes a JSON verdict; reward is computed by the
# weighted-replace formula in [0, 1]. There is no test infrastructure for the
# chart components themselves in the upstream repo, so structural F2P gates
# are the only signal — they target the four canonical patterns from the plan
# (colorMap, sortedLegendPayload, stableColorOrder, ChartTooltip migration)
# and validate the canonical 8-file diff.
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REPO=/workspace/rudel
CHARTS_DIR="$REPO/apps/web/src/components/charts"
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
REWARD_FILE="$LOGS_DIR/reward.txt"
GATES_FILE="$LOGS_DIR/gates.json"
mkdir -p "$LOGS_DIR"

cd "$REPO" || { echo "ERROR: cd $REPO" >&2; echo 0.0 > "$REWARD_FILE"; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# Helper: run a python3 snippet via env-passed CHARTS_DIR; capture stdout
# ──────────────────────────────────────────────────────────────────────────────
run_gate() {
    local gid="$1"
    local snippet="$2"
    CHARTS_DIR="$CHARTS_DIR" python3 -c "$snippet" 2>&1
}

# ──────────────────────────────────────────────────────────────────────────────
# F2P_CHARTTOOLTIP_FILE (weight 0.10): ChartTooltip.tsx exists and exports the
# ChartTooltip function. This is the foundation — the migration cannot work
# without the component.
# ──────────────────────────────────────────────────────────────────────────────
G1=$(run_gate F2P_CHARTTOOLTIP_FILE '
import os
p = os.path.join(os.environ["CHARTS_DIR"], "ChartTooltip.tsx")
if not os.path.exists(p):
    print("FAIL: ChartTooltip.tsx missing"); raise SystemExit(0)
content = open(p).read()
if "export function ChartTooltip" not in content and "export const ChartTooltip" not in content:
    print("FAIL: ChartTooltip not exported"); raise SystemExit(0)
print("PASS")
')
G1_PASS=$([[ "$G1" == "PASS"* ]] && echo true || echo false)

# ──────────────────────────────────────────────────────────────────────────────
# F2P_COLOR_MAPS (weight 0.20): ProjectTrendChart and DeveloperTrendChart
# define a `colorMap` (useMemo) and consume it via `colorMap.get(...)`. The
# canonical patch wires Bar fill/Line stroke through colorMap so colors are
# stable across metric switches. Implementation-agnostic — accepts any const
# colorMap = useMemo(...) form.
# ──────────────────────────────────────────────────────────────────────────────
G2=$(run_gate F2P_COLOR_MAPS '
import os, re
score = 0
for chart in ["ProjectTrendChart", "DeveloperTrendChart"]:
    p = os.path.join(os.environ["CHARTS_DIR"], f"{chart}.tsx")
    if not os.path.exists(p):
        print(f"FAIL: {chart}.tsx missing"); continue
    s = open(p).read()
    has_cm = bool(re.search(r"const\s+colorMap\s*=\s*useMemo", s))
    uses_cm = "colorMap.get(" in s
    if has_cm and uses_cm:
        score += 1
if score >= 2:
    print("PASS")
else:
    print(f"FAIL: only {score}/2 charts use colorMap")
')
G2_PASS=$([[ "$G2" == "PASS"* ]] && echo true || echo false)

# ──────────────────────────────────────────────────────────────────────────────
# F2P_SORTED_LEGEND (weight 0.20): At least one of the two trend charts has a
# sortedLegendPayload (or any sort-by-totals legend computation) AND wires it
# into the <Legend content={... payload={sortedLegendPayload}}> JSX. We accept
# either name as long as a totals-sorted legend payload reaches ChartLegend.
# ──────────────────────────────────────────────────────────────────────────────
G3=$(run_gate F2P_SORTED_LEGEND '
import os, re
score = 0
for chart in ["ProjectTrendChart", "DeveloperTrendChart"]:
    p = os.path.join(os.environ["CHARTS_DIR"], f"{chart}.tsx")
    if not os.path.exists(p):
        continue
    s = open(p).read()
    # Define a sorted legend payload OR sort by totals
    has_sorted_decl = "sortedLegendPayload" in s
    sorts_by_totals = bool(re.search(r"\.sort\([^)]*totals", s, re.DOTALL))
    # Pass it to ChartLegend (either by name or as a totals-sorted local)
    wires_to_legend = bool(re.search(r"payload=\{sortedLegendPayload\}", s)) or \
                       (sorts_by_totals and "ChartLegend" in s)
    if (has_sorted_decl or sorts_by_totals) and wires_to_legend:
        score += 1
if score >= 1:
    print("PASS")
else:
    print(f"FAIL: only {score}/2 charts pipe sorted legend payload to ChartLegend")
')
G3_PASS=$([[ "$G3" == "PASS"* ]] && echo true || echo false)

# ──────────────────────────────────────────────────────────────────────────────
# F2P_STABLE_COLORS (weight 0.20): ErrorTrendChart establishes a stable color
# rank (independent of the active metric) and consumes colors via colorMap.
# Implementation-agnostic — accepts any name for the stable-rank variable as
# long as it ranks by total_errors and feeds colorMap.get(...).
# ──────────────────────────────────────────────────────────────────────────────
G4=$(run_gate F2P_STABLE_COLORS '
import os, re
p = os.path.join(os.environ["CHARTS_DIR"], "ErrorTrendChart.tsx")
if not os.path.exists(p):
    print("FAIL: ErrorTrendChart.tsx missing"); raise SystemExit(0)
s = open(p).read()
has_stable_order = bool(re.search(r"stableColorOrder|stable_color_order|stableOrder|colorRank", s, re.IGNORECASE))
ranks_by_total_errors = "total_errors" in s
uses_color_map = "colorMap.get(" in s
defines_color_map = bool(re.search(r"const\s+colorMap\s*=\s*useMemo", s))
if has_stable_order and ranks_by_total_errors and uses_color_map and defines_color_map:
    print("PASS")
else:
    print(f"FAIL: stableOrder={has_stable_order} totalErrors={ranks_by_total_errors} colorMap.get={uses_color_map} colorMapDecl={defines_color_map}")
')
G4_PASS=$([[ "$G4" == "PASS"* ]] && echo true || echo false)

# ──────────────────────────────────────────────────────────────────────────────
# F2P_DIMENSION_SORT (weight 0.10): DimensionAnalysisChart sorts the split_by
# keys by total raw value descending instead of relying on Set insertion order.
# ──────────────────────────────────────────────────────────────────────────────
G5=$(run_gate F2P_DIMENSION_SORT '
import os, re
p = os.path.join(os.environ["CHARTS_DIR"], "DimensionAnalysisChart.tsx")
if not os.path.exists(p):
    print("FAIL: DimensionAnalysisChart.tsx missing"); raise SystemExit(0)
s = open(p).read()
sorts_split_keys = bool(re.search(r"rawSplitKeys\.sort|splitKeyTotals|splitKey.*\.sort", s))
if sorts_split_keys:
    print("PASS")
else:
    print("FAIL: no sort over rawSplitKeys/splitKeyTotals")
')
G5_PASS=$([[ "$G5" == "PASS"* ]] && echo true || echo false)

# ──────────────────────────────────────────────────────────────────────────────
# F2P_TOOLTIP_MIGRATION (weight 0.15): At least 2 of 3 single-metric charts
# (LearningsTrendChart, ModelTokensChart, UsageTrendChart) import and use the
# new <ChartTooltip /> component. Lenient ratio (2/3) accepts partial credit.
# ──────────────────────────────────────────────────────────────────────────────
G6=$(run_gate F2P_TOOLTIP_MIGRATION '
import os
score = 0
for chart in ["LearningsTrendChart", "ModelTokensChart", "UsageTrendChart"]:
    p = os.path.join(os.environ["CHARTS_DIR"], f"{chart}.tsx")
    if not os.path.exists(p):
        continue
    s = open(p).read()
    if "import { ChartTooltip }" in s and "<ChartTooltip" in s:
        score += 1
if score >= 2:
    print("PASS")
else:
    print(f"FAIL: only {score}/3 charts migrated to ChartTooltip")
')
G6_PASS=$([[ "$G6" == "PASS"* ]] && echo true || echo false)

# ── Build gates.json (audit log; never affects reward by itself) ─────────────
python3 - "$GATES_FILE" "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS" "$G6_PASS" <<'PYEOF'
import json, sys
gates_file = sys.argv[1]
verdicts = [s == "true" for s in sys.argv[2:8]]
ids = ["F2P_CHARTTOOLTIP_FILE", "F2P_COLOR_MAPS", "F2P_SORTED_LEGEND",
       "F2P_STABLE_COLORS", "F2P_DIMENSION_SORT", "F2P_TOOLTIP_MIGRATION"]
gates = [{"id": gid, "pass": v, "kind": "F2P"} for gid, v in zip(ids, verdicts)]
with open(gates_file, "w") as f:
    json.dump(gates, f, indent=2)
PYEOF

# ── Weighted-replace reward formula ──────────────────────────────────────────
# Weights sum to 0.95; the inner remainder (0.05) is unused since there is no
# legacy/inner reward source for this task (no upstream chart tests).
declare -A WEIGHTS
WEIGHTS[F2P_CHARTTOOLTIP_FILE]=0.10
WEIGHTS[F2P_COLOR_MAPS]=0.20
WEIGHTS[F2P_SORTED_LEGEND]=0.20
WEIGHTS[F2P_STABLE_COLORS]=0.20
WEIGHTS[F2P_DIMENSION_SORT]=0.10
WEIGHTS[F2P_TOOLTIP_MIGRATION]=0.15

declare -A VERDICTS
VERDICTS[F2P_CHARTTOOLTIP_FILE]=$G1_PASS
VERDICTS[F2P_COLOR_MAPS]=$G2_PASS
VERDICTS[F2P_SORTED_LEGEND]=$G3_PASS
VERDICTS[F2P_STABLE_COLORS]=$G4_PASS
VERDICTS[F2P_DIMENSION_SORT]=$G5_PASS
VERDICTS[F2P_TOOLTIP_MIGRATION]=$G6_PASS

base_reward=$(cat "$LOGS_DIR/base_reward.txt" 2>/dev/null || echo "0.0")

# P2P_REGRESSION: informational only — diagnostic/penalty only
p2p_failed=false

# F2P: at least one gate must pass for non-zero reward (and only if no inner reward)
f2p_any_pass=false
for gid in "${!WEIGHTS[@]}"; do
    if [[ "${VERDICTS[$gid]:-false}" == "true" ]]; then
        f2p_any_pass=true
        break
    fi
done

if $p2p_failed || (! $f2p_any_pass && [[ $(python3 -c "print(float('$base_reward') <= 0)") == "True" ]]); then
    reward=0.0
else
    reward=$(python3 -c "
existing = float('$base_reward')
weights = {'F2P_CHARTTOOLTIP_FILE': 0.10, 'F2P_COLOR_MAPS': 0.20, 'F2P_SORTED_LEGEND': 0.20, 'F2P_STABLE_COLORS': 0.20, 'F2P_DIMENSION_SORT': 0.10, 'F2P_TOOLTIP_MIGRATION': 0.15}
verdicts = {'F2P_CHARTTOOLTIP_FILE': '$G1_PASS', 'F2P_COLOR_MAPS': '$G2_PASS', 'F2P_SORTED_LEGEND': '$G3_PASS', 'F2P_STABLE_COLORS': '$G4_PASS', 'F2P_DIMENSION_SORT': '$G5_PASS', 'F2P_TOOLTIP_MIGRATION': '$G6_PASS'}
weight_sum = sum(weights.values())
inner = max(0.0, 1.0 - weight_sum)
r = existing * inner
for gid, w in weights.items():
    if verdicts.get(gid) == 'true':
        r += w
print(f'{max(0.0, min(1.0, r)):.6f}')
")
fi

echo "$reward" > "$REWARD_FILE"
echo "─────────────────────────────────────────────────"
echo "Gate verdicts:"
for gid in F2P_CHARTTOOLTIP_FILE F2P_COLOR_MAPS F2P_SORTED_LEGEND F2P_STABLE_COLORS F2P_DIMENSION_SORT F2P_TOOLTIP_MIGRATION; do
    echo "  $gid = ${VERDICTS[$gid]}"
done
echo "Final reward: $reward"
