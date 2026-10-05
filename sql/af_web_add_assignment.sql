-- Adds one web_assignments row. Inserts the launch into web_games when it is missing.
-- Does not write user_data. Call af_update_tasks_from_config_required afterward.

CREATE OR REPLACE FUNCTION af_web_add_assignment(
  p_profile text,
  p_section text,
  p_launch text,
  p_title text,
  p_url text,
  p_sort_order int,
  p_stars int,
  p_description text,
  p_web_game boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(trim(p_profile));
  v_section text := lower(trim(p_section));
  v_launch text := nullif(btrim(p_launch), '');
  v_title text := nullif(btrim(p_title), '');
  v_sort int;
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
  IF v_title IS NULL THEN
    RAISE EXCEPTION 'p_title is required';
  END IF;

  INSERT INTO web_games (launch) VALUES (v_launch) ON CONFLICT DO NOTHING;

  v_sort := p_sort_order;
  IF v_sort IS NULL THEN
    SELECT COALESCE(max(sort_order), 0) + 1
      INTO v_sort
    FROM web_assignments
    WHERE profile = v_profile
      AND section = v_section;
  END IF;

  INSERT INTO web_assignments (
    profile, section, launch, title, enabled, sort_order, stars, url,
    web_game, description
  )
  VALUES (
    v_profile,
    v_section,
    v_launch,
    v_title,
    true,
    v_sort,
    p_stars,
    nullif(btrim(p_url), ''),
    COALESCE(p_web_game, false),
    nullif(btrim(p_description), '')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION af_web_add_assignment(text, text, text, text, text, int, int, text, boolean) TO anon, authenticated, service_role;
