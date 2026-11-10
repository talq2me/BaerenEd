-- Call site: EduSiteChecker automation after checking a site.
-- POST .../rpc/af_confirm_edu_site_check_item
--   {"p_profile":"AM","p_task_name":"Read 2 Rallye books","p_is_checklist":true,"p_success":true,"p_note":"2 books today"}

DROP FUNCTION IF EXISTS af_confirm_edu_site_check_item(text, text, boolean, boolean, text);

CREATE OR REPLACE FUNCTION af_confirm_edu_site_check_item(
  p_profile text,
  p_task_name text,
  p_is_checklist boolean,
  p_success boolean,
  p_note text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(btrim(COALESCE(p_profile, '')));
  v_status text := CASE WHEN p_success THEN 'verified' ELSE 'failed' END;
  v_now timestamptz := (NOW() AT TIME ZONE 'America/Toronto');
  v_date date := v_now::date;
  cur jsonb;
  patch jsonb;
  v_pending int;
BEGIN
  IF v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;
  IF btrim(COALESCE(p_task_name, '')) = '' THEN
    RAISE EXCEPTION 'task_name required';
  END IF;

  IF p_is_checklist THEN
    SELECT COALESCE(checklist_items, '{}'::jsonb) INTO cur FROM user_data WHERE profile = v_profile;
    patch := COALESCE(cur->p_task_name, '{}'::jsonb) || jsonb_build_object(
      'verification_status', v_status,
      'verified_at', v_now,
      'verification_note', NULLIF(btrim(COALESCE(p_note, '')), '')
    );
    UPDATE user_data
    SET
      checklist_items = jsonb_set(cur, ARRAY[p_task_name], patch, true),
      last_updated = v_now
    WHERE profile = v_profile;
  ELSE
    SELECT COALESCE(required_tasks, '{}'::jsonb) INTO cur FROM user_data WHERE profile = v_profile;
    patch := COALESCE(cur->p_task_name, '{}'::jsonb) || jsonb_build_object(
      'verification_status', v_status,
      'verified_at', v_now,
      'verification_note', NULLIF(btrim(COALESCE(p_note, '')), '')
    );
    UPDATE user_data
    SET
      required_tasks = jsonb_set(cur, ARRAY[p_task_name], patch, true),
      last_updated = v_now
    WHERE profile = v_profile;
  END IF;

  SELECT count(*)::int INTO v_pending
  FROM jsonb_array_elements(af_list_edu_site_check_tasks(v_profile, v_date)) AS e(elem)
  WHERE COALESCE(e.elem->>'verification_status', 'pending') <> 'verified';

  UPDATE edu_site_checker_runs
  SET status = CASE WHEN COALESCE(v_pending, 0) > 0 THEN 'incomplete' ELSE 'complete' END
  WHERE profile = v_profile
    AND check_date = v_date;
END;
$$;

GRANT EXECUTE ON FUNCTION af_confirm_edu_site_check_item(text, text, boolean, boolean, text) TO anon, authenticated, service_role;
