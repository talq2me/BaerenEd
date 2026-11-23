-- Site-specific extraction: raw scrape JSON (+ optional flat metrics) -> metrics jsonb + value_mode.
-- Does not compute *_today (caller diffs against prior snapshot).

CREATE OR REPLACE FUNCTION af_edu_site_extract_metrics(
  p_site_kind text,
  p_raw jsonb,
  p_metrics jsonb DEFAULT NULL,
  p_value_mode text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_kind text := lower(btrim(COALESCE(p_site_kind, '')));
  v_raw jsonb := COALESCE(p_raw, '{}'::jsonb);
  v_in jsonb := COALESCE(p_metrics, '{}'::jsonb);
  v_metrics jsonb := '{}'::jsonb;
  v_mode text := lower(NULLIF(btrim(COALESCE(p_value_mode, '')), ''));
BEGIN
  IF v_kind = 'rallye_lecture' THEN
    v_metrics := jsonb_strip_nulls(jsonb_build_object(
      'books', CASE
        WHEN (v_raw->>'livres_lus') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v_raw->>'livres_lus')::numeric
        WHEN (v_in->>'books') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v_in->>'books')::numeric
        ELSE NULL
      END,
      'reussite_du_moment_pct', CASE
        WHEN (v_raw->>'reussite_du_moment_pct') ~ '^-?[0-9]+(\.[0-9]+)?$'
          THEN (v_raw->>'reussite_du_moment_pct')::numeric
        ELSE NULL
      END,
      'badges_obtenus', CASE
        WHEN (v_raw->>'badges_obtenus') ~ '^-?[0-9]+(\.[0-9]+)?$'
          THEN (v_raw->>'badges_obtenus')::numeric
        ELSE NULL
      END,
      'derniers_livres_count', CASE
        WHEN (v_raw->>'derniers_livres_count') ~ '^-?[0-9]+(\.[0-9]+)?$'
          THEN (v_raw->>'derniers_livres_count')::numeric
        ELSE NULL
      END,
      'derniers_livres_avg_pct', CASE
        WHEN (v_raw->>'derniers_livres_avg_pct') ~ '^-?[0-9]+(\.[0-9]+)?$'
          THEN (v_raw->>'derniers_livres_avg_pct')::numeric
        ELSE NULL
      END
    ));
    v_mode := COALESCE(v_mode, 'cumulative');
  ELSIF v_kind = 'motoufo' THEN
    v_metrics := jsonb_strip_nulls(jsonb_build_object(
      'feathers', CASE
        WHEN (v_raw->>'feathers') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v_raw->>'feathers')::numeric
        WHEN (v_in->>'feathers') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v_in->>'feathers')::numeric
        WHEN (v_raw->>'total_feathers') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v_raw->>'total_feathers')::numeric
        WHEN (v_in->>'total_feathers') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v_in->>'total_feathers')::numeric
        ELSE NULL
      END
    ));
    IF v_metrics = '{}'::jsonb AND v_in <> '{}'::jsonb THEN
      v_metrics := v_in;
    END IF;
    v_mode := COALESCE(v_mode, 'cumulative');
  ELSIF v_kind = 'anton' THEN
    -- Daily count of incomplete exercises (goal: incomplete <= 0).
    v_metrics := jsonb_strip_nulls(jsonb_build_object(
      'incomplete', CASE
        WHEN (v_raw->>'incomplete') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v_raw->>'incomplete')::numeric
        WHEN (v_in->>'incomplete') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v_in->>'incomplete')::numeric
        WHEN (v_raw->>'incomplete_exercises') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v_raw->>'incomplete_exercises')::numeric
        WHEN (v_in->>'incomplete_exercises') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v_in->>'incomplete_exercises')::numeric
        ELSE NULL
      END
    ));
    IF v_metrics = '{}'::jsonb AND v_in <> '{}'::jsonb THEN
      v_metrics := v_in;
    END IF;
    v_mode := COALESCE(v_mode, 'daily');
  ELSE
    -- Generic: prefer caller metrics; merge numeric scalars from raw.
    v_metrics := v_in;
    IF v_metrics = '{}'::jsonb THEN
      v_metrics := v_raw - 'student' - 'scraped_at' - 'source_url' - 'derniers_livres';
    END IF;
    v_mode := COALESCE(v_mode, 'cumulative');
  END IF;

  IF v_mode NOT IN ('cumulative', 'daily') THEN
    v_mode := 'cumulative';
  END IF;

  RETURN jsonb_build_object(
    'metrics', COALESCE(v_metrics, '{}'::jsonb),
    'value_mode', v_mode
  );
END;
$$;

GRANT EXECUTE ON FUNCTION af_edu_site_extract_metrics(text, jsonb, jsonb, text) TO anon, authenticated, service_role;
