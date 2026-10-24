-- Call site: the Grok read-aloud automation.
-- Returns today's unscored clips for one profile and language.
-- audio is the data URL stored on image_uploads.
-- words is the passage split on whitespace, with punctuation trimmed and case folded.
-- A clip that was scored and then re-recorded comes back here because the new upload clears its score.

CREATE OR REPLACE FUNCTION af_list_unscored_reading(
  p_profile text,
  p_language text,
  p_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(btrim(COALESCE(p_profile, '')));
  v_language text;
  v_date date := COALESCE(p_date, (NOW() AT TIME ZONE 'America/Toronto')::date);
  v_day text;
  v_ids bigint[];
  v_rows jsonb;
BEGIN
  IF v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;
  v_language := af_reading_language(p_language);
  v_day := to_char(v_date, 'YYYY-MM-DD');

  SELECT passage_ids INTO v_ids
  FROM reading_days
  WHERE profile = v_profile
    AND day = v_date
    AND language = v_language;

  IF v_ids IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', iu.id,
           'passage_id', p.id,
           'text', p.text,
           'words', to_jsonb(af_reading_word_list(p.text)),
           'language', v_language,
           'date', v_day,
           'audio', iu.image
         ) ORDER BY u.ord), '[]'::jsonb)
    INTO v_rows
  FROM unnest(v_ids) WITH ORDINALITY AS u(pid, ord)
  JOIN reading_passages p ON p.id = u.pid
  JOIN image_uploads iu
    ON iu.profile = v_profile
   AND iu.task = 'readAloud_' || v_language || '_' || u.pid || '_' || v_day
   AND iu.words_correct IS NULL;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION af_list_unscored_reading(text, text, date) TO anon, authenticated, service_role;
