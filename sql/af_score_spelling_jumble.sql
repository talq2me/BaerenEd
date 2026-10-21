-- Call site: web/jumble.html when a spelling jumble used as OCR or extra copy finishes.
-- Misses are known immediately, so this does not wait for Grok.
-- An empty miss list means every word was right on the first try.
-- p_extra false replaces today's list from the main spelling jumble.
-- p_extra true replaces the list with the words still missed on the extra jumble.
-- p_attempts is the first try for each word: {"word","typed","correct"}.
-- The spelling OCR report reads those rows through af_get_spelling_typing.

DROP FUNCTION IF EXISTS af_score_spelling_jumble(text, text, date, text[], boolean);
DROP FUNCTION IF EXISTS af_score_spelling_jumble(text, text, date, text[], boolean, jsonb);

ALTER TABLE spelling_dictation_reviews ADD COLUMN IF NOT EXISTS jumble_scored BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE spelling_dictation_reviews ADD COLUMN IF NOT EXISTS jumble_attempts JSONB;

CREATE OR REPLACE FUNCTION af_score_spelling_jumble(
  p_profile text,
  p_language text,
  p_date date,
  p_missed text[],
  p_extra boolean,
  p_attempts jsonb DEFAULT NULL
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
  v_typed text;
  v_item jsonb;
  v_i int;
  v_attempts jsonb := '[]'::jsonb;
  v_existing jsonb := '[]'::jsonb;
  v_kept jsonb := '[]'::jsonb;
  v_stored jsonb := '[]'::jsonb;
BEGIN
  IF v_profile IS NULL OR v_profile = '' OR v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;
  IF v_language NOT IN ('eng', 'fr') THEN
    RAISE EXCEPTION 'Invalid language: %', p_language;
  END IF;
  IF p_date IS NULL THEN
    p_date := (NOW() AT TIME ZONE 'America/Toronto')::date;
  END IF;

  IF p_missed IS NOT NULL THEN
    FOREACH v_word IN ARRAY p_missed LOOP
      v_word := btrim(v_word);
      IF v_word <> '' AND NOT v_words @> jsonb_build_array(v_word) THEN
        v_words := v_words || to_jsonb(v_word);
      END IF;
    END LOOP;
  END IF;

  IF p_attempts IS NOT NULL AND jsonb_typeof(p_attempts) = 'array' THEN
    FOR v_i IN 0 .. jsonb_array_length(p_attempts) - 1 LOOP
      v_item := p_attempts -> v_i;
      v_word := btrim(COALESCE(v_item->>'word', ''));
      v_typed := btrim(COALESCE(v_item->>'typed', ''));
      IF v_word <> '' THEN
        v_attempts := v_attempts || jsonb_build_array(jsonb_build_object(
          'word', v_word,
          'typed', v_typed,
          'correct', COALESCE((v_item->>'correct')::boolean, false),
          'extra', COALESCE(p_extra, false)
        ));
      END IF;
    END LOOP;
  END IF;

  INSERT INTO spelling_dictation_reviews (profile, review_date, language, status, webhook_sent)
  VALUES (v_profile, p_date, v_language, 'incomplete', false)
  ON CONFLICT (profile, review_date, language) DO NOTHING;

  SELECT COALESCE(jumble_attempts, '[]'::jsonb)
    INTO v_existing
  FROM spelling_dictation_reviews
  WHERE profile = v_profile
    AND review_date = p_date
    AND language = v_language;

  IF p_attempts IS NULL OR jsonb_typeof(p_attempts) <> 'array' OR jsonb_array_length(p_attempts) = 0 THEN
    v_stored := v_existing;
  ELSIF COALESCE(p_extra, false) THEN
    SELECT COALESCE(jsonb_agg(elem ORDER BY ord), '[]'::jsonb)
      INTO v_kept
    FROM jsonb_array_elements(v_existing) WITH ORDINALITY AS listed(elem, ord)
    WHERE COALESCE((elem->>'extra')::boolean, false) = false;
    v_stored := v_kept || v_attempts;
  ELSE
    v_stored := v_attempts;
  END IF;

  UPDATE spelling_dictation_reviews
  SET jumble_scored = true,
      words = v_words,
      jumble_attempts = v_stored,
      xtra_round = CASE
        WHEN jsonb_array_length(v_words) > 0 THEN COALESCE(xtra_round, 1)
        ELSE xtra_round
      END,
      status = CASE
        WHEN status = 'complete' AND NOT COALESCE(p_extra, false) THEN status
        WHEN COALESCE(p_extra, false) AND jsonb_array_length(v_words) = 0 THEN status
        ELSE 'incomplete'
      END
  WHERE profile = v_profile
    AND review_date = p_date
    AND language = v_language;
END;
$$;

GRANT EXECUTE ON FUNCTION af_score_spelling_jumble(text, text, date, text[], boolean, jsonb) TO anon, authenticated, service_role;

-- Report call site: reports/spelling_ocr_report.html and reports/spelling_ocr_detail.html.
-- Returns {"eng":[...],"fr":[...]} for a profile and Toronto day.
-- Each item is {"word","typed","correct","extra"}.
-- Older keyboard sessions stored only the missed words, so those come back with an empty typed string.

CREATE OR REPLACE FUNCTION af_get_spelling_typing(
  p_profile text,
  p_date date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(trim(p_profile));
  v_result jsonb := '{}'::jsonb;
  v_row record;
  v_attempts jsonb;
BEGIN
  IF v_profile IS NULL OR v_profile = '' OR v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;
  IF p_date IS NULL THEN
    p_date := (NOW() AT TIME ZONE 'America/Toronto')::date;
  END IF;

  FOR v_row IN
    SELECT language, jumble_attempts, words
    FROM spelling_dictation_reviews
    WHERE profile = v_profile
      AND review_date = p_date
      AND COALESCE(jumble_scored, false)
  LOOP
    v_attempts := NULL;
    IF v_row.jumble_attempts IS NOT NULL
       AND jsonb_typeof(v_row.jumble_attempts) = 'array'
       AND jsonb_array_length(v_row.jumble_attempts) > 0 THEN
      v_attempts := v_row.jumble_attempts;
    ELSIF v_row.words IS NOT NULL
       AND jsonb_typeof(v_row.words) = 'array'
       AND jsonb_array_length(v_row.words) > 0 THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'word', item,
        'typed', '',
        'correct', false,
        'extra', false
      )), '[]'::jsonb)
        INTO v_attempts
      FROM jsonb_array_elements_text(v_row.words) AS item;
    END IF;
    IF v_attempts IS NOT NULL THEN
      v_result := v_result || jsonb_build_object(v_row.language, v_attempts);
    END IF;
  END LOOP;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION af_get_spelling_typing(text, date) TO anon, authenticated, service_role;
