-- Call site: EduSiteChecker automation — one POST after checking all sites for the day.
-- Body example:
-- {
--   "p_profile": "AM",
--   "p_results": [
--     {"task_name":"Read 2 Rallye books","is_checklist":true,"success":true,"note":null},
--     {"task_name":"Anton fractions","is_checklist":false,"success":false,"note":"0 exercises today"}
--   ],
--   "p_clear_marked_on_fail": true
-- }
-- When p_clear_marked_on_fail is true (default): failed checklist items get done=false;
-- failed required tasks get status=incomplete so the app shows what still needs work.

DROP FUNCTION IF EXISTS af_confirm_edu_site_check_batch(text, jsonb, boolean);

CREATE OR REPLACE FUNCTION af_confirm_edu_site_check_batch(
  p_profile text,
  p_results jsonb,
  p_clear_marked_on_fail boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(btrim(COALESCE(p_profile, '')));
  v_now timestamptz := (NOW() AT TIME ZONE 'America/Toronto');
  v_date date := v_now::date;
  elem jsonb;
  v_name text;
  v_is_checklist boolean;
  v_success boolean;
  v_note text;
  v_status text;
  req jsonb;
  chk jsonb;
  patch jsonb;
  v_verified int := 0;
  v_failed int := 0;
BEGIN
  IF v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;
  IF p_results IS NULL OR jsonb_typeof(p_results) <> 'array' THEN
    RAISE EXCEPTION 'p_results must be a JSON array';
  END IF;

  SELECT COALESCE(required_tasks, '{}'::jsonb),
         COALESCE(checklist_items, '{}'::jsonb)
    INTO req, chk
  FROM user_data
  WHERE profile = v_profile
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown profile: %', v_profile;
  END IF;

  FOR elem IN SELECT value FROM jsonb_array_elements(p_results)
  LOOP
    v_name := btrim(elem->>'task_name');
    IF v_name = '' THEN
      CONTINUE;
    END IF;
    v_is_checklist := COALESCE((elem->>'is_checklist')::boolean, false);
    v_success := COALESCE((elem->>'success')::boolean, false);
    v_note := NULLIF(btrim(COALESCE(elem->>'note', '')), '');
    v_status := CASE WHEN v_success THEN 'verified' ELSE 'failed' END;

    IF v_is_checklist THEN
      patch := COALESCE(chk->v_name, '{}'::jsonb) || jsonb_build_object(
        'verification_status', v_status,
        'verified_at', v_now,
        'verification_note', v_note
      );
      IF NOT v_success AND COALESCE(p_clear_marked_on_fail, true) THEN
        patch := patch || jsonb_build_object('done', false);
      END IF;
      chk := jsonb_set(chk, ARRAY[v_name], patch, true);
    ELSE
      patch := COALESCE(req->v_name, '{}'::jsonb) || jsonb_build_object(
        'verification_status', v_status,
        'verified_at', v_now,
        'verification_note', v_note
      );
      IF NOT v_success AND COALESCE(p_clear_marked_on_fail, true) THEN
        patch := patch || jsonb_build_object('status', 'incomplete');
      END IF;
      req := jsonb_set(req, ARRAY[v_name], patch, true);
    END IF;

    IF v_success THEN
      v_verified := v_verified + 1;
    ELSE
      v_failed := v_failed + 1;
    END IF;
  END LOOP;

  UPDATE user_data
  SET
    required_tasks = req,
    checklist_items = chk,
    last_updated = v_now
  WHERE profile = v_profile;

  UPDATE edu_site_checker_runs
  SET status = CASE
    WHEN EXISTS (
      SELECT 1
      FROM jsonb_array_elements(af_list_edu_site_check_tasks(v_profile, v_date)) AS e(item)
      WHERE COALESCE(item->>'verification_status', 'pending') <> 'verified'
    ) THEN 'incomplete'
    ELSE 'complete'
  END
  WHERE profile = v_profile
    AND check_date = v_date;

  RETURN jsonb_build_object(
    'verified', v_verified,
    'failed', v_failed,
    'profile', v_profile,
    'date', to_char(v_date, 'YYYY-MM-DD')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION af_confirm_edu_site_check_batch(text, jsonb, boolean) TO anon, authenticated, service_role;
