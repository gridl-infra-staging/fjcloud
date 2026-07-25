#!/usr/bin/env bash
# Local real-pipeline probe: run the real local stack end-to-end and prove the
# resulting usage_daily row equals a two-scrape /metrics delta.
#
# Four modes, one owner:
#   (no arguments)                 Full mode. Prepares .env.local, brings up the
#                                  real local stack (Postgres, API, flapjack),
#                                  drives known metered traffic between two
#                                  metering-agent scrapes, runs the real
#                                  aggregation job, then classifies the produced
#                                  row by re-invoking itself in classifier mode.
#   --negative-seeded              Negative live mode. Runs the same stack and
#                                  seed path, skips clearing and traffic, runs
#                                  aggregation, then proves the seeded row is
#                                  rejected by the classifier.
#   --negative-nodrive             Negative live mode. Clears the scoped rows,
#                                  skips traffic, runs aggregation once, then
#                                  proves no produced row is rejected.
#   --assert-evidence <json-path>  Classifier mode. Pure, no-live-side-effect
#                                  known-answer classifier over one local JSON
#                                  document. Answers "did this pipeline run
#                                  produce this exact row value?" and emits one
#                                  status token. Starts no Docker/Postgres/
#                                  flapjack/AWS/collector.
#
# This owner is distinct from scripts/probe_usage_rollup_freshness.sh, which
# answers the unrelated "is some rollup fresh?" question.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# REPO_ROOT is consumed by the full-mode orchestration module sourced below.
# shellcheck disable=SC2034
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    echo "usage: local_real_pipeline_probe.sh                      # run the full local pipeline" >&2
    echo "       local_real_pipeline_probe.sh --negative-seeded" >&2
    echo "       local_real_pipeline_probe.sh --negative-nodrive" >&2
    echo "       local_real_pipeline_probe.sh --assert-evidence <local-json-path>" >&2
}

# ===========================================================================
# Classifier mode (Stage 1 owner) — pure, no live side effects.
# ===========================================================================

# Classify one local evidence JSON document. Prints the status token on stdout
# and returns 0 (PASS), 1 (FAIL), or 2 (classifier failed internally).
classify_evidence() {
    local evidence_path="$1" classification classifier_rc

    classification="$(
        python3 - "$evidence_path" 2>/dev/null <<'PY'
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


class MalformedEvidence(Exception):
    pass


ISO_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

# Canonical UTC timestamp shape: an uppercase `T` separator, a full HH:MM:SS
# time with an optional fractional part, and either a `Z` suffix or an explicit
# numeric offset. `datetime.fromisoformat()` alone accepts non-canonical shapes
# (space-separated `2026-07-24 10:00:00+00:00`, lowercase-`t`), so this gate
# runs first to fail those closed as malformed evidence.
UTC_TIMESTAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$")


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
    # `type(value) is int` deliberately rejects bool, which is an int subclass.
    return type(value) is int and value >= 0


def is_iso_date(value):
    if not isinstance(value, str) or not ISO_DATE_RE.fullmatch(value):
        return False
    try:
        datetime.strptime(value, "%Y-%m-%d")
    except ValueError:
        return False
    return True


def parse_utc_timestamp(value):
    if not isinstance(value, str) or not UTC_TIMESTAMP_RE.fullmatch(value):
        return None
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is None or parsed.utcoffset() != timezone.utc.utcoffset(parsed):
        return None
    return parsed


EXPECTED_KEYS = {
    "schema_version",
    "customer_id",
    "region",
    "target_date",
    "cleared_before",
    "expected_search",
    "expected_write",
    "probe_started_at",
    "rows_affected",
    "search_requests",
    "write_operations",
    "aggregated_at",
    # Identity of the row the aggregation actually wrote, echoed back alongside
    # the counters. Compared against the requested customer/region/date so the
    # PASS verdict proves the exact seeded specimen, not just matching counters
    # from any row (scripts/seed_local.sh writes identical 250000/25000 counters
    # to many usage_daily rows). Absent when the row is absent (see row_fields).
    "row_customer_id",
    "row_region",
    "row_target_date",
}


def validate_schema(document):
    # Exact key set: missing or extra fields are malformed. Row absence must be
    # expressed with null row fields, never by omitting them.
    if not isinstance(document, dict) or set(document) != EXPECTED_KEYS:
        raise MalformedEvidence
    if type(document["schema_version"]) is not int or document["schema_version"] != 1:
        raise MalformedEvidence
    for text_field in ("customer_id", "region"):
        if not isinstance(document[text_field], str) or not document[text_field]:
            raise MalformedEvidence
    if not is_iso_date(document["target_date"]):
        raise MalformedEvidence
    if type(document["cleared_before"]) is not bool:
        raise MalformedEvidence
    for counter_field in ("expected_search", "expected_write", "rows_affected"):
        if not is_non_negative_integer(document[counter_field]):
            raise MalformedEvidence
    if parse_utc_timestamp(document["probe_started_at"]) is None:
        raise MalformedEvidence

    # A row carries its counters, freshness stamp, and identity together, so
    # they are all present for a real row and all null for an absent row.
    row_fields = (
        "search_requests",
        "write_operations",
        "aggregated_at",
        "row_customer_id",
        "row_region",
        "row_target_date",
    )
    present = [document[name] is not None for name in row_fields]
    if any(present) and not all(present):
        # Partial absence is ambiguous evidence, not a real absent row.
        raise MalformedEvidence
    if all(present):
        if not is_non_negative_integer(document["search_requests"]):
            raise MalformedEvidence
        if not is_non_negative_integer(document["write_operations"]):
            raise MalformedEvidence
        if parse_utc_timestamp(document["aggregated_at"]) is None:
            raise MalformedEvidence
        for identity_field in ("row_customer_id", "row_region"):
            if not isinstance(document[identity_field], str) or not document[identity_field]:
                raise MalformedEvidence
        if not is_iso_date(document["row_target_date"]):
            raise MalformedEvidence


def validate_and_classify(document):
    validate_schema(document)

    # Deterministic fail precedence; PASS is reached only when every invariant
    # below holds.
    if document["cleared_before"] is not True:
        return ("FAIL", "not_cleared", 1)
    if document["aggregated_at"] is None:
        return ("FAIL", "absent", 1)
    if document["rows_affected"] == 0:
        return ("FAIL", "zero_rows_affected", 1)
    # A row was written, but is it the requested specimen? Matching counters
    # alone do not prove it because the seed reuses identical counters across
    # many rows, so the row must echo the requested customer/region/date.
    if (
        document["row_customer_id"] != document["customer_id"]
        or document["row_region"] != document["region"]
        or document["row_target_date"] != document["target_date"]
    ):
        return ("FAIL", "row_identity_mismatch", 1)
    # probe_started_at is a DB-clock instant recorded before the run (Stage 2);
    # a rollup stamped earlier than it is a stale row from a prior cycle.
    if parse_utc_timestamp(document["aggregated_at"]) < parse_utc_timestamp(
        document["probe_started_at"]
    ):
        return ("FAIL", "stale", 1)
    # The fixed 250000/25000 usage_daily seed in scripts/seed_local.sh is a seed
    # discriminator: an exact counter match proves the aggregation wrote the
    # values from this run, not a leftover row from an earlier seed.
    if (
        document["search_requests"] != document["expected_search"]
        or document["write_operations"] != document["expected_write"]
    ):
        return ("FAIL", "value_mismatch", 1)
    return ("PASS", "verified", 0)


try:
    status, reason, exit_code = validate_and_classify(parse_evidence(sys.argv[1]))
except (KeyError, MalformedEvidence):
    status, reason, exit_code = ("FAIL", "malformed", 1)

print(f"LOCAL_REAL_PIPELINE_STATUS: {status} reason={reason}")
raise SystemExit(exit_code)
PY
    )"
    classifier_rc=$?

    # Only classifier exits 0 (PASS) and 1 (FAIL) are expected verdicts. Any
    # other exit means the classifier itself failed and must not masquerade as
    # a verdict.
    case "$classifier_rc" in
        0|1)
            printf '%s\n' "$classification"
            return "$classifier_rc"
            ;;
        *)
            echo "local_real_pipeline_probe: classifier failed internally" >&2
            return 2
            ;;
    esac
}

run_assert_evidence_mode() {
    local evidence_path="$1"

    if [ ! -f "$evidence_path" ] || [ ! -r "$evidence_path" ]; then
        echo "local_real_pipeline_probe: evidence is not readable" >&2
        exit 2
    fi

    classify_evidence "$evidence_path"
    exit $?
}

# ===========================================================================
# Full mode (Stage 2 owner) — real local stack orchestration.
# ===========================================================================
# The full-mode implementation lives in a sourced sibling so the classifier
# mode above stays a pure, dependency-free known-answer classifier. The
# orchestration owner is loaded only on the full-mode path.

# ===========================================================================
# Argument dispatch.
# ===========================================================================

if [ "$#" -eq 0 ]; then
    # shellcheck source=lib/local_real_pipeline_run.sh
    source "$SCRIPT_DIR/lib/local_real_pipeline_run.sh"
    run_full_local_pipeline
    exit $?
elif [ "${1:-}" = "--assert-evidence" ]; then
    if [ "$#" -ne 2 ]; then
        usage
        exit 2
    fi
    run_assert_evidence_mode "$2"
elif [ "${1:-}" = "--negative-seeded" ]; then
    if [ "$#" -ne 1 ]; then
        usage
        exit 2
    fi
    # shellcheck source=lib/local_real_pipeline_run.sh
    source "$SCRIPT_DIR/lib/local_real_pipeline_run.sh"
    run_negative_seeded_local_pipeline
    exit $?
elif [ "${1:-}" = "--negative-nodrive" ]; then
    if [ "$#" -ne 1 ]; then
        usage
        exit 2
    fi
    # shellcheck source=lib/local_real_pipeline_run.sh
    source "$SCRIPT_DIR/lib/local_real_pipeline_run.sh"
    run_negative_nodrive_local_pipeline
    exit $?
else
    usage
    exit 2
fi
