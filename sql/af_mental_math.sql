-- Call sites:
--   app/src/main/assets/html/mentalMath.html — save each answer, then the finished run; load the best score.
--   reports/mental_math_report.html — finished runs for the time and accuracy graphs.

-- Saves one Mental Math run. The same p_token updates the row as each answer arrives.
-- A finished run stores answering time, first-try incorrect count, and every answer.

CREATE OR REPLACE FUNCTION af_mental_math_save(
  p_profile text,
  p_token text,
  p_started_at timestamptz,
  p_elapsed_ms int,
  p_answers jsonb,
  p_complete boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(trim(p_profile));
  v_token text := nullif(btrim(p_token), '');
  v_answers jsonb := '[]'::jsonb;
  v_elem jsonb;
  v_given text;
  v_expected int;
  v_ms int;
  v_ok boolean;
  v_correct int := 0;
  v_incorrect int := 0;
  v_count int;
  v_elapsed int;
  v_accuracy numeric(5,1);
  v_id bigint;
  v_existing_profile text;
  v_existing_complete boolean;
  v_prev_acc numeric(5,1);
  v_prev_ms int;
  v_beat boolean := false;
  v_best_acc numeric(5,1);
  v_best_ms int;
  r record;
BEGIN
  IF v_profile IS NULL OR v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile';
  END IF;
  IF v_token IS NULL THEN
    RAISE EXCEPTION 'p_token is required';
  END IF;
  IF p_started_at IS NULL THEN
    RAISE EXCEPTION 'p_started_at is required';
  END IF;
  IF p_elapsed_ms IS NULL OR p_elapsed_ms < 0 THEN
    RAISE EXCEPTION 'p_elapsed_ms is required';
  END IF;
  IF p_answers IS NULL OR jsonb_typeof(p_answers) <> 'array' THEN
    RAISE EXCEPTION 'p_answers must be a json array';
  END IF;

  v_count := jsonb_array_length(p_answers);
  IF v_count < 1 OR v_count > 60 THEN
    RAISE EXCEPTION 'unexpected answer count';
  END IF;

  FOR r IN
    SELECT value FROM jsonb_array_elements(p_answers) AS e(value)
  LOOP
    v_elem := r.value;
    IF nullif(btrim(v_elem->>'question'), '') IS NULL THEN
      RAISE EXCEPTION 'each answer needs a question';
    END IF;
    IF COALESCE(v_elem->>'expected', '') !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'each answer needs an expected number';
    END IF;
    v_expected := (v_elem->>'expected')::int;
    IF v_expected < 0 OR v_expected > 20 THEN
      RAISE EXCEPTION 'expected answer out of range';
    END IF;
    v_given := left(btrim(COALESCE(v_elem->>'given', '')), 8);
    v_ok := CASE
      WHEN v_given ~ '^[0-9]{1,2}$' THEN v_given::int = v_expected
      ELSE false
    END;
    v_ms := CASE
      WHEN COALESCE(v_elem->>'ms', '') ~ '^[0-9]+$' THEN (v_elem->>'ms')::int
      ELSE 0
    END;
    IF v_ok THEN
      v_correct := v_correct + 1;
    ELSE
      v_incorrect := v_incorrect + 1;
    END IF;
    v_answers := v_answers || jsonb_build_array(jsonb_build_object(
      'question', left(btrim(v_elem->>'question'), 40),
      'expected', v_expected,
      'given', v_given,
      'correct', v_ok,
      'answeredAt', left(COALESCE(v_elem->>'answeredAt', ''), 40),
      'ms', v_ms
    ));
  END LOOP;

  v_elapsed := GREATEST(
    p_elapsed_ms,
    COALESCE((v_answers->(v_count - 1)->>'ms')::int, 0)
  );
  v_accuracy := round(100.0 * v_correct / v_count, 1);

  SELECT profile, complete
    INTO v_existing_profile, v_existing_complete
  FROM mental_math_runs
  WHERE client_token = v_token;

  IF FOUND THEN
    IF v_existing_profile IS DISTINCT FROM v_profile THEN
      RAISE EXCEPTION 'run token belongs to another profile';
    END IF;
    IF v_existing_complete THEN
      RAISE EXCEPTION 'that game is already finished';
    END IF;
    UPDATE mental_math_runs
    SET started_at = p_started_at,
        finished_at = CASE WHEN COALESCE(p_complete, false) THEN p_started_at + (v_elapsed * interval '1 millisecond') ELSE NULL END,
        elapsed_ms = v_elapsed,
        correct_count = v_correct,
        incorrect_count = v_incorrect,
        question_count = v_count,
        accuracy_pct = v_accuracy,
        answers = v_answers,
        complete = COALESCE(p_complete, false)
    WHERE client_token = v_token
    RETURNING id INTO v_id;
  ELSE
    INSERT INTO mental_math_runs (
      profile, client_token, started_at, finished_at, elapsed_ms,
      correct_count, incorrect_count, question_count, accuracy_pct, answers, complete
    )
    VALUES (
      v_profile,
      v_token,
      p_started_at,
      CASE WHEN COALESCE(p_complete, false) THEN p_started_at + (v_elapsed * interval '1 millisecond') ELSE NULL END,
      v_elapsed,
      v_correct,
      v_incorrect,
      v_count,
      v_accuracy,
      v_answers,
      COALESCE(p_complete, false)
    )
    RETURNING id INTO v_id;
  END IF;

  DELETE FROM mental_math_runs
  WHERE profile = v_profile
    AND NOT complete
    AND id <> v_id
    AND started_at < now() - interval '2 days';

  IF COALESCE(p_complete, false) THEN
    SELECT accuracy_pct, elapsed_ms
      INTO v_prev_acc, v_prev_ms
    FROM mental_math_runs
    WHERE profile = v_profile
      AND complete
      AND id <> v_id
    ORDER BY accuracy_pct DESC, elapsed_ms ASC, id ASC
    LIMIT 1;

    v_beat := v_prev_acc IS NULL
      OR v_accuracy > v_prev_acc
      OR (v_accuracy = v_prev_acc AND v_elapsed < v_prev_ms);
  END IF;

  SELECT accuracy_pct, elapsed_ms
    INTO v_best_acc, v_best_ms
  FROM mental_math_runs
  WHERE profile = v_profile
    AND complete
  ORDER BY accuracy_pct DESC, elapsed_ms ASC, id ASC
  LIMIT 1;

  RETURN jsonb_build_object(
    'id', v_id,
    'elapsedMs', v_elapsed,
    'correct', v_correct,
    'incorrect', v_incorrect,
    'accuracy', v_accuracy,
    'complete', COALESCE(p_complete, false),
    'beat', v_beat,
    'best', CASE
      WHEN v_best_acc IS NULL THEN NULL
      ELSE jsonb_build_object('elapsedMs', v_best_ms, 'accuracy', v_best_acc)
    END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION af_mental_math_save(text, text, timestamptz, int, jsonb, boolean) TO anon, authenticated, service_role;


-- Best finished run (higher accuracy, then faster time) and the most recent finished run.

CREATE OR REPLACE FUNCTION af_mental_math_best(p_profile text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(trim(p_profile));
  v_best jsonb;
  v_last jsonb;
BEGIN
  IF v_profile IS NULL OR v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile';
  END IF;

  SELECT jsonb_build_object(
    'id', id,
    'finishedAt', finished_at,
    'elapsedMs', elapsed_ms,
    'correct', correct_count,
    'incorrect', incorrect_count,
    'accuracy', accuracy_pct
  )
    INTO v_best
  FROM mental_math_runs
  WHERE profile = v_profile
    AND complete
  ORDER BY accuracy_pct DESC, elapsed_ms ASC, id ASC
  LIMIT 1;

  SELECT jsonb_build_object(
    'id', id,
    'finishedAt', finished_at,
    'elapsedMs', elapsed_ms,
    'correct', correct_count,
    'incorrect', incorrect_count,
    'accuracy', accuracy_pct
  )
    INTO v_last
  FROM mental_math_runs
  WHERE profile = v_profile
    AND complete
  ORDER BY finished_at DESC, id DESC
  LIMIT 1;

  RETURN jsonb_build_object('best', v_best, 'last', v_last);
END;
$$;

GRANT EXECUTE ON FUNCTION af_mental_math_best(text) TO anon, authenticated, service_role;


-- Finished runs, oldest first, for the parent graphs. Includes each answer.

CREATE OR REPLACE FUNCTION af_mental_math_history(
  p_profile text,
  p_limit int DEFAULT 180
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile text := upper(trim(p_profile));
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 180), 1), 400);
  v_rows jsonb;
BEGIN
  IF v_profile IS NULL OR v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RAISE EXCEPTION 'Invalid profile';
  END IF;

  SELECT COALESCE(jsonb_agg(item ORDER BY finished_at, id), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT
      id,
      finished_at,
      jsonb_build_object(
        'id', id,
        'startedAt', started_at,
        'finishedAt', finished_at,
        'elapsedMs', elapsed_ms,
        'correct', correct_count,
        'incorrect', incorrect_count,
        'questionCount', question_count,
        'accuracy', accuracy_pct,
        'answers', answers
      ) AS item
    FROM mental_math_runs
    WHERE profile = v_profile
      AND complete
    ORDER BY finished_at DESC, id DESC
    LIMIT v_limit
  ) recent;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION af_mental_math_history(text, int) TO anon, authenticated, service_role;
