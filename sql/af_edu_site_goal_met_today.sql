-- True if today's edu_site_daily_goals row for this task is goal_met or parent_override.

CREATE OR REPLACE FUNCTION af_edu_site_goal_met_today(
  p_profile text,
  p_task_title text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(btrim(COALESCE(p_profile, '')));
  v_title text := btrim(COALESCE(p_task_title, ''));
  v_date date := (NOW() AT TIME ZONE 'America/Toronto')::date;
  v_ok boolean := false;
BEGIN
  IF v_profile NOT IN ('AM', 'BM', 'TE') OR v_title = '' THEN
    RETURN false;
  END IF;

  SELECT COALESCE(g.goal_met, false) OR COALESCE(g.parent_override, false)
    INTO v_ok
  FROM edu_site_daily_goals g
  WHERE g.profile = v_profile
    AND g.goal_date = v_date
    AND g.task_title = v_title;

  RETURN COALESCE(v_ok, false);
END;
$$;

GRANT EXECUTE ON FUNCTION af_edu_site_goal_met_today(text, text) TO anon, authenticated, service_role;
