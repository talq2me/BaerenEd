-- Call site: the Grok spelling automation, only when at least one word was incorrect.
-- Do not call this when every photo was correct. An empty list is ignored.
-- The first call publishes round 1. A later call, after that round is fully scored,
-- replaces the list and starts the next round.

CREATE OR REPLACE FUNCTION af_set_spelling_xtra_words(
  p_profile text,
  p_language text,
  p_date date,
  p_words text[]
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(trim(p_profile));
  v_language text := lower(trim(p_language));
  v_words jsonb := '[]'::jsonb;
  v_word text;
  v_round int;
  v_prefix text;
  v_day text;
  v_photo_count int := 0;
  v_unverified int := 0;
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
  IF p_date IS NULL THEN
    p_date := (NOW() AT TIME ZONE 'America/Toronto')::date;
  END IF;

  IF p_words IS NOT NULL THEN
    FOREACH v_word IN ARRAY p_words LOOP
      v_word := btrim(v_word);
      IF v_word <> '' AND NOT v_words @> jsonb_build_array(v_word) THEN
        v_words := v_words || to_jsonb(v_word);
      END IF;
    END LOOP;
  END IF;
  IF jsonb_array_length(v_words) < 1 THEN
    RETURN;
  END IF;

  INSERT INTO spelling_dictation_reviews (profile, review_date, language, status, webhook_sent)
  VALUES (v_profile, p_date, v_language, 'incomplete', false)
  ON CONFLICT (profile, review_date, language) DO NOTHING;

  SELECT xtra_round INTO v_round
  FROM spelling_dictation_reviews
  WHERE profile = v_profile
    AND review_date = p_date
    AND language = v_language;

  v_day := to_char(p_date, 'YYYY-MM-DD');
  IF v_round IS NOT NULL THEN
    SELECT count(*), count(*) FILTER (WHERE task LIKE '%-unverified')
      INTO v_photo_count, v_unverified
    FROM image_uploads
    WHERE profile = v_profile
      AND task LIKE v_prefix || '-' || v_day || '-r' || lpad(v_round::text, 2, '0') || '-sheet-%';
    IF v_unverified > 0 THEN
      RETURN;
    END IF;
    IF v_photo_count > 0 THEN
      v_round := v_round + 1;
    END IF;
  END IF;
  v_round := COALESCE(v_round, 1);

  UPDATE spelling_dictation_reviews
  SET words = v_words,
      xtra_round = v_round,
      status = 'incomplete'
  WHERE profile = v_profile
    AND review_date = p_date
    AND language = v_language
    AND status IS DISTINCT FROM 'complete';
END;
$$;

GRANT EXECUTE ON FUNCTION af_set_spelling_xtra_words(text, text, date, text[]) TO anon, authenticated, service_role;
