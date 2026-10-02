-- Call sites (BaerenEd Android, this repo):
--   app/src/main/java/com/talq2me/baerened/SupabaseInterface.kt  -  invokeAfUpdateRequiredTasksFromConfig.
--   app/src/main/java/com/talq2me/baerened/DbProfileSessionLoader.kt  -  chained after profile load / config refresh.

CREATE OR REPLACE FUNCTION af_update_tasks_from_config_required(p_profile text, p_config_json jsonb DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  config_json jsonb;
  existing_required jsonb;
  merged_required jsonb;
  v_today_short text := lower(to_char((NOW() AT TIME ZONE 'America/Toronto'), 'Dy'));
  v_today_date date := (NOW() AT TIME ZONE 'America/Toronto')::date;
  v_possible_stars int := 0;
  v_game_indices jsonb;
BEGIN
  IF p_config_json IS NOT NULL AND p_config_json != 'null'::jsonb THEN
    config_json := p_config_json;
  ELSE
    config_json := af_catalog_as_config(p_profile);
    IF config_json IS NULL THEN
      RAISE WARNING 'af_update_tasks_from_config_required: no catalog rows for %', p_profile;
      RETURN;
    END IF;
  END IF;

  SELECT COALESCE(required_tasks, '{}'::jsonb), COALESCE(game_indices, '{}'::jsonb)
  INTO existing_required, v_game_indices
  FROM user_data
  WHERE profile = p_profile;

  SELECT COALESCE(
    (
      SELECT jsonb_object_agg(
        t->>'title',
        jsonb_build_object(
          'status', COALESCE((existing_required->(t->>'title'))->>'status', 'incomplete'),
          'correct', existing_required->(t->>'title')->'correct',
          'incorrect', existing_required->(t->>'title')->'incorrect',
          'questions', existing_required->(t->>'title')->'questions',
          'stars', t->'stars',
          'launch', t->'launch',
          'url', t->'url',
          'webGame', t->'webGame',
          'chromePage', t->'chromePage',
          'videoSequence', t->'videoSequence',
          'video', t->'video',
          'playlistId', t->'playlistId',
          'blockOutlines', t->'blockOutlines',
          'rewardId', t->'rewardId',
          'totalQuestions', t->'totalQuestions',
          'easy', t->'easy',
          'easydays', t->'easydays',
          'harddays', t->'harddays',
          'extremedays', t->'extremedays',
          'showdays', t->'showdays',
          'hidedays', t->'hidedays',
          'displayDays', t->'displayDays',
          'disable', t->'disable'
        )
      )
      FROM jsonb_array_elements(config_json->'sections') AS sec,
           jsonb_array_elements(COALESCE(sec->'tasks', '[]'::jsonb)) AS t
      WHERE sec->>'id' = 'required'
    ),
    '{}'::jsonb
  ) INTO merged_required;

  SELECT COALESCE(SUM(COALESCE((e.value->>'stars')::int, 0)), 0)
  INTO v_possible_stars
  FROM jsonb_each(COALESCE(merged_required, '{}'::jsonb)) AS e(key, value)
  WHERE
    NOT (
      NULLIF(TRIM(COALESCE(e.value->>'disable', '')), '') IS NOT NULL
      AND to_date(e.value->>'disable', 'Mon DD, YYYY') IS NOT NULL
      AND v_today_date < to_date(e.value->>'disable', 'Mon DD, YYYY')
    )
    AND NOT EXISTS (
      SELECT 1
      FROM unnest(string_to_array(lower(replace(COALESCE(e.value->>'hidedays', ''), ' ', '')), ',')) AS d(day_token)
      WHERE d.day_token = v_today_short
    )
    AND (
      NULLIF(TRIM(COALESCE(e.value->>'displayDays', '')), '') IS NULL
      OR EXISTS (
        SELECT 1
        FROM unnest(string_to_array(lower(replace(COALESCE(e.value->>'displayDays', ''), ' ', '')), ',')) AS d(day_token)
        WHERE d.day_token = v_today_short
      )
    )
    AND (
      NULLIF(TRIM(COALESCE(e.value->>'displayDays', '')), '') IS NOT NULL
      OR NULLIF(TRIM(COALESCE(e.value->>'showdays', '')), '') IS NULL
      OR EXISTS (
        SELECT 1
        FROM unnest(string_to_array(lower(replace(COALESCE(e.value->>'showdays', ''), ' ', '')), ',')) AS d(day_token)
        WHERE d.day_token = v_today_short
      )
    )
    AND (
      COALESCE(e.value->>'launch', '') IS DISTINCT FROM 'storyRead'
      OR COALESCE(e.value->>'status', '') = 'complete'
      OR af_story_read_assigned_today(
           e.value->>'url',
           v_today_date,
           COALESCE(
             (COALESCE(v_game_indices, '{}'::jsonb) ->> ('storyRead_' || split_part(COALESCE(e.value->>'url', ''), '?', 1)))::int,
             0
           )
         )
    );

  UPDATE user_data
  SET
    required_tasks = merged_required,
    possible_stars = v_possible_stars,
    last_updated = (NOW() AT TIME ZONE 'America/Toronto')
  WHERE profile = p_profile;
END;
$$;

GRANT EXECUTE ON FUNCTION af_update_tasks_from_config_required(text, jsonb) TO anon, authenticated, service_role;
