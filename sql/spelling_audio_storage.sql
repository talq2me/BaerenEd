-- Spelling word/sentence audio clips (OGG) for school lists.
-- Apply on an existing Supabase project (Dashboard SQL editor or psql).
--
-- Public object URL shape:
--   {SUPABASE_URL}/storage/v1/object/public/spelling-audio/{fr|en}/{AM|BM|TE}/{slug}.ogg
-- Word JSON fields (optional; games fall back to device TTS):
--   "audio": { "word": "<url>", "sentence": "<url>" }

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'spelling-audio',
  'spelling-audio',
  true,
  5242880,
  ARRAY['audio/ogg', 'audio/mpeg', 'audio/mp3', 'audio/wav']
)
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "Allow public read spelling-audio" ON storage.objects;
DROP POLICY IF EXISTS "Allow anon upload spelling-audio" ON storage.objects;
DROP POLICY IF EXISTS "Allow anon update spelling-audio" ON storage.objects;
DROP POLICY IF EXISTS "Allow anon delete spelling-audio" ON storage.objects;

CREATE POLICY "Allow public read spelling-audio"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'spelling-audio');

CREATE POLICY "Allow anon upload spelling-audio"
ON storage.objects FOR INSERT
TO anon, authenticated, service_role
WITH CHECK (bucket_id = 'spelling-audio');

CREATE POLICY "Allow anon update spelling-audio"
ON storage.objects FOR UPDATE
TO anon, authenticated, service_role
USING (bucket_id = 'spelling-audio')
WITH CHECK (bucket_id = 'spelling-audio');

CREATE POLICY "Allow anon delete spelling-audio"
ON storage.objects FOR DELETE
TO anon, authenticated, service_role
USING (bucket_id = 'spelling-audio');
