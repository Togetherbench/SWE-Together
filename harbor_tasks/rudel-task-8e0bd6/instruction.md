Implement the following plan:

# Plan: Add Export/Share Buttons with Watermark to Rudel Charts

## Context

Rudel's dashboard charts have no export or sharing functionality. We want to add "Share to X" (Twitter) buttons similar to datalenses, plus a branded watermark so shared screenshots are identifiable as coming from Rudel. The watermark should show "rudel.ai" prominently and "powered by ObsessionDB" in small text.

## Approach

### 1. Install dependencies

- `html-to-image` — DOM screenshot capture (TypeScript-native, maintained fork of `dom-to-image` used by datalenses)
- `sonner` — lightweight toast library (shadcn-compatible, no existing toast system in Rudel)

Files: `apps/web/package.json`

### 2. Set up toast system

Add `<Toaster />` from sonner to the app layout.

Files:
- `apps/web/src/layouts/DashboardLayout.tsx` (or wherever the root layout is) — add `<Toaster />`

### 3. Create screenshot utility

`apps/web/src/lib/screenshot.ts` — TypeScript utility:
- `captureElement(element: HTMLElement): Promise<Blob>` — uses `html-to-image` `toBlob()`
- `copyToClipboard(blob: Blob): Promise<boolean>` — clipboard write with Safari detection fallback
- `downloadAsImage(blob: Blob, filename: string)` — fallback download via `<a>` + `URL.createObjectURL`
- `shareToX(text: string)` — opens `https://twitter.com/intent/tweet?text={encoded}` in new window

### 4. Create `ChartCard` component

`apps/web/src/components/analytics/ChartCard.tsx` — new component wrapping `AnalyticsCard`:

```
┌─────────────────────────────────────────────┐
│ Title                        [Share ▾] btn  │
│ Subtitle                                    │
│ ┌─────────────────────────────────────────┐ │
│ │         (chart content)                 │ │
│ │                                         │ │
│ │           rudel.ai          ← watermark │ │
│ │                                         │ │
│ │              powered by ObsessionDB  ←  │ │
│ └─────────────────────────────────────────┘ │
└─────────────────────────────────────────────┘
        ↑ this inner div is the screenshot ref
```

Props:
```ts
interface ChartCardProps {
  title: string;
  description?: string;
  children: ReactNode;
  className?: string;
  shareable?: boolean; // default true
}
```

- **Header row**: title + description on left, share dropdown button on right
- **Chart container**: inner `div` with `ref` for screenshot capture, contains children + watermark overlay
- **Watermark**: two absolutely-positioned elements inside the chart container:
  - "rudel.ai" — centered, large (~2rem), low opacity (~0.15), `pointer-events: none`
  - "powered by ObsessionDB" — bottom-right, small (~0.65rem), low opacity (~0.2), `pointer-events: none`
- **Share dropdown** (using existing `DropdownMenu`):
  - "Share on X" — captures screenshot → clipboard → opens Twitter intent → toast confirmation
  - "Copy as image" — captures screenshot → clipboard → toast
  - "Download as PNG" — captures screenshot → downloads file

### 5. Replace `AnalyticsCard` with `ChartCard` in dashboard pages

Update each page to use `ChartCard` instead of manual `<AnalyticsCard>` + `<h2>` + `<p>` pattern.

Files to update:
- `apps/web/src/pages/dashboard/OverviewPage.tsx` (2 charts: UsageTrend, ModelTokens)
- `apps/web/src/pages/dashboard/ProjectsListPage.tsx` (1 chart: ProjectTrend)
- `apps/web/src/pages/dashboard/DevelopersListPage.tsx` (1 chart: DeveloperTrend)
- `apps/web/src/pages/dashboard/SessionsListPage.tsx` (1 chart: TaskClassification)
- `apps/web/src/pages/dashboard/ErrorsPage.tsx` (1 chart: ErrorTrend)
- `apps/web/src/pages/dashboard/LearningsPage.tsx` (1 chart: LearningsTrend)
- `apps/web/src/pages/dashboard/ROIPage.tsx` (2 inline charts)
- `apps/web/src/pages/dashboard/ProjectDetailPage.tsx` (1 inline chart)
- `apps/web/src/pages/dashboard/DeveloperDetailPage.tsx` (2 inline charts)

The existing `AnalyticsCard` component stays untouched (still used by StatCard and non-chart cards).

### 6. Watermark styling details

- Both watermark elements use `absolute` positioning inside a `relative` container
- `pointer-events: none` and `select-none` so they don't interfere with chart interactions
- Use `text-foreground` with very low opacity so they adapt to light/dark themes
- The watermark is always visible (not just in screenshots) — same as datalenses

## File Summary

| File | Action |
|------|--------|
| `apps/web/package.json` | Add `html-to-image`, `sonner` |
| `apps/web/src/lib/screenshot.ts` | **New** — screenshot + clipboard + share utilities |
| `apps/web/src/components/analytics/ChartCard.tsx` | **New** — chart card with watermark + share dropdown |
| `apps/web/src/layouts/DashboardLayout.tsx` | Add `<Toaster />` |
| `apps/web/src/pages/dashboard/OverviewPage.tsx` | Replace AnalyticsCard → ChartCard for chart sections |
| `apps/web/src/pages/dashboard/ProjectsListPage.tsx` | Same |
| `apps/web/src/pages/dashboard/DevelopersListPage.tsx` | Same |
| `apps/web/src/pages/dashboard/SessionsListPage.tsx` | Same |
| `apps/web/src/pages/dashboard/ErrorsPage.tsx` | Same |
| `apps/web/src/pages/dashboard/LearningsPage.tsx` | Same |
| `apps/web/src/pages/dashboard/ROIPage.tsx` | Same |
| `apps/web/src/pages/dashboard/ProjectDetailPage.tsx` | Same |
| `apps/web/src/pages/dashboard/DeveloperDetailPage.tsx` | Same |

## Verification

1. `bun run verify` — type check + lint + tests pass
2. `bun run dev:local` — visual check:
   - Watermark visible on all chart cards (light + dark mode)
   - Share dropdown appears on hover/click
   - "Share on X" copies to clipboard + opens Twitter intent
   - "Copy as image" copies to clipboard + toast
   - "Download as PNG" downloads file with timestamp name
   - Watermark appears in downloaded/shared images
