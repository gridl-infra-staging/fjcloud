#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

TRIAGE_TS_RE = re.compile(r"^\d{8}T\d{6}Z$")


def _row_sort_key(row: dict[str, Any]) -> tuple[str, int, int, str]:
    return (
        str(row.get("source_path") or ""),
        int(row.get("source_row_number") or 0),
        int(row.get("row_order") or 0),
        str(row.get("title") or ""),
    )


def _extract_triage_timestamp(to_author_path: Path) -> str:
    parts = to_author_path.parts
    for index, value in enumerate(parts[:-1]):
        if value != "triage":
            continue
        if index + 1 >= len(parts):
            break
        candidate = parts[index + 1]
        if TRIAGE_TS_RE.match(candidate):
            return candidate
    raise ValueError(
        "to_author path must include docs/audits/triage/<TS>/to_author.json context"
    )


def _normalize_title_slug(title: str) -> str:
    tokens = re.findall(r"[a-z0-9]+", title.lower())
    if not tokens:
        return "untitled"
    slug = "_".join(tokens[:5])
    slug = slug[:40].strip("_")
    return slug or "untitled"


def _owner_files_text(owner_files: Any) -> str:
    if not isinstance(owner_files, list) or not owner_files:
        return "- (owner files missing in row metadata)"
    return "\n".join(f"- `{str(path)}`" for path in owner_files)


def _render_lane_markdown(ts: str, lane_number: int, row: dict[str, Any]) -> str:
    title = str(row.get("title") or "Untitled recommendation")
    body = str(row.get("body") or "")
    source_path = str(row.get("source_path") or "unknown-source")
    source_row_number = int(row.get("source_row_number") or 0)
    owners_block = _owner_files_text(row.get("owner_files"))

    return f"""# may24 {ts} — W3.{lane_number} {title}

**Authored by:** W3.0 fan-out lane (mechanical generation)
**Parent orchestration:** [`chats/icg/may24_812am_orchestration.md`](may24_812am_orchestration.md)
**Triage rationale:** P0 launch-blocking per W3.0 rule; source SUMMARY row = `{source_path}:row-{source_row_number}`

## PURPOSE
{body}

## Anti-stop rule
`blocked/inconclusive` is a failure mode. If any requirement cannot be completed, state exactly which owner file and check failed, include reproducible command evidence, and continue with the remaining in-scope steps.

## Agent operating conditions
- Full permissions, no sandbox, no human in the loop within this lane.
- May install dependencies, run tests, commit, and push.
- Do not print secret values or commit credentials.

## Out of scope
- Anything not directly addressing the gap this row identifies.
- Closing other rows from the same SUMMARY (those are separate lanes).

## Owner files
{owners_block}

## Stage 1 — TDD: write the failing regression test
- Target files:
{owners_block}
- The test must fail on `main` (proving the gap is real) and pass after Stage 2 implementation.

## Stage 2 — Implement
- Target files:
{owners_block}
- Minimum surface to close the gap; no scope creep.

## Stage 3 — Validate
- `bash scripts/local-ci.sh --with-contracts` exit 0.
- Mirror staging CI green on resulting SHA.
- Curl-probe the customer-facing change (lane authors a single concrete probe matching the gap).

## Merge plan
- Standard batman merge to `main`.
- Append `LAUNCH.md` entry: `W3.{lane_number} closed: <one-line summary>`.
"""


def author_lane_files(to_author_path: Path, output_dir: Path) -> dict[str, Any]:
    payload = json.loads(to_author_path.read_text(encoding="utf-8"))
    rows = payload.get("rows")
    if not isinstance(rows, list):
        raise ValueError("to_author payload must include rows list")

    triage_ts = _extract_triage_timestamp(to_author_path)
    output_dir.mkdir(parents=True, exist_ok=True)

    entries: list[dict[str, Any]] = []
    for lane_number, row in enumerate(sorted(rows, key=_row_sort_key), start=1):
        if not isinstance(row, dict):
            continue

        title = str(row.get("title") or "Untitled recommendation")
        slug = _normalize_title_slug(title)
        filename = f"may24_{triage_ts}_w3_{lane_number}_{slug}.md"

        lane_path = output_dir / filename
        lane_markdown = _render_lane_markdown(triage_ts, lane_number, row)
        lane_path.write_text(lane_markdown, encoding="utf-8")

        entries.append(
            {
                "lane_number": lane_number,
                "slug": slug,
                "title": title,
                "source_path": str(row.get("source_path") or ""),
                "source_row_number": int(row.get("source_row_number") or 0),
                "path": f"chats/icg/{filename}",
            }
        )

    index_payload = {
        "ts": triage_ts,
        "source_to_author": to_author_path.as_posix(),
        "entries": entries,
    }
    index_path = output_dir / f"may24_{triage_ts}_w3_index.json"
    index_path.write_text(json.dumps(index_payload, indent=2) + "\n", encoding="utf-8")
    return index_payload


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "usage: python3 scripts/w3_triage/author_lane_files.py "
            "<to_author_json> <output_dir>",
            file=sys.stderr,
        )
        return 2

    to_author_path = Path(argv[1])
    output_dir = Path(argv[2])
    author_lane_files(to_author_path, output_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
