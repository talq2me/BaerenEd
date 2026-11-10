-- Call site: EduSiteChecker Cursor Automation after webhook ping.
-- POST /rest/v1/rpc/af_list_edu_site_check_tasks {"p_profile":"AM","p_date":"2026-11-10"}
-- Returns visible-today required/checklist rows that have verify_kind in web_assignments (see display_days / hidedays on the assignment).
-- After the daily webhook, only rows the kid already marked done/complete are included — that is the set to verify.

DROP FUNCTION IF EXISTS af_list_edu_site_check_tasks(text, date);

CREATE OR REPLACE FUNCTION af_list_edu_site_check_tasks(
  p_profile text,
  p_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH v_date AS (
    SELECT COALESCE(
      p_date,
      (NOW() AT TIME ZONE 'America/Toronto')::date
    ) AS d
  ),
  rows AS (
    SELECT
      t.task_name,
      t.is_checklist,
      lower(t.completion_status) AS completion_status,
      wa.section,
      wa.verify_kind,
      wa.verify_params,
      COALESCE(
        CASE
          WHEN t.is_checklist THEN ud.checklist_items->t.task_name->>'verification_status'
          ELSE ud.required_tasks->t.task_name->>'verification_status'
        END,
        'pending'
      ) AS verification_status
    FROM af_get_tasks_required(p_profile) AS t
    CROSS JOIN v_date
    LEFT JOIN user_data ud ON ud.profile = p_profile
    INNER JOIN web_assignments wa
      ON wa.profile = p_profile
      AND wa.title = t.task_name
      AND wa.section = CASE WHEN t.is_checklist THEN 'checklist' ELSE 'required' END
      AND wa.enabled
    WHERE btrim(COALESCE(wa.verify_kind, '')) <> ''
      AND lower(t.completion_status) IN ('complete', 'done')
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'task_name', r.task_name,
        'is_checklist', r.is_checklist,
        'section', r.section,
        'verify_kind', r.verify_kind,
        'verify_params', COALESCE(r.verify_params, '{}'::jsonb),
        'verification_status', r.verification_status
      )
      ORDER BY r.is_checklist, r.task_name
    ),
    '[]'::jsonb
  )
  FROM rows r;
$$;

GRANT EXECUTE ON FUNCTION af_list_edu_site_check_tasks(text, date) TO anon, authenticated, service_role;
