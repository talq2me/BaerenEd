-- Parent Task Manager: force-verify an edu-site task for today and mark it complete/done.

CREATE OR REPLACE FUNCTION af_parent_override_edu_site_goal(
  p_profile text,
  p_task_title text,
  p_is_checklist boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(btrim(COALESCE(p_profile, '')));
  v_title text := btrim(COALESCE(p_task_title, ''));
  v_date date := (NOW() AT TIME ZONE 'America/Toronto')::date;
  v_now timestamp(3) := (NOW() AT TIME ZONE 'America/Toronto');
  v_kind text;
  v_section text;
  v_params jsonb;
  v_resolved jsonb;
BEGIN
  IF v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;
  IF v_title = '' THEN
    RAISE EXCEPTION 'p_task_title is required';
  END IF;

  v_section := CASE WHEN COALESCE(p_is_checklist, false) THEN 'checklist' ELSE 'required' END;

  SELECT lower(btrim(COALESCE(wa.verify_kind, ''))), COALESCE(wa.verify_params, '{}'::jsonb)
    INTO v_kind, v_params
  FROM web_assignments wa
  WHERE wa.profile = v_profile
    AND wa.title = v_title
    AND wa.section = v_section
    AND wa.enabled
  LIMIT 1;

  IF v_kind IS NULL OR v_kind = '' THEN
    -- Fall back: any section with this title + verify_kind
    SELECT lower(btrim(COALESCE(wa.verify_kind, ''))), COALESCE(wa.verify_params, '{}'::jsonb), wa.section
      INTO v_kind, v_params, v_section
    FROM web_assignments wa
    WHERE wa.profile = v_profile
      AND wa.title = v_title
      AND wa.enabled
      AND btrim(COALESCE(wa.verify_kind, '')) <> ''
    LIMIT 1;
  END IF;

  IF v_kind IS NULL OR v_kind = '' THEN
    RAISE EXCEPTION 'No verify_kind assignment for task: %', v_title;
  END IF;

  v_resolved := af_edu_site_resolve_goal_params(v_kind, v_params);

  INSERT INTO edu_site_daily_goals AS g (
    profile, goal_date, site_kind, task_title, section,
    target, metric, value_mode, measured_value, baseline_value,
    goal_met, parent_override, note, evaluated_at
  ) VALUES (
    v_profile, v_date, v_kind, v_title, v_section,
    CASE WHEN (v_resolved->>'target') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v_resolved->>'target')::numeric ELSE NULL END,
    v_resolved->>'metric',
    COALESCE(v_resolved->>'value_mode', 'cumulative'),
    NULL, NULL,
    true, true, 'parent override', v_now
  )
  ON CONFLICT (profile, goal_date, task_title) DO UPDATE SET
    site_kind = EXCLUDED.site_kind,
    section = EXCLUDED.section,
    goal_met = true,
    parent_override = true,
    note = 'parent override',
    evaluated_at = EXCLUDED.evaluated_at;

  IF v_section = 'checklist' THEN
    PERFORM af_update_tasks_checklist_items(v_profile, v_title, true);
  ELSE
    PERFORM af_update_task_completion(v_profile, v_title, 'required', NULL, NULL, NULL, NULL);
  END IF;

  -- Ensure verification_status is verified even if complete path wrote first
  IF v_section = 'checklist' THEN
    UPDATE user_data
    SET checklist_items = jsonb_set(
          COALESCE(checklist_items, '{}'::jsonb),
          ARRAY[v_title],
          COALESCE(checklist_items->v_title, '{}'::jsonb) || jsonb_build_object(
            'verification_status', 'verified',
            'verification_note', 'parent override',
            'verified_at', v_now,
            'done', true
          ),
          true
        ),
        last_updated = v_now
    WHERE profile = v_profile;
  ELSE
    UPDATE user_data
    SET required_tasks = jsonb_set(
          COALESCE(required_tasks, '{}'::jsonb),
          ARRAY[v_title],
          COALESCE(required_tasks->v_title, '{}'::jsonb) || jsonb_build_object(
            'verification_status', 'verified',
            'verification_note', 'parent override',
            'verified_at', v_now,
            'status', 'complete'
          ),
          true
        ),
        last_updated = v_now
    WHERE profile = v_profile;
  END IF;

  PERFORM af_maybe_complete_edu_site_checker_run(v_profile);

  RETURN jsonb_build_object(
    'profile', v_profile,
    'task_title', v_title,
    'section', v_section,
    'site_kind', v_kind,
    'date', to_char(v_date, 'YYYY-MM-DD'),
    'goal_met', true,
    'parent_override', true
  );
END;
$$;

GRANT EXECUTE ON FUNCTION af_parent_override_edu_site_goal(text, text, boolean)
  TO anon, authenticated, service_role;
