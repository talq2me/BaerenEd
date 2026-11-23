-- Mark edu_site_checker_runs complete when every visible-today verify_kind task has goal_met
-- (or parent_override). No outbound webhook in this path.

CREATE OR REPLACE FUNCTION af_maybe_complete_edu_site_checker_run(p_profile text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(btrim(COALESCE(p_profile, '')));
  v_date date := (NOW() AT TIME ZONE 'America/Toronto')::date;
  v_pending int := 0;
  v_total int := 0;
  v_status text;
BEGIN
  IF v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_profile');
  END IF;

  SELECT
    count(*)::int,
    count(*) FILTER (
      WHERE NOT COALESCE(g.goal_met, false) AND NOT COALESCE(g.parent_override, false)
    )::int
  INTO v_total, v_pending
  FROM af_get_tasks_required(v_profile) AS t
  INNER JOIN web_assignments wa
    ON wa.profile = v_profile
   AND wa.title = t.task_name
   AND wa.section = CASE WHEN t.is_checklist THEN 'checklist' ELSE 'required' END
   AND wa.enabled
   AND btrim(COALESCE(wa.verify_kind, '')) <> ''
  LEFT JOIN edu_site_daily_goals g
    ON g.profile = v_profile
   AND g.goal_date = v_date
   AND g.task_title = t.task_name;

  INSERT INTO edu_site_checker_runs (profile, check_date, status, webhook_sent, webhook_send_count)
  VALUES (v_profile, v_date, 'incomplete', false, 0)
  ON CONFLICT (profile, check_date) DO NOTHING;

  IF v_total > 0 AND v_pending = 0 THEN
    v_status := 'complete';
  ELSE
    v_status := 'incomplete';
  END IF;

  UPDATE edu_site_checker_runs
  SET status = v_status
  WHERE profile = v_profile
    AND check_date = v_date;

  RETURN jsonb_build_object(
    'profile', v_profile,
    'date', to_char(v_date, 'YYYY-MM-DD'),
    'status', v_status,
    'verify_tasks', v_total,
    'pending', v_pending
  );
END;
$$;

GRANT EXECUTE ON FUNCTION af_maybe_complete_edu_site_checker_run(text) TO anon, authenticated, service_role;
