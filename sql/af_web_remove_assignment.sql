-- Removes one web_assignments row by profile, section, and launch.
-- Match is not the title, so a sentence task can be removed before a new title is added.
-- Does not write user_data. Call af_update_tasks_from_config_required afterward.

CREATE OR REPLACE FUNCTION af_web_remove_assignment(
  p_profile text,
  p_section text,
  p_launch text
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(trim(p_profile));
  v_section text := lower(trim(p_section));
  v_launch text := nullif(btrim(p_launch), '');
  v_n int;
BEGIN
  IF v_profile IS NULL OR v_profile = '' OR v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;
  IF v_section IS NULL OR v_section NOT IN ('required', 'optional', 'bonus', 'checklist') THEN
    RAISE EXCEPTION 'Invalid section: %', p_section;
  END IF;
  IF v_launch IS NULL THEN
    RAISE EXCEPTION 'p_launch is required';
  END IF;

  DELETE FROM web_assignments
  WHERE profile = v_profile
    AND section = v_section
    AND launch = v_launch;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;

GRANT EXECUTE ON FUNCTION af_web_remove_assignment(text, text, text) TO anon, authenticated, service_role;
