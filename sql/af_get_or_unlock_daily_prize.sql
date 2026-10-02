-- Call sites (BaerenEd Android, this repo):
--   app/src/main/java/com/talq2me/baerened/SupabaseInterface.kt  -  invokeAfGetOrUnlockDailyPrize.
--   app/src/main/java/com/talq2me/baerened/RewardSpinnerActivity.kt  -  resolve/open daily prize.

-- If prize_unlocked already exists for the profile, return it.
-- Otherwise, unlock only when all visible required/checklist tasks are complete for today.
-- Newly unlocking Pokemon/Soccer Card also records one collector_card_days row (spin_prize).
-- Newly unlocking Extra 10 minutes screen time also grants 10 banked/active reward minutes (once per spin).
DROP FUNCTION IF EXISTS af_get_or_unlock_daily_prize(text);

CREATE OR REPLACE FUNCTION af_get_or_unlock_daily_prize(p_profile text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prize_unlocked text := NULL;
  v_reward_name text := NULL;
  v_total_tasks int := 0;
  v_incomplete_tasks int := 0;
  v_today text := NULL;
BEGIN
  SELECT
    NULLIF(trim(ud.prize_unlocked), '')
  INTO v_prize_unlocked
  FROM user_data ud
  WHERE ud.profile = p_profile
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'prize_unlocked', NULL,
      'newly_unlocked', false,
      'eligible', false
    );
  END IF;

  IF v_prize_unlocked IS NOT NULL THEN
    RETURN jsonb_build_object(
      'prize_unlocked', v_prize_unlocked,
      'newly_unlocked', false,
      'eligible', true
    );
  END IF;

  -- Same required games the web battle hub uses to enable Daily Spin.
  -- Checklist items and not-yet-converted tasks do not block the wheel.
  v_today := (ARRAY['sun','mon','tue','wed','thu','fri','sat'])[
    extract(dow FROM (NOW() AT TIME ZONE 'America/Toronto'))::int + 1
  ];

  SELECT
    COUNT(*),
    COUNT(*) FILTER (WHERE NOT done)
  INTO v_total_tasks, v_incomplete_tasks
  FROM (
    SELECT EXISTS (
      SELECT 1
      FROM af_get_tasks_required(p_profile) t
      WHERE NOT COALESCE(t.is_checklist, false)
        AND t.task_name = a.title
        AND lower(coalesce(t.completion_status, '')) IN ('complete', 'done')
    ) AS done
    FROM web_assignments a
    WHERE upper(a.profile) = upper(trim(p_profile))
      AND a.enabled
      AND a.section = 'required'
      AND NOT COALESCE(a.chrome_page, false)
      AND (a.video_sequence IS NULL OR btrim(a.video_sequence) = '')
      AND COALESCE(a.launch, '') NOT IN ('boukili', 'googleReadAlong', 'printing', 'tappableText', 'storyRead')
      AND (
        a.display_days IS NULL
        OR btrim(a.display_days) = ''
        OR position(v_today IN lower(a.display_days)) > 0
      )
  ) web_tasks;

  IF v_total_tasks = 0 THEN
    SELECT
      COUNT(*),
      COUNT(*) FILTER (WHERE lower(coalesce(t.completion_status, 'incomplete')) NOT IN ('complete', 'done'))
    INTO v_total_tasks, v_incomplete_tasks
    FROM af_get_current_required_tasks(p_profile) t;
  END IF;

  IF v_total_tasks = 0 OR v_incomplete_tasks > 0 THEN
    RETURN jsonb_build_object(
      'prize_unlocked', NULL,
      'newly_unlocked', false,
      'eligible', false
    );
  END IF;

  WITH weighted AS (
    SELECT
      rs.id,
      rs.name,
      rs.percent,
      SUM(rs.percent) OVER (ORDER BY rs.id) AS cumulative_weight
    FROM reward_spinner rs
    WHERE rs.percent > 0
  ),
  total AS (
    SELECT MAX(cumulative_weight) AS total_weight
    FROM weighted
  ),
  roll AS (
    SELECT (FLOOR(random() * total_weight) + 1)::int AS ticket
    FROM total
  )
  SELECT w.name
  INTO v_reward_name
  FROM weighted w, roll r
  WHERE w.cumulative_weight >= r.ticket
  ORDER BY w.cumulative_weight
  LIMIT 1;

  IF v_reward_name IS NULL THEN
    RETURN jsonb_build_object(
      'prize_unlocked', NULL,
      'newly_unlocked', false,
      'eligible', false,
      'error', 'No reward spinner rows with positive percent.'
    );
  END IF;

  UPDATE user_data
  SET
    prize_unlocked = v_reward_name,
    last_updated = (NOW() AT TIME ZONE 'America/Toronto')
  WHERE profile = p_profile;

  IF v_reward_name ~* '(pokemon|poke|soccer).{0,20}card' THEN
    INSERT INTO collector_card_days (profile, completion_date, earned_at, paid_out, earn_source)
    VALUES (
      p_profile,
      (NOW() AT TIME ZONE 'America/Toronto')::date,
      (NOW() AT TIME ZONE 'America/Toronto'),
      false,
      'spin_prize'
    )
    ON CONFLICT (profile, completion_date, earn_source) DO NOTHING;
  END IF;

  IF v_reward_name ~* 'extra\s+10\s+minute' THEN
    PERFORM af_reward_time_add(p_profile, 10);
  END IF;

  RETURN jsonb_build_object(
    'prize_unlocked', v_reward_name,
    'newly_unlocked', true,
    'eligible', true
  );
END;
$$;

GRANT EXECUTE ON FUNCTION af_get_or_unlock_daily_prize(text) TO anon, authenticated, service_role;

-- The wheel reads this instead of the table, so a locked-down reward_spinner still draws.
CREATE OR REPLACE FUNCTION af_list_reward_spinner()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object('id', rs.id, 'name', rs.name, 'percent', rs.percent)
      ORDER BY rs.id
    ),
    '[]'::jsonb
  )
  FROM reward_spinner rs
  WHERE rs.percent > 0;
$$;

GRANT EXECUTE ON FUNCTION af_list_reward_spinner() TO anon, authenticated, service_role;
