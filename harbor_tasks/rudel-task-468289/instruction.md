Implement the following plan:

# Plan: Consistent Legend Sorting + Stable Colors

## Context

Chart legends on the right side have two problems:
1. **Inconsistent sort order**: ProjectTrendChart and DeveloperTrendChart always sort by sessions (even when tokens or hours is selected). ErrorTrendChart re-sorts by the active metric but that also changes colors. DimensionAnalysisChart uses non-deterministic Set insertion order.
2. **Unstable colors**: In ErrorTrendChart, switching metrics re-ranks series → colors shift. This is confusing because e.g. "project-a" might be blue on one metric and red on another.

**Goal**: Legend always sorted by highest total of the currently selected metric (top = biggest), AND each series retains the same color regardless of which metric is selected.

## Key Insight

Separate **color assignment** (stable, identity-based) from **display order** (dynamic, metric-based):
- `colorMap: Map<string, string>` — computed from a stable ranking (sessions or total_errors). Never changes within a chart session.
- `sortedLegendPayload` — series sorted by current metric totals, colors pulled from `colorMap`. Passed directly to `ChartLegend` instead of recharts' auto-generated `payload`.
- Bar/Line declaration order stays stable (colorMap-based) to avoid visual reordering of stacked bars.

## Charts to change

### 1. `ProjectTrendChart.tsx`

**Color assignment** — already stable (ranked by sessions). Add explicit `colorMap`:
```ts
const colorMap = useMemo(() => {
  const map = new Map<string, string>();
  topProjects.forEach((p, i) => map.set(p, PROJECT_COLORS[i % PROJECT_COLORS.length]));
  map.set("Other", OTHER_COLOR);
  return map;
}, [topProjects]);
```

**sortedLegendPayload** — sort `seriesList` by current metric total using `chartData`:
```ts
const sortedLegendPayload = useMemo(() => {
  const totals = new Map<string, number>();
  for (const row of chartData) {
    for (const key of seriesList) {
      totals.set(key, (totals.get(key) ?? 0) + ((row[key] as number) ?? 0));
    }
  }
  return [...seriesList]
    .sort((a, b) => (totals.get(b) ?? 0) - (totals.get(a) ?? 0))
    .map(key => ({ value: key, color: colorMap.get(key) ?? OTHER_COLOR, type: "square" as const }));
}, [chartData, seriesList, colorMap]);
```

**Changes to JSX**:
- `<Line stroke={colorMap.get(projectPath) ?? OTHER_COLOR}>`
- `<Bar fill={colorMap.get(projectPath) ?? OTHER_COLOR}>`
- `<Legend content={() => <ChartLegend payload={sortedLegendPayload} ... />}>`  (ignore recharts `payload`)

### 2. `DeveloperTrendChart.tsx`

Identical pattern to ProjectTrendChart. `colorMap` based on `topDevelopers` (sessions rank). `sortedLegendPayload` sorted by current metric total.

### 3. `ErrorTrendChart.tsx`

**Problem**: `seriesKeys` is recomputed per metric change, so colors shift.

**Stable colorMap** — rank by `total_errors` (the primary summable metric, independent of active metric):
```ts
const stableColorOrder = useMemo(() => {
  const totals = new Map<string, number>();
  for (const item of data) {
    totals.set(item.dimension, (totals.get(item.dimension) ?? 0) + item.total_errors);
  }
  return [...totals.entries()].sort((a, b) => b[1] - a[1]).slice(0, MAX_SERIES).map(([k]) => k);
}, [data]);

const colorMap = useMemo(() => {
  const map = new Map<string, string>();
  stableColorOrder.forEach((k, i) => map.set(k, COLORS[i % COLORS.length]));
  map.set("Other", OTHER_COLOR);
  return map;
}, [stableColorOrder]);
```

`seriesKeys` still sorted by active metric (already correct for legend order). Build `sortedLegendPayload` from `seriesKeys` mapped with `colorMap` colors.

**Changes to JSX**:
- `<Bar fill={colorMap.get(key) ?? COLORS[0]}>`
- `<Line stroke={colorMap.get(key) ?? COLORS[0]}>`
- `<Legend content={() => <ChartLegend payload={sortedLegendPayload} ... />}>`

### 4. `DimensionAnalysisChart.tsx`

When `split_by` is set, `rawSplitKeys` comes from Set iteration (insertion order = non-deterministic). Fix: sort by total raw metric value across all dimension values.

Inside the existing `useMemo` for `chartData/dataKeys`, after collecting `rawSplitKeys`:
```ts
// Sort split keys by total raw value descending
const splitKeyTotals = new Map<string, number>();
for (const item of data) {
  for (const key of rawSplitKeys) {
    splitKeyTotals.set(key, (splitKeyTotals.get(key) ?? 0) + (item.split_values?.[key] || 0));
  }
}
rawSplitKeys.sort((a, b) => (splitKeyTotals.get(b) ?? 0) - (splitKeyTotals.get(a) ?? 0));
```
Colors follow naturally (index-based on sorted order). When `split_by` or data changes, a full recompute is fine.

## Charts NOT changed

- **ModelTokensChart** — single metric, already sorted by tokens total. ✓
- **LearningsTrendChart** — single metric (count), sorted by total. ✓
- **UsageTrendChart** — fixed 2 series, no sorting needed. ✓
- **TaskClassificationChart** — pie chart, different design. ✓

## File paths

- `apps/web/src/components/charts/ProjectTrendChart.tsx`
- `apps/web/src/components/charts/DeveloperTrendChart.tsx`
- `apps/web/src/components/charts/ErrorTrendChart.tsx`
- `apps/web/src/components/charts/DimensionAnalysisChart.tsx`

## Verification

1. `bun run verify` — types and lint pass
2. In ProjectTrendChart: select "Tokens" → legend reorders to highest-token project at top; switch back to "Sessions" → order reverts; colors remain the same across switches
3. In ErrorTrendChart: switch from "Total Errors" → "Avg per Session" → legend reorders but colors stay the same per project/user/model
4. In DimensionAnalysis: select a 2nd dimension → legend items appear sorted by highest split value at top
