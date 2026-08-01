#!/usr/bin/env python3
"""Deterministic shard manifest for follow-up triage lanes."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


SHARD_COUNT = 10
FEED_PATH = "chats/icg/_followups.md"
TRIAGE_PATH = "docs/audits/followup-triage/TRIAGE.md"
PINNED_SHA_RE = re.compile(r"Pinned base SHA:\s*`([0-9a-f]{40})`")
OPEN_WINDOW_RE = re.compile(r"^- open_window:\s*([0-9]+)\s*$", re.MULTILINE)


@dataclass(frozen=True)
class PinnedCensus:
    sha: str
    open_window: int


@dataclass
class Shard:
    index: int
    lanes: list[str]
    records: int = 0


class ShardError(Exception):
    pass


def repo_root() -> Path:
    return Path(os.environ.get("FJCLOUD_REPO_ROOT", ".")).resolve()


def read_pinned_sha(root: Path) -> PinnedCensus:
    triage_file = root / TRIAGE_PATH
    try:
        triage = triage_file.read_text(encoding="utf-8")
    except OSError as exc:
        raise ShardError(f"ERROR: cannot read {TRIAGE_PATH}: {exc}") from exc

    pins = PINNED_SHA_RE.findall(triage)
    denominators = OPEN_WINDOW_RE.findall(triage)
    if len(pins) != 1:
        raise ShardError("ERROR: TRIAGE.md must contain exactly one pinned SHA")
    if len(denominators) != 1:
        raise ShardError("ERROR: TRIAGE.md must contain exactly one open_window denominator")
    return PinnedCensus(sha=pins[0], open_window=int(denominators[0]))


def load_pinned_feed(root: Path, pinned_sha: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "show", f"{pinned_sha}:{FEED_PATH}"],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        raise ShardError(
            f"ERROR: cannot run git to load pinned feed {pinned_sha}:{FEED_PATH}: {exc}"
        ) from exc
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise ShardError(f"ERROR: cannot load pinned feed {pinned_sha}:{FEED_PATH}: {detail}")
    return result.stdout


def parse_open_lane_counts(feed: str) -> dict[str, int]:
    section = ""
    counts: dict[str, int] = {}
    lane_prefix = "- lane_id: "
    for line_number, line in enumerate(feed.splitlines(), start=1):
        if line == "## Open":
            section = "open"
            continue
        if line.startswith("## "):
            section = "other"
            continue
        if section == "open" and line.startswith("- lane_id:"):
            if not line.startswith(lane_prefix):
                raise ShardError(
                    f"MALFORMED: invalid lane_id row at pinned feed line {line_number}"
                )
            lane_id = line.removeprefix(lane_prefix).split("::", 1)[0].strip()
            if not lane_id:
                raise ShardError(
                    f"MALFORMED: empty lane_id row at pinned feed line {line_number}"
                )
            counts[lane_id] = counts.get(lane_id, 0) + 1
    return counts


def risk_ordered_lanes(lane_counts: dict[str, int]) -> list[tuple[str, int]]:
    """Sole owner of the LPT risk order shared by sharding and lane-count output.

    The order is load-bearing because sibling lanes run against a moving working
    tree: largest lanes first, then ascending lane-id for ties.
    """
    return sorted(lane_counts.items(), key=lambda item: (-item[1], item[0]))


def assign_shards(lane_counts: dict[str, int]) -> list[Shard]:
    shards = [Shard(index=index, lanes=[]) for index in range(SHARD_COUNT)]
    for lane_id, record_count in risk_ordered_lanes(lane_counts):
        # The shard tie-break is deterministic too: choose the lowest record
        # total, then the lowest shard index when multiple bins are equal.
        shard = min(shards, key=lambda candidate: (candidate.records, candidate.index))
        shard.lanes.append(lane_id)
        shard.records += record_count
    return shards


def load_shards(root: Path) -> tuple[PinnedCensus, dict[str, int], list[Shard]]:
    census = read_pinned_sha(root)
    lane_counts = parse_open_lane_counts(load_pinned_feed(root, census.sha))
    record_total = sum(lane_counts.values())
    if record_total == 0:
        raise ShardError("VACUOUS: no Open lane_id records in pinned feed")
    if record_total != census.open_window:
        raise ShardError(
            "ERROR: pinned feed Open record total "
            f"{record_total} does not match open_window {census.open_window}"
        )
    return census, lane_counts, assign_shards(lane_counts)


def format_shard(shard: Shard) -> str:
    lines = [f"shard: {shard.index:02d}", f"records: {shard.records}", "lanes:"]
    lines.extend(shard.lanes)
    return "\n".join(lines)


def print_shard(root: Path, shard_id: str) -> int:
    if not re.fullmatch(r"0[0-9]", shard_id):
        print("ERROR: invalid shard id; expected 00 through 09", file=sys.stderr)
        return 2
    _, _, shards = load_shards(root)
    print(format_shard(shards[int(shard_id)]))
    return 0


def format_lane_counts(lane_counts: dict[str, int]) -> str:
    return "\n".join(
        f"{lane_id}\t{record_count}"
        for lane_id, record_count in risk_ordered_lanes(lane_counts)
    )


def print_lane_counts(root: Path) -> int:
    _, lane_counts, _ = load_shards(root)
    print(format_lane_counts(lane_counts))
    return 0


def coverage_defects(source_lanes: set[str], shards: list[Shard]) -> list[str]:
    defects: list[str] = []
    seen: set[str] = set()
    overlaps: set[str] = set()
    for shard in shards:
        for lane_id in shard.lanes:
            if lane_id in seen:
                overlaps.add(lane_id)
            seen.add(lane_id)
    missing = sorted(source_lanes - seen)
    extra = sorted(seen - source_lanes)
    if missing:
        defects.append(f"MISSING: {', '.join(missing)}")
    if overlaps:
        defects.append(f"OVERLAP: {', '.join(sorted(overlaps))}")
    if extra:
        defects.append(f"EXTRA: {', '.join(extra)}")
    return defects


def format_coverage(census: PinnedCensus, lane_counts: dict[str, int], shards: list[Shard]) -> str:
    lines = [f"pin: {census.sha}", f"open_window: {census.open_window}"]
    for shard in shards:
        lines.append(
            f"shard {shard.index:02d}: lanes={len(shard.lanes)} records={shard.records}"
        )
    grand_total = sum(shard.records for shard in shards)
    lines.append(f"grand_total: lanes={len(lane_counts)} records={grand_total}")
    lines.append("coverage: OK")
    return "\n".join(lines)


def verify_coverage(root: Path) -> int:
    census, lane_counts, shards = load_shards(root)
    defects = coverage_defects(set(lane_counts), shards)
    if defects:
        print("\n".join(defects), file=sys.stderr)
        return 1
    print(format_coverage(census, lane_counts, shards))
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--verify-coverage", action="store_true")
    group.add_argument("--lane-counts", action="store_true")
    group.add_argument("--shard")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        root = repo_root()
        if args.verify_coverage:
            return verify_coverage(root)
        if args.lane_counts:
            return print_lane_counts(root)
        return print_shard(root, args.shard)
    except ShardError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
