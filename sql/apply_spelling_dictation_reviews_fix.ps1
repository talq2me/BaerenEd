# Apply the missing RLS policy for spelling_dictation_reviews table
# This fixes the issue where queries return zero rows due to missing policy

param()

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$PropertiesFile = if ($env:PROPERTIES_FILE) { $env:PROPERTIES_FILE } else { Join-Path $RepoRoot "local.properties" }

function Read-Property {
    param([string]$File, [string]$Key)
    
    if (-not (Test-Path $File)) {
        return $null
    }
    
    $line = Get-Content $File | Where-Object { $_ -match "^$Key=" } | Select-Object -Last 1
    if ($line) {
        ($line -split '=', 2)[1].Trim()
    }
}

if (-not (Test-Path $PropertiesFile)) {
    Write-Error "Missing $PropertiesFile - add SUPABASE_DATABASE_URL (see sql/BACKUP.md)."
    exit 1
}

$DatabaseUrl = Read-Property -File $PropertiesFile -Key "SUPABASE_DATABASE_URL"

if ([string]::IsNullOrWhiteSpace($DatabaseUrl)) {
    Write-Error "SUPABASE_DATABASE_URL is empty in $PropertiesFile"
    Write-Host "See sql/BACKUP.md for setup instructions." -ForegroundColor Yellow
    exit 1
}

function Find-Psql {
    if (Get-Command psql -ErrorAction SilentlyContinue) {
        return "psql"
    }
    
    $candidates = @(
        "C:\Program Files\PostgreSQL\17\bin\psql.exe",
        "C:\Program Files\PostgreSQL\16\bin\psql.exe",
        "C:\Program Files\PostgreSQL\15\bin\psql.exe"
    )
    
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }
    
    return $null
}

$Psql = Find-Psql
if (-not $Psql) {
    Write-Error "psql not found. Install PostgreSQL client tools first."
    Write-Host "  Windows: winget install PostgreSQL.PostgreSQL.17" -ForegroundColor Yellow
    exit 1
}

$SqlFile = Join-Path $ScriptDir "fix_spelling_dictation_reviews_rls.sql"

Write-Host "Applying RLS policy fix for spelling_dictation_reviews..." -ForegroundColor Cyan
Write-Host "Database: $DatabaseUrl"
Write-Host ""

try {
    & $Psql --dbname="$DatabaseUrl" -f $SqlFile
    if ($LASTEXITCODE -ne 0) {
        throw "psql exited with code $LASTEXITCODE"
    }
}
catch {
    Write-Host ""
    Write-Error "Failed to apply SQL migration. Check your database connection."
    exit 1
}

Write-Host ""
Write-Host "✓ Success! The spelling_dictation_reviews table now has the correct RLS policy." -ForegroundColor Green
Write-Host "  Grok should now be able to read game results for all profiles." -ForegroundColor Green
