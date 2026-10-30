-- Fix missing RLS policy for spelling_dictation_reviews table
-- This table had RLS enabled but no policy, blocking all access

DROP POLICY IF EXISTS "Allow all operations on spelling_dictation_reviews" ON spelling_dictation_reviews;

CREATE POLICY "Allow all operations on spelling_dictation_reviews" ON spelling_dictation_reviews
    FOR ALL
    USING (true)
    WITH CHECK (true);
