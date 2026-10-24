-- Call site: af_reading_passages_today, af_list_unscored_reading, af_score_reading_audio.
-- A word is a whitespace token with punctuation trimmed from both ends.
-- Case is folded. Apostrophes and accents inside a word stay.

CREATE OR REPLACE FUNCTION af_reading_language(p_language text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v text := lower(btrim(COALESCE(p_language, '')));
BEGIN
  IF v IN ('en', 'eng', 'english') THEN
    RETURN 'en';
  END IF;
  IF v IN ('fr', 'fre', 'french') THEN
    RETURN 'fr';
  END IF;
  RAISE EXCEPTION 'Invalid language: %', p_language;
END;
$$;

GRANT EXECUTE ON FUNCTION af_reading_language(text) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION af_reading_word_list(p_text text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(
    (
      SELECT array_agg(word ORDER BY ord)
      FROM (
        SELECT ord,
               regexp_replace(lower(token), '^[^[:alnum:]]+|[^[:alnum:]]+$', '', 'g') AS word
        FROM regexp_split_to_table(COALESCE(p_text, ''), E'\\s+') WITH ORDINALITY AS s(token, ord)
      ) cleaned
      WHERE word <> ''
    ),
    ARRAY[]::text[]
  );
$$;

GRANT EXECUTE ON FUNCTION af_reading_word_list(text) TO anon, authenticated, service_role;
