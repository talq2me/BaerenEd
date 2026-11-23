-- AM daily NorthStar review: one question per day from edusites/NorthStar/AM.
-- Safe to re-run. Does not truncate the catalog.

INSERT INTO web_games (launch) VALUES ('northStarDaily')
ON CONFLICT DO NOTHING;

INSERT INTO web_assignments (
    profile, section, launch, title, enabled, sort_order, stars, url, web_game,
    total_questions, display_days, description
)
SELECT
    'AM',
    'required',
    'northStarDaily',
    'NorthStar Math',
    true,
    35,
    3,
    'https://talq2me.github.io/BaerenEd/app/src/main/assets/html/dailyReview.html?pack=NorthStar',
    true,
    1,
    NULL,
    'One NorthStar review question each day. Wrong answers stay on the same question after a parent reset.'
WHERE NOT EXISTS (
    SELECT 1
    FROM web_assignments
    WHERE profile = 'AM'
      AND section = 'required'
      AND launch = 'northStarDaily'
);

UPDATE web_assignments
SET enabled = true,
    title = 'NorthStar Math',
    sort_order = 35,
    stars = 3,
    url = 'https://talq2me.github.io/BaerenEd/app/src/main/assets/html/dailyReview.html?pack=NorthStar',
    web_game = true,
    total_questions = 1,
    display_days = NULL,
    description = 'One NorthStar review question each day. Wrong answers stay on the same question after a parent reset.'
WHERE profile = 'AM'
  AND section = 'required'
  AND launch = 'northStarDaily';

SELECT af_update_tasks_from_config_required('AM');
