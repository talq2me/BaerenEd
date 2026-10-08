-- Call site: web/map.html and web/xtra.html.
-- The extra task completes itself when every OCR photo is scored correct and Grok
-- never wrote a review list. It also completes when the current extra round is all correct.
-- A paper photo (EngSpellingOCRPaper / FrSpellingOCRPaper) counts as that day's OCR paper.
-- Paper extra is one sheet photo, task ...-rNN-sheet-word|word-status.
-- Screen extra is one drawing per copy, task ...-rNN-01-word-status, three copies of each word.
-- A review list appears only when Grok calls af_set_spelling_xtra_words.

DROP FUNCTION IF EXISTS af_get_spelling_copy_status(text, text, date);
DROP FUNCTION IF EXISTS af_enqueue_spelling_copy_review(text, text, date, int);
DROP FUNCTION IF EXISTS af_mark_spelling_copy_complete(text, text, date);

ALTER TABLE spelling_dictation_reviews ADD COLUMN IF NOT EXISTS words JSONB;
ALTER TABLE spelling_dictation_reviews ADD COLUMN IF NOT EXISTS xtra_round INT;
ALTER TABLE spelling_dictation_reviews ADD COLUMN IF NOT EXISTS xtra_sent_round INT NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION spelling_photo_kind(p_status text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_status IS NULL THEN 'unknown'
    WHEN p_status IN ('✓', 'checkmark') OR lower(p_status) IN ('correct', 'checkmark') THEN 'correct'
    WHEN lower(p_status) = 'unverified' THEN 'unverified'
    WHEN lower(p_status) IN ('x', 'incorrect') THEN 'incorrect'
    ELSE 'unknown'
  END;
$$;

CREATE OR REPLACE FUNCTION af_get_spelling_xtra_status(
  p_profile text,
  p_language text,
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
  v_language text := lower(trim(p_language));
  v_day text;
  v_ocr_prefix text;
  v_paper_prefix text;
  v_xtra_prefix text;
  v_title text;
  v_label text;
  v_ocr_re text;
  v_paper_re text;
  v_sheet text;
  v_xtra_re text;
  v_ocr_complete boolean := false;
  v_ocr_unverified boolean := false;
  v_ocr_incorrect boolean := false;
  v_raw_ocr int := 0;
  v_parsed_ocr int := 0;
  v_words jsonb;
  v_round int;
  v_sent int := 0;
  v_photos jsonb := '[]'::jsonb;
  v_practice jsonb := '[]'::jsonb;
  v_round_unverified boolean := false;
  v_all_correct boolean := true;
  v_any_missing boolean := false;
  v_item jsonb;
  v_i int;
  v_word text;
  v_n int;
  v_filled int;
  v_kinds text[];
  v_message_wait text := 'Your spelling is still being checked. Try again in a minute.';
BEGIN
  IF v_profile IS NULL OR v_profile = '' OR v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile: %', p_profile;
  END IF;
  IF v_language = 'eng' THEN
    v_ocr_prefix := 'EngSpellingOCR';
    v_paper_prefix := 'EngSpellingOCRPaper';
    v_xtra_prefix := 'EngSpellingOCRXtra';
    v_title := 'Eng Spelling OCR';
    v_label := 'English';
  ELSIF v_language = 'fr' THEN
    v_ocr_prefix := 'FrSpellingOCR';
    v_paper_prefix := 'FrSpellingOCRPaper';
    v_xtra_prefix := 'FrSpellingOCRXtra';
    v_title := 'FR Spelling OCR';
    v_label := 'French';
  ELSE
    RAISE EXCEPTION 'Invalid language: %', p_language;
  END IF;

  IF p_date IS NULL THEN
    p_date := (NOW() AT TIME ZONE 'America/Toronto')::date;
  END IF;
  v_day := to_char(p_date, 'YYYY-MM-DD');
  v_ocr_re := '^(?:Eng|Fr)SpellingOCR-' || v_day || '-([0-9]+)-(.+)-(unverified|X|x|✓|checkmark|correct|incorrect)$';
  v_paper_re := '^(?:Eng|Fr)SpellingOCRPaper-' || v_day || '-(.+)-(unverified|X|x|✓|checkmark|correct|incorrect)$';

  SELECT lower(COALESCE(required_tasks -> v_title ->> 'status', '')) IN ('complete', 'done')
    INTO v_ocr_complete
  FROM user_data
  WHERE profile = v_profile;
  v_ocr_complete := COALESCE(v_ocr_complete, false);

  IF NOT v_ocr_complete THEN
    RETURN jsonb_build_object(
      'phase', 'need_ocr',
      'language', v_language,
      'label', v_label,
      'message', 'Complete ' || v_label || ' Spelling OCR first.',
      'round', NULL,
      'expectedCount', NULL,
      'words', '[]'::jsonb
    );
  END IF;

  SELECT count(*) INTO v_raw_ocr
  FROM image_uploads
  WHERE profile = v_profile
    AND (
      task LIKE v_ocr_prefix || '-' || v_day || '-%'
      OR task LIKE v_paper_prefix || '-' || v_day || '-%'
    );

  SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', spelling_photo_kind(status))), '[]'::jsonb)
    INTO v_photos
  FROM (
    SELECT (regexp_match(task, v_ocr_re))[3] AS status
    FROM image_uploads
    WHERE profile = v_profile
      AND task LIKE v_ocr_prefix || '-' || v_day || '-%'
    UNION ALL
    SELECT (regexp_match(task, v_paper_re))[2]
    FROM image_uploads
    WHERE profile = v_profile
      AND task LIKE v_paper_prefix || '-' || v_day || '-%'
  ) parsed
  WHERE status IS NOT NULL;

  v_parsed_ocr := COALESCE(jsonb_array_length(v_photos), 0);
  FOR v_i IN 0 .. v_parsed_ocr - 1 LOOP
    v_word := v_photos -> v_i ->> 'kind';
    IF v_word IN ('unverified', 'unknown') THEN
      v_ocr_unverified := true;
    ELSIF v_word = 'incorrect' THEN
      v_ocr_incorrect := true;
    END IF;
  END LOOP;

  IF v_ocr_unverified OR v_raw_ocr > v_parsed_ocr THEN
    RETURN jsonb_build_object(
      'phase', 'waiting', 'language', v_language, 'label', v_label,
      'message', v_message_wait, 'round', NULL, 'expectedCount', NULL, 'words', '[]'::jsonb
    );
  END IF;

  SELECT words, xtra_round, COALESCE(xtra_sent_round, 0)
    INTO v_words, v_round, v_sent
  FROM spelling_dictation_reviews
  WHERE profile = v_profile
    AND review_date = p_date
    AND language = v_language;

  IF v_words IS NULL OR jsonb_typeof(v_words) <> 'array' OR jsonb_array_length(v_words) = 0 THEN
    IF v_ocr_incorrect THEN
      RETURN jsonb_build_object(
        'phase', 'waiting', 'language', v_language, 'label', v_label,
        'message', v_message_wait, 'round', NULL, 'expectedCount', NULL, 'words', '[]'::jsonb
      );
    END IF;
    RETURN jsonb_build_object(
      'phase', 'perfect', 'language', v_language, 'label', v_label,
      'message', '', 'round', NULL, 'expectedCount', NULL, 'words', '[]'::jsonb
    );
  END IF;

  v_round := COALESCE(v_round, 1);
  v_xtra_re := '^(?:Eng|Fr)SpellingOCRXtra-' || v_day || '-r' || lpad(v_round::text, 2, '0')
    || '-sheet-.+-(unverified|X|x|✓|checkmark|correct|incorrect)$';

  SELECT spelling_photo_kind((regexp_match(task, v_xtra_re))[1])
    INTO v_sheet
  FROM image_uploads
  WHERE profile = v_profile
    AND task LIKE v_xtra_prefix || '-' || v_day || '-r' || lpad(v_round::text, 2, '0') || '-sheet-%'
    AND regexp_match(task, v_xtra_re) IS NOT NULL
  ORDER BY id DESC
  LIMIT 1;

  IF v_sheet = 'correct' THEN
    RETURN jsonb_build_object(
      'phase', 'perfect', 'language', v_language, 'label', v_label,
      'message', '', 'round', v_round, 'expectedCount', NULL, 'words', '[]'::jsonb
    );
  END IF;

  IF v_sheet = 'unverified' AND v_sent < v_round THEN
    RETURN jsonb_build_object(
      'phase', 'pending_submit', 'language', v_language, 'label', v_label,
      'message', v_message_wait, 'round', v_round, 'expectedCount', 1, 'words', '[]'::jsonb
    );
  END IF;

  IF v_sheet IS NULL THEN
    v_xtra_re := '^(?:Eng|Fr)SpellingOCRXtra-' || v_day || '-r' || lpad(v_round::text, 2, '0')
      || '-([0-9]+)-(.+)-(unverified|X|x|✓|checkmark|correct|incorrect)$';

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'n', m[1]::int,
             'word', m[2],
             'kind', spelling_photo_kind(m[3])
           )), '[]'::jsonb)
      INTO v_photos
    FROM (
      SELECT regexp_match(task, v_xtra_re) AS m
      FROM image_uploads
      WHERE profile = v_profile
        AND task LIKE v_xtra_prefix || '-' || v_day || '-r' || lpad(v_round::text, 2, '0') || '-%'
        AND task NOT LIKE v_xtra_prefix || '-' || v_day || '-r' || lpad(v_round::text, 2, '0') || '-sheet-%'
    ) parsed
    WHERE m IS NOT NULL;

    FOR v_i IN 0 .. jsonb_array_length(v_words) - 1 LOOP
      v_word := v_words ->> v_i;
      v_filled := 0;
      v_kinds := ARRAY['missing', 'missing', 'missing'];
      FOR v_n IN 0 .. COALESCE(jsonb_array_length(v_photos), 0) - 1 LOOP
        v_item := v_photos -> v_n;
        IF v_item->>'word' IS DISTINCT FROM v_word THEN
          CONTINUE;
        END IF;
        IF (v_item->>'n')::int BETWEEN 1 AND 3 AND v_kinds[(v_item->>'n')::int] = 'missing' THEN
          v_kinds[(v_item->>'n')::int] := v_item->>'kind';
          v_filled := v_filled + 1;
        END IF;
      END LOOP;

      IF v_filled = 3
         AND v_kinds[1] = 'correct' AND v_kinds[2] = 'correct' AND v_kinds[3] = 'correct' THEN
        CONTINUE;
      END IF;

      v_all_correct := false;
      IF v_filled < 3 THEN
        v_any_missing := true;
        v_practice := v_practice || jsonb_build_array(jsonb_build_object(
          'word', v_word,
          'round', v_round,
          'copies', jsonb_build_array(
            jsonb_build_object('n', 1, 'status', v_kinds[1]),
            jsonb_build_object('n', 2, 'status', v_kinds[2]),
            jsonb_build_object('n', 3, 'status', v_kinds[3])
          )
        ));
      ELSIF v_kinds[1] IN ('unverified', 'unknown')
            OR v_kinds[2] IN ('unverified', 'unknown')
            OR v_kinds[3] IN ('unverified', 'unknown') THEN
        v_round_unverified := true;
      END IF;
    END LOOP;

    IF v_all_correct AND COALESCE(jsonb_array_length(v_photos), 0) > 0 THEN
      RETURN jsonb_build_object(
        'phase', 'perfect', 'language', v_language, 'label', v_label,
        'message', '', 'round', v_round, 'expectedCount', NULL, 'words', '[]'::jsonb
      );
    END IF;

    IF v_any_missing OR COALESCE(jsonb_array_length(v_photos), 0) = 0 THEN
      IF NOT v_any_missing THEN
        FOR v_i IN 0 .. jsonb_array_length(v_words) - 1 LOOP
          v_practice := v_practice || jsonb_build_array(jsonb_build_object(
            'word', v_words ->> v_i,
            'round', v_round,
            'copies', jsonb_build_array(
              jsonb_build_object('n', 1, 'status', 'missing'),
              jsonb_build_object('n', 2, 'status', 'missing'),
              jsonb_build_object('n', 3, 'status', 'missing')
            )
          ));
        END LOOP;
      END IF;
      RETURN jsonb_build_object(
        'phase', 'practice', 'language', v_language, 'label', v_label,
        'message', '', 'round', v_round, 'expectedCount', NULL, 'words', v_practice
      );
    END IF;

    IF v_round_unverified AND v_sent < v_round THEN
      RETURN jsonb_build_object(
        'phase', 'pending_submit', 'language', v_language, 'label', v_label,
        'message', v_message_wait, 'round', v_round,
        'expectedCount', jsonb_array_length(v_words) * 3,
        'words', '[]'::jsonb
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'phase', 'waiting', 'language', v_language, 'label', v_label,
    'message', v_message_wait, 'round', v_round, 'expectedCount', NULL, 'words', '[]'::jsonb
  );
END;
$$;

GRANT EXECUTE ON FUNCTION spelling_photo_kind(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION af_get_spelling_xtra_status(text, text, date) TO anon, authenticated, service_role;
