#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

PRIORITY_RE = re.compile(r"\bP([0-3])\b", re.IGNORECASE)
EFFORT_RE = re.compile(
    r"(?:effort\s*band|effort)\s*[:=`-]?\s*`?\b(S|M|L|XL)\b`?", re.IGNORECASE
)
GATE_RE = re.compile(
    r"(?:suggested\s*gate|gate)\s*[:=`-]?\s*`?"
    r"(pre-L6|pre-W4-cutover|between\s+L6/L7|post-L7)"
    r"`?",
    re.IGNORECASE,
)
OWNER_SEED_RE = re.compile(r"owner[\s-]*files\s*seed\s*[:=]\s*(.+)", re.IGNORECASE)
PATH_RE = re.compile(r"`([^`]+)`|([A-Za-z0-9_./\-\[\](){}+]+\.[A-Za-z0-9_]+)")
ROW_START_RE = re.compile(r"^\s*(\d+)\.\s+(.+?)\s*$")
HEADER_RE = re.compile(r"^##\s+", re.IGNORECASE)


def _slice_prioritized_section(markdown: str) -> tuple[bool, list[str]]:
    lines = markdown.splitlines()
    start_idx: int | None = None
    for idx, line in enumerate(lines):
        if line.strip().lower() == "## prioritized recommendations":
            start_idx = idx + 1
            break

    if start_idx is None:
        return False, []

    section_lines: list[str] = []
    for line in lines[start_idx:]:
        if HEADER_RE.match(line.strip()):
            break
        section_lines.append(line)

    return True, section_lines


def _parse_owner_files(text: str) -> list[str]:
    owner_text = text
    owner_match = OWNER_SEED_RE.search(text)
    if owner_match:
        owner_text = owner_match.group(1)

    owners: list[str] = []
    for match in PATH_RE.finditer(owner_text):
        value = match.group(1) or match.group(2)
        if not value:
            continue
        cleaned = value.strip().rstrip(",.;)")
        if "/" in cleaned and cleaned not in owners:
            owners.append(cleaned)
    return owners


def _normalize_row(source_path: str, source_type: str, order: int, lines: list[str]) -> dict[str, Any]:
    title_match = ROW_START_RE.match(lines[0])
    if not title_match:
        raise ValueError(f"invalid row start: {lines[0]}")

    body_lines = [line.strip() for line in lines[1:] if line.strip()]
    title = title_match.group(2).strip()
    body = "\n".join(body_lines)
    full_text = f"{title}\n{body}" if body else title

    priority_match = PRIORITY_RE.search(full_text)
    effort_match = EFFORT_RE.search(full_text)
    gate_match = GATE_RE.search(full_text)

    priority = f"P{priority_match.group(1)}" if priority_match else None
    effort_band = effort_match.group(1).upper() if effort_match else None
    gate = gate_match.group(1) if gate_match else None
    owner_files = _parse_owner_files(full_text)

    return {
        "source_path": source_path,
        "source_type": source_type,
        "source_row_number": int(title_match.group(1)),
        "row_order": order,
        "title": title,
        "body": body,
        "priority": priority,
        "gate": gate,
        "effort_band": effort_band,
        "owner_files": owner_files,
    }


def _parse_rows(source_path: str, source_type: str, section_lines: list[str]) -> list[dict[str, Any]]:
    grouped: list[list[str]] = []
    current: list[str] = []

    for line in section_lines:
        if ROW_START_RE.match(line):
            if current:
                grouped.append(current)
            current = [line]
            continue

        if current:
            current.append(line)

    if current:
        grouped.append(current)

    rows: list[dict[str, Any]] = []
    for order, row_lines in enumerate(grouped, start=1):
        rows.append(_normalize_row(source_path, source_type, order, row_lines))
    return rows


def parse_recommendation_sources(parity_summary: Path, coverage_summary: Path) -> dict[str, Any]:
    summaries = [
        ("parity", parity_summary),
        ("coverage", coverage_summary),
    ]
    all_rows: list[dict[str, Any]] = []
    sources: list[dict[str, Any]] = []

    for source_type, path in summaries:
        markdown = path.read_text(encoding="utf-8")
        section_found, section_lines = _slice_prioritized_section(markdown)

        if section_found:
            rows = _parse_rows(path.as_posix(), source_type, section_lines)
            parse_status = "ok"
        else:
            rows = []
            parse_status = "missing_prioritized_recommendations"

        sources.append(
            {
                "source_path": path.as_posix(),
                "source_type": source_type,
                "section_found": section_found,
                "parse_status": parse_status,
                "row_count": len(rows),
            }
        )
        all_rows.extend(rows)

    return {
        "sources": sources,
        "rows": all_rows,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "usage: python3 scripts/w3_triage/parse_audit_recommendations.py "
            "<parity_summary> <coverage_summary>",
            file=sys.stderr,
        )
        return 2

    parity_summary = Path(argv[1])
    coverage_summary = Path(argv[2])
    parsed = parse_recommendation_sources(parity_summary, coverage_summary)
    json.dump(parsed, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
