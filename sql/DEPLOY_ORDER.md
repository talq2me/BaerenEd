# Supabase deploy (new project / branch)

1. Run **[`supabase_schema_create.sql`](supabase_schema_create.sql)** (extensions, tables, policies).
2. On existing DBs, run **[`spelling_audio_storage.sql`](spelling_audio_storage.sql)** if the `spelling-audio` bucket is missing (school-list OGG clips).
3. On existing DBs, run **[`rename_spelling_ocr_titles.sql`](rename_spelling_ocr_titles.sql)** once to rename kid/parent titles to Spelling / Dictée (keeps launch keys).
4. On existing DBs, run **[`edu_site_checker_setup.sql`](edu_site_checker_setup.sql)** if `edu_site_checker_runs` is missing.
5. Run **[`supabase_functions_create.sql`](supabase_functions_create.sql)** (all `af_*` RPCs in dependency order).
6. Configure Vault **`edu_site_checker_webhook_bearer`** — see **[`EDU_SITE_CHECKER.md`](EDU_SITE_CHECKER.md)**.
7. Optional TE test rows: **[`seed_te_edu_site_test_tasks.sql`](seed_te_edu_site_test_tasks.sql)**. Or run **`deploy_edu_site_checker.ps1`** (setup + full functions bundle + TE seed) when `local.properties` has `SUPABASE_DATABASE_URL`.

Regenerate the functions bundle after editing any `sql/af_*.sql` file:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "c:\Sandbox\Baeren\BaerenEd-Android-App-1\sql\regen_deploy_all_functions.ps1"
```

Optional later cleanup: **[`refactor_drop_legacy_config_rpcs_AFTER_MIGRATION.sql`](refactor_drop_legacy_config_rpcs_AFTER_MIGRATION.sql)** when no client calls legacy config RPC names.
