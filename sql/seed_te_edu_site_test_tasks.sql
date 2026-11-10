-- TE profile: sample checklist tasks with EduSiteChecker verify_kind (safe to re-run).
-- After this, merge into user_data: SELECT af_update_tasks_from_config_checklist('TE');

INSERT INTO web_assignments (
  profile, section, launch, title, enabled, sort_order, stars,
  display_days, verify_kind, verify_params
)
VALUES
  (
    'TE', 'checklist', NULL, 'Read 2 Rallye books', true, 900, 2,
    'sun,mon,tue,wed,thu,fri,sat', 'rallye_lecture', '{"min_books": 2}'::jsonb
  ),
  (
    'TE', 'checklist', NULL, 'XtraMath practice', true, 901, 1,
    'sun,mon,tue,wed,thu,fri,sat', 'xtramath', '{"min_sessions": 1}'::jsonb
  )
ON CONFLICT (profile, section, title, launch) DO UPDATE SET
  enabled = EXCLUDED.enabled,
  sort_order = EXCLUDED.sort_order,
  stars = EXCLUDED.stars,
  display_days = EXCLUDED.display_days,
  verify_kind = EXCLUDED.verify_kind,
  verify_params = EXCLUDED.verify_params;

SELECT af_update_tasks_from_config_checklist('TE');
