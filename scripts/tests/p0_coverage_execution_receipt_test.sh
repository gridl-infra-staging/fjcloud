#!/usr/bin/env bash
# Fail-closed execution-evidence guard for the three routine-local P0 skip rows.
#
# Stage 1 intentionally leaves this guard RED at repository HEAD: later stages
# must create runner-owned receipt and raw-log evidence before it can pass.
set -uo pipefail

usage() {
    echo "usage: p0_coverage_execution_receipt_test.sh [--evidence-root <directory>]" >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
evidence_root="$REPO_ROOT/docs/runbooks/evidence/local-p0-coverage"

case "$#" in
    0)
        ;;
    2)
        if [ "${1:-}" != "--evidence-root" ] || [ -z "${2:-}" ]; then
            usage
            exit 2
        fi
        evidence_root="$2"
        ;;
    *)
        usage
        exit 2
        ;;
esac

python3 - \
    "$evidence_root" \
    "$REPO_ROOT/scripts/probe_launch_evidence_freshness.sh" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


EVIDENCE_ROOT = Path(sys.argv[1])
FRESHNESS_OWNER = Path(sys.argv[2])
EXPECTED_SPECS = {
    "B2": "web/tests/e2e-ui/full/billing_portal_payment_method_update.spec.ts",
    "B7": "web/tests/e2e-ui/full/upgrade_to_shared_unmocked.spec.ts",
    "B21": "web/tests/e2e-ui/full/auth-end-effects.spec.ts",
}
REQUIRED_FIELDS = (
    "row_id",
    "spec_path",
    "runner_command",
    "outcome",
    "recorded_at",
    "raw_log",
)
BUNDLE_TIMESTAMP = re.compile(r"^[0-9]{8}T[0-9]{6}Z$")
OWNER_DEFAULT = re.compile(
    r'^max_age_days="\$\{LAUNCH_EVIDENCE_MAX_AGE_DAYS:-([0-9]+)\}"$',
    re.MULTILINE,
)
ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
PASS_MARKER = re.compile(r"(?:✓|✔|\bPASS(?:ED)?\b)", re.IGNORECASE)
NON_PASS_MARKER = re.compile(
    r"(?:✗|✘|×|\bFAIL(?:ED|URE)?\b|\bSKIP(?:PED)?\b|"
    r"\bNOT[ _-](?:RUN|PASSED)\b)",
    re.IGNORECASE,
)


def finish(errors: list[str], rows_checked: int) -> None:
    for message in errors:
        print(f"FAIL: {message}", file=sys.stderr)
    if rows_checked == 0:
        print("rows_checked=0 VACUOUS")
    else:
        print(f"rows_checked={rows_checked}")
    if errors:
        raise SystemExit(1)
    print("PASS: B2/B7/B21 have fresh runner-supported executed_pass receipts")


def parse_utc_timestamp(value: str, label: str, errors: list[str]) -> datetime | None:
    try:
        if label == "bundle":
            if BUNDLE_TIMESTAMP.fullmatch(value) is None:
                raise ValueError
            parsed = datetime.strptime(value, "%Y%m%dT%H%M%SZ")
        else:
            if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value) is None:
                raise ValueError
            parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        errors.append(f"{label} timestamp is malformed: {value!r}")
        return None
    return parsed.replace(tzinfo=timezone.utc)


def freshness_days(errors: list[str]) -> int | None:
    try:
        owner_source = FRESHNESS_OWNER.read_text(encoding="utf-8")
    except OSError as exc:
        errors.append(f"freshness owner is unreadable: {exc}")
        return None

    match = OWNER_DEFAULT.search(owner_source)
    if match is None:
        errors.append(
            "freshness owner no longer exposes LAUNCH_EVIDENCE_MAX_AGE_DAYS"
        )
        return None
    configured = os.environ.get("LAUNCH_EVIDENCE_MAX_AGE_DAYS", match.group(1))
    if re.fullmatch(r"[0-9]+", configured) is None:
        errors.append(
            "LAUNCH_EVIDENCE_MAX_AGE_DAYS must be a non-negative integer"
        )
        return None
    return int(configured)


def is_fresh(
    timestamp: datetime,
    label: str,
    now: datetime,
    max_age_days: int,
    errors: list[str],
) -> None:
    if timestamp > now:
        errors.append(f"{label} timestamp is future-dated")
    elif now - timestamp >= timedelta(days=max_age_days):
        errors.append(
            f"{label} timestamp is stale (must be <{max_age_days} days old)"
        )


def command_mentions_spec(command: str, spec_path: str) -> bool:
    web_relative = spec_path.removeprefix("web/")
    return spec_path in command or web_relative in command


def raw_log_has_pass_line(raw_text: str, spec_path: str) -> bool:
    web_relative = spec_path.removeprefix("web/")
    for raw_line in raw_text.splitlines():
        line = ANSI_ESCAPE.sub("", raw_line)
        if (
            (spec_path in line or web_relative in line)
            and PASS_MARKER.search(line) is not None
            and NON_PASS_MARKER.search(line) is None
        ):
            return True
    return False


def verify_line_reporter_pass_binding(errors: list[str]) -> None:
    ambiguous_log = "\n".join(
        (
            "✓ [setup:user] › tests/fixtures/auth.setup.ts:110:1 › authenticate",
            (
                "[2/2] [chromium] › "
                "tests/e2e-ui/full/auth-end-effects.spec.ts:66:2 › B21"
            ),
            "  1 skipped",
            "  1 passed (1.0s)",
        )
    )
    if raw_log_has_pass_line(ambiguous_log, EXPECTED_SPECS["B21"]):
        errors.append(
            "line-reporter mutation attributed setup:user aggregate pass to B21"
        )
    explicit_spec_pass = (
        "✓ [chromium] › "
        "tests/e2e-ui/full/auth-end-effects.spec.ts:66:2 › B21"
    )
    if not raw_log_has_pass_line(explicit_spec_pass, EXPECTED_SPECS["B21"]):
        errors.append("runner pass marker bound to B21 was not accepted")


def validate_row(
    row: Any,
    index: int,
    bundle: Path,
    now: datetime,
    max_age_days: int,
    errors: list[str],
) -> str | None:
    label = f"rows[{index}]"
    if not isinstance(row, dict):
        errors.append(f"{label} must be an object")
        return None

    for field in REQUIRED_FIELDS:
        value = row.get(field)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{label}.{field} must be a non-empty string")

    row_id = row.get("row_id")
    if not isinstance(row_id, str):
        return None

    spec_path = row.get("spec_path")
    expected_spec = EXPECTED_SPECS.get(row_id)
    if expected_spec is None:
        errors.append(f"{label}.row_id is unexpected: {row_id!r}")
    elif spec_path != expected_spec:
        errors.append(
            f"{label}.spec_path for {row_id} must be {expected_spec!r}"
        )

    outcome = row.get("outcome")
    if outcome != "executed_pass":
        errors.append(
            f"{label}.outcome for {row_id} must be 'executed_pass', got {outcome!r}"
        )

    runner_command = row.get("runner_command")
    if (
        isinstance(runner_command, str)
        and isinstance(spec_path, str)
        and not command_mentions_spec(runner_command, spec_path)
    ):
        errors.append(f"{label}.runner_command does not name its spec_path")

    recorded_at = row.get("recorded_at")
    if isinstance(recorded_at, str):
        recorded_timestamp = parse_utc_timestamp(
            recorded_at, f"{label}.recorded_at", errors
        )
        if recorded_timestamp is not None:
            is_fresh(
                recorded_timestamp,
                f"{label}.recorded_at",
                now,
                max_age_days,
                errors,
            )

    raw_log = row.get("raw_log")
    if not isinstance(raw_log, str) or not raw_log.strip():
        return row_id
    raw_relative = Path(raw_log)
    if raw_relative.is_absolute():
        errors.append(f"{label}.raw_log must be bundle-relative")
        return row_id

    raw_root = (bundle / "raw").resolve()
    raw_path = (bundle / raw_relative).resolve()
    try:
        raw_path.relative_to(raw_root)
    except ValueError:
        errors.append(f"{label}.raw_log escapes the bundle raw/ directory")
        return row_id

    if not raw_path.is_file():
        errors.append(f"{label}.raw_log does not exist: {raw_log!r}")
        return row_id
    if raw_path.stat().st_size == 0:
        errors.append(f"{label}.raw_log is empty: {raw_log!r}")
        return row_id

    try:
        raw_text = raw_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        errors.append(f"{label}.raw_log is unreadable text: {exc}")
        return row_id
    if isinstance(spec_path, str) and not raw_log_has_pass_line(raw_text, spec_path):
        errors.append(
            f"{label}.raw_log lacks a runner pass line for {spec_path!r}"
        )
    return row_id


def main() -> None:
    errors: list[str] = []
    verify_line_reporter_pass_binding(errors)
    max_age_days = freshness_days(errors)
    if max_age_days is None:
        finish(errors, 0)

    if not EVIDENCE_ROOT.is_dir():
        errors.append(f"receipt root is missing: {EVIDENCE_ROOT}")
        finish(errors, 0)

    now = datetime.now(timezone.utc)
    bundles: list[tuple[datetime, Path]] = []
    for child in sorted(EVIDENCE_ROOT.iterdir()):
        if not child.is_dir():
            continue
        timestamp = parse_utc_timestamp(child.name, "bundle", errors)
        if timestamp is not None:
            bundles.append((timestamp, child))

    if not bundles:
        errors.append("no UTC-stamped receipt bundle exists")
        finish(errors, 0)

    bundle_timestamp, bundle = max(bundles)
    is_fresh(bundle_timestamp, "newest bundle", now, max_age_days, errors)
    receipt_path = bundle / "receipt.json"
    if not receipt_path.is_file():
        errors.append(f"newest bundle has no receipt.json: {bundle.name}")
        finish(errors, 0)

    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        errors.append(f"receipt.json is malformed or unreadable: {exc}")
        finish(errors, 0)

    if not isinstance(receipt, dict) or not isinstance(receipt.get("rows"), list):
        errors.append("receipt.json must be an object with a rows array")
        finish(errors, 0)

    rows = receipt["rows"]
    rows_checked = len(rows)
    if rows_checked == 0:
        errors.append("receipt rows are empty")
        finish(errors, rows_checked)

    row_ids = [
        row_id
        for index, row in enumerate(rows)
        if (
            row_id := validate_row(
                row, index, bundle, now, max_age_days, errors
            )
        )
    ]
    duplicates = sorted(
        row_id for row_id in set(row_ids) if row_ids.count(row_id) > 1
    )
    if duplicates:
        errors.append(f"receipt has duplicate row ids: {','.join(duplicates)}")
    expected_ids = set(EXPECTED_SPECS)
    actual_ids = set(row_ids)
    missing_ids = sorted(expected_ids - actual_ids)
    unexpected_ids = sorted(actual_ids - expected_ids)
    if missing_ids:
        errors.append(f"receipt is missing row ids: {','.join(missing_ids)}")
    if unexpected_ids:
        errors.append(f"receipt has unexpected row ids: {','.join(unexpected_ids)}")
    if rows_checked != len(expected_ids):
        errors.append(
            f"receipt must contain exactly {len(expected_ids)} rows, got {rows_checked}"
        )

    finish(errors, rows_checked)


main()
PY
