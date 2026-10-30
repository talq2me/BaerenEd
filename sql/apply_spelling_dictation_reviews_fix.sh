#!/usr/bin/env bash
# Apply the missing RLS policy for spelling_dictation_reviews table
# This fixes the issue where queries return zero rows due to missing policy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROPERTIES_FILE="${PROPERTIES_FILE:-$REPO_ROOT/local.properties}"

read_properties() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

if [[ ! -f "$PROPERTIES_FILE" ]]; then
  echo "Missing $PROPERTIES_FILE - add SUPABASE_DATABASE_URL (see sql/BACKUP.md)." >&2
  exit 1
fi

SUPABASE_DATABASE_URL="$(read_properties "$PROPERTIES_FILE" SUPABASE_DATABASE_URL || true)"

if [[ -z "$SUPABASE_DATABASE_URL" ]]; then
  echo "SUPABASE_DATABASE_URL is empty in $PROPERTIES_FILE" >&2
  echo "See sql/BACKUP.md for setup instructions." >&2
  exit 1
fi

find_psql() {
  if command -v psql >/dev/null 2>&1; then
    command -v psql
    return
  fi
  for candidate in \
    "/c/Program Files/PostgreSQL/17/bin/psql.exe" \
    "/c/Program Files/PostgreSQL/16/bin/psql.exe" \
    "/c/Program Files/PostgreSQL/15/bin/psql.exe"
  do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done
  return 1
}

PSQL="$(find_psql)" || {
  echo "psql not found. Install PostgreSQL client tools first." >&2
  echo "  Windows: winget install PostgreSQL.PostgreSQL.17" >&2
  exit 1
}

SQL_FILE="$SCRIPT_DIR/fix_spelling_dictation_reviews_rls.sql"

echo "Applying RLS policy fix for spelling_dictation_reviews..."
echo "Database: $SUPABASE_DATABASE_URL"
echo ""

if ! "$PSQL" --dbname="$SUPABASE_DATABASE_URL" -f "$SQL_FILE"; then
  echo "" >&2
  echo "Failed to apply SQL migration. Check your database connection." >&2
  exit 1
fi

echo ""
echo "✓ Success! The spelling_dictation_reviews table now has the correct RLS policy."
echo "  Grok should now be able to read game results for all profiles."
