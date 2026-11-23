-- Edu site scraper progress + daily goal evaluation.
-- Run once on existing DBs (also embedded in supabase_schema_create.sql for greenfield).
-- Vault secret edu_site_checker_webhook_bearer is the inbound scraper bearer (p_bearer).

CREATE TABLE IF NOT EXISTS edu_site_progress_snapshots (
    id BIGSERIAL PRIMARY KEY,
    profile TEXT NOT NULL CHECK (profile IN ('AM', 'BM', 'TE')),
    site_kind TEXT NOT NULL,
    snapshot_at TIMESTAMP(3) NOT NULL,
    snapshot_date DATE NOT NULL,
    metrics JSONB NOT NULL DEFAULT '{}'::jsonb,
    value_mode TEXT NOT NULL DEFAULT 'cumulative'
        CHECK (value_mode IN ('cumulative', 'daily')),
    source TEXT,
    raw JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_edu_site_progress_snapshots_lookup
    ON edu_site_progress_snapshots (profile, site_kind, snapshot_date DESC, id DESC);

-- One snapshot row per profile + site + Toronto calendar day (re-scrapes overwrite).
CREATE UNIQUE INDEX IF NOT EXISTS uq_edu_site_progress_snapshots_day
    ON edu_site_progress_snapshots (profile, site_kind, snapshot_date);

ALTER TABLE edu_site_progress_snapshots ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow all operations on edu_site_progress_snapshots" ON edu_site_progress_snapshots;
CREATE POLICY "Allow all operations on edu_site_progress_snapshots" ON edu_site_progress_snapshots
    FOR ALL USING (true) WITH CHECK (true);

CREATE TABLE IF NOT EXISTS edu_site_daily_goals (
    profile TEXT NOT NULL CHECK (profile IN ('AM', 'BM', 'TE')),
    goal_date DATE NOT NULL,
    site_kind TEXT NOT NULL,
    task_title TEXT NOT NULL,
    section TEXT NOT NULL CHECK (section IN ('required', 'checklist')),
    target NUMERIC,
    metric TEXT,
    value_mode TEXT NOT NULL DEFAULT 'cumulative'
        CHECK (value_mode IN ('cumulative', 'daily')),
    measured_value NUMERIC,
    baseline_value NUMERIC,
    goal_met BOOLEAN NOT NULL DEFAULT false,
    parent_override BOOLEAN NOT NULL DEFAULT false,
    note TEXT,
    evaluated_at TIMESTAMP(3) NOT NULL DEFAULT ((NOW() AT TIME ZONE 'America/Toronto')),
    PRIMARY KEY (profile, goal_date, task_title)
);

CREATE INDEX IF NOT EXISTS idx_edu_site_daily_goals_site
    ON edu_site_daily_goals (profile, goal_date, site_kind);

ALTER TABLE edu_site_daily_goals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow all operations on edu_site_daily_goals" ON edu_site_daily_goals;
CREATE POLICY "Allow all operations on edu_site_daily_goals" ON edu_site_daily_goals
    FOR ALL USING (true) WITH CHECK (true);

-- Existing checker run ledger (no-op if already present).
CREATE TABLE IF NOT EXISTS edu_site_checker_runs (
    profile TEXT NOT NULL CHECK (profile IN ('AM', 'BM', 'TE')),
    check_date DATE NOT NULL,
    status TEXT NOT NULL DEFAULT 'incomplete',
    webhook_sent BOOLEAN NOT NULL DEFAULT false,
    webhook_sent_at TIMESTAMP(3),
    webhook_send_count INT NOT NULL DEFAULT 0,
    PRIMARY KEY (profile, check_date)
);

ALTER TABLE edu_site_checker_runs ADD COLUMN IF NOT EXISTS webhook_send_count INT NOT NULL DEFAULT 0;
ALTER TABLE edu_site_checker_runs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow all operations on edu_site_checker_runs" ON edu_site_checker_runs;
CREATE POLICY "Allow all operations on edu_site_checker_runs" ON edu_site_checker_runs
    FOR ALL USING (true) WITH CHECK (true);

ALTER TABLE web_assignments ADD COLUMN IF NOT EXISTS verify_kind TEXT;
ALTER TABLE web_assignments ADD COLUMN IF NOT EXISTS verify_params JSONB;
