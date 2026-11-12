#!/usr/bin/env python3
"""Validate QuickMD's Localizable.strings files.

Checks, for every language next to the English base:
  * the key sets are identical (no missing / extra keys),
  * no file declares the same key twice,
  * every value is non-empty,
  * format placeholders (%@, %lld, %% ...) match the English value exactly.

Run from anywhere:

    python3 scripts/check-localizations.py

Exit code 0 = all good, 1 = problems found.
"""

from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCALIZATION_DIR = ROOT / "QuickMD" / "QuickMD"
BASE_LANGUAGE = "en"

ENTRY_RE = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT_RE = re.compile(r"^\s*//.*$", re.M)
PLACEHOLDER_RE = re.compile(r"%(?:%|(?:[0-9]+\$)?[-+ 0#']*(?:\.[0-9]+)?(?:hh|h|ll|l|q|L)?[@dDiuUxXoOfFeEgGcs])")

_SIMPLE_ESCAPES = {
    "n": "\n",
    "t": "\t",
    "r": "\r",
    '"': '"',
    "\\": "\\",
    "0": "\0",
}


def decode_strings_literal(text: str) -> str:
    """Decode the escapes used by an old-style .strings literal."""
    out: list[str] = []
    i = 0
    while i < len(text):
        char = text[i]
        if char != "\\" or i + 1 >= len(text):
            out.append(char)
            i += 1
            continue
        nxt = text[i + 1]
        if nxt in _SIMPLE_ESCAPES:
            out.append(_SIMPLE_ESCAPES[nxt])
            i += 2
        elif nxt == "u" and text.startswith("u{", i + 1) is False and i + 5 < len(text):
            out.append(chr(int(text[i + 2:i + 6], 16)))
            i += 6
        elif nxt == "U" and i + 9 < len(text):
            out.append(chr(int(text[i + 2:i + 10], 16)))
            i += 10
        else:
            # Unknown escape: keep the backslash rather than guessing.
            out.append(char)
            i += 1
    return "".join(out)


def parse_strings(path: Path) -> list[tuple[str, str, int]]:
    """Return [(key, value, line)] and fail loudly on malformed entries."""
    source = path.read_text(encoding="utf-8")
    source = COMMENT_RE.sub("", source)
    source = LINE_COMMENT_RE.sub("", source)

    entries: list[tuple[str, str, int]] = []
    consumed = 0
    for match in ENTRY_RE.finditer(source):
        between = source[consumed:match.start()]
        if between.strip():
            raise ValueError(f"unparsed text before line {source[:match.start()].count(chr(10)) + 1}")
        consumed = match.end()
        key = decode_strings_literal(match.group(1))
        value = decode_strings_literal(match.group(2))
        line = source[:match.start()].count("\n") + 1
        entries.append((key, value, line))
    if source[consumed:].strip():
        raise ValueError(f"unparsed text after line {source[:consumed].count(chr(10)) + 1}")
    return entries


def placeholders(value: str) -> list[str]:
    return PLACEHOLDER_RE.findall(value)


def main() -> int:
    base_path = LOCALIZATION_DIR / f"{BASE_LANGUAGE}.lproj" / "Localizable.strings"
    if not base_path.is_file():
        print(f"error: missing base localization: {base_path}", file=sys.stderr)
        return 1

    paths = sorted(LOCALIZATION_DIR.glob("*.lproj/Localizable.strings"))
    if not paths:
        print("error: no Localizable.strings files found", file=sys.stderr)
        return 1

    problems: list[str] = []
    base_entries: dict[str, str] = {}

    for path in paths:
        language = path.parent.stem
        try:
            entries = parse_strings(path)
        except ValueError as error:
            problems.append(f"{language}: cannot parse {path}: {error}")
            continue

        duplicates = sorted(key for key, count in Counter(key for key, _, _ in entries).items() if count > 1)
        for key in duplicates:
            problems.append(f"{language}: duplicate key {key!r}")

        data: dict[str, str] = {}
        for key, value, line in entries:
            if not value:
                problems.append(f"{language}:{line}: empty value for {key!r}")
            data[key] = value

        if language == BASE_LANGUAGE:
            base_entries = data
            print(f"{language:<8} {len(data):>4} keys (base)")
            continue

        missing = sorted(set(base_entries) - set(data))
        extra = sorted(set(data) - set(base_entries))
        for key in missing:
            problems.append(f"{language}: missing key {key!r}")
        for key in extra:
            problems.append(f"{language}: extra key {key!r}")

        for key in sorted(set(base_entries) & set(data)):
            expected = placeholders(base_entries[key])
            actual = placeholders(data[key])
            if expected != actual:
                problems.append(
                    f"{language}: placeholder mismatch for {key!r}: "
                    f"expected {expected}, found {actual}"
                )
        print(f"{language:<8} {len(data):>4} keys")

    if problems:
        print("\nProblems:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print("\nOK: keys and placeholders match.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
