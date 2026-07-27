#!/usr/bin/env python3
"""Pure JSON helpers for the local multinode migration live probe."""

from __future__ import annotations

import ipaddress
import json
import socket
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from local_multinode_migration_evidence import (
    EXPECTED_BRANCH_DENOMINATOR,
    EXPECTED_HA_RESPONSE,
    MalformedEvidence,
    ORDERED_CLEANUP_KEYS,
    require_utc_timestamp,
)


def read_json(path: str) -> object:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write_json(path: str, payload: object) -> None:
    Path(path).write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")


def migration_response(outcome_path: str, parity_path: str) -> dict[str, object]:
    """Project a captured async import outcome into the evidence response shape.

    The async status endpoint carries the real settings/synonyms/rules outcome and
    the settings-passthrough warnings, but no object count; the imported count is
    the parity-checked target browse count. Every field is read from the captured
    live outcome or the real parity report.
    """
    outcome = read_json(outcome_path)
    parity = read_json(parity_path)
    response: dict[str, object] = {
        "disposition": outcome["disposition"],
        "terminal_at": outcome["terminal_at"],
        "settings": outcome["settings"],
        "synonyms": {"imported": outcome["synonyms"]},
        "rules": {"imported": outcome["rules"]},
        "objects": {"imported": parity["count_migrated"]},
    }
    warnings = outcome.get("warnings") or []
    if warnings:
        response["warnings"] = warnings
    return response


def imported_count(node: object) -> int:
    if not (isinstance(node, dict) and set(node) == {"imported"}):
        raise ValueError
    count = node["imported"]
    if not (isinstance(count, int) and not isinstance(count, bool) and count >= 0):
        raise ValueError
    return count


def capture_outcome(argv: list[str]) -> int:
    """Project a terminal async import status body into the owned outcome file.

    Warnings are carried through verbatim: real Algolia GET /settings always forces
    settings-passthrough warnings, and the classifier — not this capture — owns the
    benign-vs-unexpected verdict, so nothing is dropped or defaulted to healthy.
    """
    body_json, output = argv
    try:
        value = json.loads(body_json)
        disposition = value["disposition"]
        terminal_at = value["terminalAt"]
        settings_applied = value["settingsApplied"]
        warnings = value["warnings"] if "warnings" in value else []
        if disposition != "succeeded":
            return 1
        require_utc_timestamp(terminal_at)
        if not isinstance(settings_applied, bool):
            return 1
        if not isinstance(warnings, list):
            return 1
        outcome = {
            "disposition": disposition,
            "terminal_at": terminal_at,
            "settings": settings_applied,
            "synonyms": imported_count(value["synonymsImported"]),
            "rules": imported_count(value["rulesImported"]),
            "warnings": warnings,
        }
    except (KeyError, TypeError, ValueError, json.JSONDecodeError, MalformedEvidence):
        return 1
    write_json(output, outcome)
    return 0


def free_port(argv: list[str]) -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        print(listener.getsockname()[1])
    return 0


def batch_add_payload(argv: list[str]) -> int:
    """Build an Algolia batch addObject payload from a fixture of documents."""
    fixture, output = argv
    documents = read_json(fixture)
    write_json(
        output,
        {"requests": [{"action": "addObject", "body": document} for document in documents]},
    )
    return 0


def extract_hits(argv: list[str]) -> int:
    body_json, output = argv
    try:
        value = json.loads(body_json)
        hits = value.get("hits") if isinstance(value, dict) else None
        if not isinstance(hits, list) or not all(isinstance(hit, dict) for hit in hits):
            return 1
    except json.JSONDecodeError:
        return 1
    write_json(output, hits)
    return 0


def safe_peer_host(argv: list[str]) -> int:
    """Print the host's private non-loopback IPv4, or exit 1 when none exists.

    Flapjack's replication config rejects loopback and localhost peer origins, so
    peers must advertise a non-loopback address. This helper intentionally refuses
    public internet addresses because the live probe's HA mode runs without auth;
    only RFC1918/private addresses are eligible. A UDP connect to a TEST-NET
    address only fixes the outbound route (no packets are sent), so this never
    depends on external reachability.
    """
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("192.0.2.1", 9))
        host = probe.getsockname()[0]
        probe.close()
        ip = ipaddress.ip_address(host)
    except OSError:
        return 1
    if (
        ip.is_loopback
        or ip.is_link_local
        or ip.is_unspecified
        or ip.is_multicast
        or not ip.is_private
    ):
        return 1
    print(host)
    return 0


def write_peer_node_config(argv: list[str]) -> int:
    path, node_id, bind_addr, peer_id, peer_url = argv
    write_json(
        path,
        {
            "node_id": node_id,
            "bind_addr": bind_addr,
            "peers": [{"node_id": peer_id, "addr": peer_url}],
        },
    )
    return 0


def cleanup_counts(argv: list[str]) -> int:
    print(
        json.dumps(
            {key: int(value) for key, value in zip(ORDERED_CLEANUP_KEYS, argv)},
            separators=(",", ":"),
        )
    )
    return 0


def stamp_cleanup(argv: list[str]) -> int:
    evidence_path, cleanup = argv
    document = read_json(evidence_path)
    if not isinstance(document, dict):
        return 1
    document["cleanup"] = json.loads(cleanup)
    document["indeterminate"] = False
    write_json(evidence_path, document)
    return 0


def ha_refusal(argv: list[str]) -> int:
    peer_count = int(argv[0])
    status = int(argv[1])
    body = json.loads(argv[2])
    if peer_count < 1 or status != 503 or body != EXPECTED_HA_RESPONSE:
        return 1
    print(
        json.dumps(
            {"peer_count": peer_count, "http_status": status, "response": body},
            separators=(",", ":"),
        )
    )
    return 0


def rebind_ha_refusal_peer_count(argv: list[str]) -> int:
    refusal = json.loads(argv[0])
    peer_count = int(argv[1])
    if set(refusal) != {"peer_count", "http_status", "response"}:
        return 1
    if refusal["http_status"] != 503 or refusal["response"] != EXPECTED_HA_RESPONSE:
        return 1
    refusal["peer_count"] = peer_count
    print(json.dumps(refusal, separators=(",", ":")))
    return 0


def assert_parity(argv: list[str]) -> int:
    report_path, fixture_path, expected_count, expected_ids = argv
    report = read_json(report_path)
    fixture = read_json(fixture_path)
    object_ids = ",".join(sorted(item["objectID"] for item in fixture))
    expected = {
        "count_source": int(expected_count),
        "count_migrated": int(expected_count),
        "only_in_source": [],
        "only_in_migrated": [],
        "field_mismatches": [],
    }
    return 0 if report == expected and object_ids == expected_ids else 1


def write_evidence(argv: list[str]) -> int:
    (
        output,
        repo_sha,
        binary_sha,
        source_revision,
        standalone_peer_count,
        standalone_docker,
        ha_peer_count,
        ha_docker,
        create_source,
        create_target,
        create_parity,
        create_outcome,
        overwrite_source,
        overwrite_target,
        overwrite_parity,
        overwrite_outcome,
        ha_create_refusal,
        ha_overwrite_refusal,
        cleanup,
        stale_destination_object_ids,
    ) = argv
    document = {
        "schema_version": 1,
        "repo_sha": repo_sha,
        "flapjack_identity": {
            "binary_sha256": binary_sha,
            "source_revision": source_revision,
        },
        "topology": {
            "standalone": {
                "peer_count": int(standalone_peer_count),
                "docker": standalone_docker == "true",
            },
            "ha": {"peer_count": int(ha_peer_count), "docker": ha_docker == "true"},
        },
        "branch_denominator": EXPECTED_BRANCH_DENOMINATOR,
        "node_local_create": {
            "http_status": 202,
            "response": migration_response(create_outcome, create_parity),
            "source_objects": read_json(create_source),
            "target_objects": read_json(create_target),
            "parity": read_json(create_parity),
        },
        "node_local_overwrite": {
            "http_status": 202,
            "response": migration_response(overwrite_outcome, overwrite_parity),
            "source_objects": read_json(overwrite_source),
            "target_objects": read_json(overwrite_target),
            "parity": read_json(overwrite_parity),
            "stale_destination_object_ids": json.loads(stale_destination_object_ids),
        },
        "ha_create_refusal": json.loads(ha_create_refusal),
        "ha_overwrite_refusal": json.loads(ha_overwrite_refusal),
        "cleanup": json.loads(cleanup),
        # The candidate is written before cleanup is measured. stamp_cleanup
        # is the sole promotion point that can make it classifier-eligible.
        "indeterminate": True,
    }
    write_json(output, document)
    return 0


def main(argv: list[str]) -> int:
    commands = {
        "cleanup-counts": cleanup_counts,
        "stamp-cleanup": stamp_cleanup,
        "ha-refusal": ha_refusal,
        "rebind-ha-refusal-peer-count": rebind_ha_refusal_peer_count,
        "assert-parity": assert_parity,
        "peer-node-config": write_peer_node_config,
        "safe-peer-host": safe_peer_host,
        "free-port": free_port,
        "batch-add-payload": batch_add_payload,
        "extract-hits": extract_hits,
        "capture-outcome": capture_outcome,
        "write-evidence": write_evidence,
    }
    expected_arity = {
        "cleanup-counts": 5,
        "stamp-cleanup": 2,
        "ha-refusal": 3,
        "rebind-ha-refusal-peer-count": 2,
        "assert-parity": 4,
        "peer-node-config": 5,
        "safe-peer-host": 0,
        "free-port": 0,
        "batch-add-payload": 2,
        "extract-hits": 2,
        "capture-outcome": 2,
        "write-evidence": 20,
    }
    if not argv or argv[0] not in commands:
        return 2
    command = argv[0]
    if len(argv[1:]) != expected_arity[command]:
        return 2
    try:
        return commands[command](argv[1:])
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
