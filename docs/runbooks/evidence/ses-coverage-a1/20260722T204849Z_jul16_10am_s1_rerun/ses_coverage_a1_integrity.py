#!/usr/bin/env python3
"""Canonical §1 SES coverage integrity checker for the six-probe in-VPC bundle.

Validates a completed evidence bundle by cross-checking probe_results.tsv rows
against saved log files, per-probe JSON sidecars, all_green.txt, and
failure_classifications.json. Importable surface: detect_from_log, EXPECTED,
DETECT_KIND, CLASSIFICATION_MAP, classify_failure.

Bundle-check mode (legacy CLI contract):
    ses_coverage_a1_integrity.py <bundle>
    Prints per-probe rows and all_green=<0|1> to stdout. Exits 0 on integrity
    pass, 1 on any inconsistency or missing artifact.

Validate subcommand (Stage 2 contract):
    ses_coverage_a1_integrity.py validate \\
        --manifest=<path> --sha=<40hex> --billing-month=<YYYY-MM> \\
        --validation-output=<path>
    Reads the manifest, verifies sha and billing-month match, computes the
    manifest digest, and atomically writes a validation receipt to the output
    path. The output path must be OUTSIDE the bundle directory to avoid
    self-inventory cycles. Exits 0 on success, 1 on mismatch or error.
"""

from __future__ import annotations

import csv
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path


EXPECTED = [
    "verify_email_clickthrough",
    "password_reset_clickthrough",
    "dunning_email_inbox",
    "ses_bounce",
    "ses_complaint",
    "staging_dunning_delivery",
]

DETECT_KIND = {
    "verify_email_clickthrough": "terminus_email_verified",
    "password_reset_clickthrough": "terminus_password_reset_login",
    "dunning_email_inbox": "terminus_and_result_json",
    "ses_bounce": "final_json_passed_true",
    "ses_complaint": "final_json_passed_true",
    "staging_dunning_delivery": "final_json_result_passed",
}

TERMINUS = {
    "verify_email_clickthrough": "TERMINUS: email_verified=true",
    "password_reset_clickthrough": "TERMINUS: login succeeded with new password",
    "dunning_email_inbox": "TERMINUS: body contains hosted invoice url",
}

REQUIRED_FILES = [
    "run_manifest.json",
    "run_status.json",
    "probe_results.tsv",
    "all_green.txt",
    "failure_classifications.json",
    "GAP_SPEC.md",
    "ses_coverage_a1_integrity.py",
]

CLASSIFICATION_MAP: dict[str, str] = {
    "invoice_email_ses_query_failed": "setup_infra",
    "rehearsal_failed": "setup_infra",
    "probe_side_residual_requires_green_deployed_bundle": "setup_infra",
    "reset_stripe_list_invalid": "real_defect",
    "rehearsal_reset_failed": "real_defect",
}


def classify_failure(classification: str) -> str:
    """Map a per-probe failure classification to its category.

    Returns 'setup_infra' for recognized environment/precondition issues,
    'real_defect' for known product reasons, or 'investigate' for any
    unrecognized value.
    """
    return CLASSIFICATION_MAP.get(classification, "investigate")


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def reject_duplicate_json_keys(pairs):
    """Reject duplicate JSON object keys while preserving normal json.loads output."""
    data = {}
    for key, value in pairs:
        if key in data:
            fail(f"duplicate JSON key in manifest: {key}")
        data[key] = value
    return data


def load_manifest(path: Path) -> tuple[bytes, dict]:
    """Load a run manifest with the validator's duplicate-key policy."""
    manifest_bytes = path.read_bytes()
    manifest_data = json.loads(
        manifest_bytes, object_pairs_hook=reject_duplicate_json_keys)
    if not isinstance(manifest_data, dict):
        fail("run_manifest.json must be a JSON object")
    return manifest_bytes, manifest_data


def parse_json_objects(text: str) -> list[object]:
    """Extract all top-level JSON objects/arrays from log text, one per line."""
    decoder = json.JSONDecoder()
    objects: list[object] = []
    for line in text.splitlines():
        stripped = line.lstrip()
        if not stripped or stripped[0] not in "[{":
            continue
        try:
            value, _ = decoder.raw_decode(stripped)
        except json.JSONDecodeError:
            continue
        objects.append(value)
    return objects


def load_tsv(bundle: Path) -> list[dict[str, str]]:
    """Load and validate probe_results.tsv from a bundle directory."""
    path = bundle / "probe_results.tsv"
    with path.open(newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    if [row.get("probe_id") for row in rows] != EXPECTED:
        fail("probe_results.tsv probe_id order/content mismatch")
    for row in rows:
        if set(row) != {"probe_id", "rc", "pass", "log_path"}:
            fail("probe_results.tsv columns mismatch")
    return rows


def detect_from_log(probe_id: str, log_text: str) -> tuple[bool, dict[str, object]]:
    """Detect pass/fail for a probe by inspecting its saved log output.

    Returns (passed, evidence) where evidence contains the parsed JSON objects,
    the final JSON object, the terminus line (if applicable), and the last
    non-empty line. Detection strategy depends on probe type: terminus-line
    probes look for a specific TERMINUS marker, JSON probes check for
    'passed: true' or 'result: passed' in the final JSON object.
    """
    objects = parse_json_objects(log_text)
    final_json = objects[-1] if objects and isinstance(objects[-1], dict) else None
    terminus_line = None
    for line in log_text.splitlines():
        expected = TERMINUS.get(probe_id)
        if expected and expected in line:
            terminus_line = line

    evidence: dict[str, object] = {
        "json_object_count": len(objects),
        "final_json": final_json,
        "terminus_line": terminus_line,
        "last_nonempty_line": next(
            (line for line in reversed(log_text.splitlines()) if line.strip()),
            "",
        ),
    }

    if probe_id in {"verify_email_clickthrough", "password_reset_clickthrough"}:
        return terminus_line is not None, evidence
    if probe_id == "dunning_email_inbox":
        return (
            terminus_line is not None
            and isinstance(final_json, dict)
            and final_json.get("result") == "passed"
        ), evidence
    if probe_id in {"ses_bounce", "ses_complaint"}:
        return isinstance(final_json, dict) and final_json.get("passed") is True, evidence
    if probe_id == "staging_dunning_delivery":
        return isinstance(final_json, dict) and final_json.get("result") == "passed", evidence
    fail(f"unexpected probe_id {probe_id}")


def main() -> int:
    """Run bundle integrity checks.

    Validates that all required files are present and non-empty, that
    probe_results.tsv rows match the saved log detection results, that
    per-probe JSON sidecars agree with the log evidence, and that
    all_green.txt and failure_classifications.json are consistent.
    Prints per-probe rows and all_green=<0|1> to stdout.
    """
    if len(sys.argv) != 2:
        fail("usage: ses_coverage_a1_integrity.py <bundle>")
    bundle = Path(sys.argv[1])
    if not bundle.is_dir():
        fail(f"bundle directory not found: {bundle}")
    bundle_resolved = bundle.resolve()

    for name in REQUIRED_FILES:
        path = bundle / name
        if not path.exists():
            fail(f"required file missing: {name}")
        if name.endswith((".log", ".txt", ".tsv", ".md", ".json")) and path.stat().st_size == 0:
            fail(f"required file is empty: {name}")

    rows = load_tsv(bundle)
    _, manifest = load_manifest(bundle / "run_manifest.json")
    manifest_probes = manifest.get("probes")
    if not isinstance(manifest_probes, list):
        fail("run_manifest.json probes must be a list")
    if [row.get("probe_id") for row in manifest_probes] != EXPECTED:
        fail("run_manifest.json probe_id order/content mismatch")
    if manifest.get("n") != len(EXPECTED):
        fail("run_manifest.json n mismatch")
    _validate_deployable_currency(manifest)

    log_files = sorted(path.name for path in bundle.glob("*.log")
                       if not path.name.endswith(".stderr.log"))
    expected_logs = sorted(f"{probe_id}.log" for probe_id in EXPECTED)
    if log_files != expected_logs:
        fail("probe log file set mismatch")

    stderr_files = sorted(path.name for path in bundle.glob("*.stderr.log"))
    expected_stderr = sorted(f"{probe_id}.stderr.log" for probe_id in EXPECTED)
    if stderr_files != expected_stderr:
        fail("probe stderr log file set mismatch")

    sidecar_files = sorted(path.name for path in bundle.glob("*.json")
                           if path.name not in {"run_manifest.json", "run_status.json",
                                                "failure_classifications.json"})
    expected_sidecars = sorted(f"{probe_id}.json" for probe_id in EXPECTED)
    if sidecar_files != expected_sidecars:
        fail("probe JSON sidecar set mismatch")

    all_green = True
    print("probe_id\trc\tpass\tlog_path")
    for row in rows:
        probe_id = row["probe_id"]
        log_path = Path(row["log_path"])
        log_path_resolved = log_path.resolve()
        if bundle_resolved not in (log_path_resolved, *log_path_resolved.parents):
            fail(f"{probe_id} log_path escapes bundle: {log_path}")
        if not log_path_resolved.exists():
            fail(f"{probe_id} log_path missing: {log_path}")
        if log_path_resolved.stat().st_size == 0:
            fail(f"{probe_id} log_path is empty: {log_path}")
        log_text = log_path_resolved.read_text()
        detected_pass, evidence = detect_from_log(probe_id, log_text)

        sidecar_path = bundle / f"{probe_id}.json"
        sidecar = json.loads(sidecar_path.read_text())
        if sidecar.get("probe_id") != probe_id:
            fail(f"{probe_id} sidecar probe_id mismatch")
        if sidecar.get("detect_kind") != DETECT_KIND[probe_id]:
            fail(f"{probe_id} sidecar detect_kind mismatch")
        if Path(sidecar.get("log_path", "")) != log_path:
            fail(f"{probe_id} sidecar log_path mismatch")
        if bool(sidecar.get("pass")) != detected_pass:
            fail(f"{probe_id} sidecar pass disagrees with saved log")
        if sidecar.get("parsed_evidence", {}).get("final_json") != evidence["final_json"]:
            fail(f"{probe_id} sidecar final_json disagrees with saved log")
        if sidecar.get("parsed_evidence", {}).get("terminus_line") != evidence["terminus_line"]:
            fail(f"{probe_id} sidecar terminus_line disagrees with saved log")

        row_pass = row["pass"] == "1"
        if row_pass != detected_pass:
            fail(f"{probe_id} TSV pass disagrees with saved log")
        if row["rc"] != str(sidecar.get("rc")):
            fail(f"{probe_id} TSV rc disagrees with sidecar")
        all_green = all_green and row["rc"] == "0" and row_pass
        print(f"{probe_id}\t{row['rc']}\t{row['pass']}\t{row['log_path']}")

    expected_all_green = "1" if all_green else "0"
    actual_all_green = (bundle / "all_green.txt").read_text().strip()
    if actual_all_green != expected_all_green:
        fail("all_green.txt disagrees with TSV rows")

    failures = json.loads((bundle / "failure_classifications.json").read_text())
    if expected_all_green == "0" and not failures.get("failures"):
        fail("failure_classifications.json has no failures for non-green bundle")
    if expected_all_green == "1" and failures.get("failures"):
        fail("failure_classifications.json has failures for green bundle")

    print(f"all_green={expected_all_green}")
    return 0


def _validate_deployable_currency(manifest_data: dict) -> None:
    """Validate the optional Stage 1 deployable-currency manifest payload."""
    if "deployable_currency" not in manifest_data:
        return

    deployable_currency = manifest_data["deployable_currency"]
    if not isinstance(deployable_currency, dict):
        fail("deployable_currency must be a JSON object")

    required_keys = [
        "schema_version",
        "source_sha",
        "dev_sha",
        "deployable_drift",
        "doc_only_ahead",
    ]
    required_key_set = set(required_keys)
    actual_key_set = set(deployable_currency)
    for key in required_keys:
        if key not in actual_key_set:
            fail(f"deployable_currency missing required key: {key}")
    for key in deployable_currency:
        if key not in required_key_set:
            fail(f"deployable_currency has unexpected key: {key}")

    if deployable_currency["schema_version"] != "1":
        fail('deployable_currency.schema_version must be string "1"')

    for key in ("source_sha", "dev_sha"):
        value = deployable_currency[key]
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
            fail(f"deployable_currency.{key} must be a lowercase 40-hex string")

    for key in ("deployable_drift", "doc_only_ahead"):
        if type(deployable_currency[key]) is not bool:
            fail(f"deployable_currency.{key} must be a boolean")

    if deployable_currency["deployable_drift"] and deployable_currency["doc_only_ahead"]:
        fail("deployable_currency cannot set both deployable_drift and doc_only_ahead")

    if deployable_currency["source_sha"] != manifest_data["source_sha"]:
        fail("deployable_currency.source_sha must match manifest source_sha")


def validate_subcommand(args: list[str]) -> int:
    """Run the validate subcommand: verify manifest against sha/billing-month.

    Reads the manifest, checks that source_sha and billing_month match the
    provided arguments, computes the manifest's SHA-256 digest, and writes
    a validation receipt to the output path. The output path must be outside
    the bundle (manifest's parent directory).
    """
    manifest_path = None
    sha = None
    billing_month = None
    validation_output = None

    for arg in args:
        if arg.startswith("--manifest="):
            manifest_path = Path(arg.split("=", 1)[1])
        elif arg.startswith("--sha="):
            sha = arg.split("=", 1)[1]
        elif arg.startswith("--billing-month="):
            billing_month = arg.split("=", 1)[1]
        elif arg.startswith("--validation-output="):
            validation_output = Path(arg.split("=", 1)[1])

    if not manifest_path or not sha or not billing_month or not validation_output:
        fail("validate requires --manifest, --sha, --billing-month, --validation-output")

    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        fail(f"--sha must be a 40-character hex string, got: {sha}")

    if not re.fullmatch(r"\d{4}-\d{2}", billing_month):
        fail(f"--billing-month must be YYYY-MM format, got: {billing_month}")

    if not manifest_path.exists():
        fail(f"manifest not found: {manifest_path}")

    bundle_dir = manifest_path.parent.resolve()
    output_resolved = validation_output.resolve()
    if output_resolved == bundle_dir or bundle_dir in output_resolved.parents:
        fail("validation-output must be outside the bundle (inside the bundle "
             "would cause self-inventory cycles)")

    manifest_bytes, manifest_data = load_manifest(manifest_path)
    manifest_digest = hashlib.sha256(manifest_bytes).hexdigest()

    if manifest_data.get("source_sha") != sha:
        fail(f"sha mismatch: manifest has {manifest_data.get('source_sha')}, "
             f"expected {sha}")

    if manifest_data.get("billing_month") != billing_month:
        fail(f"billing-month mismatch: manifest has "
             f"{manifest_data.get('billing_month')}, expected {billing_month}")

    _validate_deployable_currency(manifest_data)

    receipt = {
        "manifest_digest": manifest_digest,
        "sha": sha,
        "billing_month": billing_month,
        "status": "validated",
        "manifest_path": str(manifest_path),
    }

    output_dir = validation_output.parent
    output_dir.mkdir(parents=True, exist_ok=True)
    tmp_fd, tmp_path = tempfile.mkstemp(
        dir=str(output_dir), suffix=".tmp", prefix="receipt_")
    try:
        with os.fdopen(tmp_fd, "w") as f:
            json.dump(receipt, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, str(validation_output))
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "validate":
        raise SystemExit(validate_subcommand(sys.argv[2:]))
    raise SystemExit(main())
