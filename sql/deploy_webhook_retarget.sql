-- Paste into the Supabase SQL editor to retarget every Grok bot webhook.
-- Destination: https://api2.cursor.sh/automations/webhook/f84fbceb-3b8e-5598-a447-b64fc0313ddc
-- Vault secret names are unchanged: spelling_ocr_webhook_bearer,
-- reading_audio_webhook_bearer, and edu_site_checker_webhook_bearer.

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
      'https://api2.cursor.sh/automations/webhook/f84fbceb-3b8e-5598-a447-b64fc0313ddc',
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

CREATE OR REPLACE FUNCTION af_maybe_enqueue_edu_site_checker(p_profile text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_profile text := upper(btrim(COALESCE(p_profile, '')));
  v_date date := (NOW() AT TIME ZONE 'America/Toronto')::date;
  v_day text;
  v_progress jsonb;
  v_task_count int;
  v_token text;
  v_body text;
  v_claimed int;
  v_status int;
  v_send_count int;
BEGIN
  IF v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RETURN;
  END IF;

  v_progress := af_get_required_progress_today(v_profile);
  IF NOT COALESCE((v_progress->>'all_done')::boolean, false) THEN
    RETURN;
  END IF;

  SELECT count(*)::int INTO v_task_count
  FROM af_get_tasks_required(v_profile) AS t
  WHERE NOT t.is_checklist OR COALESCE(t.berry_value, 0) > 0;

  IF COALESCE(v_task_count, 0) < 1 THEN
    RETURN;
  END IF;

  INSERT INTO edu_site_checker_runs (profile, check_date, status, webhook_sent, webhook_send_count)
  VALUES (v_profile, v_date, 'incomplete', false, 0)
  ON CONFLICT (profile, check_date) DO NOTHING;

  SELECT webhook_send_count INTO v_send_count
  FROM edu_site_checker_runs
  WHERE profile = v_profile
    AND check_date = v_date;

  IF COALESCE(v_send_count, 0) >= 2 THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM edu_site_checker_runs
    WHERE profile = v_profile
      AND check_date = v_date
      AND status = 'complete'
  ) THEN
    RETURN;
  END IF;

  SELECT decrypted_secret INTO v_token
  FROM vault.decrypted_secrets
  WHERE name = 'edu_site_checker_webhook_bearer'
  LIMIT 1;

  IF v_token IS NULL OR btrim(v_token) = '' THEN
    RAISE WARNING 'edu_site_checker_webhook_bearer not configured in Supabase Vault';
    RETURN;
  END IF;

  UPDATE edu_site_checker_runs
  SET
    webhook_sent = true,
    webhook_sent_at = (NOW() AT TIME ZONE 'America/Toronto'),
    webhook_send_count = webhook_send_count + 1
  WHERE profile = v_profile
    AND check_date = v_date
    AND webhook_send_count < 2
    AND status IS DISTINCT FROM 'complete';

  GET DIAGNOSTICS v_claimed = ROW_COUNT;
  IF v_claimed = 0 THEN
    RETURN;
  END IF;

  v_day := to_char(v_date, 'YYYY-MM-DD');
  v_body := jsonb_build_object(
    'profile', v_profile,
    'date', v_day,
    'kind', 'edu_site_check'
  )::text;

  BEGIN
    SELECT r.status INTO v_status
    FROM extensions.http((
      'POST',
      'https://api2.cursor.sh/automations/webhook/f84fbceb-3b8e-5598-a447-b64fc0313ddc',
      ARRAY[
        extensions.http_header('Authorization', 'Bearer ' || btrim(v_token)),
        extensions.http_header('Content-Type', 'application/json')
      ]::extensions.http_header[],
      'application/json',
      v_body
    )::extensions.http_request) r;
  EXCEPTION WHEN OTHERS THEN
    UPDATE edu_site_checker_runs
    SET
      webhook_sent = false,
      webhook_sent_at = NULL,
      webhook_send_count = GREATEST(webhook_send_count - 1, 0)
    WHERE profile = v_profile
      AND check_date = v_date
      AND status IS DISTINCT FROM 'complete';
    RAISE WARNING 'EduSiteChecker webhook request failed: %', SQLERRM;
    RETURN;
  END;

  IF v_status IS NULL OR v_status < 200 OR v_status >= 300 THEN
    UPDATE edu_site_checker_runs
    SET
      webhook_sent = false,
      webhook_sent_at = NULL,
      webhook_send_count = GREATEST(webhook_send_count - 1, 0)
    WHERE profile = v_profile
      AND check_date = v_date
      AND status IS DISTINCT FROM 'complete';
    RAISE WARNING 'EduSiteChecker webhook returned status %', COALESCE(v_status, -1);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION af_enqueue_spelling_ocr_review(
  p_profile text,
  p_language text,
  p_date date,
  p_expected_count int
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_profile text := upper(trim(p_profile));
  v_language text := lower(trim(p_language));
  v_prefix text;
  v_day text;
  v_count int;
  v_token text;
  v_body text;
  v_status int;
  v_claimed int;
BEGIN
  IF v_profile IS NULL OR v_profile = '' OR v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;
  IF v_language NOT IN ('eng', 'fr') THEN
    RAISE EXCEPTION 'Invalid language: %', p_language;
  END IF;
  IF p_date IS NULL OR COALESCE(p_expected_count, 0) < 1 THEN
    RETURN;
  END IF;

  v_prefix := CASE v_language WHEN 'eng' THEN 'EngSpellingOCR' ELSE 'FrSpellingOCR' END;
  v_day := to_char(p_date, 'YYYY-MM-DD');

  SELECT count(*) INTO v_count
  FROM image_uploads
  WHERE profile = v_profile
    AND task LIKE v_prefix || '-' || v_day || '-%';

  IF v_count < p_expected_count THEN
    RETURN;
  END IF;

  INSERT INTO spelling_dictation_reviews (profile, review_date, language, status, webhook_sent)
  VALUES (v_profile, p_date, v_language, 'incomplete', false)
  ON CONFLICT (profile, review_date, language) DO NOTHING;

  UPDATE spelling_dictation_reviews
  SET webhook_sent = true,
      jumble_scored = false
  WHERE profile = v_profile
    AND review_date = p_date
    AND language = v_language
    AND webhook_sent = false
    AND status IS DISTINCT FROM 'complete';

  GET DIAGNOSTICS v_claimed = ROW_COUNT;
  IF v_claimed = 0 THEN
    RETURN;
  END IF;

  SELECT decrypted_secret INTO v_token
  FROM vault.decrypted_secrets
  WHERE name = 'spelling_ocr_webhook_bearer'
  LIMIT 1;

  IF v_token IS NULL OR btrim(v_token) = '' THEN
    UPDATE spelling_dictation_reviews
    SET webhook_sent = false
    WHERE profile = v_profile
      AND review_date = p_date
      AND language = v_language
      AND status IS DISTINCT FROM 'complete';
    RAISE WARNING 'spelling_ocr_webhook_bearer not configured in Supabase Vault';
    RETURN;
  END IF;

  v_body := jsonb_build_object(
    'profile', v_profile,
    'language', v_language,
    'date', v_day
  )::text;

  BEGIN
    SELECT r.status INTO v_status
    FROM extensions.http((
      'POST',
      'https://api2.cursor.sh/automations/webhook/f84fbceb-3b8e-5598-a447-b64fc0313ddc',
      ARRAY[
        extensions.http_header('Authorization', 'Bearer ' || btrim(v_token)),
        extensions.http_header('Content-Type', 'application/json')
      ]::extensions.http_header[],
      'application/json',
      v_body
    )::extensions.http_request) r;
  EXCEPTION WHEN OTHERS THEN
    UPDATE spelling_dictation_reviews
    SET webhook_sent = false
    WHERE profile = v_profile
      AND review_date = p_date
      AND language = v_language
      AND status IS DISTINCT FROM 'complete';
    RAISE WARNING 'spelling OCR webhook request failed: %', SQLERRM;
    RETURN;
  END;

  IF v_status IS NULL OR v_status < 200 OR v_status >= 300 THEN
    UPDATE spelling_dictation_reviews
    SET webhook_sent = false
    WHERE profile = v_profile
      AND review_date = p_date
      AND language = v_language
      AND status IS DISTINCT FROM 'complete';
    RAISE WARNING 'spelling OCR webhook returned status %', COALESCE(v_status, -1);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION af_enqueue_spelling_paper_review(
  p_profile text,
  p_language text,
  p_date date,
  p_expected_count int
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_profile text := upper(trim(p_profile));
  v_language text := lower(trim(p_language));
  v_prefix text;
  v_day text;
  v_count int;
  v_token text;
  v_body text;
  v_status int;
  v_claimed int;
BEGIN
  IF v_profile IS NULL OR v_profile = '' OR v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;
  IF v_language NOT IN ('eng', 'fr') THEN
    RAISE EXCEPTION 'Invalid language: %', p_language;
  END IF;
  IF p_date IS NULL OR COALESCE(p_expected_count, 0) < 1 THEN
    RETURN;
  END IF;

  v_prefix := CASE v_language WHEN 'eng' THEN 'EngSpellingOCRPaper' ELSE 'FrSpellingOCRPaper' END;
  v_day := to_char(p_date, 'YYYY-MM-DD');

  SELECT count(*) INTO v_count
  FROM image_uploads
  WHERE profile = v_profile
    AND task LIKE v_prefix || '-' || v_day || '-%';

  IF v_count < p_expected_count THEN
    RETURN;
  END IF;

  INSERT INTO spelling_dictation_reviews (profile, review_date, language, status, webhook_sent)
  VALUES (v_profile, p_date, v_language, 'incomplete', false)
  ON CONFLICT (profile, review_date, language) DO NOTHING;

  UPDATE spelling_dictation_reviews
  SET webhook_sent = true,
      jumble_scored = false
  WHERE profile = v_profile
    AND review_date = p_date
    AND language = v_language
    AND webhook_sent = false
    AND status IS DISTINCT FROM 'complete';

  GET DIAGNOSTICS v_claimed = ROW_COUNT;
  IF v_claimed = 0 THEN
    RETURN;
  END IF;

  SELECT decrypted_secret INTO v_token
  FROM vault.decrypted_secrets
  WHERE name = 'spelling_ocr_webhook_bearer'
  LIMIT 1;

  IF v_token IS NULL OR btrim(v_token) = '' THEN
    UPDATE spelling_dictation_reviews
    SET webhook_sent = false
    WHERE profile = v_profile
      AND review_date = p_date
      AND language = v_language
      AND status IS DISTINCT FROM 'complete';
    RAISE WARNING 'spelling_ocr_webhook_bearer not configured in Supabase Vault';
    RETURN;
  END IF;

  v_body := jsonb_build_object(
    'profile', v_profile,
    'language', v_language,
    'date', v_day,
    'kind', 'paper'
  )::text;

  BEGIN
    SELECT r.status INTO v_status
    FROM extensions.http((
      'POST',
      'https://api2.cursor.sh/automations/webhook/f84fbceb-3b8e-5598-a447-b64fc0313ddc',
      ARRAY[
        extensions.http_header('Authorization', 'Bearer ' || btrim(v_token)),
        extensions.http_header('Content-Type', 'application/json')
      ]::extensions.http_header[],
      'application/json',
      v_body
    )::extensions.http_request) r;
  EXCEPTION WHEN OTHERS THEN
    UPDATE spelling_dictation_reviews
    SET webhook_sent = false
    WHERE profile = v_profile
      AND review_date = p_date
      AND language = v_language
      AND status IS DISTINCT FROM 'complete';
    RAISE WARNING 'spelling list webhook request failed: %', SQLERRM;
    RETURN;
  END;

  IF v_status IS NULL OR v_status < 200 OR v_status >= 300 THEN
    UPDATE spelling_dictation_reviews
    SET webhook_sent = false
    WHERE profile = v_profile
      AND review_date = p_date
      AND language = v_language
      AND status IS DISTINCT FROM 'complete';
    RAISE WARNING 'spelling list webhook returned status %', COALESCE(v_status, -1);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION af_enqueue_spelling_jumble_review(
  p_profile text,
  p_language text,
  p_date date
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_profile text := upper(trim(p_profile));
  v_language text := lower(trim(p_language));
  v_day text;
  v_token text;
  v_body text;
  v_status int;
  v_claimed int;
  v_jumble_scored boolean;
BEGIN
  IF v_profile IS NULL OR v_profile = '' OR v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;
  IF v_language NOT IN ('eng', 'fr') THEN
    RAISE EXCEPTION 'Invalid language: %', p_language;
  END IF;
  IF p_date IS NULL THEN
    RETURN;
  END IF;

  v_day := to_char(p_date, 'YYYY-MM-DD');

  -- Only proceed if jumble_scored is true (af_score_spelling_jumble already ran)
  SELECT COALESCE(jumble_scored, false)
    INTO v_jumble_scored
  FROM spelling_dictation_reviews
  WHERE profile = v_profile
    AND review_date = p_date
    AND language = v_language;

  IF NOT COALESCE(v_jumble_scored, false) THEN
    RETURN;
  END IF;

  -- Mark webhook_sent = true to prevent duplicate webhooks
  UPDATE spelling_dictation_reviews
  SET webhook_sent = true
  WHERE profile = v_profile
    AND review_date = p_date
    AND language = v_language
    AND webhook_sent = false
    AND jumble_scored = true
    AND status IS DISTINCT FROM 'complete';

  GET DIAGNOSTICS v_claimed = ROW_COUNT;
  IF v_claimed = 0 THEN
    RETURN;
  END IF;

  SELECT decrypted_secret INTO v_token
  FROM vault.decrypted_secrets
  WHERE name = 'spelling_ocr_webhook_bearer'
  LIMIT 1;

  IF v_token IS NULL OR btrim(v_token) = '' THEN
    UPDATE spelling_dictation_reviews
    SET webhook_sent = false
    WHERE profile = v_profile
      AND review_date = p_date
      AND language = v_language
      AND status IS DISTINCT FROM 'complete';
    RAISE WARNING 'spelling_ocr_webhook_bearer not configured in Supabase Vault';
    RETURN;
  END IF;

  v_body := jsonb_build_object(
    'profile', v_profile,
    'language', v_language,
    'date', v_day,
    'kind', 'jumble'
  )::text;

  BEGIN
    SELECT r.status INTO v_status
    FROM extensions.http((
      'POST',
      'https://api2.cursor.sh/automations/webhook/f84fbceb-3b8e-5598-a447-b64fc0313ddc',
      ARRAY[
        extensions.http_header('Authorization', 'Bearer ' || btrim(v_token)),
        extensions.http_header('Content-Type', 'application/json')
      ]::extensions.http_header[],
      'application/json',
      v_body
    )::extensions.http_request) r;
  EXCEPTION WHEN OTHERS THEN
    UPDATE spelling_dictation_reviews
    SET webhook_sent = false
    WHERE profile = v_profile
      AND review_date = p_date
      AND language = v_language
      AND status IS DISTINCT FROM 'complete';
    RAISE WARNING 'spelling jumble webhook request failed: %', SQLERRM;
    RETURN;
  END;

  IF v_status IS NULL OR v_status < 200 OR v_status >= 300 THEN
    UPDATE spelling_dictation_reviews
    SET webhook_sent = false
    WHERE profile = v_profile
      AND review_date = p_date
      AND language = v_language
      AND status IS DISTINCT FROM 'complete';
    RAISE WARNING 'spelling jumble webhook returned status %', COALESCE(v_status, -1);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION af_enqueue_spelling_xtra_review(
  p_profile text,
  p_language text,
  p_date date,
  p_expected_count int
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_profile text := upper(trim(p_profile));
  v_language text := lower(trim(p_language));
  v_prefix text;
  v_day text;
  v_round int;
  v_sent int;
  v_count int;
  v_token text;
  v_body text;
  v_status int;
BEGIN
  IF v_profile IS NULL OR v_profile = '' OR v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;
  IF v_language = 'eng' THEN
    v_prefix := 'EngSpellingOCRXtra';
  ELSIF v_language = 'fr' THEN
    v_prefix := 'FrSpellingOCRXtra';
  ELSE
    RAISE EXCEPTION 'Invalid language: %', p_language;
  END IF;
  IF p_date IS NULL OR COALESCE(p_expected_count, 0) < 1 THEN
    RETURN;
  END IF;

  SELECT xtra_round, COALESCE(xtra_sent_round, 0)
    INTO v_round, v_sent
  FROM spelling_dictation_reviews
  WHERE profile = v_profile
    AND review_date = p_date
    AND language = v_language;

  IF v_round IS NULL OR v_sent >= v_round THEN
    RETURN;
  END IF;

  v_day := to_char(p_date, 'YYYY-MM-DD');
  SELECT count(*) INTO v_count
  FROM image_uploads
  WHERE profile = v_profile
    AND task LIKE v_prefix || '-' || v_day || '-r' || lpad(v_round::text, 2, '0') || '-%';

  IF v_count < p_expected_count THEN
    RETURN;
  END IF;

  UPDATE spelling_dictation_reviews
  SET xtra_sent_round = v_round
  WHERE profile = v_profile
    AND review_date = p_date
    AND language = v_language
    AND COALESCE(xtra_sent_round, 0) < v_round
    AND status IS DISTINCT FROM 'complete';

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT decrypted_secret INTO v_token
  FROM vault.decrypted_secrets
  WHERE name = 'spelling_ocr_webhook_bearer'
  LIMIT 1;

  IF v_token IS NULL OR btrim(v_token) = '' THEN
    UPDATE spelling_dictation_reviews
    SET xtra_sent_round = v_sent
    WHERE profile = v_profile AND review_date = p_date AND language = v_language;
    RAISE WARNING 'spelling_ocr_webhook_bearer not configured in Supabase Vault';
    RETURN;
  END IF;

  v_body := jsonb_build_object(
    'profile', v_profile,
    'language', v_language,
    'date', v_day,
    'kind', 'xtra',
    'round', v_round
  )::text;

  BEGIN
    SELECT r.status INTO v_status
    FROM extensions.http((
      'POST',
      'https://api2.cursor.sh/automations/webhook/f84fbceb-3b8e-5598-a447-b64fc0313ddc',
      ARRAY[
        extensions.http_header('Authorization', 'Bearer ' || btrim(v_token)),
        extensions.http_header('Content-Type', 'application/json')
      ]::extensions.http_header[],
      'application/json',
      v_body
    )::extensions.http_request) r;
  EXCEPTION WHEN OTHERS THEN
    UPDATE spelling_dictation_reviews
    SET xtra_sent_round = v_sent
    WHERE profile = v_profile AND review_date = p_date AND language = v_language;
    RAISE WARNING 'spelling extra webhook request failed: %', SQLERRM;
    RETURN;
  END;

  IF v_status IS NULL OR v_status < 200 OR v_status >= 300 THEN
    UPDATE spelling_dictation_reviews
    SET xtra_sent_round = v_sent
    WHERE profile = v_profile AND review_date = p_date AND language = v_language;
    RAISE WARNING 'spelling extra webhook returned status %', COALESCE(v_status, -1);
  END IF;
END;
$$;
