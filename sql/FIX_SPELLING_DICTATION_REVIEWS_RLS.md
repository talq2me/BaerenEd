# Fix: spelling_dictation_reviews RLS Policy Missing

## Problem

The `spelling_dictation_reviews` table had Row-Level Security (RLS) enabled but **no policy defined**. This caused all queries to return zero rows, regardless of the profile or API key being used.

**Symptoms:**
- Queries to `spelling_dictation_reviews` return 0 rows for all profiles
- Grok cannot read game results (scores, missed words, practice counts)
- The issue affects every profile (AM, BM, TE), not just specific ones

**Root Cause:**
In `sql/supabase_schema_create.sql`, the table had:
```sql
ALTER TABLE spelling_dictation_reviews ENABLE ROW LEVEL SECURITY;
```

But was missing the corresponding policy that all other tables have:
```sql
CREATE POLICY "Allow all operations on spelling_dictation_reviews" ON spelling_dictation_reviews
    FOR ALL
    USING (true)
    WITH CHECK (true);
```

## Solution

We created a migration SQL file and helper scripts to add the missing policy.

### Quick Fix (Recommended)

**Windows (PowerShell):**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sql\apply_spelling_dictation_reviews_fix.ps1
```

**Linux/Mac/Git Bash:**
```bash
bash sql/apply_spelling_dictation_reviews_fix.sh
```

### Manual Fix

If you prefer to run the SQL directly:

1. Get your database connection string from `local.properties` (the `SUPABASE_DATABASE_URL` value)
2. Run the SQL file:

```powershell
psql --dbname="YOUR_SUPABASE_DATABASE_URL" -f sql/fix_spelling_dictation_reviews_rls.sql
```

### What Changed

1. **`sql/fix_spelling_dictation_reviews_rls.sql`** - Migration file that adds the missing policy
2. **`sql/supabase_schema_create.sql`** - Updated to include the policy for future deployments
3. Helper scripts to apply the fix easily

## Verification

After applying the fix, test that the table is now accessible:

```sql
SELECT * FROM spelling_dictation_reviews WHERE profile = 'TE' LIMIT 5;
```

This should now return rows instead of zero results.

## Files Modified

- `sql/supabase_schema_create.sql` - Added missing RLS policy (lines after 493)
- `sql/fix_spelling_dictation_reviews_rls.sql` - New migration file
- `sql/apply_spelling_dictation_reviews_fix.sh` - New bash script
- `sql/apply_spelling_dictation_reviews_fix.ps1` - New PowerShell script
- `sql/FIX_SPELLING_DICTATION_REVIEWS_RLS.md` - This documentation

## Date

Fixed: October 30, 2024 (UTC-4)
