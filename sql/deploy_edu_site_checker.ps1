# Deploy EduSiteChecker SQL to Supabase (uses local.properties SUPABASE_DATABASE_URL).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File sql/deploy_edu_site_checker.ps1

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

$files = @(
    (Join-Path $base "edu_site_checker_setup.sql"),
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

Write-Host "EduSiteChecker deploy finished. Ensure Vault secret edu_site_checker_webhook_bearer is set."
