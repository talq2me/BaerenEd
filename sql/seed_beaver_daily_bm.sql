-- BM daily Beaver Computing Challenge question: one question per day from
-- edusites/BeaverContests/BM (all contest years, in manifest order).
-- Safe to re-run. Does not truncate the catalog.

INSERT INTO web_games (launch) VALUES ('beaverContestsDaily')
ON CONFLICT DO NOTHING;

INSERT INTO web_assignments (
    profile, section, launch, title, enabled, sort_order, stars, url, web_game,
    total_questions, display_days, description
)
SELECT
    'BM',
    'required',
    'beaverContestsDaily',
    'Beaver Computing Challenge',
    true,
    86,
    3,
    'https://talq2me.github.io/BaerenEd/app/src/main/assets/html/dailyReview.html?pack=BeaverContests',
    true,
    1,
    NULL,
    'One Beaver Computing Challenge question each day. Wrong answers stay on the same question after a parent reset.'
WHERE NOT EXISTS (
    SELECT 1
    FROM web_assignments
    WHERE profile = 'BM'
      AND section = 'required'
      AND launch = 'beaverContestsDaily'
);

UPDATE web_assignments
SET enabled = true,
    title = 'Beaver Computing Challenge',
    sort_order = 86,
    stars = 3,
    url = 'https://talq2me.github.io/BaerenEd/app/src/main/assets/html/dailyReview.html?pack=BeaverContests',
    web_game = true,
    total_questions = 1,
    display_days = NULL,
    description = 'One Beaver Computing Challenge question each day. Wrong answers stay on the same question after a parent reset.'
WHERE profile = 'BM'
  AND section = 'required'
  AND launch = 'beaverContestsDaily';

SELECT af_update_tasks_from_config_required('BM');
