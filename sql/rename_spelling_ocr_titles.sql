-- Rename kid/parent-facing Spelling OCR task titles to Spelling / Dictée.
-- Keeps launch keys (spellingOCR, spellingOCRXtra) and image_uploads prefixes unchanged.
-- Apply on the live Supabase DB (psql or SQL editor), then redeploy af_get_spelling_xtra_status
-- (or the full functions bundle).

-- 1) Schedule catalog titles
UPDATE web_assignments SET title = 'Dictée'
WHERE title = 'FR Spelling OCR';

UPDATE web_assignments SET title = 'Spelling'
WHERE title = 'Eng Spelling OCR';

UPDATE web_assignments SET title = 'Dictée Extra'
WHERE title = 'FR Spelling OCR Extra';

UPDATE web_assignments SET title = 'Spelling Extra'
WHERE title = 'Eng Spelling OCR Extra';

UPDATE web_assignments SET title = 'Dictée (Practice)'
WHERE title IN ('FR Spelling OCR (Practice)', 'French Spelling OCR (Practice)');

UPDATE web_assignments SET title = 'Spelling (Practice)'
WHERE title = 'Eng Spelling OCR (Practice)';

-- 2) user_data JSON keys (completion status is keyed by title)
CREATE OR REPLACE FUNCTION _baeren_rename_json_key(p_obj jsonb, p_old text, p_new text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_val jsonb;
BEGIN
  IF p_obj IS NULL OR p_old IS NULL OR p_new IS NULL OR p_old = p_new THEN
    RETURN p_obj;
  END IF;
  IF NOT (p_obj ? p_old) THEN
    RETURN p_obj;
  END IF;
  v_val := p_obj -> p_old;
  p_obj := p_obj - p_old;
  IF p_obj ? p_new THEN
    -- Prefer keeping existing new-key data; drop the old duplicate.
    RETURN p_obj;
  END IF;
  RETURN jsonb_set(p_obj, ARRAY[p_new], v_val, true);
END;
$$;

UPDATE user_data
SET
  required_tasks = _baeren_rename_json_key(
    _baeren_rename_json_key(
      _baeren_rename_json_key(
        _baeren_rename_json_key(required_tasks, 'FR Spelling OCR', 'Dictée'),
        'Eng Spelling OCR', 'Spelling'
      ),
      'FR Spelling OCR Extra', 'Dictée Extra'
    ),
    'Eng Spelling OCR Extra', 'Spelling Extra'
  ),
  practice_tasks = _baeren_rename_json_key(
    _baeren_rename_json_key(
      _baeren_rename_json_key(
        _baeren_rename_json_key(
          _baeren_rename_json_key(practice_tasks, 'FR Spelling OCR (Practice)', 'Dictée (Practice)'),
          'French Spelling OCR (Practice)', 'Dictée (Practice)'
        ),
        'Eng Spelling OCR (Practice)', 'Spelling (Practice)'
      ),
      'FR Spelling OCR', 'Dictée'
    ),
    'Eng Spelling OCR', 'Spelling'
  );

DROP FUNCTION IF EXISTS _baeren_rename_json_key(jsonb, text, text);
