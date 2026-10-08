-- Call site: web/xtra.html after the rewrite sheet is stored, and web/map.html if that webhook never went out.
-- Paper sends one sheet and p_expected_count 1. Screen sends one drawing per copy.
-- Sends kind "xtra".
-- xtra_sent_round stops a second POST for the same round.
-- The next round can send again after af_set_spelling_xtra_words advances xtra_round.

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
      'https://api2.cursor.sh/automations/webhook/2cb85974-7eea-5dd6-99ad-8d521fa2e7f7',
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

GRANT EXECUTE ON FUNCTION af_enqueue_spelling_xtra_review(text, text, date, int) TO anon, authenticated, service_role;
