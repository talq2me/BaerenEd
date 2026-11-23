-- Evaluate daily goals for visible-today assignments matching p_site_kind.
-- Uses latest snapshot for today vs prior-day baseline when value_mode = cumulative.

CREATE OR REPLACE FUNCTION af_eval_edu_site_goal(
  p_profile text,
  p_site_kind text,
  p_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(btrim(COALESCE(p_profile, '')));
  v_kind text := lower(btrim(COALESCE(p_site_kind, '')));
  v_date date := COALESCE(p_date, (NOW() AT TIME ZONE 'America/Toronto')::date);
  v_now timestamp(3) := (NOW() AT TIME ZONE 'America/Toronto');
  r record;
  v_resolved jsonb;
  v_metric text;
  v_target numeric;
  v_mode text;
  v_compare text;
  v_snap jsonb;
  v_baseline jsonb;
  v_current numeric;
  v_base numeric;
  v_measured numeric;
  v_met boolean;
  v_note text;
  v_today_key text;
  req jsonb;
  chk jsonb;
  patch jsonb;
  v_results jsonb := '[]'::jsonb;
  v_section text;
BEGIN
  IF v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;
  IF v_kind = '' THEN
    RAISE EXCEPTION 'p_site_kind is required';
  END IF;

  SELECT COALESCE(required_tasks, '{}'::jsonb), COALESCE(checklist_items, '{}'::jsonb)
    INTO req, chk
  FROM user_data
  WHERE profile = v_profile
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown profile: %', p_profile;
  END IF;

  -- Latest snapshot for this site on/before goal date (prefer same day).
  SELECT s.metrics INTO v_snap
  FROM edu_site_progress_snapshots s
  WHERE s.profile = v_profile
    AND lower(s.site_kind) = v_kind
    AND s.snapshot_date <= v_date
  ORDER BY s.snapshot_date DESC, s.id DESC
  LIMIT 1;

  SELECT s.metrics INTO v_baseline
  FROM edu_site_progress_snapshots s
  WHERE s.profile = v_profile
    AND lower(s.site_kind) = v_kind
    AND s.snapshot_date < v_date
  ORDER BY s.snapshot_date DESC, s.id DESC
  LIMIT 1;

  FOR r IN
    SELECT
      t.task_name,
      t.is_checklist,
      wa.verify_params,
      wa.section
    FROM af_get_tasks_required(v_profile) AS t
    INNER JOIN web_assignments wa
      ON wa.profile = v_profile
     AND wa.title = t.task_name
     AND wa.section = CASE WHEN t.is_checklist THEN 'checklist' ELSE 'required' END
     AND wa.enabled
     AND lower(btrim(COALESCE(wa.verify_kind, ''))) = v_kind
  LOOP
    v_resolved := af_edu_site_resolve_goal_params(v_kind, r.verify_params);
    v_metric := v_resolved->>'metric';
    v_mode := v_resolved->>'value_mode';
    v_compare := COALESCE(NULLIF(v_resolved->>'compare', ''), 'gte');
    v_target := CASE
      WHEN (v_resolved->>'target') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v_resolved->>'target')::numeric
      ELSE NULL
    END;
    v_today_key := v_metric || '_today';
    v_section := CASE WHEN r.is_checklist THEN 'checklist' ELSE 'required' END;
    v_note := NULL;
    v_met := false;
    v_measured := NULL;
    v_base := NULL;
    v_current := NULL;

    IF v_snap IS NULL THEN
      v_note := 'no snapshot yet';
    ELSIF v_target IS NULL THEN
      v_note := 'no target in verify_params';
    ELSIF v_mode = 'daily' THEN
      IF (v_snap->>v_metric) ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
        v_measured := (v_snap->>v_metric)::numeric;
      ELSIF (v_snap->>v_today_key) ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
        v_measured := (v_snap->>v_today_key)::numeric;
      END IF;
      IF v_measured IS NULL THEN
        v_note := 'metric missing in snapshot: ' || v_metric;
      ELSE
        IF v_compare = 'lte' THEN
          v_met := v_measured <= v_target;
          IF NOT v_met THEN
            v_note := format('need %s <= %s, have %s', v_metric, v_target, v_measured);
          END IF;
        ELSE
          v_met := v_measured >= v_target;
          IF NOT v_met THEN
            v_note := format('need %s %s today, have %s', v_target, v_metric, v_measured);
          END IF;
        END IF;
      END IF;
    ELSE
      -- cumulative: prefer precomputed *_today on snapshot; else diff vs prior day
      IF (v_snap->>v_today_key) ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
        v_measured := (v_snap->>v_today_key)::numeric;
        IF v_baseline IS NOT NULL AND (v_baseline->>v_metric) ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
          v_base := (v_baseline->>v_metric)::numeric;
        END IF;
        IF (v_snap->>v_metric) ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
          v_current := (v_snap->>v_metric)::numeric;
        END IF;
      ELSIF (v_snap->>v_metric) ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
        v_current := (v_snap->>v_metric)::numeric;
        IF v_baseline IS NULL OR NOT ((v_baseline->>v_metric) ~ '^-?[0-9]+(\.[0-9]+)?$') THEN
          v_note := 'need prior snapshot';
          v_measured := NULL;
        ELSE
          v_base := (v_baseline->>v_metric)::numeric;
          v_measured := v_current - v_base;
        END IF;
      ELSE
        v_note := 'metric missing in snapshot: ' || v_metric;
      END IF;

      IF v_measured IS NOT NULL AND v_target IS NOT NULL THEN
        IF v_compare = 'lte' THEN
          v_met := v_measured <= v_target;
          IF NOT v_met AND v_note IS NULL THEN
            v_note := format('need %s <= %s, have %s', v_metric, v_target, v_measured);
          END IF;
        ELSE
          v_met := v_measured >= v_target;
          IF NOT v_met AND v_note IS NULL THEN
            v_note := format('need %s %s today, have %s', v_target, v_metric, v_measured);
          END IF;
        END IF;
      END IF;
    END IF;

    -- Preserve parent_override if already set
    INSERT INTO edu_site_daily_goals AS g (
      profile, goal_date, site_kind, task_title, section,
      target, metric, value_mode, measured_value, baseline_value,
      goal_met, parent_override, note, evaluated_at
    ) VALUES (
      v_profile, v_date, v_kind, r.task_name, v_section,
      v_target, v_metric, v_mode, v_measured, v_base,
      v_met, false, v_note, v_now
    )
    ON CONFLICT (profile, goal_date, task_title) DO UPDATE SET
      site_kind = EXCLUDED.site_kind,
      section = EXCLUDED.section,
      target = EXCLUDED.target,
      metric = EXCLUDED.metric,
      value_mode = EXCLUDED.value_mode,
      measured_value = EXCLUDED.measured_value,
      baseline_value = EXCLUDED.baseline_value,
      goal_met = CASE WHEN g.parent_override THEN true ELSE EXCLUDED.goal_met END,
      note = CASE WHEN g.parent_override THEN COALESCE(g.note, EXCLUDED.note) ELSE EXCLUDED.note END,
      evaluated_at = EXCLUDED.evaluated_at;

    SELECT COALESCE(g.goal_met, false) OR COALESCE(g.parent_override, false), g.note
      INTO v_met, v_note
    FROM edu_site_daily_goals g
    WHERE g.profile = v_profile AND g.goal_date = v_date AND g.task_title = r.task_name;

    patch := jsonb_build_object(
      'verification_status', CASE WHEN v_met THEN 'verified' ELSE 'failed' END,
      'verified_at', v_now,
      'verification_note', v_note
    );

    IF r.is_checklist THEN
      chk := jsonb_set(chk, ARRAY[r.task_name], COALESCE(chk->r.task_name, '{}'::jsonb) || patch, true);
    ELSE
      req := jsonb_set(req, ARRAY[r.task_name], COALESCE(req->r.task_name, '{}'::jsonb) || patch, true);
    END IF;

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'task_title', r.task_name,
      'section', v_section,
      'metric', v_metric,
      'target', v_target,
      'measured_value', v_measured,
      'baseline_value', v_base,
      'goal_met', v_met,
      'note', v_note
    ));
  END LOOP;

  UPDATE user_data
  SET
    required_tasks = req,
    checklist_items = chk,
    last_updated = v_now
  WHERE profile = v_profile;

  PERFORM af_maybe_complete_edu_site_checker_run(v_profile);

  RETURN v_results;
END;
$$;

GRANT EXECUTE ON FUNCTION af_eval_edu_site_goal(text, text, date) TO anon, authenticated, service_role;
