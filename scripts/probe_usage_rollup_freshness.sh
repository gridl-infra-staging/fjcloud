#!/usr/bin/env bash
# Deterministic classifier for normalized usage-rollup freshness evidence.
#
# This owner reads one local JSON document and emits one classification token.
# Collection, database access, snapshot registration, and summary rendering
# belong to the live-state probe.

set -uo pipefail

usage() {
    echo "usage: probe_usage_rollup_freshness.sh --evidence <local-json-path>" >&2
}

if [ "$#" -ne 2 ] || [ "${1:-}" != "--evidence" ]; then
    usage
    exit 2
fi

evidence_path="$2"
if [ ! -f "$evidence_path" ] || [ ! -r "$evidence_path" ]; then
    echo "probe_usage_rollup_freshness: evidence is not readable" >&2
    exit 2
fi

classification="$(
    python3 - "$evidence_path" 2>/dev/null <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


class MalformedEvidence(Exception):
    pass


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise MalformedEvidence
        result[key] = value
    return result


def parse_evidence(path):
    try:
        raw = Path(path).read_text(encoding="utf-8")
        return json.loads(raw, object_pairs_hook=reject_duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError, MalformedEvidence):
        raise MalformedEvidence from None


def is_non_negative_integer(value):
    return type(value) is int and value >= 0


def is_utc_timestamp(value):
    if not isinstance(value, str) or not value:
        return False
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return False
    return parsed.tzinfo is not None and parsed.utcoffset() == timezone.utc.utcoffset(parsed)


def validate_and_classify(document):
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise MalformedEvidence
    if type(document["schema_version"]) is not int:
        raise MalformedEvidence

    query_outcome = document.get("query_outcome")
    if query_outcome == "failed":
        if set(document) != {"schema_version", "query_outcome"}:
            raise MalformedEvidence
        return ("PROBE_ERROR", "query_failed", 1)

    expected_keys = {
        "schema_version",
        "query_outcome",
        "total_rows",
        "fresh_rows",
        "latest_aggregated_at",
    }
    if query_outcome != "ok" or set(document) != expected_keys:
        raise MalformedEvidence

    total_rows = document["total_rows"]
    fresh_rows = document["fresh_rows"]
    latest_aggregated_at = document["latest_aggregated_at"]
    if not is_non_negative_integer(total_rows) or not is_non_negative_integer(fresh_rows):
        raise MalformedEvidence
    if fresh_rows > total_rows:
        raise MalformedEvidence
    if total_rows == 0:
        if fresh_rows != 0 or latest_aggregated_at is not None:
            raise MalformedEvidence
        return ("ACTION_REQUIRED", "no_rollups", 1)
    if not is_utc_timestamp(latest_aggregated_at):
        raise MalformedEvidence
    if fresh_rows > 0:
        return ("OK", "fresh_rollups_present", 0)
    return ("ACTION_REQUIRED", "rollups_stale", 1)


try:
    status, reason, exit_code = validate_and_classify(parse_evidence(sys.argv[1]))
except (KeyError, MalformedEvidence):
    status, reason, exit_code = ("PROBE_ERROR", "malformed_evidence", 1)

print(f"USAGE_ROLLUP_FRESHNESS_STATUS: {status} reason={reason}")
raise SystemExit(exit_code)
PY
)"
classifier_rc=$?

case "$classifier_rc" in
    0|1)
        printf '%s\n' "$classification"
        exit "$classifier_rc"
        ;;
    *)
        echo "probe_usage_rollup_freshness: classifier failed internally" >&2
        exit 2
        ;;
esac
