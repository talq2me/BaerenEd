# Deploy edu site progress tables + all RPCs to Supabase (uses local.properties SUPABASE_DATABASE_URL).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File sql/deploy_edu_site_progress.ps1

$ErrorActionPreference = "Stop"
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $base
$propsFile = Join-Path $repoRoot "local.properties"

function Read-Property([string]$file, [string]$key) {
    if (-not (Test-Path $file)) { return $null }
    foreach ($line in Get-Content $file) {
        if ($line -match "^\s*$([regex]::Escape($key))\s*=\s*(.+)\s*$") {
            return $matches[1].Trim()
        }
    }
    return $null
}

$dbUrl = Read-Property $propsFile "SUPABASE_DATABASE_URL"
if (-not $dbUrl) {
    Write-Error "Set SUPABASE_DATABASE_URL in $propsFile (see sql/BACKUP.md)."
}

$psql = Get-Command psql -ErrorAction SilentlyContinue
if (-not $psql) {
    Write-Error "psql not found on PATH."
}

Write-Host "Regenerating supabase_functions_create.sql ..."
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $base "regen_deploy_all_functions.ps1")
if ($LASTEXITCODE -ne 0) {
    Write-Error "regen_deploy_all_functions.ps1 failed"
}

$files = @(
    (Join-Path $base "edu_site_progress_setup.sql"),
    (Join-Path $base "supabase_functions_create.sql"),
    (Join-Path $base "seed_te_edu_site_test_tasks.sql")
)

foreach ($f in $files) {
    if (-not (Test-Path $f)) {
        Write-Error "Missing $f"
    }
    Write-Host "Running $([IO.Path]::GetFileName($f)) ..."
    & psql --dbname="$dbUrl" -v ON_ERROR_STOP=1 -f $f
    if ($LASTEXITCODE -ne 0) {
        Write-Error "psql failed on $f"
    }
}

Write-Host "Edu site progress deploy finished. Vault edu_site_scraper_email must be set to the scraper's Supabase Auth email."
