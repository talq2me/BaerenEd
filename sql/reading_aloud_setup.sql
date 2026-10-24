-- Existing databases: tables, the two AM English sentences, and the Read aloud task.
-- Does not change choreAudio, piano, or Read to Sibling.
-- After this, deploy the functions (sql/regen_deploy_all_functions.ps1, then supabase_functions_create.sql,
-- or run the af_reading_*.sql files and af_upsert_image_upload.sql).
-- The finished game pings the same Grok webhook as spelling OCR (spelling_ocr_webhook_bearer).

ALTER TABLE image_uploads ADD COLUMN IF NOT EXISTS words_correct INT;
ALTER TABLE image_uploads ADD COLUMN IF NOT EXISTS words_total INT;

CREATE TABLE IF NOT EXISTS reading_passages (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    profile TEXT NOT NULL CHECK (profile IN ('AM', 'BM', 'TE')),
    language TEXT NOT NULL CHECK (language IN ('en', 'fr')),
    text TEXT NOT NULL,
    sort_order INT NOT NULL DEFAULT 0,
    enabled BOOLEAN NOT NULL DEFAULT true
);

CREATE INDEX IF NOT EXISTS idx_reading_passages_bank
    ON reading_passages (profile, language, enabled, sort_order, id);

CREATE TABLE IF NOT EXISTS reading_days (
    profile TEXT NOT NULL CHECK (profile IN ('AM', 'BM', 'TE')),
    day DATE NOT NULL,
    language TEXT NOT NULL CHECK (language IN ('en', 'fr')),
    passage_ids BIGINT[] NOT NULL,
    PRIMARY KEY (profile, day, language)
);

CREATE TABLE IF NOT EXISTS reading_audio_reviews (
    profile TEXT NOT NULL CHECK (profile IN ('AM', 'BM', 'TE')),
    review_date DATE NOT NULL,
    language TEXT NOT NULL CHECK (language IN ('en', 'fr')),
    status TEXT NOT NULL DEFAULT 'incomplete',
    webhook_sent BOOLEAN NOT NULL DEFAULT false,
    webhook_sent_at TIMESTAMP(3),
    PRIMARY KEY (profile, review_date, language)
);

ALTER TABLE reading_audio_reviews ADD COLUMN IF NOT EXISTS webhook_sent_at TIMESTAMP(3);

ALTER TABLE reading_passages ENABLE ROW LEVEL SECURITY;
ALTER TABLE reading_days ENABLE ROW LEVEL SECURITY;
ALTER TABLE reading_audio_reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow all operations on reading_passages" ON reading_passages;
CREATE POLICY "Allow all operations on reading_passages" ON reading_passages
    FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Allow all operations on reading_days" ON reading_days;
CREATE POLICY "Allow all operations on reading_days" ON reading_days
    FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Allow all operations on reading_audio_reviews" ON reading_audio_reviews;
CREATE POLICY "Allow all operations on reading_audio_reviews" ON reading_audio_reviews
    FOR ALL USING (true) WITH CHECK (true);

INSERT INTO reading_passages (profile, language, text, sort_order)
SELECT 'AM', 'en', 'There are two classes in line.', 1
WHERE NOT EXISTS (
    SELECT 1 FROM reading_passages
    WHERE profile = 'AM' AND language = 'en' AND text = 'There are two classes in line.'
);

INSERT INTO reading_passages (profile, language, text, sort_order)
SELECT 'AM', 'en', 'Does he have time to do the dishes?', 2
WHERE NOT EXISTS (
    SELECT 1 FROM reading_passages
    WHERE profile = 'AM' AND language = 'en' AND text = 'Does he have time to do the dishes?'
);

INSERT INTO web_games (launch) VALUES ('readAloud')
ON CONFLICT (launch) DO NOTHING;

UPDATE web_assignments
SET enabled = false
WHERE launch IN ('choreUfliSentence1', 'choreUfliSentence2');

INSERT INTO web_assignments (
    profile, section, launch, title, enabled, sort_order, stars, url, web_game,
    total_questions, display_days, easy_days, hard_days, extreme_days,
    chrome_page, video_sequence, video, easy, description, block_outlines
)
SELECT
    'AM', 'required', 'readAloud', 'Read aloud', true, 7, 0,
    'https://talq2me.github.io/BaerenEd/app/src/main/assets/html/readAloud.html?lang=en&count=2',
    true, NULL, NULL, NULL, NULL, NULL, false, NULL, NULL, false, 'Read this out loud.', false
WHERE NOT EXISTS (
    SELECT 1 FROM web_assignments
    WHERE profile = 'AM' AND section = 'required' AND launch = 'readAloud' AND title = 'Read aloud'
);

-- Pull the new task onto today's list without clearing other work.
SELECT af_update_tasks_from_config_required('AM');
