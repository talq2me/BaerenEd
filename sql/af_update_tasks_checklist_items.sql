-- Call sites (BaerenEd Android, this repo):
--   SupabaseInterface.invokeAfUpdateChecklistItem; DailyProgressManager (SingleItemUpdate.ChecklistItem).

-- BaerenEd: Update a single checklist item by label. Sets done for the item.
-- When p_done is true and item was not done, adds item's stars (from DB) to berries_earned and to banked_mins.
-- Requires af_get_stars_to_minutes (af_get_stars_to_minutes.sql). Identifies item by p_item_label (key in checklist_items JSONB).
-- Call: POST /rest/v1/rpc/af_update_tasks_checklist_items with body e.g.
--   {"p_profile": "TE", "p_item_label": "Laundry", "p_done": true}

CREATE OR REPLACE FUNCTION af_update_tasks_checklist_items(
  p_profile text,
  p_item_label text,
  p_done boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cur jsonb;
  existing jsonb;
  new_item jsonb;
  old_done boolean;
  item_stars int;
  add_berries int := 0;
  add_mins int := 0;
  v_verify_kind text;
  v_goal_note text;
BEGIN
  SELECT COALESCE(checklist_items, '{}'::jsonb) INTO cur FROM user_data WHERE profile = p_profile;
  existing := cur->p_item_label;
  old_done := COALESCE((existing->>'done')::boolean, false);

  IF p_done AND NOT old_done THEN
    SELECT NULLIF(btrim(COALESCE(wa.verify_kind, '')), '')
      INTO v_verify_kind
    FROM web_assignments wa
    WHERE wa.profile = p_profile
      AND wa.title = p_item_label
      AND wa.section = 'checklist'
      AND wa.enabled
    LIMIT 1;

    IF v_verify_kind IS NOT NULL THEN
      IF NOT af_edu_site_goal_met_today(p_profile, p_item_label) THEN
        SELECT g.note INTO v_goal_note
        FROM edu_site_daily_goals g
        WHERE g.profile = p_profile
          AND g.goal_date = (NOW() AT TIME ZONE 'America/Toronto')::date
          AND g.task_title = p_item_label;
        RAISE EXCEPTION 'Edu site goal not met for %: %',
          p_item_label,
          COALESCE(v_goal_note, 'scraper has not verified today''s target yet');
      END IF;
    END IF;
  END IF;

  new_item := COALESCE(existing, '{}'::jsonb) || jsonb_build_object('done', p_done);

  IF p_done AND NOT old_done THEN
    item_stars := COALESCE((new_item->>'stars')::int, 0);
    IF item_stars > 0 THEN
      add_berries := item_stars;
      add_mins := af_get_stars_to_minutes(item_stars);
    END IF;
  END IF;

  UPDATE user_data
  SET
    checklist_items = jsonb_set(cur, ARRAY[p_item_label], new_item, true),
    berries_earned = COALESCE(berries_earned, 0) + add_berries,
    banked_mins = COALESCE(banked_mins, 0) + add_mins,
    last_updated = (NOW() AT TIME ZONE 'America/Toronto')
  WHERE profile = p_profile;

  IF p_done AND NOT old_done THEN
    PERFORM af_maybe_advance_spelling_pools(p_profile);
    PERFORM af_maybe_record_collector_card_day(p_profile);
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION af_update_tasks_checklist_items(text, text, boolean) TO anon, authenticated, service_role;
