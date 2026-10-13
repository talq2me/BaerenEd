-- Call site: the Grok spelling automation, after it has compared each image to its word.
-- p_scores is a JSON array of {"id": <image_uploads.id>, "correct": true|false}.
-- A paper sheet (one photo of the whole list) also sends "missed": ["word", ...]
-- for the words that were wrong. Screen photos omit "missed"; each photo is one word.
-- Only a task that still ends in -unverified is changed. Returns how many rows changed.

CREATE OR REPLACE FUNCTION af_score_spelling_photos(p_scores jsonb)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item jsonb;
  v_i int;
  v_j int;
  v_id bigint;
  v_correct boolean;
  v_missed jsonb;
  v_stored jsonb;
  v_word text;
  v_updated int := 0;
  v_one int;
BEGIN
  IF p_scores IS NULL OR jsonb_typeof(p_scores) <> 'array' THEN
    RAISE EXCEPTION 'p_scores must be a JSON array';
  END IF;

  FOR v_i IN 0 .. jsonb_array_length(p_scores) - 1 LOOP
    v_item := p_scores -> v_i;
    v_id := (v_item->>'id')::bigint;
    v_correct := COALESCE((v_item->>'correct')::boolean, false);
    v_missed := v_item -> 'missed';
    v_stored := NULL;
    IF NOT v_correct AND v_missed IS NOT NULL AND jsonb_typeof(v_missed) = 'array' THEN
      v_stored := '[]'::jsonb;
      FOR v_j IN 0 .. jsonb_array_length(v_missed) - 1 LOOP
        v_word := btrim(v_missed ->> v_j);
        IF v_word <> '' AND NOT EXISTS (
          SELECT 1
          FROM jsonb_array_elements_text(v_stored) AS existing(word)
          WHERE lower(existing.word) = lower(v_word)
        ) THEN
          v_stored := v_stored || to_jsonb(v_word);
        END IF;
      END LOOP;
    END IF;
    UPDATE image_uploads
    SET task = regexp_replace(task, '-unverified$', CASE WHEN v_correct THEN '-✓' ELSE '-X' END),
        missed_words = CASE
          WHEN v_correct THEN NULL
          WHEN v_missed IS NOT NULL AND jsonb_typeof(v_missed) = 'array' THEN v_stored
          ELSE missed_words
        END
    WHERE id = v_id
      AND task LIKE '%-unverified';
    GET DIAGNOSTICS v_one = ROW_COUNT;
    v_updated := v_updated + v_one;
  END LOOP;

  RETURN v_updated;
END;
$$;

GRANT EXECUTE ON FUNCTION af_score_spelling_photos(jsonb) TO anon, authenticated, service_role;
