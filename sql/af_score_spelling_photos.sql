-- Call site: the Grok spelling automation, after it has compared each image to its word.
-- p_scores is a JSON array of {"id": <image_uploads.id>, "correct": true|false}.
-- A paper sheet (one photo of the whole list) also sends "missed": ["word", ...]
-- for the words that were wrong. Screen photos omit "missed"; each photo is one word.
-- The first score changes a task that still ends in -unverified.
-- The same call corrects a photo already marked -✓ or -X when that photo's date is
-- today in America/Toronto. Send the same {"id","correct"} object again.
-- To correct by word, send {"profile","language","word","correct"} with no id.
-- Example: {"profile":"AM","language":"eng","word":"glasses","correct":true}
-- Photos from earlier days stay as they are.
-- Correcting an English or French spelling photo rewrites today's extra-practice
-- list, including a jumble list when the call names the word. A word that is no
-- longer wrong is not practised three times. An id correction leaves a jumble
-- list alone and rebuilds the list from the photos instead.
-- Returns how many photos were scored or corrected.

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
  v_task text;
  v_profile text;
  v_today text;
  v_date date;
  v_prefix text;
  v_language text;
  v_was_scored boolean;
  v_list_photo boolean;
  v_words jsonb;
  v_ocr_re text;
  v_paper_re text;
BEGIN
  IF p_scores IS NULL OR jsonb_typeof(p_scores) <> 'array' THEN
    RAISE EXCEPTION 'p_scores must be a JSON array';
  END IF;

  v_date := (NOW() AT TIME ZONE 'America/Toronto')::date;
  v_today := to_char(v_date, 'YYYY-MM-DD');

  FOR v_i IN 0 .. jsonb_array_length(p_scores) - 1 LOOP
    v_item := p_scores -> v_i;
    v_correct := COALESCE((v_item->>'correct')::boolean, false);
    v_missed := v_item -> 'missed';
    v_stored := NULL;
    v_task := NULL;
    v_profile := NULL;
    v_id := NULL;
    IF NULLIF(btrim(v_item->>'id'), '') IS NOT NULL THEN
      v_id := (v_item->>'id')::bigint;
    END IF;

    IF v_id IS NULL AND NULLIF(btrim(v_item->>'word'), '') IS NOT NULL THEN
      v_word := btrim(v_item->>'word');
      v_profile := upper(btrim(COALESCE(v_item->>'profile', '')));
      v_language := lower(btrim(COALESCE(v_item->>'language', 'eng')));
      IF v_profile NOT IN ('AM', 'BM', 'TE') THEN
        RAISE EXCEPTION 'Invalid profile: %', v_item->>'profile';
      END IF;
      IF v_language NOT IN ('eng', 'fr') THEN
        RAISE EXCEPTION 'Invalid language: %', v_item->>'language';
      END IF;
      v_prefix := CASE WHEN v_language = 'fr' THEN 'Fr' ELSE 'Eng' END;

      UPDATE image_uploads iu
      SET task = regexp_replace(iu.task, '-(unverified|X|x|✓|checkmark|correct|incorrect)$', CASE WHEN v_correct THEN '-✓' ELSE '-X' END)
      WHERE iu.profile = v_profile
        AND iu.task ~ ('^' || v_prefix || 'SpellingOCR-' || v_today || '-[0-9]+-.+-(X|x|✓|checkmark|correct|incorrect)$')
        AND lower((regexp_match(iu.task, '^' || v_prefix || 'SpellingOCR-' || v_today || '-[0-9]+-(.+)-(?:X|x|✓|checkmark|correct|incorrect)$'))[1]) = lower(v_word);
      GET DIAGNOSTICS v_one = ROW_COUNT;
      v_updated := v_updated + v_one;

      IF v_correct THEN
        UPDATE image_uploads iu
        SET missed_words = COALESCE((
              SELECT jsonb_agg(to_jsonb(btrim(elem.word)) ORDER BY elem.ord)
              FROM jsonb_array_elements_text(iu.missed_words) WITH ORDINALITY AS elem(word, ord)
              WHERE btrim(elem.word) <> ''
                AND lower(btrim(elem.word)) <> lower(v_word)
            ), '[]'::jsonb),
            task = CASE
              WHEN NOT EXISTS (
                SELECT 1
                FROM jsonb_array_elements_text(iu.missed_words) AS left_behind(word)
                WHERE btrim(left_behind.word) <> ''
                  AND lower(btrim(left_behind.word)) <> lower(v_word)
              ) THEN regexp_replace(iu.task, '-(unverified|X|x|✓|checkmark|correct|incorrect)$', '-✓')
              ELSE iu.task
            END
        WHERE iu.profile = v_profile
          AND iu.task ~ ('^' || v_prefix || 'SpellingOCRPaper-' || v_today || '-.+-(X|x|✓|checkmark|correct|incorrect)$')
          AND iu.missed_words IS NOT NULL
          AND jsonb_typeof(iu.missed_words) = 'array'
          AND EXISTS (
            SELECT 1
            FROM jsonb_array_elements_text(iu.missed_words) AS listed(word)
            WHERE lower(btrim(listed.word)) = lower(v_word)
          );
      ELSE
        UPDATE image_uploads iu
        SET missed_words = CASE
              WHEN iu.missed_words IS NOT NULL
                   AND jsonb_typeof(iu.missed_words) = 'array'
                   AND EXISTS (
                     SELECT 1
                     FROM jsonb_array_elements_text(iu.missed_words) AS listed(word)
                     WHERE lower(btrim(listed.word)) = lower(v_word)
                   ) THEN iu.missed_words
              WHEN iu.missed_words IS NOT NULL AND jsonb_typeof(iu.missed_words) = 'array'
                   THEN iu.missed_words || to_jsonb(v_word)
              ELSE jsonb_build_array(v_word)
            END,
            task = regexp_replace(iu.task, '-(unverified|X|x|✓|checkmark|correct|incorrect)$', '-X')
        WHERE iu.profile = v_profile
          AND iu.task ~ ('^' || v_prefix || 'SpellingOCRPaper-' || v_today || '-.+-(X|x|✓|checkmark|correct|incorrect)$')
          AND lower(v_word) IN (
            SELECT lower(btrim(part))
            FROM unnest(string_to_array(
              (regexp_match(iu.task, '^' || v_prefix || 'SpellingOCRPaper-' || v_today || '-(.+)-(?:X|x|✓|checkmark|correct|incorrect)$'))[1],
              '|'
            )) AS part
          );
      END IF;
      GET DIAGNOSTICS v_one = ROW_COUNT;
      v_updated := v_updated + v_one;

      v_words := NULL;
      SELECT COALESCE(words, '[]'::jsonb)
        INTO v_words
      FROM spelling_dictation_reviews
      WHERE profile = v_profile
        AND review_date = v_date
        AND language = v_language;
      IF NOT FOUND THEN
        v_words := NULL;
      END IF;

      IF v_correct THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(btrim(elem.word)) ORDER BY elem.ord), '[]'::jsonb)
          INTO v_stored
        FROM jsonb_array_elements_text(COALESCE(v_words, '[]'::jsonb)) WITH ORDINALITY AS elem(word, ord)
        WHERE btrim(elem.word) <> ''
          AND lower(btrim(elem.word)) <> lower(v_word);
      ELSE
        v_stored := COALESCE(v_words, '[]'::jsonb);
        IF NOT EXISTS (
          SELECT 1
          FROM jsonb_array_elements_text(v_stored) AS listed(word)
          WHERE lower(btrim(listed.word)) = lower(v_word)
        ) THEN
          v_stored := v_stored || to_jsonb(v_word);
        END IF;
      END IF;

      IF v_words IS NOT NULL OR NOT v_correct THEN
        IF EXISTS (
          SELECT 1
          FROM spelling_dictation_reviews
          WHERE profile = v_profile
            AND review_date = v_date
            AND language = v_language
        ) THEN
          UPDATE spelling_dictation_reviews
          SET words = v_stored,
              status = CASE WHEN jsonb_array_length(v_stored) = 0 THEN 'complete' ELSE 'incomplete' END,
              xtra_round = CASE
                WHEN jsonb_array_length(v_stored) > 0 THEN COALESCE(xtra_round, 1)
                ELSE xtra_round
              END
          WHERE profile = v_profile
            AND review_date = v_date
            AND language = v_language
            AND words IS DISTINCT FROM v_stored;
          GET DIAGNOSTICS v_one = ROW_COUNT;
          v_updated := v_updated + v_one;
        ELSIF jsonb_array_length(v_stored) > 0 THEN
          INSERT INTO spelling_dictation_reviews (profile, review_date, language, status, webhook_sent, words, xtra_round)
          VALUES (v_profile, v_date, v_language, 'incomplete', false, v_stored, 1);
          v_updated := v_updated + 1;
        END IF;
      END IF;
      CONTINUE;
    END IF;

    SELECT task, profile
      INTO v_task, v_profile
    FROM image_uploads
    WHERE id = v_id;

    IF v_task IS NULL THEN
      CONTINUE;
    END IF;
    IF v_task !~ '-(unverified|X|x|✓|checkmark|correct|incorrect)$' THEN
      CONTINUE;
    END IF;

    v_was_scored := v_task !~ '-unverified$';
    IF v_was_scored AND v_task NOT LIKE ('%-' || v_today || '-%') THEN
      RAISE EXCEPTION 'Spelling scores can be corrected only for today';
    END IF;

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
    SET task = regexp_replace(task, '-(unverified|X|x|✓|checkmark|correct|incorrect)$', CASE WHEN v_correct THEN '-✓' ELSE '-X' END),
        missed_words = CASE
          WHEN v_correct THEN NULL
          WHEN v_missed IS NOT NULL AND jsonb_typeof(v_missed) = 'array' THEN v_stored
          ELSE missed_words
        END
    WHERE id = v_id
      AND task ~ '-(unverified|X|x|✓|checkmark|correct|incorrect)$'
      AND (task LIKE '%-unverified' OR task LIKE ('%-' || v_today || '-%'));
    GET DIAGNOSTICS v_one = ROW_COUNT;
    v_updated := v_updated + v_one;
    IF v_one = 0 OR NOT v_was_scored THEN
      CONTINUE;
    END IF;

    v_prefix := CASE WHEN v_task LIKE 'Fr%' THEN 'Fr' ELSE 'Eng' END;
    v_list_photo := v_task ~ ('^' || v_prefix || 'SpellingOCR-')
      OR v_task ~ ('^' || v_prefix || 'SpellingOCRPaper-');
    IF NOT v_list_photo THEN
      CONTINUE;
    END IF;
    IF EXISTS (
      SELECT 1
      FROM spelling_dictation_reviews
      WHERE profile = v_profile
        AND review_date = v_date
        AND language = CASE WHEN v_prefix = 'Fr' THEN 'fr' ELSE 'eng' END
        AND jumble_scored
    ) THEN
      CONTINUE;
    END IF;

    v_language := CASE WHEN v_prefix = 'Fr' THEN 'fr' ELSE 'eng' END;
    v_ocr_re := '^' || v_prefix || 'SpellingOCR-' || v_today || '-[0-9]+-(.+)-(X|x|incorrect)$';
    v_paper_re := '^' || v_prefix || 'SpellingOCRPaper-' || v_today || '-.+-(X|x|incorrect)$';

    SELECT COALESCE(jsonb_agg(to_jsonb(picked.word) ORDER BY picked.ord), '[]'::jsonb)
      INTO v_words
    FROM (
      SELECT DISTINCT ON (lower(btrim(found.word))) btrim(found.word) AS word, found.ord
      FROM (
        SELECT (regexp_match(iu.task, v_ocr_re))[1] AS word,
               COALESCE((regexp_match(iu.task, '^' || v_prefix || 'SpellingOCR-' || v_today || '-([0-9]+)-'))[1], '0')::int AS ord
        FROM image_uploads iu
        WHERE iu.profile = v_profile
          AND iu.task ~ v_ocr_re
        UNION ALL
        SELECT elem.word, (100000 + elem.ord)::int
        FROM image_uploads iu
        CROSS JOIN LATERAL jsonb_array_elements_text(iu.missed_words) WITH ORDINALITY AS elem(word, ord)
        WHERE iu.profile = v_profile
          AND iu.task ~ v_paper_re
          AND iu.missed_words IS NOT NULL
          AND jsonb_typeof(iu.missed_words) = 'array'
      ) found
      WHERE btrim(COALESCE(found.word, '')) <> ''
      ORDER BY lower(btrim(found.word)), found.ord
    ) picked;

    IF EXISTS (
      SELECT 1
      FROM spelling_dictation_reviews
      WHERE profile = v_profile
        AND review_date = v_date
        AND language = v_language
    ) THEN
      UPDATE spelling_dictation_reviews
      SET words = v_words,
          status = CASE WHEN jsonb_array_length(v_words) = 0 THEN 'complete' ELSE 'incomplete' END
      WHERE profile = v_profile
        AND review_date = v_date
        AND language = v_language
        AND NOT jumble_scored;
    ELSIF jsonb_array_length(v_words) > 0 THEN
      INSERT INTO spelling_dictation_reviews (profile, review_date, language, status, webhook_sent, words, xtra_round)
      VALUES (v_profile, v_date, v_language, 'incomplete', false, v_words, 1);
    END IF;
  END LOOP;

  RETURN v_updated;
END;
$$;

GRANT EXECUTE ON FUNCTION af_score_spelling_photos(jsonb) TO anon, authenticated, service_role;
