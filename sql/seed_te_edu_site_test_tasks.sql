-- TE profile: sample edu-site tasks with verify_kind (safe to re-run).
-- After this, merge into user_data checklist/required as needed.

INSERT INTO web_assignments (
  profile, section, launch, title, enabled, sort_order, stars,
  display_days, verify_kind, verify_params
)
VALUES
  (
    'TE', 'checklist', NULL, 'Read 2 Rallye books', true, 900, 2,
    'sun,mon,tue,wed,thu,fri,sat', 'rallye_lecture',
    '{"metric":"books","target":2,"value_mode":"cumulative","min_books":2}'::jsonb
  ),
  (
    'TE', 'checklist', NULL, 'Motoufo feathers', true, 901, 1,
    'sun,mon,tue,wed,thu,fri,sat', 'motoufo',
    '{"metric":"feathers","target":20,"value_mode":"cumulative"}'::jsonb
  ),
  (
    'TE', 'checklist', NULL, 'Anton practice', true, 902, 1,
    'sun,mon,tue,wed,thu,fri,sat', 'anton',
    '{"metric":"incomplete","target":0,"value_mode":"daily","compare":"lte"}'::jsonb
  ),
  (
    'TE', 'checklist', NULL, 'NorthStar math', true, 903, 1,
    'sun,mon,tue,wed,thu,fri,sat', 'northstar_math',
    '{"metric":"value","target":1,"value_mode":"cumulative"}'::jsonb
  )
ON CONFLICT (profile, section, title, launch) DO UPDATE SET
  enabled = EXCLUDED.enabled,
  sort_order = EXCLUDED.sort_order,
  stars = EXCLUDED.stars,
  display_days = EXCLUDED.display_days,
  verify_kind = EXCLUDED.verify_kind,
  verify_params = EXCLUDED.verify_params;

SELECT af_update_tasks_from_config_checklist('TE');
