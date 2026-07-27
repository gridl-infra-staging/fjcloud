#!/usr/bin/env python3
"""Known-answer test for live migration evidence assembly and promotion."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

CREATE_OBJECTS = [
    {"objectID": "create-doc-1", "title": "Quartz adapter", "category": "hardware"},
    {"objectID": "create-doc-2", "title": "Velvet compass", "category": "navigation"},
]
OVERWRITE_OBJECTS = [
    {"objectID": "overwrite-doc-1", "title": "Copper relay", "category": "hardware"},
    {"objectID": "overwrite-doc-2", "title": "Basalt lens", "category": "optics"},
    {"objectID": "overwrite-doc-3", "title": "Amber gauge", "category": "metrology"},
]
BENIGN_WARNINGS = [
    {
        "code": "PersistedNoBehaviorSetting",
        "message": (
            "Source setting is preserved for compatibility but has no "
            "Flapjack behavior."
        ),
        "resource": "Settings",
        "jsonPath": "$.hitsPerPage",
    },
    {
        "code": "ReadOnlySourceField",
        "message": (
            "Source field is read-only in Flapjack and is not applied "
            "during migration."
        ),
        "resource": "Settings",
        "jsonPath": "$.version",
    },
]
HA_REFUSAL = {
    "peer_count": 1,
    "http_status": 503,
    "response": {
        "message": (
            "Algolia migration import is unavailable on HA clusters until MIG-7 "
            "supplies a costed convergence protocol."
        ),
        "status": 503,
        "code": "migration_ha_unsupported",
    },
}
CLEANUP = {
    "algolia_indexes": 0,
    "flapjack_indexes": 0,
    "algolia_keys": 0,
    "local_stack": 0,
    "runtime_files": 0,
}


def parity(objects: list[dict[str, str]]) -> dict[str, Any]:
    return {
        "count_source": len(objects),
        "count_migrated": len(objects),
        "only_in_source": [],
        "only_in_migrated": [],
        "field_mismatches": [],
    }


def write_json(directory: Path, name: str, value: Any) -> str:
    path = directory / name
    path.write_text(json.dumps(value), encoding="utf-8")
    return str(path)


def write_specimen_inputs(directory: Path) -> list[str]:
    outcome_base = {
        "disposition": "succeeded",
        "settings": True,
        "synonyms": 0,
        "rules": 0,
        "warnings": BENIGN_WARNINGS,
    }
    create_outcome = {**outcome_base, "terminal_at": "2026-07-26T00:00:00Z"}
    overwrite_outcome = {**outcome_base, "terminal_at": "2026-07-26T00:00:01Z"}
    return [
        write_json(directory, "create_source.json", CREATE_OBJECTS),
        write_json(directory, "create_target.json", CREATE_OBJECTS),
        write_json(directory, "create_parity.json", parity(CREATE_OBJECTS)),
        write_json(directory, "create_outcome.json", create_outcome),
        write_json(directory, "overwrite_source.json", OVERWRITE_OBJECTS),
        write_json(directory, "overwrite_target.json", OVERWRITE_OBJECTS),
        write_json(directory, "overwrite_parity.json", parity(OVERWRITE_OBJECTS)),
        write_json(directory, "overwrite_outcome.json", overwrite_outcome),
    ]


def write_candidate(directory: Path, helper: str) -> Path:
    evidence = directory / "evidence.json"
    command = [
        "python3",
        helper,
        "write-evidence",
        str(evidence),
        "0123456789abcdef0123456789abcdef01234567",
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "89abcdef0123456789abcdef0123456789abcdef",
        "0",
        "false",
        "1",
        "false",
        *write_specimen_inputs(directory),
        json.dumps(HA_REFUSAL),
        json.dumps(HA_REFUSAL),
        json.dumps(CLEANUP),
        "[]",
    ]
    subprocess.run(command, check=True)
    return evidence


def assert_candidate_shape(evidence: Path) -> None:
    document = json.loads(evidence.read_text(encoding="utf-8"))
    create = document["node_local_create"]
    assert document["indeterminate"] is True
    assert create["http_status"] == 202
    assert create["response"]["disposition"] == "succeeded"
    assert create["response"]["terminal_at"] == "2026-07-26T00:00:00Z"
    assert "status" not in create["response"]
    assert "taskID" not in create["response"]
    assert create["response"]["warnings"] == BENIGN_WARNINGS
    assert create["response"]["objects"] == {"imported": 2}
    assert document["node_local_overwrite"]["response"]["objects"] == {"imported": 3}


def classify(classifier: str, evidence: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", classifier, str(evidence)],
        capture_output=True,
        text=True,
        check=False,
    )


def main(argv: list[str]) -> int:
    directory, helper, classifier = Path(argv[0]), argv[1], argv[2]
    evidence = write_candidate(directory, helper)
    assert_candidate_shape(evidence)
    result = classify(classifier, evidence)
    assert result.returncode == 1, result.stdout + result.stderr
    assert result.stdout.strip().endswith("FAIL reason=indeterminate")
    subprocess.run(
        ["python3", helper, "stamp-cleanup", str(evidence), json.dumps(CLEANUP)],
        check=True,
    )
    result = classify(classifier, evidence)
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.strip().endswith("PASS reason=verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
