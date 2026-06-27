# Task: rudel-task-491983

| Field | Value |
|-------|-------|
| Source session | `491983cb-b3ca-448f-b386-3fc23bbd8d05` |
| Repo | obsessiondb/rudel (184 stars) |
| Base commit | `5f27d8f` |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 2 |

## Description

Fix 500 errors on the project details API endpoint. The user reports 500 errors
when loading `https://app.rudel.ai/rpc/analytics/projects/details`. The root cause
is a ClickHouse query in `getProjectDetails` that uses bare `AVG()` without GROUP BY —
when the query matches 0 rows, ClickHouse emits `nan` for the aggregate, which is
invalid JSON and causes a parse error → 500. A secondary navigation bug exists in
the frontend where open-source projects with empty `project_path` can't be navigated to.

## User Simulator Behavior

- Total real user messages: 2 in 2 turns. Silence is the default.
- Longest silence: 75 agent turns (~16 minutes)
- Turn 1: Bug report — "I see 500 errors when loading the Project details specifically this endpoint https://app.rudel.ai/rpc/analytics/projects/details"
- Turn 2: Approval — "ok commit and open pr"

## Changes Required

1. **API fix** (`apps/api/src/services/project.service.ts`): Replace bare `AVG()` with `avgOrNull()` + `ifNull()` in the `getProjectDetails` ClickHouse query to prevent NaN on empty result sets. Tighten the null guard to return NOT_FOUND when `total_sessions === 0`.

2. **Frontend fix** (`apps/web/src/pages/dashboard/ProjectsListPage.tsx`): Navigate by `git_remote` (falling back to `project_path`) so open-source projects where `project_path` is empty correctly reach the detail page.

## CI Source

`.github/workflows/ci.yml` runs `bunx turbo run lint check-types test build` with PG_CONNECTION_STRING + CLICKHOUSE_URL secrets. Integration tests not runnable without backend infrastructure.
