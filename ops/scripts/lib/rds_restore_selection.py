#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
from typing import Any

SEP = "\x1f"
OUTPUT_FIELDS = (
    "status",
    "reason",
    "source",
    "target",
    "restore_mode",
    "snapshot_id",
    "restore_time",
    "source_status",
    "source_endpoint",
    "retention",
    "latest_restore_time_text",
    "instance_count",
    "snapshot_count",
    "cluster_count",
    "available_snapshot_count",
    "source_scoped_snapshot_count",
    "source_instance_present",
)


def emit(*values: Any) -> None:
    print(SEP.join("" if value is None else str(value) for value in values))


def snapshot_sort_key(snapshot: dict[str, Any]) -> tuple[str, str]:
    return (
        str(snapshot.get("SnapshotCreateTime", "")),
        str(snapshot.get("DBSnapshotIdentifier", "")),
    )


def load_json_file(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def load_inputs(argv: list[str]) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any], str, str, str, str, str]:
    instances_doc = load_json_file(argv[1])
    snapshots_doc = load_json_file(argv[2])
    clusters_doc = load_json_file(argv[3])
    source = argv[4]
    target_override = argv[5]
    snapshot_override = argv[6]
    restore_time_override = argv[7]
    timestamp = argv[8]
    return (
        instances_doc,
        snapshots_doc,
        clusters_doc,
        source,
        target_override,
        snapshot_override,
        restore_time_override,
        timestamp,
    )


def resolve_default_target(source: str, target_override: str, timestamp: str, instances: list[dict[str, Any]]) -> str:
    if target_override:
        return target_override

    existing_identifiers = {
        str(item.get("DBInstanceIdentifier", ""))
        for item in instances
    }
    base_target = f"{source}-restore-{timestamp}"
    target = base_target
    suffix = 2
    while target in existing_identifiers:
        target = f"{base_target}-{suffix}"
        suffix += 1
    return target


def build_result(source: str, target: str, instance_count: int, snapshot_count: int, cluster_count: int) -> dict[str, Any]:
    return {
        "status": "ok",
        "reason": "",
        "source": source,
        "target": target,
        "restore_mode": "",
        "snapshot_id": "",
        "restore_time": "",
        "source_status": "",
        "source_endpoint": "",
        "retention": "",
        "latest_restore_time_text": "",
        "instance_count": instance_count,
        "snapshot_count": snapshot_count,
        "cluster_count": cluster_count,
        "available_snapshot_count": 0,
        "source_scoped_snapshot_count": 0,
        "source_instance_present": "false",
    }


def emit_result(result: dict[str, Any]) -> None:
    emit(*(result[field] for field in OUTPUT_FIELDS))


def parse_retention(raw_retention: Any) -> int:
    try:
        return int(raw_retention or 0)
    except (TypeError, ValueError):
        return 0


def resolve_source_instance(
    result: dict[str, Any], instances: list[dict[str, Any]], clusters: list[dict[str, Any]]
) -> dict[str, Any] | None:
    source = str(result["source"])
    source_instance = next(
        (item for item in instances if item.get("DBInstanceIdentifier") == source),
        None,
    )
    if source_instance is None:
        if len(instances) == 0 and len(clusters) > 0:
            result["status"] = "blocked"
            result["reason"] = (
                "cluster-shaped inputs detected; wrapper handles DB instance restores only"
            )
            return None
        result["status"] = "blocked"
        result["reason"] = f"missing source DB instance restore inputs for '{source}'"
        return None

    result["source_status"] = str(source_instance.get("DBInstanceStatus", ""))
    result["source_endpoint"] = str((source_instance.get("Endpoint") or {}).get("Address", ""))
    result["latest_restore_time_text"] = str(source_instance.get("LatestRestorableTime") or "")
    result["source_instance_present"] = "true"
    result["retention"] = parse_retention(source_instance.get("BackupRetentionPeriod"))
    return source_instance


def select_snapshot_fallback(result: dict[str, Any], snapshots: list[dict[str, Any]]) -> bool:
    source = str(result["source"])
    available_snapshots = [
        item for item in snapshots if str(item.get("Status", "")).lower() == "available"
    ]
    scoped_snapshots = [
        item
        for item in available_snapshots
        if str(item.get("DBInstanceIdentifier", "")) == source
    ]
    result["available_snapshot_count"] = len(available_snapshots)
    result["source_scoped_snapshot_count"] = len(scoped_snapshots)

    if not scoped_snapshots:
        result["status"] = "blocked"
        result["reason"] = (
            "missing required restore selectors (no PITR timestamp and "
            f"no available snapshot bound to source '{source}')"
        )
        return False

    result["restore_mode"] = "snapshot"
    result["snapshot_id"] = str(
        sorted(scoped_snapshots, key=snapshot_sort_key, reverse=True)[0].get(
            "DBSnapshotIdentifier", ""
        )
    )
    return True


def select_restore_mode(
    result: dict[str, Any],
    snapshots: list[dict[str, Any]],
    snapshot_override: str,
    restore_time_override: str,
) -> None:
    if snapshot_override and restore_time_override:
        result["status"] = "fail"
        result["reason"] = (
            "provide exactly one restore mode selector (--snapshot-id or --restore-time)"
        )
        result["source"] = ""
        result["target"] = ""
        return
    if snapshot_override:
        result["restore_mode"] = "snapshot"
        result["snapshot_id"] = snapshot_override
        return
    if restore_time_override:
        result["restore_mode"] = "pitr"
        result["restore_time"] = restore_time_override
        return
    if int(result["retention"]) > 0 and str(result["latest_restore_time_text"]):
        result["restore_mode"] = "pitr"
        result["restore_time"] = str(result["latest_restore_time_text"])
        return
    select_snapshot_fallback(result, snapshots)


def main() -> int:
    (
        instances_doc,
        snapshots_doc,
        clusters_doc,
        source,
        target_override,
        snapshot_override,
        restore_time_override,
        timestamp,
    ) = load_inputs(sys.argv)

    instances = instances_doc.get("DBInstances", [])
    snapshots = snapshots_doc.get("DBSnapshots", [])
    clusters = clusters_doc.get("DBClusters", [])
    target = resolve_default_target(source, target_override, timestamp, instances)
    result = build_result(source, target, len(instances), len(snapshots), len(clusters))

    if source == target:
        result["status"] = "fail"
        result["reason"] = (
            "--source-db-instance-id and --target-db-instance-id must be different"
        )
        result["source"] = ""
        result["target"] = ""
        result["snapshot_id"] = ""
        result["restore_time"] = ""
        emit_result(result)
        return 0

    if resolve_source_instance(result, instances, clusters) is None:
        emit_result(result)
        return 0

    select_restore_mode(result, snapshots, snapshot_override, restore_time_override)
    emit_result(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
