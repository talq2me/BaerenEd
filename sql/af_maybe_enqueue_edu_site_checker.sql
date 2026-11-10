-- Call sites: af_update_task_completion (required), af_update_tasks_checklist_items (mark done).
-- Fires EduSiteChecker Bot Webhook up to twice per profile per Toronto day when all visible required work is marked done/complete.
-- Vault secret: edu_site_checker_webhook_bearer (crsr_ token only, no "Bearer " prefix).

CREATE OR REPLACE FUNCTION af_maybe_enqueue_edu_site_checker(p_profile text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_profile text := upper(btrim(COALESCE(p_profile, '')));
  v_date date := (NOW() AT TIME ZONE 'America/Toronto')::date;
  v_day text;
  v_progress jsonb;
  v_task_count int;
  v_token text;
  v_body text;
  v_claimed int;
  v_status int;
  v_send_count int;
BEGIN
  IF v_profile NOT IN ('AM', 'BM', 'TE') THEN
    RETURN;
  END IF;

  v_progress := af_get_required_progress_today(v_profile);
  IF NOT COALESCE((v_progress->>'all_done')::boolean, false) THEN
    RETURN;
  END IF;

  SELECT count(*)::int INTO v_task_count
  FROM af_get_tasks_required(v_profile) AS t
  WHERE NOT t.is_checklist OR COALESCE(t.berry_value, 0) > 0;

  IF COALESCE(v_task_count, 0) < 1 THEN
    RETURN;
  END IF;

  INSERT INTO edu_site_checker_runs (profile, check_date, status, webhook_sent, webhook_send_count)
  VALUES (v_profile, v_date, 'incomplete', false, 0)
  ON CONFLICT (profile, check_date) DO NOTHING;

  SELECT webhook_send_count INTO v_send_count
  FROM edu_site_checker_runs
  WHERE profile = v_profile
    AND check_date = v_date;

  IF COALESCE(v_send_count, 0) >= 2 THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM edu_site_checker_runs
    WHERE profile = v_profile
      AND check_date = v_date
      AND status = 'complete'
  ) THEN
    RETURN;
  END IF;

  SELECT decrypted_secret INTO v_token
  FROM vault.decrypted_secrets
  WHERE name = 'edu_site_checker_webhook_bearer'
  LIMIT 1;

  IF v_token IS NULL OR btrim(v_token) = '' THEN
    RAISE WARNING 'edu_site_checker_webhook_bearer not configured in Supabase Vault';
    RETURN;
  END IF;

  UPDATE edu_site_checker_runs
  SET
    webhook_sent = true,
    webhook_sent_at = (NOW() AT TIME ZONE 'America/Toronto'),
    webhook_send_count = webhook_send_count + 1
  WHERE profile = v_profile
    AND check_date = v_date
    AND webhook_send_count < 2
    AND status IS DISTINCT FROM 'complete';

  GET DIAGNOSTICS v_claimed = ROW_COUNT;
  IF v_claimed = 0 THEN
    RETURN;
  END IF;

  v_day := to_char(v_date, 'YYYY-MM-DD');
  v_body := jsonb_build_object(
    'profile', v_profile,
    'date', v_day,
    'kind', 'edu_site_check'
  )::text;

  BEGIN
    SELECT r.status INTO v_status
    FROM extensions.http((
      'POST',
      'https://api2.cursor.sh/automations/webhook/70a32960-ae8b-5234-b797-bddcebfd118d',
      ARRAY[
        extensions.http_header('Authorization', 'Bearer ' || btrim(v_token)),
        extensions.http_header('Content-Type', 'application/json')
      ]::extensions.http_header[],
      'application/json',
      v_body
    )::extensions.http_request) r;
  EXCEPTION WHEN OTHERS THEN
    UPDATE edu_site_checker_runs
    SET
      webhook_sent = false,
      webhook_sent_at = NULL,
      webhook_send_count = GREATEST(webhook_send_count - 1, 0)
    WHERE profile = v_profile
      AND check_date = v_date
      AND status IS DISTINCT FROM 'complete';
    RAISE WARNING 'EduSiteChecker webhook request failed: %', SQLERRM;
    RETURN;
  END;

  IF v_status IS NULL OR v_status < 200 OR v_status >= 300 THEN
    UPDATE edu_site_checker_runs
    SET
      webhook_sent = false,
      webhook_sent_at = NULL,
      webhook_send_count = GREATEST(webhook_send_count - 1, 0)
    WHERE profile = v_profile
      AND check_date = v_date
      AND status IS DISTINCT FROM 'complete';
    RAISE WARNING 'EduSiteChecker webhook returned status %', COALESCE(v_status, -1);
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION af_maybe_enqueue_edu_site_checker(text) TO anon, authenticated, service_role;
