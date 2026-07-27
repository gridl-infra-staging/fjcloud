#!/usr/bin/env python3
"""Fail-closed classifier for local multinode migration evidence."""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


class MalformedEvidence(Exception):
    """Evidence does not match the closed Stage 2 schema."""


class StaleEvidence(Exception):
    """Evidence was captured from a different repository revision."""


EXPECTED_HA_RESPONSE = {
    "message": (
        "Algolia migration import is unavailable on HA clusters until MIG-7 supplies "
        "a costed convergence protocol."
    ),
    "status": 503,
    "code": "migration_ha_unsupported",
}
EXPECTED_BRANCH_DENOMINATOR = [
    "node_local_create",
    "node_local_overwrite",
    "ha_create_refusal",
    "ha_overwrite_refusal",
    "parity",
    "cleanup",
]
TOP_LEVEL_KEYS = {
    "schema_version",
    "repo_sha",
    "flapjack_identity",
    "topology",
    "branch_denominator",
    "node_local_create",
    "node_local_overwrite",
    "ha_create_refusal",
    "ha_overwrite_refusal",
    "cleanup",
    "indeterminate",
}
FLAPJACK_IDENTITY_KEYS = {"binary_sha256", "source_revision"}
TOPOLOGY_KEYS = {"standalone", "ha"}
TOPOLOGY_NODE_KEYS = {"peer_count", "docker"}
SCENARIO_KEYS = {"http_status", "response", "source_objects", "target_objects", "parity"}
OVERWRITE_KEYS = SCENARIO_KEYS | {"stale_destination_object_ids"}
RESPONSE_REQUIRED_KEYS = {
    "disposition",
    "terminal_at",
    "settings",
    "synonyms",
    "rules",
    "objects",
}
RESPONSE_OPTIONAL_KEYS = {"warnings"}
WARNING_REQUIRED_KEYS = {"code", "message", "resource", "jsonPath"}
WARNING_OPTIONAL_KEYS = {"pageIndex", "itemIndex"}
# Real Algolia GET /settings always returns default warning-owned fields, so a
# genuine migration of even a minimal source always emits settings-passthrough
# warnings. These are benign: Flapjack either persists the value without runtime
# behavior or treats the source field as read-only. Any other warning code (e.g. a
# replica-topology warning on a replica-free source) signals a real migration
# fidelity problem and must fail closed. Owned here as the classifier is the sole
# arbiter of the live verdict; see scripts/local_multinode_migration_probe.sh.
BENIGN_WARNING_RESOURCE = "Settings"
BENIGN_WARNING_CODES = {"PersistedNoBehaviorSetting", "ReadOnlySourceField"}
COUNT_KEYS = {"imported"}
PARITY_KEYS = {
    "count_source",
    "count_migrated",
    "only_in_source",
    "only_in_migrated",
    "field_mismatches",
}
HA_KEYS = {"peer_count", "http_status", "response"}
HA_RESPONSE_KEYS = {"message", "status", "code"}
GENERIC_HA_MESSAGES = {"Service unavailable", "Unavailable", "HA unavailable"}
GENERIC_HA_CODES = {"service_unavailable", "unavailable"}
ORDERED_CLEANUP_KEYS = (
    "algolia_indexes",
    "flapjack_indexes",
    "algolia_keys",
    "local_stack",
    "runtime_files",
)
RESIDUE_KEYS = set(ORDERED_CLEANUP_KEYS)


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise MalformedEvidence
        result[key] = value
    return result


def parse_evidence(path: str) -> Any:
    try:
        raw = Path(path).read_text(encoding="utf-8")
        return json.loads(raw, object_pairs_hook=reject_duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError, MalformedEvidence):
        raise MalformedEvidence from None


def exact_keys(value: Any, expected: set[str]) -> None:
    if not isinstance(value, dict) or set(value) != expected:
        raise MalformedEvidence


def require_bool(value: Any) -> bool:
    if type(value) is not bool:
        raise MalformedEvidence
    return value


def require_non_negative_int(value: Any) -> int:
    if type(value) is not int or value < 0:
        raise MalformedEvidence
    return value


def require_string(value: Any) -> str:
    if not isinstance(value, str) or value == "":
        raise MalformedEvidence
    return value


def require_utc_timestamp(value: Any) -> str:
    text = require_string(value)
    if re.fullmatch(
        r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z", text
    ) is None:
        raise MalformedEvidence
    try:
        datetime.fromisoformat(text.removesuffix("Z") + "+00:00")
    except ValueError:
        raise MalformedEvidence from None
    return text


def require_string_list(value: Any) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise MalformedEvidence
    return value


def require_list(value: Any) -> list[Any]:
    if not isinstance(value, list):
        raise MalformedEvidence
    return value


def validate_count_object(value: Any) -> int:
    exact_keys(value, COUNT_KEYS)
    return require_non_negative_int(value["imported"])


def validate_warning(value: Any) -> None:
    if not isinstance(value, dict):
        raise MalformedEvidence
    keys = set(value)
    if WARNING_REQUIRED_KEYS - keys or keys - WARNING_REQUIRED_KEYS - WARNING_OPTIONAL_KEYS:
        raise MalformedEvidence
    for key in sorted(WARNING_REQUIRED_KEYS):
        require_string(value[key])
    for key in sorted(WARNING_OPTIONAL_KEYS & keys):
        require_non_negative_int(value[key])


def warning_is_benign(value: dict[str, Any]) -> bool:
    return (
        value["resource"] == BENIGN_WARNING_RESOURCE
        and value["code"] in BENIGN_WARNING_CODES
    )


def validate_response(value: Any, expected_objects: int) -> tuple[bool, bool]:
    if not isinstance(value, dict):
        raise MalformedEvidence
    keys = set(value)
    if RESPONSE_REQUIRED_KEYS - keys or keys - RESPONSE_REQUIRED_KEYS - RESPONSE_OPTIONAL_KEYS:
        raise MalformedEvidence
    disposition = require_string(value["disposition"])
    require_utc_timestamp(value["terminal_at"])
    settings = require_bool(value["settings"])
    synonyms_imported = validate_count_object(value["synonyms"])
    rules_imported = validate_count_object(value["rules"])
    objects_imported = validate_count_object(value["objects"])
    has_unexpected_warning = False
    if "warnings" in value:
        warnings = require_list(value["warnings"])
        # Flapjack skips an empty Vec on the wire, so an explicit empty array is an
        # off-wire shape that must be rejected rather than treated as clean.
        if not warnings:
            raise MalformedEvidence
        for warning in warnings:
            validate_warning(warning)
        has_unexpected_warning = any(not warning_is_benign(w) for w in warnings)
    response_ok = (
        disposition == "succeeded"
        and settings is True
        and synonyms_imported == 0
        and rules_imported == 0
        and objects_imported == expected_objects
        and not has_unexpected_warning
    )
    return response_ok, has_unexpected_warning


def objects_by_id(value: Any) -> tuple[dict[str, dict[str, Any]], bool]:
    items = require_list(value)
    by_id: dict[str, dict[str, Any]] = {}
    duplicate = False
    for item in items:
        if not isinstance(item, dict):
            raise MalformedEvidence
        object_id = require_string(item.get("objectID"))
        if object_id in by_id:
            duplicate = True
        by_id[object_id] = {key: item[key] for key in sorted(item)}
    return by_id, duplicate


def validate_parity(
    value: Any, source_by_id: dict[str, Any], target_by_id: dict[str, Any]
) -> bool:
    exact_keys(value, PARITY_KEYS)
    count_source = require_non_negative_int(value["count_source"])
    count_migrated = require_non_negative_int(value["count_migrated"])
    only_in_source = require_string_list(value["only_in_source"])
    only_in_migrated = require_string_list(value["only_in_migrated"])
    field_mismatches = require_list(value["field_mismatches"])
    if any(not isinstance(item, dict) for item in field_mismatches):
        raise MalformedEvidence
    return (
        count_source == len(source_by_id)
        and count_migrated == len(target_by_id)
        and only_in_source == []
        and only_in_migrated == []
        and field_mismatches == []
        and source_by_id == target_by_id
    )


def validate_scenario(
    value: Any, expected_objects: int, overwrite: bool
) -> tuple[bool, bool, bool]:
    exact_keys(value, OVERWRITE_KEYS if overwrite else SCENARIO_KEYS)
    http_status = require_non_negative_int(value["http_status"])
    response_ok, has_unexpected_warning = validate_response(
        value["response"], expected_objects
    )
    source_by_id, source_duplicate = objects_by_id(value["source_objects"])
    target_by_id, target_duplicate = objects_by_id(value["target_objects"])
    parity_ok = validate_parity(value["parity"], source_by_id, target_by_id)
    stale_destination_object_ids = (
        require_string_list(value["stale_destination_object_ids"]) if overwrite else []
    )
    has_duplicate = source_duplicate or target_duplicate
    scenario_ok = (
        http_status == 202
        and response_ok
        and not has_duplicate
        and parity_ok
        and stale_destination_object_ids == []
    )
    return scenario_ok, has_duplicate, has_unexpected_warning


def classify_ha_refusal(value: Any) -> str | None:
    exact_keys(value, HA_KEYS)
    peer_count = require_non_negative_int(value["peer_count"])
    http_status = require_non_negative_int(value["http_status"])
    exact_keys(value["response"], HA_RESPONSE_KEYS)
    message = require_string(value["response"]["message"])
    status = require_non_negative_int(value["response"]["status"])
    code = require_string(value["response"]["code"])
    if peer_count < 1:
        return "ha_peer_count_invalid"
    if http_status != 503 or status != 503:
        return "ha_contract_mismatch"
    if value["response"] == EXPECTED_HA_RESPONSE:
        return None
    if message in GENERIC_HA_MESSAGES or code in GENERIC_HA_CODES:
        return "generic_ha_refusal"
    return "ha_contract_mismatch"


def cleanup_has_residue(value: Any) -> bool:
    exact_keys(value, RESIDUE_KEYS)
    counts = [require_non_negative_int(value[key]) for key in ORDERED_CLEANUP_KEYS]
    return any(count != 0 for count in counts)


def require_lower_hex(value: Any, length: int) -> None:
    text = require_string(value)
    if len(text) != length or any(char not in "0123456789abcdef" for char in text):
        raise MalformedEvidence


def validate_provenance(document: dict[str, Any], current_repo_sha: str | None) -> None:
    require_lower_hex(document["repo_sha"], 40)
    if current_repo_sha is not None:
        require_lower_hex(current_repo_sha, 40)
        if document["repo_sha"] != current_repo_sha:
            raise StaleEvidence
    identity = document["flapjack_identity"]
    exact_keys(identity, FLAPJACK_IDENTITY_KEYS)
    require_lower_hex(identity["binary_sha256"], 64)
    require_lower_hex(identity["source_revision"], 40)
    topology = document["topology"]
    exact_keys(topology, TOPOLOGY_KEYS)
    for node in topology.values():
        exact_keys(node, TOPOLOGY_NODE_KEYS)
        require_non_negative_int(node["peer_count"])
        require_bool(node["docker"])
    if topology["standalone"]["peer_count"] != 0 or topology["ha"]["peer_count"] < 1:
        raise MalformedEvidence


def validate_top_level(document: Any, current_repo_sha: str | None) -> None:
    exact_keys(document, TOP_LEVEL_KEYS)
    if require_non_negative_int(document["schema_version"]) != 1:
        raise MalformedEvidence
    if document["branch_denominator"] != EXPECTED_BRANCH_DENOMINATOR:
        raise MalformedEvidence
    require_bool(document["indeterminate"])
    validate_provenance(document, current_repo_sha)


def classify_document(
    document: Any, current_repo_sha: str | None = None
) -> tuple[str, str, int]:
    validate_top_level(document, current_repo_sha)
    create_ok, create_duplicate, create_bad_warning = validate_scenario(
        document["node_local_create"], expected_objects=2, overwrite=False
    )
    overwrite_ok, overwrite_duplicate, overwrite_bad_warning = validate_scenario(
        document["node_local_overwrite"], expected_objects=3, overwrite=True
    )
    ha_create_reason = classify_ha_refusal(document["ha_create_refusal"])
    ha_overwrite_reason = classify_ha_refusal(document["ha_overwrite_refusal"])
    if ha_overwrite_reason == "ha_contract_mismatch":
        ha_overwrite_reason = "ha_overwrite_contract_mismatch"
    cleanup_residue = cleanup_has_residue(document["cleanup"])
    if document["indeterminate"]:
        return "FAIL", "indeterminate", 1
    if create_duplicate or overwrite_duplicate:
        return "FAIL", "duplicate_object_ids", 1
    if create_bad_warning or overwrite_bad_warning:
        return "FAIL", "unexpected_migration_warning", 1
    if not create_ok or not overwrite_ok:
        if require_string_list(document["node_local_overwrite"]["stale_destination_object_ids"]):
            return "FAIL", "stale_destination_survivors", 1
        return "FAIL", "parity_mismatch", 1
    if ha_create_reason is not None:
        return "FAIL", ha_create_reason, 1
    if ha_overwrite_reason is not None:
        return "FAIL", ha_overwrite_reason, 1
    if cleanup_residue:
        return "FAIL", "cleanup_residue", 1
    return "PASS", "verified", 0


def main(argv: list[str]) -> int:
    if len(argv) not in {1, 2}:
        return 2
    current_repo_sha = argv[1] if len(argv) == 2 else None
    try:
        status, reason, exit_code = classify_document(
            parse_evidence(argv[0]), current_repo_sha
        )
    except StaleEvidence:
        status, reason, exit_code = "FAIL", "stale_repo_sha", 1
    except (KeyError, IndexError, MalformedEvidence):
        status, reason, exit_code = "FAIL", "malformed", 1
    print(f"LOCAL_MULTINODE_MIGRATION_STATUS: {status} reason={reason}")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
