-- Resolve verify_params (+ site defaults) into metric / target / value_mode / compare.
-- compare: gte (need at least target) | lte (need at most target, e.g. Anton incomplete=0)
-- Used by af_eval_edu_site_goal.

CREATE OR REPLACE FUNCTION af_edu_site_resolve_goal_params(
  p_site_kind text,
  p_verify_params jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_kind text := lower(btrim(COALESCE(p_site_kind, '')));
  v_params jsonb := COALESCE(p_verify_params, '{}'::jsonb);
  v_metric text;
  v_target numeric;
  v_mode text;
  v_compare text;
BEGIN
  v_metric := NULLIF(btrim(COALESCE(v_params->>'metric', '')), '');
  v_mode := lower(NULLIF(btrim(COALESCE(v_params->>'value_mode', '')), ''));
  v_compare := lower(NULLIF(btrim(COALESCE(v_params->>'compare', '')), ''));

  IF v_params ? 'target' AND (v_params->>'target') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
    v_target := (v_params->>'target')::numeric;
  END IF;

  -- Aliases
  IF v_target IS NULL AND v_params ? 'min_books' AND (v_params->>'min_books') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
    v_metric := COALESCE(v_metric, 'books');
    v_target := (v_params->>'min_books')::numeric;
  END IF;
  IF v_target IS NULL AND v_params ? 'min_sessions' AND (v_params->>'min_sessions') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
    v_metric := COALESCE(v_metric, 'sessions');
    v_target := (v_params->>'min_sessions')::numeric;
  END IF;
  IF v_target IS NULL AND v_params ? 'min_feathers' AND (v_params->>'min_feathers') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
    v_metric := COALESCE(v_metric, 'feathers');
    v_target := (v_params->>'min_feathers')::numeric;
  END IF;
  IF v_target IS NULL AND v_params ? 'min_minutes' AND (v_params->>'min_minutes') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
    v_metric := COALESCE(v_metric, 'minutes');
    v_target := (v_params->>'min_minutes')::numeric;
  END IF;
  IF v_target IS NULL AND v_params ? 'max_incomplete' AND (v_params->>'max_incomplete') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
    v_metric := COALESCE(v_metric, 'incomplete');
    v_target := (v_params->>'max_incomplete')::numeric;
    v_compare := COALESCE(v_compare, 'lte');
    v_mode := COALESCE(v_mode, 'daily');
  END IF;

  -- Site defaults
  IF v_kind = 'motoufo' THEN
    v_metric := COALESCE(v_metric, 'feathers');
    v_mode := COALESCE(v_mode, 'cumulative');
    v_compare := COALESCE(v_compare, 'gte');
  ELSIF v_kind = 'rallye_lecture' THEN
    v_metric := COALESCE(v_metric, 'books');
    v_mode := COALESCE(v_mode, 'cumulative');
    v_compare := COALESCE(v_compare, 'gte');
  ELSIF v_kind = 'xtramath' THEN
    v_metric := COALESCE(v_metric, 'sessions');
    v_mode := COALESCE(v_mode, 'daily');
    v_compare := COALESCE(v_compare, 'gte');
  ELSIF v_kind = 'anton' THEN
    v_metric := COALESCE(v_metric, 'incomplete');
    v_mode := COALESCE(v_mode, 'daily');
    v_compare := COALESCE(v_compare, 'lte');
    IF v_target IS NULL THEN
      v_target := 0;
    END IF;
  ELSIF v_kind = 'northstar_math' THEN
    v_mode := COALESCE(v_mode, 'cumulative');
    v_compare := COALESCE(v_compare, 'gte');
  ELSE
    v_mode := COALESCE(v_mode, 'cumulative');
    v_compare := COALESCE(v_compare, 'gte');
  END IF;

  IF v_metric IS NULL OR v_metric = '' THEN
    v_metric := 'value';
  END IF;
  IF v_mode NOT IN ('cumulative', 'daily') THEN
    v_mode := 'cumulative';
  END IF;
  IF v_compare NOT IN ('gte', 'lte') THEN
    v_compare := 'gte';
  END IF;

  RETURN jsonb_build_object(
    'metric', v_metric,
    'target', v_target,
    'value_mode', v_mode,
    'compare', v_compare
  );
END;
$$;

GRANT EXECUTE ON FUNCTION af_edu_site_resolve_goal_params(text, jsonb) TO anon, authenticated, service_role;
