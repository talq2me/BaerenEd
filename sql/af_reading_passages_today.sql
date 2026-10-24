-- Call site: app/src/main/assets/html/readAloud.html when the game opens.
-- Pins today's passages for this profile and language, then returns them.
-- A second open on the same Toronto date returns the same set.
-- Does not advance the cursor. af_enqueue_reading_audio_review does that
-- after every passage for the day has a recording.

CREATE OR REPLACE FUNCTION af_reading_passages_today(
  p_profile text,
  p_language text,
  p_count int DEFAULT 2
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(btrim(COALESCE(p_profile, '')));
  v_language text := af_reading_language(p_language);
  v_count int := GREATEST(COALESCE(p_count, 2), 1);
  v_today date := (NOW() AT TIME ZONE 'America/Toronto')::date;
  v_day text := to_char(v_today, 'YYYY-MM-DD');
  v_key text := 'readAloud_' || v_language;
  v_bank int;
  v_cursor int := 0;
  v_ids bigint[];
  v_rows jsonb;
BEGIN
  IF v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;

  SELECT passage_ids INTO v_ids
  FROM reading_days
  WHERE profile = v_profile
    AND day = v_today
    AND language = v_language;

  IF v_ids IS NULL THEN
    SELECT count(*) INTO v_bank
    FROM reading_passages
    WHERE profile = v_profile
      AND language = v_language
      AND enabled;

    IF v_bank < 1 THEN
      RETURN jsonb_build_object(
        'day', v_day,
        'language', v_language,
        'passages', '[]'::jsonb
      );
    END IF;

    v_count := LEAST(v_count, v_bank);

    SELECT COALESCE((game_indices->>v_key)::int, 0)
      INTO v_cursor
    FROM user_data
    WHERE profile = v_profile;

    IF v_cursor IS NULL OR v_cursor < 0 THEN
      v_cursor := 0;
    END IF;
    v_cursor := v_cursor % v_bank;

    SELECT array_agg(picked.id ORDER BY picked.n)
      INTO v_ids
    FROM (
      SELECT p.id, gs.n
      FROM generate_series(0, v_count - 1) AS gs(n)
      JOIN LATERAL (
        SELECT id
        FROM reading_passages
        WHERE profile = v_profile
          AND language = v_language
          AND enabled
        ORDER BY sort_order, id
        OFFSET (v_cursor + gs.n) % v_bank
        LIMIT 1
      ) p ON true
    ) picked;

    INSERT INTO reading_days (profile, day, language, passage_ids)
    VALUES (v_profile, v_today, v_language, v_ids)
    ON CONFLICT (profile, day, language) DO NOTHING;

    SELECT passage_ids INTO v_ids
    FROM reading_days
    WHERE profile = v_profile
      AND day = v_today
      AND language = v_language;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', p.id,
           'text', p.text,
           'words', to_jsonb(af_reading_word_list(p.text)),
           'recorded', EXISTS (
             SELECT 1
             FROM image_uploads iu
             WHERE iu.profile = v_profile
               AND iu.task = 'readAloud_' || v_language || '_' || p.id || '_' || v_day
               AND iu.image LIKE 'data:audio%'
           )
         ) ORDER BY u.ord), '[]'::jsonb)
    INTO v_rows
  FROM unnest(v_ids) WITH ORDINALITY AS u(pid, ord)
  JOIN reading_passages p ON p.id = u.pid;

  RETURN jsonb_build_object(
    'day', v_day,
    'language', v_language,
    'passages', COALESCE(v_rows, '[]'::jsonb)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION af_reading_passages_today(text, text, int) TO anon, authenticated, service_role;
