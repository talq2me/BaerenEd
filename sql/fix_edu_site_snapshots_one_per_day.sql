-- Deduplicate same-day scrape piles, then enforce one row per (profile, site_kind, snapshot_date).

DELETE FROM edu_site_progress_snapshots s
USING edu_site_progress_snapshots newer
WHERE s.profile = newer.profile
  AND s.site_kind = newer.site_kind
  AND s.snapshot_date = newer.snapshot_date
  AND s.id < newer.id;

CREATE UNIQUE INDEX IF NOT EXISTS uq_edu_site_progress_snapshots_day
    ON edu_site_progress_snapshots (profile, site_kind, snapshot_date);
