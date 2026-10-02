-- Call site: the Grok spelling automation, after it has compared each image to its word.
-- p_scores is a JSON array of {"id": <image_uploads.id>, "correct": true|false}.
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
  v_id bigint;
  v_correct boolean;
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
    UPDATE image_uploads
    SET task = regexp_replace(task, '-unverified$', CASE WHEN v_correct THEN '-✓' ELSE '-X' END)
    WHERE id = v_id
      AND task LIKE '%-unverified';
    GET DIAGNOSTICS v_one = ROW_COUNT;
    v_updated := v_updated + v_one;
  END LOOP;

  RETURN v_updated;
END;
$$;

GRANT EXECUTE ON FUNCTION af_score_spelling_photos(jsonb) TO anon, authenticated, service_role;
