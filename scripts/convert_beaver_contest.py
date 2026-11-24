#!/usr/bin/env python3
"""Convert a Beaver Computing Challenge contest PDF (+ solutions PDF) into a
daily-review quiz folder:

  edusites/BeaverContests/BM/<folder>/
    <folder>_quiz.json
    q1.png … qN.png

Questions come from the contest PDF. Correct letters come from the separate
solutions PDF (page that starts with "(A)"/"(B)"/"(C)"/"(D)" then "Answer").

Example:
  python scripts/convert_beaver_contest.py --year 2025
  python scripts/convert_beaver_contest.py --questions path/to/Q.pdf --solutions path/to/S.pdf
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

try:
    import pymupdf as fitz
except ImportError:  # pragma: no cover
    import fitz  # type: ignore

ROOT = Path(__file__).resolve().parent.parent
EDUSITES = ROOT / "app" / "src" / "main" / "assets" / "edusites" / "BeaverContests"
DEFAULT_PROFILE = "BM"

SKIP_TITLES = {
    "story", "question", "answer", "explanation of answer",
    "connections to computer science", "country of original author",
    "beaver", "computing", "challenge", "questions", "questions,",
    "answers,", "explanations,", "and", "connections",
}
PART_RE = re.compile(r"^Part\s+[ABC]$", re.I)
ANSWER_HEAD_RE = re.compile(r"^\(([A-D])\)(.*)$")
CHOICE_RE = re.compile(r"^\(([A-D])\)\s*(.*)$")


def lines_of(page) -> list[str]:
    return [ln.strip() for ln in page.get_text("text").splitlines() if ln.strip()]


def page_text(page) -> str:
    return page.get_text("text")


def is_part_divider(lines: list[str]) -> bool:
    if not lines:
        return False
    if any(PART_RE.match(ln) for ln in lines[:3]):
        return True
    return False


def is_question_page(lines: list[str]) -> bool:
    return ("Story" in lines or "story" in {x.lower() for x in lines}) and (
        "Question" in lines or "question" in {x.lower() for x in lines}
    )


def is_answer_page(lines: list[str]) -> bool:
    if not lines:
        return False
    if lines[0].lower() == "answer":
        return True
    # Answer pages start with the correct choice, e.g. "(B) Step 2" or a long
    # multi-line choice ("(B) Take out" ... "Answer" further down the page).
    if ANSWER_HEAD_RE.match(lines[0]) and any(ln.lower() == "answer" for ln in lines):
        return True
    return False


def extract_title(lines: list[str]) -> str | None:
    for ln in lines[:10]:
        low = ln.lower()
        if low in SKIP_TITLES or PART_RE.match(ln) or ln.isdigit():
            continue
        if ANSWER_HEAD_RE.match(ln):
            continue
        if len(ln) < 3:
            continue
        if low.startswith("(grades"):
            continue
        return ln
    return None


def extract_question_prompt(lines: list[str]) -> str:
    """Text under the Question heading, before choices."""
    try:
        qi = next(i for i, ln in enumerate(lines) if ln.lower() == "question")
    except StopIteration:
        return ""
    parts = []
    for ln in lines[qi + 1:]:
        if CHOICE_RE.match(ln):
            break
        if ln.lower() in {"story", "answer"}:
            break
        if ln.isdigit():  # footer page number
            continue
        parts.append(ln)
    return " ".join(parts).strip()


STOP_WORDS = {
    "story", "question", "answer", "explanation of answer",
    "connection to computer science", "connections to computer science",
    "country of original author",
}


def _is_choice_stop(ln: str) -> bool:
    low = ln.lower()
    return (
        ln.isdigit()
        or low in STOP_WORDS
        or bool(PART_RE.match(ln))
        or low.startswith("explanation")
    )


def extract_choices(lines: list[str]) -> dict[str, str]:
    """Collect (A)-(D) choice text, including continuation lines for multi-line choices."""
    out: dict[str, str] = {}
    current: str | None = None
    for ln in lines:
        m = CHOICE_RE.match(ln)
        if m:
            current = m.group(1)
            out[current] = (m.group(2) or "").strip()
            continue
        if current is None:
            continue
        if _is_choice_stop(ln):
            current = None
            continue
        out[current] = (out[current] + " " + ln).strip()
    tidy = {}
    for letter, body in out.items():
        body = re.sub(r"\s+", " ", body).strip()
        body = re.sub(r"\s+([,.;:])", r"\1", body)
        tidy[letter] = body
    return tidy


def extract_answer_letter(lines: list[str]) -> str | None:
    for ln in lines[:6]:
        m = ANSWER_HEAD_RE.match(ln)
        if m:
            return m.group(1)
        if ln.lower() == "answer":
            continue
    # Fallback: first (A-D) on page
    for ln in lines[:10]:
        m = ANSWER_HEAD_RE.match(ln)
        if m:
            return m.group(1)
    return None


def find_year_pdfs(year: int) -> tuple[Path, Path]:
    q_candidates = sorted(EDUSITES.glob(f"{year}BCCContest5_6*.pdf"))
    # Prefer contest PDF that is NOT a solutions file
    q_candidates = [p for p in q_candidates if "Solution" not in p.name]
    s_candidates = sorted(EDUSITES.glob(f"{year}BCCContestSolutions5_6*.pdf"))
    if not q_candidates:
        raise FileNotFoundError(f"No contest PDF for {year} under {EDUSITES}")
    if not s_candidates:
        raise FileNotFoundError(f"No solutions PDF for {year} under {EDUSITES}")
    return q_candidates[0], s_candidates[0]


def collect_questions(doc) -> list[dict]:
    questions = []
    for i, page in enumerate(doc):
        lines = lines_of(page)
        if not is_question_page(lines):
            continue
        title = extract_title(lines) or f"Question {len(questions) + 1}"
        questions.append({
            "page_index": i,
            "title": title,
            "prompt": extract_question_prompt(lines),
            "choices": extract_choices(lines),
        })
    return questions


def collect_answers(doc) -> dict[str, str]:
    """Map question title -> answer letter using solutions PDF order."""
    answers: dict[str, str] = {}
    pending_title: str | None = None
    for page in doc:
        lines = lines_of(page)
        if is_question_page(lines):
            pending_title = extract_title(lines)
            continue
        if pending_title and is_answer_page(lines):
            letter = extract_answer_letter(lines)
            if letter:
                answers[pending_title] = letter
            pending_title = None
    return answers


def render_page_png(page, dest: Path, zoom: float = 2.0) -> None:
    mat = fitz.Matrix(zoom, zoom)
    pix = page.get_pixmap(matrix=mat, alpha=False)
    dest.parent.mkdir(parents=True, exist_ok=True)
    pix.save(str(dest))


def slug_folder(year: int, questions_path: Path) -> str:
    name = questions_path.stem
    name = re.sub(r"\s*\(\d+\)\s*$", "", name).strip()
    name = re.sub(r"[^\w\-]+", "_", name)
    return name or f"BCC_{year}_5_6"


def build_quiz_items(questions: list[dict], answers: dict[str, str]) -> list[dict]:
    items = []
    for n, q in enumerate(questions, start=1):
        letter = answers.get(q["title"])
        if not letter:
            # fuzzy: ignore curly apostrophes
            norm = {k.replace("'", "'").replace("'", "'"): v for k, v in answers.items()}
            letter = norm.get(q["title"].replace("'", "'").replace("'", "'"))
        if not letter:
            raise RuntimeError(f"No solutions answer found for question {n!r}: {q['title']!r}")

        choice_map = q["choices"] or {}
        letters = ["A", "B", "C", "D"]
        # Use short letter buttons when any choice is image-only / empty,
        # so labels always match the (A)–(D) marks on the page image.
        bodies = [choice_map.get(L, "").strip() for L in letters]
        # Text labels only when all four choices were read and they are distinct;
        # otherwise the page image is the source of truth, so use A-D buttons.
        use_letters_only = (not all(bodies)) or len(set(bodies)) < len(bodies)

        def label(L: str) -> str:
            if use_letters_only:
                return L
            body = choice_map.get(L) or ""
            return f"{L}. {body}" if body else L

        correct_label = label(letter)
        extra = [{"text": label(x)} for x in letters if x != letter]

        prompt_bits = [q["title"]]
        if q["prompt"]:
            prompt_bits.append(q["prompt"])
        prompt_text = " — ".join(prompt_bits)

        items.append({
            "prompt": {
                "text": prompt_text,
                "lang": "en",
                "displayText": True,
            },
            "question": {
                "media": {
                    "images": [f"q{n}.png"],
                }
            },
            "correctChoices": [{"text": correct_label}],
            "extraChoices": extra,
            "_meta": {
                "title": q["title"],
                "answerLetter": letter,
                "page": q["page_index"] + 1,
            },
        })
    return items


def convert(questions_pdf: Path, solutions_pdf: Path, out_dir: Path, zoom: float) -> Path:
    qdoc = fitz.open(questions_pdf)
    sdoc = fitz.open(solutions_pdf)
    questions = collect_questions(qdoc)
    if not questions:
        raise RuntimeError(f"No question pages found in {questions_pdf}")
    answers = collect_answers(sdoc)
    items = build_quiz_items(questions, answers)

    if out_dir.exists():
        for old in out_dir.glob("q*.png"):
            old.unlink()
        for old in out_dir.glob("*_quiz.json"):
            old.unlink()
    out_dir.mkdir(parents=True, exist_ok=True)

    clean_items = []
    for n, (q, item) in enumerate(zip(questions, items), start=1):
        png_name = f"q{n}.png"
        render_page_png(qdoc[q["page_index"]], out_dir / png_name, zoom=zoom)
        meta = item.pop("_meta", {})
        clean_items.append(item)
        print(f"  q{n}: {meta.get('title')} -> {meta.get('answerLetter')} (page {meta.get('page')})")

    quiz_path = out_dir / f"{out_dir.name}_quiz.json"
    quiz_path.write_text(json.dumps(clean_items, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return quiz_path


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--year", type=int, help="Contest year (looks up PDFs under BeaverContests/)")
    ap.add_argument("--questions", type=Path, help="Contest questions PDF")
    ap.add_argument("--solutions", type=Path, help="Solutions PDF (separate file)")
    ap.add_argument("--profile", default=DEFAULT_PROFILE, help="Profile folder under BeaverContests (default BM)")
    ap.add_argument("--folder", type=str, help="Output folder name (default from questions PDF name)")
    ap.add_argument("--zoom", type=float, default=2.0, help="PNG render scale (default 2.0)")
    ap.add_argument("--refresh-manifest", action="store_true", default=True,
                    help="Run make_edusite_manifests.py after convert (default on)")
    args = ap.parse_args(argv)

    if args.year:
        questions_pdf, solutions_pdf = find_year_pdfs(args.year)
        year = args.year
    else:
        if not args.questions or not args.solutions:
            ap.error("Provide --year, or both --questions and --solutions")
        questions_pdf = args.questions.resolve()
        solutions_pdf = args.solutions.resolve()
        m = re.search(r"(20\d{2})", questions_pdf.name)
        year = int(m.group(1)) if m else 0

    folder = args.folder or slug_folder(year, questions_pdf)
    out_dir = EDUSITES / args.profile / folder

    print(f"questions: {questions_pdf}")
    print(f"solutions: {solutions_pdf}")
    print(f"output:    {out_dir}")

    quiz_path = convert(questions_pdf, solutions_pdf, out_dir, zoom=args.zoom)
    print(f"wrote {quiz_path}")

    if args.refresh_manifest:
        man = ROOT / "scripts" / "make_edusite_manifests.py"
        if man.is_file():
            import runpy
            runpy.run_path(str(man), run_name="__main__")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
