-- Call site: web/jumble.html after af_score_spelling_jumble completes.
-- Fires once per profile, language, and day when jumble typing is complete.
-- The jumble stores attempts immediately, so jumble_scored is already true.
-- This webhook tells Grok to review the typed attempts and update xtra words if needed.
-- Same webhook endpoint as spelling OCR.

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

GRANT EXECUTE ON FUNCTION af_enqueue_spelling_jumble_review(text, text, date) TO anon, authenticated, service_role;
