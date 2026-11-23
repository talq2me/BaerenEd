#!/usr/bin/env bash
# Installs repo git hooks from .githooks/ into .git/hooks/ (no git config changes).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/.githooks"
DST="$ROOT/.git/hooks"

if [[ ! -d "$ROOT/.git" ]]; then
  echo "Not a git repo: $ROOT" >&2
  exit 1
fi
if [[ ! -d "$SRC" ]]; then
  echo "Missing $SRC" >&2
  exit 1
fi

mkdir -p "$DST"
for hook in "$SRC"/*; do
  [[ -f "$hook" ]] || continue
  name="$(basename "$hook")"
  cp "$hook" "$DST/$name"
  chmod +x "$DST/$name"
  echo "installed .git/hooks/$name"
done

echo "Done. Edusite manifests will refresh on commit when edusites/ files are staged."
