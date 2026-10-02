-- Call site: web/map.html when the extra task has nothing left to practice.

CREATE OR REPLACE FUNCTION af_mark_spelling_xtra_complete(
  p_profile text,
  p_language text,
  p_date date
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(trim(p_profile));
  v_language text := lower(trim(p_language));
  v_status jsonb;
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

  v_status := af_get_spelling_xtra_status(v_profile, v_language, p_date);
  IF v_status->>'phase' IS DISTINCT FROM 'perfect' THEN
    RAISE EXCEPTION 'Spelling extra is not finished';
  END IF;

  INSERT INTO spelling_dictation_reviews (profile, review_date, language, status, webhook_sent)
  VALUES (v_profile, p_date, v_language, 'complete', false)
  ON CONFLICT (profile, review_date, language) DO UPDATE
  SET status = 'complete';
END;
$$;

GRANT EXECUTE ON FUNCTION af_mark_spelling_xtra_complete(text, text, date) TO anon, authenticated, service_role;
