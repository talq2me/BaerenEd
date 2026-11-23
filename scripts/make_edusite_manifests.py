#!/usr/bin/env python3
"""Generate edusites/{pack}/{profile}/manifest.json from test folders.

Layout expected:
  edusites/<pack>/<profile>/<testFolder>/*_quiz.json
  (+ images next to the quiz json)

Run from repo root, or any cwd (script finds the edusites root).
Safe to run repeatedly; only rewrites when content changes.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

MONTHS = {
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
    "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
}
DATE_RE = re.compile(
    r"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*[_-]?(\d{4})",
    re.I,
)


def repo_root() -> Path:
    here = Path(__file__).resolve().parent
    return here.parent


def edusites_root() -> Path:
    return repo_root() / "app" / "src" / "main" / "assets" / "edusites"


def sort_key(folder_name: str):
    """Prefer school-year order when a Month_YYYY is in the folder name.

    Aug–Dec of year Y, then Jan–Jul of year Y (so Oct/Nov 2026 then Mar 2026).
    """
    m = DATE_RE.search(folder_name)
    if m:
        mon = MONTHS.get(m.group(1)[:3].lower(), 99)
        year = int(m.group(2))
        # Aug=0 … Dec=4, Jan=5 … Jul=11
        term = (mon - 8) if mon >= 8 else (mon + 4)
        return (year, term, folder_name.lower())
    return (9999, 99, folder_name.lower())


def quiz_file_in(test_dir: Path) -> Path | None:
    quizzes = sorted(test_dir.glob("*_quiz.json"))
    if not quizzes:
        quizzes = sorted(test_dir.glob("*quiz*.json"))
    return quizzes[0] if quizzes else None


def profile_tests(profile_dir: Path) -> list[dict]:
    tests = []
    for child in profile_dir.iterdir():
        if not child.is_dir():
            continue
        if child.name.startswith("."):
            continue
        quiz = quiz_file_in(child)
        if not quiz:
            continue
        tests.append({
            "id": child.name,
            "quiz": quiz.name,
        })
    tests.sort(key=lambda t: sort_key(t["id"]))
    return tests


def write_manifest(path: Path, tests: list[dict]) -> bool:
    payload = {
        "tests": tests,
    }
    text = json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
    if path.is_file() and path.read_text(encoding="utf-8") == text:
        return False
    path.write_text(text, encoding="utf-8")
    return True


def main() -> int:
    root = edusites_root()
    if not root.is_dir():
        print(f"edusites root not found: {root}", file=sys.stderr)
        return 1

    wrote = []
    skipped_packs = []

    for pack_dir in sorted(p for p in root.iterdir() if p.is_dir()):
        profile_dirs = [p for p in pack_dir.iterdir() if p.is_dir() and not p.name.startswith(".")]
        any_profile = False
        for profile_dir in sorted(profile_dirs, key=lambda p: p.name.lower()):
            tests = profile_tests(profile_dir)
            if not tests:
                continue
            any_profile = True
            manifest_path = profile_dir / "manifest.json"
            if write_manifest(manifest_path, tests):
                wrote.append(str(manifest_path.relative_to(repo_root())))
                print(f"wrote {manifest_path.relative_to(repo_root())} ({len(tests)} tests)")
            else:
                print(f"ok    {manifest_path.relative_to(repo_root())} ({len(tests)} tests)")
        if not any_profile:
            skipped_packs.append(pack_dir.name)

    if skipped_packs:
        print("no quiz folders yet in: " + ", ".join(skipped_packs))
    if not wrote:
        print("manifests up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
