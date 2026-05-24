#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

from author_lane_files import _extract_triage_timestamp

BAND_ORDER = ("S", "M", "L", "XL")
REPO_CHAT_ROOT = "/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/chats/icg"


def _row_identity(row: dict[str, Any]) -> tuple[str, int, str]:
    return (
        str(row.get("source_path") or ""),
        int(row.get("source_row_number") or 0),
        str(row.get("title") or ""),
    )


def _load_payload(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"payload at {path} must be a JSON object")
    return payload


def _extract_ts(to_author_path: Path, index_payload: dict[str, Any]) -> str:
    index_ts = str(index_payload.get("ts") or "").strip()
    if not index_ts:
        raise ValueError("index payload must include non-empty ts")

    author_ts = _extract_triage_timestamp(to_author_path)
    if author_ts != index_ts:
        raise ValueError(
            f"timestamp mismatch between to_author ({author_ts}) and index ({index_ts})"
        )
    return index_ts


def _effort_band_map(rows: list[dict[str, Any]]) -> dict[tuple[str, int, str], str]:
    mapping: dict[tuple[str, int, str], str] = {}
    for row in rows:
        band = str(row.get("effort_band") or "").upper()
        if band not in BAND_ORDER:
            continue
        key = _row_identity(row)
        existing = mapping.get(key)
        if existing is not None and existing != band:
            raise ValueError(f"conflicting effort_band for source identity: {key}")
        mapping[key] = band
    return mapping


def _join_index_entries(
    index_entries: list[dict[str, Any]],
    effort_bands: dict[tuple[str, int, str], str],
) -> list[dict[str, Any]]:
    joined: list[dict[str, Any]] = []
    for entry in index_entries:
        key = _row_identity(entry)
        if key not in effort_bands:
            raise ValueError(f"missing effort band for index entry source identity: {key}")

        lane_path = str(entry.get("path") or "").strip()
        if not lane_path.startswith("chats/icg/may24_") or not lane_path.endswith(".md"):
            raise ValueError(f"invalid index lane path: {lane_path}")

        joined.append(
            {
                "path": lane_path,
                "title": str(entry.get("title") or "Untitled lane"),
                "effort_band": effort_bands[key],
            }
        )
    return joined


def _chunked_subwaves(joined_entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[str, list[dict[str, Any]]] = {band: [] for band in BAND_ORDER}
    for entry in joined_entries:
        grouped[entry["effort_band"]].append(entry)

    waves: list[dict[str, Any]] = []
    wave_number = 1
    for band in BAND_ORDER:
        entries = grouped[band]
        for offset in range(0, len(entries), 4):
            chunk = entries[offset : offset + 4]
            waves.append({"wave_number": wave_number, "band": band, "entries": chunk})
            wave_number += 1
    return waves


def _dispatch_command(entry_path: str) -> str:
    filename = entry_path.removeprefix("chats/icg/")
    return f"batman {REPO_CHAT_ROOT}/{filename}"


def _defer_reason(row: dict[str, Any]) -> str:
    explicit = str(row.get("defer_reason") or "").strip()
    if explicit:
        return explicit

    eval_payload = row.get("rule_evaluation")
    if isinstance(eval_payload, dict):
        priority = str(eval_payload.get("priority_match")).lower()
        gate = str(eval_payload.get("gate_match")).lower()
        visible = str(eval_payload.get("customer_visible")).lower()
        return f"priority_match={priority}, gate_match={gate}, customer_visible={visible}"

    return "deferred by deterministic rule"


def _render_manifest(
    ts: str,
    waves: list[dict[str, Any]],
    to_defer_rows: list[dict[str, Any]],
    source_warnings: list[dict[str, Any]],
) -> str:
    lines = [
        f"# may24 {ts} - W3 dispatch manifest",
        "",
        "## Dispatch lanes",
    ]

    if not waves:
        lines.append("- No launch-blocking lanes in this run.")
    for wave in waves:
        count = len(wave["entries"])
        lane_label = "lane" if count == 1 else "lanes"
        lines.append(
            f"### Sub-wave {wave['wave_number']} - {wave['band']} - {count} {lane_label}"
        )
        for entry in wave["entries"]:
            lines.append(f"- `{_dispatch_command(entry['path'])}`")
        lines.append("")

    lines.extend(["## Deferred past announce", ""])
    if not to_defer_rows:
        lines.append("- None")
    for row in to_defer_rows:
        lines.append(
            "- "
            f"{str(row.get('title') or 'Untitled deferred row')} "
            f"(`{str(row.get('source_path') or '')}:row-{int(row.get('source_row_number') or 0)}`) "
            f"- {_defer_reason(row)}"
        )

    if source_warnings:
        lines.extend(["", "## Blocked / requires upstream re-run", ""])
        for warning in source_warnings:
            lines.append(
                "- "
                f"{str(warning.get('source_type') or 'unknown')} "
                f"`{str(warning.get('source_path') or '')}` "
                f"parse_status={str(warning.get('parse_status') or 'unknown')} "
                f"row_count={int(warning.get('row_count') or 0)}"
            )

    lines.append("")
    return "\n".join(lines)


def _render_shell_script(waves: list[dict[str, Any]]) -> str:
    lines = ["#!/usr/bin/env bash", "set -euo pipefail", ""]
    for wave in waves:
        lines.append(f"# Sub-wave {wave['wave_number']} ({wave['band']})")
        for entry in wave["entries"]:
            lines.append(_dispatch_command(entry["path"]))
        lines.append("")
    return "\n".join(lines)


def emit_dispatch_manifest(
    *,
    to_author_path: Path,
    to_defer_path: Path,
    index_path: Path,
    output_dir: Path,
    emit_shell: bool,
) -> tuple[Path, Path | None]:
    to_author = _load_payload(to_author_path)
    to_defer = _load_payload(to_defer_path)
    index_payload = _load_payload(index_path)

    to_author_rows = to_author.get("rows")
    to_defer_rows = to_defer.get("rows")
    index_entries = index_payload.get("entries")

    if not isinstance(to_author_rows, list):
        raise ValueError("to_author rows must be a list")
    if not isinstance(to_defer_rows, list):
        raise ValueError("to_defer rows must be a list")
    if not isinstance(index_entries, list):
        raise ValueError("index entries must be a list")

    source_warnings: list[dict[str, Any]] = []
    metadata = to_author.get("metadata")
    if isinstance(metadata, dict):
        candidate = metadata.get("source_warnings")
        if isinstance(candidate, list):
            source_warnings = [warning for warning in candidate if isinstance(warning, dict)]

    ts = _extract_ts(to_author_path, index_payload)
    effort_bands = _effort_band_map([row for row in to_author_rows if isinstance(row, dict)])
    joined = _join_index_entries([row for row in index_entries if isinstance(row, dict)], effort_bands)
    waves = _chunked_subwaves(joined)

    manifest_text = _render_manifest(
        ts=ts,
        waves=waves,
        to_defer_rows=[row for row in to_defer_rows if isinstance(row, dict)],
        source_warnings=source_warnings,
    )

    output_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = output_dir / f"may24_{ts}_w3_dispatch.md"
    manifest_path.write_text(manifest_text, encoding="utf-8")

    shell_path: Path | None = None
    if emit_shell:
        shell_path = output_dir / f"may24_{ts}_w3_dispatch.sh"
        shell_path.write_text(_render_shell_script(waves), encoding="utf-8")
        shell_path.chmod(0o755)

    return manifest_path, shell_path


def main(argv: list[str]) -> int:
    if len(argv) not in (4, 5):
        print(
            "usage: python3 scripts/w3_triage/emit_dispatch_manifest.py "
            "<to_author_json> <to_defer_json> <index_json> [--emit-shell]",
            file=sys.stderr,
        )
        return 2

    emit_shell = len(argv) == 5
    if emit_shell and argv[4] != "--emit-shell":
        print("only optional flag supported: --emit-shell", file=sys.stderr)
        return 2

    to_author_path = Path(argv[1])
    to_defer_path = Path(argv[2])
    index_path = Path(argv[3])

    manifest_path, shell_path = emit_dispatch_manifest(
        to_author_path=to_author_path,
        to_defer_path=to_defer_path,
        index_path=index_path,
        output_dir=index_path.parent,
        emit_shell=emit_shell,
    )
    print(manifest_path.as_posix())
    if shell_path is not None:
        print(shell_path.as_posix())
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
