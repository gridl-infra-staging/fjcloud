#!/usr/bin/env python3
"""Compare Algolia migration source and migrated hit collections."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, NoReturn

RESPONSE_DECORATION_FIELDS = {"_highlightResult", "_snippetResult", "_rankingInfo"}


def fail(reason: str) -> NoReturn:
    print(reason, file=sys.stderr)
    raise SystemExit(2)


def load_json(path: Path, reason: str) -> Any:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        fail(reason)


def extract_hits(payload: Any, label: str) -> list[dict[str, Any]]:
    hits = payload.get("hits") if isinstance(payload, dict) else payload
    if not isinstance(hits, list) or any(not isinstance(hit, dict) for hit in hits):
        raise ValueError(f"{label}_hits_invalid")
    return hits


def canonical_hit(hit: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value
        for key, value in sorted(hit.items())
        if key not in RESPONSE_DECORATION_FIELDS
    }


def hits_by_object_id(payload: Any, label: str) -> dict[str, dict[str, Any]]:
    indexed: dict[str, dict[str, Any]] = {}
    for hit in extract_hits(payload, label):
        object_id = hit.get("objectID")
        if not isinstance(object_id, str) or object_id == "":
            raise ValueError(f"{label}_object_id_invalid")
        if object_id in indexed:
            raise ValueError(f"{label}_object_id_duplicate")
        indexed[object_id] = canonical_hit(hit)
    return indexed


def compare_hit_sets(source_payload: Any, migrated_payload: Any) -> dict[str, Any]:
    source_hits = extract_hits(source_payload, "source")
    migrated_hits = extract_hits(migrated_payload, "migrated")
    source_by_id = hits_by_object_id(source_hits, "source")
    migrated_by_id = hits_by_object_id(migrated_hits, "migrated")

    source_ids = set(source_by_id)
    migrated_ids = set(migrated_by_id)
    shared_ids = sorted(source_ids & migrated_ids)

    mismatches = [
        {
            "objectID": object_id,
            "source": source_by_id[object_id],
            "migrated": migrated_by_id[object_id],
        }
        for object_id in shared_ids
        if source_by_id[object_id] != migrated_by_id[object_id]
    ]

    return {
        "count_source": len(source_hits),
        "count_migrated": len(migrated_hits),
        "only_in_source": sorted(source_ids - migrated_ids),
        "only_in_migrated": sorted(migrated_ids - source_ids),
        "field_mismatches": mismatches,
    }


def report_is_empty(report: dict[str, Any]) -> bool:
    return (
        report["only_in_source"] == []
        and report["only_in_migrated"] == []
        and report["field_mismatches"] == []
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare source and migrated Algolia hit JSON."
    )
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--migrated", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        report = compare_hit_sets(
            load_json(args.source, "source_json_invalid"),
            load_json(args.migrated, "migrated_json_invalid"),
        )
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2

    print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    return 0 if report_is_empty(report) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
