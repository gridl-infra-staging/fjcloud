#!/usr/bin/env python3
"""
Stub summary for docs/runbooks/evidence/ses-coverage-a1/20260603T033009Z_in_vpc_rerun/stage4_integrity.py.
"""

from __future__ import annotations

import csv
import json
import sys
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
    "run_manifest.txt",
    "SUMMARY.md",
    "verification_commands.txt",
    "reference_bundle_comparison.md",
    "secret_preflight_evidence.txt",
    "tarball_build_evidence.txt",
    "probe_results.tsv",
    "all_green.txt",
    "failure_classifications.json",
    "GAP_SPEC.md",
    "aws_identity.json",
    "ssm_target_preflight.json",
    "host_checkout.log",
    "host_env_materialize.log",
    "host_cleanup.log",
    "s3_upload.log",
    "s3_cleanup.log",
]


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_json_objects(text: str) -> list[object]:
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
    if len(sys.argv) != 2:
        fail("usage: stage4_integrity.py <bundle>")
    bundle = Path(sys.argv[1])
    if not bundle.is_dir():
        fail(f"bundle directory not found: {bundle}")
    bundle_resolved = bundle.resolve()

    for name in REQUIRED_FILES:
        path = bundle / name
        if not path.exists():
            fail(f"required file missing: {name}")
        if name.endswith((".log", ".txt", ".tsv", ".md", ".json")) and path.stat().st_size == 0:
            if name != "tarball_build.log":
                fail(f"required file is empty: {name}")

    rows = load_tsv(bundle)
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


if __name__ == "__main__":
    raise SystemExit(main())
