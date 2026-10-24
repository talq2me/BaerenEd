-- Call site: the Grok read-aloud automation, after it has listened to each clip.
-- p_scores is a JSON array of:
--   {"id": <image_uploads.id>, "words_correct": <int>, "missed_words": ["word", ...]}
-- words_total is taken from the passage (whitespace tokens, punctuation trimmed).
-- A sent words_total is ignored so the denominator stays the passage length.
-- words_correct is how many of those passage words the child said.
-- Extra words the child added do not change the total.
-- missed_words lists the expected words that were omitted or said wrong.
-- Returns how many clips were scored.

CREATE OR REPLACE FUNCTION af_score_reading_audio(p_scores jsonb)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item jsonb;
  v_i int;
  v_id bigint;
  v_task text;
  v_profile text;
  v_text text;
  v_passage_id bigint;
  v_words text[];
  v_total int;
  v_correct int;
  v_missed jsonb;
  v_language text;
  v_date date;
  v_day text;
  v_ids bigint[];
  v_tasks text[];
  v_unscored int;
  v_have int;
  v_updated int := 0;
BEGIN
  IF p_scores IS NULL OR jsonb_typeof(p_scores) <> 'array' THEN
    RAISE EXCEPTION 'p_scores must be a JSON array';
  END IF;

  FOR v_i IN 0 .. jsonb_array_length(p_scores) - 1 LOOP
    v_item := p_scores -> v_i;
    IF NULLIF(btrim(v_item->>'id'), '') IS NULL THEN
      RAISE EXCEPTION 'Each score needs an id';
    END IF;
    v_id := (v_item->>'id')::bigint;

    SELECT iu.task, iu.profile
      INTO v_task, v_profile
    FROM image_uploads iu
    WHERE iu.id = v_id;

    IF v_task IS NULL OR v_task !~ '^readAloud_(en|fr)_[0-9]+_[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
      RAISE EXCEPTION 'Not a read-aloud clip: %', v_id;
    END IF;

    v_passage_id := (substring(v_task from 'readAloud_[a-z]+_([0-9]+)_'))::bigint;
    SELECT p.text INTO v_text
    FROM reading_passages p
    WHERE p.id = v_passage_id;

    v_words := af_reading_word_list(v_text);
    v_total := COALESCE(array_length(v_words, 1), 0);
    v_missed := v_item -> 'missed_words';
    IF v_missed IS NULL OR jsonb_typeof(v_missed) <> 'array' THEN
      v_missed := '[]'::jsonb;
    END IF;

    IF NULLIF(btrim(v_item->>'words_correct'), '') IS NULL THEN
      v_correct := v_total - jsonb_array_length(v_missed);
    ELSE
      v_correct := (v_item->>'words_correct')::int;
    END IF;
    IF v_correct < 0 THEN
      v_correct := 0;
    END IF;
    IF v_correct > v_total THEN
      v_correct := v_total;
    END IF;

    UPDATE image_uploads
    SET words_correct = v_correct,
        words_total = v_total,
        missed_words = v_missed
    WHERE id = v_id;

    v_updated := v_updated + 1;
    v_language := substring(v_task from '^readAloud_(en|fr)_');
    v_day := substring(v_task from '[0-9]{4}-[0-9]{2}-[0-9]{2}$');
    v_date := v_day::date;

    SELECT passage_ids INTO v_ids
    FROM reading_days
    WHERE profile = v_profile
      AND day = v_date
      AND language = v_language;

    IF v_ids IS NOT NULL AND cardinality(v_ids) > 0 THEN
      SELECT array_agg('readAloud_' || v_language || '_' || pid || '_' || v_day)
        INTO v_tasks
      FROM unnest(v_ids) AS pid;

      SELECT count(*) FILTER (WHERE words_correct IS NULL), count(*)
        INTO v_unscored, v_have
      FROM image_uploads
      WHERE profile = v_profile
        AND task = ANY (v_tasks);

      IF v_have >= cardinality(v_ids) AND v_unscored = 0 THEN
        UPDATE reading_audio_reviews
        SET status = 'complete'
        WHERE profile = v_profile
          AND review_date = v_date
          AND language = v_language;
      END IF;
    END IF;
  END LOOP;

  RETURN v_updated;
END;
$$;

GRANT EXECUTE ON FUNCTION af_score_reading_audio(jsonb) TO anon, authenticated, service_role;
