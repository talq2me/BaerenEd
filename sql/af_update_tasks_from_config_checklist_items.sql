-- Call sites (BaerenEd Android, this repo):
--   app/src/main/java/com/talq2me/baerened/SupabaseInterface.kt  -  invokeAfUpdateChecklistItemsFromConfig (RPC af_update_tasks_from_config_checklist_items).
--   app/src/main/java/com/talq2me/baerened/DbProfileSessionLoader.kt  -  chained after profile load / config refresh.
--
-- When the schedule editor has enabled checklist rows (Rallye Lecture and other site tasks),
-- those rows are the checklist. Opening the trainer map must not replace them with the
-- GitHub profile file. Profiles with no schedule-editor checklist still use that file.

CREATE OR REPLACE FUNCTION af_update_tasks_from_config_checklist_items(p_profile text, p_config_json jsonb DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_profile text := upper(btrim(COALESCE(p_profile, '')));
  github_url text;
  config_json jsonb;
  http_status int;
  existing_checklist jsonb;
  merged_checklist jsonb;
  web_checklist jsonb;
BEGIN
  IF v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;

  github_url := 'https://talq2me.github.io/BaerenEd-Android-App/app/src/main/assets/config/' || v_profile || '_config.json';

  IF p_config_json IS NOT NULL AND p_config_json != 'null'::jsonb THEN
    config_json := p_config_json;
  ELSE
    SELECT r.status, r.content::jsonb INTO http_status, config_json FROM http_get(github_url) r LIMIT 1;
    IF http_status != 200 OR config_json IS NULL THEN
      RAISE WARNING 'af_update_tasks_from_config_checklist_items: failed to fetch config for %', p_profile;
      config_json := NULL;
    END IF;
  END IF;

  SELECT COALESCE(checklist_items, '{}'::jsonb) INTO existing_checklist
  FROM user_data
  WHERE profile = v_profile;

  IF existing_checklist IS NULL THEN
    existing_checklist := '{}'::jsonb;
  END IF;

  IF config_json IS NULL THEN
    merged_checklist := existing_checklist;
  ELSE
    SELECT COALESCE(
      (
        SELECT jsonb_object_agg(
          it->>'label',
          jsonb_strip_nulls(jsonb_build_object(
            'done', COALESCE((existing_checklist->(it->>'label')->>'done')::boolean, false),
            'stars', COALESCE((it->>'stars')::int, 0),
            'id', it->'id',
            'showdays', it->'showdays',
            'hidedays', it->'hidedays',
            'displayDays', it->'displayDays',
            'launch', to_jsonb('checklist_' || COALESCE(it->>'id', it->>'label')),
            'verification_status', existing_checklist->(it->>'label')->'verification_status',
            'verification_note', existing_checklist->(it->>'label')->'verification_note',
            'verified_at', existing_checklist->(it->>'label')->'verified_at'
          ))
        )
        FROM jsonb_array_elements(config_json->'sections') AS sec
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(sec->'items', '[]'::jsonb)) AS it
        WHERE NULLIF(btrim(it->>'label'), '') IS NOT NULL
          AND sec->'items' IS NOT NULL
          AND jsonb_array_length(COALESCE(sec->'items', '[]'::jsonb)) > 0
      ),
      '{}'::jsonb
    ) INTO merged_checklist;
  END IF;

  SELECT COALESCE(
    (
      SELECT jsonb_object_agg(
        a.title,
        jsonb_strip_nulls(jsonb_build_object(
          'done', COALESCE((existing_checklist->a.title->>'done')::boolean, false),
          'stars', COALESCE(a.stars, 0),
          'id', COALESCE(
            merged_checklist->a.title->'id',
            existing_checklist->a.title->'id',
            to_jsonb(a.title)
          ),
          'displayDays', to_jsonb(NULLIF(btrim(a.display_days), '')),
          'launch', to_jsonb(
            'checklist_' || COALESCE(
              NULLIF(merged_checklist->a.title->>'id', ''),
              NULLIF(existing_checklist->a.title->>'id', ''),
              a.title
            )
          ),
          'verification_status', existing_checklist->a.title->'verification_status',
          'verification_note', existing_checklist->a.title->'verification_note',
          'verified_at', existing_checklist->a.title->'verified_at'
        ))
      )
      FROM (
        SELECT DISTINCT ON (title)
          title, stars, display_days
        FROM web_assignments
        WHERE profile = v_profile
          AND section = 'checklist'
          AND enabled
          AND NULLIF(btrim(title), '') IS NOT NULL
        ORDER BY title, sort_order DESC
      ) a
    ),
    '{}'::jsonb
  ) INTO web_checklist;

  IF web_checklist IS NOT NULL AND web_checklist <> '{}'::jsonb THEN
    merged_checklist := web_checklist;
  ELSE
    merged_checklist := COALESCE(merged_checklist, existing_checklist, '{}'::jsonb);
  END IF;

  UPDATE user_data
  SET
    checklist_items = merged_checklist,
    last_updated = (NOW() AT TIME ZONE 'America/Toronto')
  WHERE profile = v_profile;
END;
$$;

GRANT EXECUTE ON FUNCTION af_update_tasks_from_config_checklist_items(text, jsonb) TO anon, authenticated, service_role;
