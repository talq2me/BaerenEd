-- Scraper entrypoint: validate bearer, store snapshot, evaluate daily goals.
-- POST /rest/v1/rpc/af_upsert_edu_site_progress
-- Body: { "p_site_kind":"rallye_lecture", "p_bearer":"crsr_…", "p_raw":{...} }
-- Vault secret: edu_site_checker_webhook_bearer

DROP FUNCTION IF EXISTS af_upsert_edu_site_progress(text, text, jsonb, text, jsonb, text, text);

CREATE OR REPLACE FUNCTION af_upsert_edu_site_progress(
  p_site_kind text,
  p_bearer text,
  p_raw jsonb,
  p_profile text DEFAULT NULL,
  p_metrics jsonb DEFAULT NULL,
  p_value_mode text DEFAULT NULL,
  p_source text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, vault
AS $$
DECLARE
  v_token text;
  v_kind text := lower(btrim(COALESCE(p_site_kind, '')));
  v_raw jsonb := COALESCE(p_raw, '{}'::jsonb);
  v_profile text;
  v_extracted jsonb;
  v_metrics jsonb;
  v_mode text;
  v_metric text;
  v_today_key text;
  v_current numeric;
  v_baseline numeric;
  v_snap_at timestamp(3);
  v_snap_date date;
  v_source text;
  v_id bigint;
  v_goals jsonb;
  v_toronto_now timestamp(3) := (NOW() AT TIME ZONE 'America/Toronto');
BEGIN
  IF v_kind = '' THEN
    RAISE EXCEPTION 'p_site_kind is required';
  END IF;

  -- Dashboard may use either the snake_case id or the UI label as vault.secrets.name
  SELECT decrypted_secret INTO v_token
  FROM vault.decrypted_secrets
  WHERE name IN ('edu_site_checker_webhook_bearer', 'EduSiteChecker Bot Webhook')
  ORDER BY CASE name
    WHEN 'edu_site_checker_webhook_bearer' THEN 0
    ELSE 1
  END
  LIMIT 1;

  IF v_token IS NULL OR btrim(v_token) = '' THEN
    RAISE EXCEPTION 'Edu site scraper bearer not configured in Vault (expected name edu_site_checker_webhook_bearer or EduSiteChecker Bot Webhook)';
  END IF;
  IF btrim(COALESCE(p_bearer, '')) IS DISTINCT FROM btrim(v_token) THEN
    RAISE EXCEPTION 'Invalid bearer';
  END IF;

  v_profile := upper(btrim(COALESCE(NULLIF(btrim(COALESCE(p_profile, '')), ''), COALESCE(v_raw->>'student', ''))));
  IF v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile (use AM/BM/TE in p_profile or p_raw.student): %', v_profile;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM user_data WHERE profile = v_profile) THEN
    RAISE EXCEPTION 'Unknown profile: %', v_profile;
  END IF;

  v_extracted := af_edu_site_extract_metrics(v_kind, v_raw, p_metrics, p_value_mode);
  v_metrics := COALESCE(v_extracted->'metrics', '{}'::jsonb);
  v_mode := COALESCE(v_extracted->>'value_mode', 'cumulative');

  -- Snapshot time: scraped_at (UTC) -> Toronto wall, else now
  IF NULLIF(btrim(COALESCE(v_raw->>'scraped_at', '')), '') IS NOT NULL THEN
    BEGIN
      v_snap_at := ((v_raw->>'scraped_at')::timestamptz AT TIME ZONE 'America/Toronto');
    EXCEPTION WHEN OTHERS THEN
      v_snap_at := v_toronto_now;
    END;
  ELSE
    v_snap_at := v_toronto_now;
  END IF;
  v_snap_date := v_snap_at::date;

  v_source := NULLIF(btrim(COALESCE(p_source, '')), '');
  IF v_source IS NULL THEN
    v_source := NULLIF(btrim(COALESCE(v_raw->>'source_url', '')), '');
  END IF;

  -- Compute *_today vs latest prior calendar day (not same-day). Missing baseline => omit *_today.
  IF v_mode = 'cumulative' THEN
    FOR v_metric IN
      SELECT m
      FROM unnest(ARRAY['books', 'feathers', 'sessions', 'minutes', 'value']) AS m
      WHERE v_metrics ? m
        AND (v_metrics->>m) ~ '^-?[0-9]+(\.[0-9]+)?$'
    LOOP
      v_current := (v_metrics->>v_metric)::numeric;
      SELECT CASE
        WHEN (s.metrics->>v_metric) ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (s.metrics->>v_metric)::numeric
        ELSE NULL
      END
        INTO v_baseline
      FROM edu_site_progress_snapshots s
      WHERE s.profile = v_profile
        AND lower(s.site_kind) = v_kind
        AND s.snapshot_date < v_snap_date
      ORDER BY s.snapshot_date DESC, s.id DESC
      LIMIT 1;

      IF v_baseline IS NOT NULL THEN
        v_today_key := v_metric || '_today';
        v_metrics := v_metrics || jsonb_build_object(v_today_key, v_current - v_baseline);
      END IF;
    END LOOP;
  END IF;

  INSERT INTO edu_site_progress_snapshots (
    profile, site_kind, snapshot_at, snapshot_date, metrics, value_mode, source, raw
  ) VALUES (
    v_profile, v_kind, v_snap_at, v_snap_date, v_metrics, v_mode, v_source, v_raw
  )
  ON CONFLICT (profile, site_kind, snapshot_date) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at,
    metrics = EXCLUDED.metrics,
    value_mode = EXCLUDED.value_mode,
    source = EXCLUDED.source,
    raw = EXCLUDED.raw
  RETURNING id INTO v_id;

  v_goals := af_eval_edu_site_goal(v_profile, v_kind, v_snap_date);

  RETURN jsonb_build_object(
    'profile', v_profile,
    'snapshot_id', v_id,
    'snapshot_date', to_char(v_snap_date, 'YYYY-MM-DD'),
    'metrics', v_metrics,
    'value_mode', v_mode,
    'goals', COALESCE(v_goals, '[]'::jsonb)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION af_upsert_edu_site_progress(text, text, jsonb, text, jsonb, text, text)
  TO anon, authenticated, service_role;
