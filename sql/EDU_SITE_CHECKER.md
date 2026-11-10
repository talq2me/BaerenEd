# EduSiteChecker webhook

When a child marks **all** visible required tasks and checklist items done for the day, Supabase sends **one** webhook per profile per Toronto day to the Cursor automation **EduSiteChecker Bot Webhook**.

## One-time Supabase setup

1. Run [`edu_site_checker_setup.sql`](edu_site_checker_setup.sql) if the project was created before `edu_site_checker_runs` was added to [`supabase_schema_create.sql`](supabase_schema_create.sql).
2. Deploy RPCs (regen [`supabase_functions_create.sql`](supabase_functions_create.sql) or run the new `af_*.sql` files).
3. In **Supabase Vault**, create secret **`edu_site_checker_webhook_bearer`** with the Cursor automation token only (no `Bearer ` prefix), same pattern as `reading_audio_webhook_bearer`.

Webhook URL (also hard-coded in `af_maybe_enqueue_edu_site_checker.sql`):

`https://api2.cursor.sh/automations/webhook/70a32960-ae8b-5234-b797-bddcebfd118d`

## Automation flow

1. Webhook body: `{"profile":"AM","date":"YYYY-MM-DD","kind":"edu_site_check"}`.
2. `POST /rest/v1/rpc/af_list_edu_site_check_tasks` with `{"p_profile":"<profile>","p_date":"<date>"}`.
   - Returns **only tasks scheduled for that calendar day** (same `display_days` / hide rules as the app) **and** with `verify_kind` set on `web_assignments`.
   - At webhook time the kid has marked everything done, so the list is the set of external sites to check today — not every site in your catalog.
3. Branch in the bot on each row’s `verify_kind` (e.g. `rallye_lecture`, `anton`, `motoufo`, `xtramath`, `boukili`, `beaver_contest`, `northstar_math`).
4. **One** callback: `POST .../rpc/af_confirm_edu_site_check_batch` with all results (see below).

## Many sites, certain days only

Configure each task in `web_assignments`:

| Column | Purpose |
|--------|---------|
| `verify_kind` | Bot switch key, e.g. `rallye_lecture`, `anton`, `boukili` |
| `verify_params` | Site-specific JSON, e.g. `{"min_books": 2}`, `{"min_minutes": 15}` |
| `display_days` | Same as other tasks — if the assignment isn’t visible today, it won’t appear in `af_list_edu_site_check_tasks` |

Tasks **without** `verify_kind` still count toward “all marked done” but are not sent to the bot (in-app games, spelling, etc.).

## Batch callback (preferred)

```json
{
  "p_profile": "AM",
  "p_clear_marked_on_fail": true,
  "p_results": [
    {
      "task_name": "Read 2 Rallye books",
      "is_checklist": true,
      "success": true,
      "note": null
    },
    {
      "task_name": "Anton",
      "is_checklist": false,
      "success": false,
      "note": "Need at least 1 exercise today"
    }
  ]
}
```

Response: `{"verified":1,"failed":1,"profile":"AM","date":"YYYY-MM-DD"}`.

With `p_clear_marked_on_fail: true` (default), failures **unmark** the task in `user_data` (`done=false` on checklist, `status=incomplete` on required) and set `verification_status` / `verification_note` so the kid sees what to fix and **all_done** is false again until they redo the work and re-complete the day.

You can still call `af_confirm_edu_site_check_item` once per task if you prefer; batch is easier for the bot.

## Kid UI

Stored on each task JSON: `verification_status` (`pending` | `verified` | `failed`), `verification_note`. Showing that in the Android app or reports is a follow-up; the data model is in place.

## Re-run same day

Supabase allows **two** automatic webhook sends per profile per Toronto day (`edu_site_checker_runs.webhook_send_count`). After a failed batch unmarks tasks, the child can complete the day again and trigger a second Grok run.

## Schedule editor

In **Checklist / site-verify tasks** and on required/practice rows, use **Site kind** + optional JSON params — same on/off toggle and day picker as other tasks. Saved via `af_web_save_schedule` into `web_assignments.verify_kind` / `verify_params`.

## Parent reports

`verification_status` on each task in `user_data` drives the green ✓ on **index.html** and **daily_progress_report.html** (no Grok calls from the browser).

## Manual test

After Vault is configured, complete the last required item for a profile in the app, then check `edu_site_checker_runs` for `webhook_sent = true` for today’s date.
