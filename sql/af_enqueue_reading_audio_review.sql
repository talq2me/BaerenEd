-- Call site: readAloud.html after the last clip for the day is stored.
-- Authorization: Bearer token is Vault secret reading_audio_webhook_bearer (no "Bearer " prefix).
-- Different webhook from spelling so the audio bot receives the ping.
-- kind=readAloud tells the bot to score audio instead of photos.
-- Body: {"profile","language","date","kind":"readAloud"}

DROP FUNCTION IF EXISTS af_enqueue_reading_audio_review(text, text, date, boolean);

CREATE OR REPLACE FUNCTION af_enqueue_reading_audio_review(
  p_profile text,
  p_language text,
  p_date date DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_profile text := upper(btrim(COALESCE(p_profile, '')));
  v_language text;
  v_date date := COALESCE(p_date, (NOW() AT TIME ZONE 'America/Toronto')::date);
  v_day text;
  v_key text;
  v_guard text;
  v_ids bigint[];
  v_tasks text[];
  v_count int;
  v_unscored int;
  v_bank int;
  v_cursor int;
  v_next int;
  v_token text;
  v_body text;
  v_claimed int;
  v_status int;
BEGIN
  IF v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;
  v_language := af_reading_language(p_language);
  v_day := to_char(v_date, 'YYYY-MM-DD');
  v_key := 'readAloud_' || v_language;
  v_guard := '_readAloudAdvancedOn_' || v_language;

  SELECT passage_ids INTO v_ids
  FROM reading_days
  WHERE profile = v_profile
    AND day = v_date
    AND language = v_language;

  IF v_ids IS NULL OR cardinality(v_ids) < 1 THEN
    RETURN;
  END IF;

  SELECT array_agg('readAloud_' || v_language || '_' || pid || '_' || v_day ORDER BY ord)
    INTO v_tasks
  FROM unnest(v_ids) WITH ORDINALITY AS u(pid, ord);

  SELECT count(*) INTO v_count
  FROM image_uploads
  WHERE profile = v_profile
    AND task = ANY (v_tasks);

  IF v_count < cardinality(v_ids) THEN
    RETURN;
  END IF;

  SELECT count(*) INTO v_bank
  FROM reading_passages
  WHERE profile = v_profile
    AND language = v_language
    AND enabled;

  IF v_bank > 0 THEN
    SELECT COALESCE((game_indices->>v_key)::int, 0)
      INTO v_cursor
    FROM user_data
    WHERE profile = v_profile;

    IF v_cursor IS NULL OR v_cursor < 0 THEN
      v_cursor := 0;
    END IF;
    v_next := (v_cursor + cardinality(v_ids)) % v_bank;

    UPDATE user_data
    SET game_indices = jsonb_set(
          jsonb_set(COALESCE(game_indices, '{}'::jsonb), ARRAY[v_key], to_jsonb(v_next), true),
          ARRAY[v_guard], to_jsonb(v_day), true
        ),
        last_updated = (NOW() AT TIME ZONE 'America/Toronto')
    WHERE profile = v_profile
      AND COALESCE(game_indices->>v_guard, '') IS DISTINCT FROM v_day;
  END IF;

  SELECT count(*) INTO v_unscored
  FROM image_uploads
  WHERE profile = v_profile
    AND task = ANY (v_tasks)
    AND words_correct IS NULL;

  INSERT INTO reading_audio_reviews (profile, review_date, language, status, webhook_sent)
  VALUES (v_profile, v_date, v_language, 'incomplete', false)
  ON CONFLICT (profile, review_date, language) DO NOTHING;

  IF v_unscored = 0 THEN
    UPDATE reading_audio_reviews
    SET status = 'complete'
    WHERE profile = v_profile
      AND review_date = v_date
      AND language = v_language;
    RETURN;
  END IF;

  UPDATE reading_audio_reviews r
  SET webhook_sent = false,
      webhook_sent_at = NULL,
      status = 'incomplete'
  WHERE r.profile = v_profile
    AND r.review_date = v_date
    AND r.language = v_language
    AND r.webhook_sent = true
    AND EXISTS (
      SELECT 1
      FROM image_uploads iu
      WHERE iu.profile = v_profile
        AND iu.task = ANY (v_tasks)
        AND r.webhook_sent_at IS NOT NULL
        AND iu.capture_date_time > r.webhook_sent_at
    );

  SELECT decrypted_secret INTO v_token
  FROM vault.decrypted_secrets
  WHERE name = 'reading_audio_webhook_bearer'
  LIMIT 1;

  IF v_token IS NULL OR btrim(v_token) = '' THEN
    RAISE WARNING 'reading_audio_webhook_bearer not configured in Supabase Vault';
    RETURN;
  END IF;

  UPDATE reading_audio_reviews
  SET webhook_sent = true,
      webhook_sent_at = (NOW() AT TIME ZONE 'America/Toronto'),
      status = 'incomplete'
  WHERE profile = v_profile
    AND review_date = v_date
    AND language = v_language
    AND webhook_sent = false;

  GET DIAGNOSTICS v_claimed = ROW_COUNT;
  IF v_claimed = 0 THEN
    RETURN;
  END IF;

  v_body := jsonb_build_object(
    'profile', v_profile,
    'language', v_language,
    'date', v_day,
    'kind', 'readAloud'
  )::text;

  BEGIN
    SELECT r.status INTO v_status
    FROM extensions.http((
      'POST',
      'https://api2.cursor.sh/automations/webhook/fea2ec63-4c7f-5c82-ad08-e8e14986505e',
      ARRAY[
        extensions.http_header('Authorization', 'Bearer ' || btrim(v_token)),
        extensions.http_header('Content-Type', 'application/json')
      ]::extensions.http_header[],
      'application/json',
      v_body
    )::extensions.http_request) r;
  EXCEPTION WHEN OTHERS THEN
    UPDATE reading_audio_reviews
    SET webhook_sent = false,
        webhook_sent_at = NULL
    WHERE profile = v_profile
      AND review_date = v_date
      AND language = v_language
      AND status IS DISTINCT FROM 'complete';
    RAISE WARNING 'reading audio webhook request failed: %', SQLERRM;
    RETURN;
  END;

  IF v_status IS NULL OR v_status < 200 OR v_status >= 300 THEN
    UPDATE reading_audio_reviews
    SET webhook_sent = false,
        webhook_sent_at = NULL
    WHERE profile = v_profile
      AND review_date = v_date
      AND language = v_language
      AND status IS DISTINCT FROM 'complete';
    RAISE WARNING 'reading audio webhook returned status %', COALESCE(v_status, -1);
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION af_enqueue_reading_audio_review(text, text, date) TO anon, authenticated, service_role;
