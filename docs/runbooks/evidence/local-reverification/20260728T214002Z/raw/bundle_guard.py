#!/usr/bin/env python3
from collections import Counter
from pathlib import Path
import csv
import json
import re
import sys

EXPECTED_HEADER = [
    "section",
    "row_label",
    "owner_path",
    "command",
    "exit_code",
    "status",
    "residual_reason",
]
EXPECTED_RELATIONSHIP_COUNT = 13
EXPECTED_MANIFEST_ROW_COUNT = 14
EXPECTED_STATUS_COUNTS = Counter({"green": 13, "not_local": 1})
ALLOWED_STATUSES = {"green", "red", "not_local"}
AMOUNT_PATTERN = re.compile(
    r"actual_amount_paid_cents=(\d+) expected_amount_paid_cents=(\d+)"
)
TEST_RESULT_PATTERN = re.compile(r"test result: ok\. (\d+) passed; 0 failed;")


def read_text(path, errors):
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        errors.append(f"{path}: unable to read ({exc.__class__.__name__})")
        return ""


def load_manifest(path, errors):
    try:
        with path.open(newline="", encoding="utf-8") as manifest_file:
            rows = list(csv.reader(manifest_file, delimiter="\t"))
    except (OSError, csv.Error) as exc:
        errors.append(f"{path}: unable to parse manifest ({exc.__class__.__name__})")
        return []

    if not rows:
        errors.append("manifest is empty")
        return []
    if rows[0] != EXPECTED_HEADER:
        errors.append(f"manifest header mismatch: {rows[0]!r}")

    manifest_rows = []
    for line_number, row in enumerate(rows[1:], start=2):
        if len(row) != len(EXPECTED_HEADER):
            errors.append(f"manifest line {line_number} has {len(row)} columns")
            continue
        manifest_rows.append(dict(zip(EXPECTED_HEADER, row)))
    if len(manifest_rows) != EXPECTED_MANIFEST_ROW_COUNT:
        errors.append(
            f"manifest data row count={len(manifest_rows)}, "
            f"expected={EXPECTED_MANIFEST_ROW_COUNT}"
        )
    return manifest_rows


def validate_manifest(manifest_rows, errors):
    labels = Counter(row["row_label"] for row in manifest_rows)
    status_counts = Counter(row["status"] for row in manifest_rows)
    for label, count in labels.items():
        if count > 1:
            errors.append(f"duplicate row_label={label}")
    if status_counts != EXPECTED_STATUS_COUNTS:
        errors.append(
            f"manifest status counts={dict(status_counts)}, "
            f"expected={dict(EXPECTED_STATUS_COUNTS)}"
        )

    for row in manifest_rows:
        label = row["row_label"] or "<missing-row-label>"
        status = row["status"]
        if row["section"] != "2":
            errors.append(f"{label}: section must be 2")
        if not row["owner_path"]:
            errors.append(f"{label}: owner_path is required")
        if status not in ALLOWED_STATUSES:
            errors.append(f"{label}: unsupported status={status!r}")
        if status in {"green", "red"}:
            if not row["command"]:
                errors.append(f"{label}: run row missing command")
            if row["exit_code"] == "":
                errors.append(f"{label}: run row missing exit_code")
        if status == "green":
            if row["exit_code"] != "0":
                errors.append(f"{label}: green row has exit_code={row['exit_code']!r}")
            if (
                "INTEGRATION=1" not in row["command"]
                or "BACKEND_LIVE_GATE=1" not in row["command"]
            ):
                errors.append(f"{label}: green command missing live-gate env")
        if status == "not_local":
            if row["command"] or row["exit_code"]:
                errors.append(
                    f"{label}: not_local row must not claim a command or exit code"
                )
            if not row["residual_reason"]:
                errors.append(f"{label}: not_local row missing residual_reason")


def load_relationship_results(path, errors):
    text = read_text(path, errors)
    if not text:
        return []
    try:
        results = json.loads(text)
    except json.JSONDecodeError as exc:
        errors.append(f"{path}: invalid JSON at line {exc.lineno}, column {exc.colno}")
        return []
    if not isinstance(results, list):
        errors.append("relationship_results must be a JSON array")
        return []
    if len(results) != EXPECTED_RELATIONSHIP_COUNT:
        errors.append(
            f"relationship_results count={len(results)}, "
            f"expected={EXPECTED_RELATIONSHIP_COUNT}"
        )
    return results


def resolve_bundle_log(bundle, log_value, label, errors):
    if not isinstance(log_value, str) or not log_value:
        errors.append(f"{label}: relationship result missing log path")
        return None
    repo_root = bundle.parents[4]
    log_path = Path(log_value)
    if not log_path.is_absolute():
        log_path = repo_root / log_path
    resolved_path = log_path.resolve()
    try:
        resolved_path.relative_to((bundle / "raw").resolve())
    except ValueError:
        errors.append(f"{label}: log path is outside the bundle raw directory")
        return None
    return resolved_path


def validate_result_log(bundle, result, label, errors):
    log_path = resolve_bundle_log(bundle, result.get("log"), label, errors)
    if log_path is None:
        return
    log_text = read_text(log_path, errors)
    test_result = TEST_RESULT_PATTERN.search(log_text)
    if not test_result:
        errors.append(f"{label}: green raw log missing ok test result")
        return
    passed_count = int(test_result.group(1))
    if passed_count <= 0:
        errors.append(f"{label}: green raw log has zero passed tests")
    if result.get("passed_count") != passed_count:
        errors.append(f"{label}: result passed_count differs from raw log")


def validate_relationship_results(bundle, manifest_rows, results, errors):
    manifest_by_label = {
        row["row_label"]: row
        for row in manifest_rows
        if row["status"] in {"green", "red"}
    }
    result_labels = []

    for result in results:
        if not isinstance(result, dict):
            errors.append("relationship result must be an object")
            continue
        label = result.get("row")
        if not isinstance(label, str) or not label:
            errors.append("relationship result missing row label")
            continue
        result_labels.append(label)
        manifest_row = manifest_by_label.get(label)
        if manifest_row is None:
            errors.append(f"{label}: relationship result has no run-row manifest owner")
            continue

        expected_values = {
            "command": manifest_row["command"],
            "status": manifest_row["status"],
            "residual_reason": manifest_row["residual_reason"],
        }
        for field, expected in expected_values.items():
            if result.get(field) != expected:
                errors.append(f"{label}: result {field} differs from manifest")
        try:
            expected_exit_code = int(manifest_row["exit_code"])
        except ValueError:
            errors.append(f"{label}: manifest exit_code is not an integer")
            expected_exit_code = None
        if result.get("exit_code") != expected_exit_code:
            errors.append(f"{label}: result exit_code differs from manifest")

        validate_result_log(bundle, result, label, errors)

    result_counts = Counter(result_labels)
    for label, count in result_counts.items():
        if count > 1:
            errors.append(f"duplicate relationship result row={label}")
    if set(result_labels) != set(manifest_by_label):
        errors.append("relationship result rows differ from manifest run rows")


def validate_summary(bundle, manifest_rows, results, errors):
    summary_text = read_text(bundle / "SUMMARY.md", errors)
    status_counts = Counter(row["status"] for row in manifest_rows)
    run_count = status_counts["green"] + status_counts["red"]
    expected_counts = (
        f"section2: rows_total={len(manifest_rows)} rows_run_locally={run_count} "
        f"rows_green={status_counts['green']} rows_red={status_counts['red']} "
        f"rows_not_local={status_counts['not_local']}"
    )
    if summary_text.count(expected_counts) != 1:
        errors.append("summary section2 counts missing, duplicated, or inconsistent")

    for result in results:
        if not isinstance(result, dict):
            continue
        expected_line = (
            f"- {result.get('row')}: status={result.get('status')} "
            f"exit_code={result.get('exit_code')} log={result.get('log')}"
        )
        if summary_text.count(expected_line) != 1:
            errors.append(
                f"{result.get('row', '<missing-row-label>')}: "
                "summary relationship line missing, duplicated, or inconsistent"
            )
    return summary_text


def validate_amount_proof(bundle, summary_text, errors):
    stripe_log_text = read_text(
        bundle / "raw" / "section2_stripe_test_clock_full_cycle.log", errors
    )
    stripe_matches = AMOUNT_PATTERN.findall(stripe_log_text)
    summary_matches = AMOUNT_PATTERN.findall(summary_text)
    if len(stripe_matches) != 1:
        errors.append(
            f"stripe amount-proof line count={len(stripe_matches)}, expected=1"
        )
    elif stripe_matches[0][0] != stripe_matches[0][1]:
        errors.append(
            "stripe amount mismatch "
            f"actual={stripe_matches[0][0]} expected={stripe_matches[0][1]}"
        )
    if len(summary_matches) != 1:
        errors.append(
            f"summary amount-proof line count={len(summary_matches)}, expected=1"
        )
    elif stripe_matches and summary_matches[0] != stripe_matches[0]:
        errors.append("summary amount-proof line differs from stripe raw log")
    return stripe_matches


def main():
    bundle = Path(__file__).resolve().parents[1]
    errors = []
    manifest_rows = load_manifest(bundle / "owner_manifest.tsv", errors)
    validate_manifest(manifest_rows, errors)
    results = load_relationship_results(
        bundle / "raw" / "relationship_results.json", errors
    )
    validate_relationship_results(bundle, manifest_rows, results, errors)
    summary_text = validate_summary(bundle, manifest_rows, results, errors)
    stripe_matches = validate_amount_proof(bundle, summary_text, errors)

    if errors:
        print("bundle_guard=FAIL")
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print("bundle_guard=PASS")
    print("manifest_header=ok")
    print(f"manifest_data_rows={len(manifest_rows)}")
    print("manifest_relationship_results_reconciled=ok")
    print("green_rows_have_live_gate=ok")
    print("green_raw_logs_nonzero_passed=ok")
    print(
        "amount_proof_line=actual_amount_paid_cents=%s "
        "expected_amount_paid_cents=%s" % stripe_matches[0]
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
