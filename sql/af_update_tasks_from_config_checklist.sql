-- Merge enabled checklist rows from web_assignments into user_data.checklist_items (preserves done per label).

CREATE OR REPLACE FUNCTION af_update_tasks_from_config_checklist(p_profile text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(btrim(COALESCE(p_profile, '')));
  existing jsonb;
  merged jsonb;
BEGIN
  IF v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;

  SELECT COALESCE(checklist_items, '{}'::jsonb) INTO existing
  FROM user_data
  WHERE profile = v_profile;

  SELECT COALESCE(
    jsonb_object_agg(
      a.title,
      jsonb_strip_nulls(jsonb_build_object(
        'done', COALESCE((existing->a.title->>'done')::boolean, false),
        'stars', a.stars,
        'displayDays', a.display_days,
        'verification_status', existing->a.title->'verification_status',
        'verification_note', existing->a.title->'verification_note',
        'verified_at', existing->a.title->'verified_at'
      ))
    ),
    '{}'::jsonb
  )
  INTO merged
  FROM web_assignments a
  WHERE a.profile = v_profile
    AND a.section = 'checklist'
    AND a.enabled;

  UPDATE user_data
  SET
    checklist_items = COALESCE(merged, '{}'::jsonb),
    last_updated = (NOW() AT TIME ZONE 'America/Toronto')
  WHERE profile = v_profile;
END;
$$;

GRANT EXECUTE ON FUNCTION af_update_tasks_from_config_checklist(text) TO anon, authenticated, service_role;
