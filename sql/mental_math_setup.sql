-- Mental Math: answer log, and AM's required game every day.
-- Run after the schema tables exist:
--   psql "$SUPABASE_DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/mental_math_setup.sql -f sql/af_mental_math.sql

CREATE TABLE IF NOT EXISTS mental_math_runs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    profile TEXT NOT NULL CHECK (profile IN ('AM', 'BM', 'TE')),
    client_token TEXT NOT NULL UNIQUE,
    started_at TIMESTAMPTZ NOT NULL,
    finished_at TIMESTAMPTZ,
    elapsed_ms INT,
    correct_count INT NOT NULL DEFAULT 0,
    incorrect_count INT NOT NULL DEFAULT 0,
    question_count INT NOT NULL DEFAULT 0,
    accuracy_pct NUMERIC(5,1),
    answers JSONB NOT NULL DEFAULT '[]'::jsonb,
    complete BOOLEAN NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS idx_mental_math_runs_profile_finished
    ON mental_math_runs (profile, finished_at DESC, id DESC)
    WHERE complete;

ALTER TABLE mental_math_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow all operations on mental_math_runs" ON mental_math_runs;
CREATE POLICY "Allow all operations on mental_math_runs" ON mental_math_runs
    FOR ALL
    USING (true)
    WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON mental_math_runs TO anon, authenticated, service_role;

INSERT INTO web_games (launch) VALUES ('mentalMath')
ON CONFLICT DO NOTHING;

INSERT INTO web_assignments (
    profile, section, launch, title, enabled, sort_order, stars, url, web_game,
    total_questions, display_days, description
)
SELECT
    'AM',
    'required',
    'mentalMath',
    'Mental Math',
    true,
    31,
    3,
    'https://talq2me.github.io/BaerenEd/app/src/main/assets/html/mentalMath.html',
    true,
    30,
    NULL,
    '30 addition and subtraction questions within 20. Go fast and get them right.'
WHERE NOT EXISTS (
    SELECT 1
    FROM web_assignments
    WHERE profile = 'AM'
      AND section = 'required'
      AND launch = 'mentalMath'
);

UPDATE web_assignments
SET enabled = true,
    title = 'Mental Math',
    sort_order = 31,
    stars = 3,
    url = 'https://talq2me.github.io/BaerenEd/app/src/main/assets/html/mentalMath.html',
    web_game = true,
    total_questions = 30,
    display_days = NULL,
    description = '30 addition and subtraction questions within 20. Go fast and get them right.'
WHERE profile = 'AM'
  AND section = 'required'
  AND launch = 'mentalMath';

SELECT af_update_tasks_from_config_required('AM');
