-- Parent reports: today's site-check tasks and verification_status from user_data (no Grok calls).

DROP FUNCTION IF EXISTS af_web_edu_site_verification(text);

CREATE OR REPLACE FUNCTION af_web_edu_site_verification(p_profile text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH rows AS (
    SELECT
      t.task_name,
      t.is_checklist,
      lower(t.completion_status) AS completion_status,
      wa.section,
      wa.verify_kind,
      COALESCE(
        CASE
          WHEN t.is_checklist THEN ud.checklist_items->t.task_name->>'verification_status'
          ELSE ud.required_tasks->t.task_name->>'verification_status'
        END,
        'none'
      ) AS verification_status,
      COALESCE(
        CASE
          WHEN t.is_checklist THEN ud.checklist_items->t.task_name->>'verification_note'
          ELSE ud.required_tasks->t.task_name->>'verification_note'
        END,
        ''
      ) AS verification_note,
      r.status AS run_status,
      COALESCE(r.webhook_send_count, 0) AS webhook_send_count
    FROM af_get_tasks_required(p_profile) AS t
    LEFT JOIN user_data ud ON ud.profile = p_profile
    INNER JOIN web_assignments wa
      ON wa.profile = upper(btrim(p_profile))
      AND wa.title = t.task_name
      AND wa.section = CASE WHEN t.is_checklist THEN 'checklist' ELSE 'required' END
      AND wa.enabled
    LEFT JOIN edu_site_checker_runs r
      ON r.profile = upper(btrim(p_profile))
      AND r.check_date = (NOW() AT TIME ZONE 'America/Toronto')::date
    WHERE btrim(COALESCE(wa.verify_kind, '')) <> ''
  ),
  agg AS (
    SELECT
      count(*)::int AS need_verify,
      count(*) FILTER (WHERE verification_status = 'verified')::int AS verified,
      count(*) FILTER (WHERE verification_status = 'failed')::int AS failed,
      count(*) FILTER (WHERE verification_status IN ('pending', 'none'))::int AS pending,
      max(run_status) AS run_status,
      max(webhook_send_count) AS webhook_send_count
    FROM rows
  )
  SELECT jsonb_build_object(
    'summary', (
      SELECT jsonb_build_object(
        'need_verify', a.need_verify,
        'verified', a.verified,
        'failed', a.failed,
        'pending', a.pending,
        'all_verified', a.need_verify > 0 AND a.verified = a.need_verify,
        'run_status', a.run_status,
        'webhook_send_count', COALESCE(a.webhook_send_count, 0)
      )
      FROM agg a
    ),
    'tasks', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'title', r.task_name,
            'is_checklist', r.is_checklist,
            'section', r.section,
            'verify_kind', r.verify_kind,
            'completion_status', r.completion_status,
            'verification_status', r.verification_status,
            'verification_note', NULLIF(btrim(r.verification_note), '')
          )
          ORDER BY r.is_checklist, r.task_name
        )
        FROM rows r
      ),
      '[]'::jsonb
    )
  );
$$;

GRANT EXECUTE ON FUNCTION af_web_edu_site_verification(text) TO anon, authenticated, service_role;
