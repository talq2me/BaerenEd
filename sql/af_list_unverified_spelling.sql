-- Call site: the Grok spelling automation.
-- Returns unverified photos for one profile, language, and date.
-- p_kind is 'ocr' or 'xtra'. Each row includes the image and the word to compare.

CREATE OR REPLACE FUNCTION af_list_unverified_spelling(
  p_profile text,
  p_language text,
  p_date date,
  p_kind text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(trim(p_profile));
  v_language text := lower(trim(p_language));
  v_kind text := lower(trim(COALESCE(p_kind, 'ocr')));
  v_prefix text;
  v_day text;
  v_re text;
  v_rows jsonb;
BEGIN
  IF v_profile IS NULL OR v_profile = '' OR v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;
  IF v_language = 'eng' AND v_kind = 'ocr' THEN
    v_prefix := 'EngSpellingOCR';
  ELSIF v_language = 'fr' AND v_kind = 'ocr' THEN
    v_prefix := 'FrSpellingOCR';
  ELSIF v_language = 'eng' AND v_kind = 'xtra' THEN
    v_prefix := 'EngSpellingOCRXtra';
  ELSIF v_language = 'fr' AND v_kind = 'xtra' THEN
    v_prefix := 'FrSpellingOCRXtra';
  ELSE
    RAISE EXCEPTION 'Invalid language or kind: % %', p_language, p_kind;
  END IF;

  IF p_date IS NULL THEN
    p_date := (NOW() AT TIME ZONE 'America/Toronto')::date;
  END IF;
  v_day := to_char(p_date, 'YYYY-MM-DD');

  IF v_kind = 'ocr' THEN
    v_re := '^(?:Eng|Fr)SpellingOCR-' || v_day || '-([0-9]+)-(.+)-unverified$';
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'id', id,
             'task', task,
             'word', m[2],
             'n', m[1]::int,
             'round', NULL,
             'image', image
           ) ORDER BY m[1]::int), '[]'::jsonb)
      INTO v_rows
    FROM (
      SELECT id, task, image, regexp_match(task, v_re) AS m
      FROM image_uploads
      WHERE profile = v_profile
        AND task LIKE v_prefix || '-' || v_day || '-%-unverified'
    ) parsed
    WHERE m IS NOT NULL;
  ELSE
    v_re := '^(?:Eng|Fr)SpellingOCRXtra-' || v_day || '-r([0-9]+)-([0-9]+)-(.+)-unverified$';
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'id', id,
             'task', task,
             'word', m[3],
             'n', m[2]::int,
             'round', m[1]::int,
             'image', image
           ) ORDER BY m[1]::int, m[2]::int), '[]'::jsonb)
      INTO v_rows
    FROM (
      SELECT id, task, image, regexp_match(task, v_re) AS m
      FROM image_uploads
      WHERE profile = v_profile
        AND task LIKE v_prefix || '-' || v_day || '-%-unverified'
    ) parsed
    WHERE m IS NOT NULL;
  END IF;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION af_list_unverified_spelling(text, text, date, text) TO anon, authenticated, service_role;
