# Task: rudel-task-468289

| Field | Value |
|-------|-------|
| Source session | `4682893d-3cfc-46f3-a655-115f08a18bfb` |
| Repo | obsessiondb/rudel (184 stars) |
| Base commit | `799c99ecc34c1448efb6fd860fb09dc683eff29b` |
| Difficulty | medium |
| Category | feature |
| Real user msgs | 3 |
| CI source | `.github/workflows/ci.yml` → `bunx turbo run lint check-types test build` |

## Summary

Implement stable chart colors and metric-sorted legends across 8 chart components in a React/TypeScript analytics dashboard. The user provides a detailed implementation plan covering:
- **colorMap** with stable color assignment (based on identity rank, not metric-dependent index)
- **sortedLegendPayload** for metric-sorted legend ordering
- **stableColorOrder** in ErrorTrendChart (based on `total_errors`, independent of active metric)
- **Deterministic split-key sorting** in DimensionAnalysisChart
- **ChartTooltip component** creation and migration to additional chart files

## User Simulator Behavior
- Total real user messages: 3 in 134 total messages. Silence is the default.
- Longest silence: ~70 agent turns (~10 minutes)
- Turn 1: Delivers the detailed implementation plan (this is `instruction.md`)
- Turn 2: After agent finishes work, says "seems to work please commit changes and open PR"
- Turn 3: PR creation skill checklist for final verification and submission
