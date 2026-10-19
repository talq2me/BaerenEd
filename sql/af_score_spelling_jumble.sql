-- Call site: web/jumble.html when a spelling jumble used as OCR or extra copy finishes.
-- Misses are known immediately, so this does not wait for Grok.
-- An empty miss list means every word was right on the first try.
-- p_extra false replaces today's list from the main spelling jumble.
-- p_extra true replaces the list with the words still missed on the extra jumble.

ALTER TABLE spelling_dictation_reviews ADD COLUMN IF NOT EXISTS jumble_scored BOOLEAN NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION af_score_spelling_jumble(
  p_profile text,
  p_language text,
  p_date date,
  p_missed text[],
  p_extra boolean
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

  INSERT INTO spelling_dictation_reviews (profile, review_date, language, status, webhook_sent)
  VALUES (v_profile, p_date, v_language, 'incomplete', false)
  ON CONFLICT (profile, review_date, language) DO NOTHING;

  UPDATE spelling_dictation_reviews
  SET jumble_scored = true,
      words = v_words,
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

GRANT EXECUTE ON FUNCTION af_score_spelling_jumble(text, text, date, text[], boolean) TO anon, authenticated, service_role;
