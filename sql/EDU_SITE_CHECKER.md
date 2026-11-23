# Edu site progress + daily goals

Scrapers post cumulative (or daily) snapshots. The DB evaluates today’s goals from `web_assignments.verify_kind` / `verify_params`. Kids can mark an edu-site task complete only when that day’s goal is already met (or a parent force-verifies).

The old all-done → Grok webhook scrape path is **disabled**. Vault secret **`edu_site_checker_webhook_bearer`** is the **inbound scraper bearer** (`p_bearer`).

## One-time setup

1. Run [`edu_site_progress_setup.sql`](edu_site_progress_setup.sql) (tables).
2. Deploy RPCs (`regen_deploy_all_functions.ps1` → `supabase_functions_create.sql`, or `deploy_edu_site_progress.ps1`).
3. Vault secret must exist. This project’s secret **name** is **`EduSiteChecker Bot Webhook`** (RPCs also accept `edu_site_checker_webhook_bearer`). The secret **value** is what the scraper sends as `p_bearer` (often a `crsr_` token).

## Scraper call

```http
POST https://xvnosesmkoahykndbzgy.supabase.co/rest/v1/rpc/af_upsert_edu_site_progress
apikey: <supabase anon key>
Authorization: Bearer <supabase anon key>
Content-Type: application/json
```

```json
{
  "p_site_kind": "rallye_lecture",
  "p_bearer": "<vault secret value>",
  "p_raw": {
    "student": "BM",
    "scraped_at": "2026-11-21T16:32:21.207Z",
    "source_url": "https://rallye-lecture.fr/eleve-resultats/",
    "livres_lus": 97,
    "reussite_du_moment_pct": 72,
    "badges_obtenus": 19,
    "derniers_livres_count": 4,
    "derniers_livres_avg_pct": 80,
    "derniers_livres": []
  }
}
```

### Function signature

```sql
af_upsert_edu_site_progress(
  p_site_kind text,
  p_bearer text,
  p_raw jsonb,
  p_profile text DEFAULT NULL,
  p_metrics jsonb DEFAULT NULL,
  p_value_mode text DEFAULT NULL,
  p_source text DEFAULT NULL
) RETURNS jsonb
```

- Profile from `p_profile` or `p_raw.student` (`AM` / `BM` / `TE` only — no real names).
- Stores full `p_raw` on `edu_site_progress_snapshots.raw`.
- Extracts metrics (Rallye: `books` ← `livres_lus`, plus `books_today` vs prior day).
- Evaluates visible-today assignments for that `verify_kind`.
- Returns `{ profile, snapshot_id, metrics, goals: [...] }`.

## Goals on assignments

| Field | Role |
|-------|------|
| `verify_kind` | `rallye_lecture`, `motoufo`, `anton`, `northstar_math`, … |
| `verify_params` | e.g. `{"metric":"books","target":2,"value_mode":"cumulative"}` |
| `display_days` | Day visibility (same as other tasks) |

Aliases still work: `min_books`, `min_feathers`, `min_sessions`, `max_incomplete`.

Optional `compare`: `gte` (default, need at least target) or `lte` (need at most target).

**Anton:** goal is zero incomplete exercises. Defaults are `metric=incomplete`, `target=0`, `value_mode=daily`, `compare=lte`. Scraper posts e.g.:

```json
{
  "p_site_kind": "anton",
  "p_bearer": "<vault secret>",
  "p_raw": {
    "student": "BM",
    "scraped_at": "2026-11-21T16:32:21.207Z",
    "incomplete": 0
  }
}
```

(`incomplete_exercises` is also accepted.) Met when `incomplete <= 0`.

Goals are **daily only** (America/Toronto calendar day). Cumulative sites need a prior-day snapshot before `*_today` can be computed.

## Kid Complete

`af_update_task_completion` / `af_update_tasks_checklist_items` reject complete/done for rows with `verify_kind` unless `edu_site_daily_goals.goal_met` or `parent_override` for today.

## Parent override

Task Manager → **Force verify** → `af_parent_override_edu_site_goal(p_profile, p_task_title, p_is_checklist)`.

## Run ledger

`edu_site_checker_runs.status = complete` when every visible-today `verify_kind` task has `goal_met` (via `af_maybe_complete_edu_site_checker_run`). No outbound webhook yet.
