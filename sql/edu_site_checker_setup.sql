-- EduSiteChecker (Cursor Automation "EduSiteChecker Bot Webhook").
-- Run once in Supabase SQL Editor after supabase_schema_create.sql, or merge into schema on greenfield deploy.
-- Vault: create secret edu_site_checker_webhook_bearer with the crsr_ token only (no "Bearer " prefix).

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
