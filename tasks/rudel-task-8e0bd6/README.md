# Task: rudel-task-8e0bd6

| Field | Value |
|-------|-------|
| Source session | `8e0bd61c-0332-4bb5-b76c-7a342db7d775` |
| Repo | obsessiondb/rudel (184 stars) |
| Base commit | `aa38a30fec325453291cc6ffeb1baa93045f7755` |
| Canonical commit | `9f5a1633e80abb372099f4a51b0e6742850396e6` |
| Difficulty | medium |
| Category | feature |
| Real user msgs | ~25 (15 text + 10 images over 38 total turns) |

## Summary

Add export/share buttons with branded watermarks to Rudel's dashboard analytics charts. The user provided a detailed 6K-char plan covering: installing `html-to-image` + `sonner`, creating a screenshot utility (`screenshot.ts`), building a `ChartCard` wrapper component with watermark overlays and a share dropdown, integrating a toast system, and updating 8+ dashboard pages to use the new component.

## Implementation Requirements

1. Add `html-to-image` and `sonner` to `apps/web/package.json` dependencies
2. Create `apps/web/src/lib/screenshot.ts` — capture, clipboard, download, share utilities
3. Create `apps/web/src/components/analytics/ChartCard.tsx` — wraps `AnalyticsCard` with watermark + share dropdown
4. Add `<Toaster />` from sonner to `apps/web/src/layouts/DashboardLayout.tsx`
5. Replace bare `<AnalyticsCard>` + manual headers with `<ChartCard>` in dashboard pages (OverviewPage, ProjectsListPage, DevelopersListPage, SessionsListPage, ErrorsPage, LearningsPage, ROIPage, ProjectDetailPage, DeveloperDetailPage)

## Verification

5 F2P gates (sum weights = 1.0):
- `f2p_pkg_deps` (0.15): Dependencies added to package.json
- `f2p_screenshot_lib` (0.20): Screenshot utility with 4 non-stub functions
- `f2p_chartcard_comp` (0.25): ChartCard component structure
- `f2p_page_usage` (0.20): Dashboard pages using ChartCard
- `f2p_toaster` (0.20): Toaster integration in layout

2 P2P regression gates (zero on fail):
- AnalyticsCard.tsx preserved
- package.json remains valid JSON

## User Simulator Behavior

- Total real user messages: 15 text turns in 38 total. Default is silence.
- Longest silence: 118 agent turns (~7 minutes while agent implements)
- Pattern: detailed plan → silence → PR request → local testing → iterative visual polish → approval
- User is hands-on, tests locally, provides visual feedback with screenshots
- Turn-by-turn summary: see user_simulation_prompt.md
