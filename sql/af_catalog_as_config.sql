-- Builds the profile config shape from web_assignments.
-- Daily reset uses this instead of the GitHub AM/BM/TE config JSON files.
-- Checklist is unused in this version, so it is not included.

CREATE OR REPLACE FUNCTION af_catalog_as_config(p_profile text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH tasks AS (
    SELECT
      CASE a.section WHEN 'optional' THEN 'optional' WHEN 'bonus' THEN 'bonus' ELSE 'required' END AS section_id,
      a.sort_order,
      jsonb_build_object(
        'title', a.title,
        'launch', a.launch,
        'stars', a.stars,
        'url', a.url,
        'webGame', a.web_game,
        'chromePage', a.chrome_page,
        'videoSequence', a.video_sequence,
        'video', a.video,
        'totalQuestions', a.total_questions,
        'easy', a.easy,
        'easydays', a.easy_days,
        'harddays', a.hard_days,
        'extremedays', a.extreme_days,
        'displayDays', a.display_days,
        'blockOutlines', a.block_outlines,
        'description', a.description
      ) AS task
    FROM web_assignments a
    WHERE a.profile = upper(trim(p_profile))
      AND a.enabled
      AND a.section IN ('required', 'optional', 'bonus')
  )
  SELECT jsonb_build_object(
    'sections', jsonb_build_array(
      jsonb_build_object('id', 'required', 'tasks', COALESCE((
        SELECT jsonb_agg(task ORDER BY sort_order) FROM tasks WHERE section_id = 'required'
      ), '[]'::jsonb)),
      jsonb_build_object('id', 'optional', 'tasks', COALESCE((
        SELECT jsonb_agg(task ORDER BY sort_order) FROM tasks WHERE section_id = 'optional'
      ), '[]'::jsonb)),
      jsonb_build_object('id', 'bonus', 'tasks', COALESCE((
        SELECT jsonb_agg(task ORDER BY sort_order) FROM tasks WHERE section_id = 'bonus'
      ), '[]'::jsonb)),
      jsonb_build_object('id', 'checklist', 'items', '[]'::jsonb)
    )
  );
$$;

GRANT EXECUTE ON FUNCTION af_catalog_as_config(text) TO anon, authenticated, service_role;
