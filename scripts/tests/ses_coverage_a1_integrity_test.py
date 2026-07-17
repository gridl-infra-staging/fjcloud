#!/usr/bin/env python3
"""Tests for scripts/lib/ses_coverage_a1_integrity.py — the canonical §1 integrity library."""

from __future__ import annotations

import csv
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
LIB_PATH = REPO_ROOT / "scripts" / "lib" / "ses_coverage_a1_integrity.py"

sys.path.insert(0, str(REPO_ROOT / "scripts" / "lib"))


# Non-probe sidecar/evidence files every §1 runner-emitted bundle carries;
# created as placeholders so integrity checks inventory a complete set.
_BUNDLE_PLACEHOLDER_FILES = [
    "run_status.json", "GAP_SPEC.md", "ses_coverage_a1_integrity.py",
]


def _build_bundle(tmp: Path, name: str, probes, all_green: bool,
                  failures_payload: dict) -> Path:
    """Materialize a hermetic §1 bundle and return its path.

    ``probes`` is a list of ``(probe_id, rc, passed, detect_kind, log_content)``
    tuples. For each probe this writes the raw ``.log``, runs the canonical
    ``detect_from_log`` to build the ``.json`` sidecar, and records a TSV row.
    ``all_green`` drives ``all_green.txt``; ``failures_payload`` is written
    verbatim to ``failure_classifications.json``.
    """
    from ses_coverage_a1_integrity import detect_from_log
    bundle = tmp / name
    bundle.mkdir()
    rows = []
    manifest_probes = []
    for probe_id, rc, passed, detect_kind, log_content in probes:
        log_path = bundle / f"{probe_id}.log"
        log_path.write_text(log_content)
        (bundle / f"{probe_id}.stderr.log").write_text("")
        detected_pass, evidence = detect_from_log(probe_id, log_content)
        sidecar = {
            "probe_id": probe_id,
            "detect_kind": detect_kind,
            "log_path": str(log_path),
            "pass": detected_pass,
            "rc": rc,
            "parsed_evidence": {
                "final_json": evidence["final_json"],
                "terminus_line": evidence["terminus_line"],
                "json_object_count": evidence["json_object_count"],
                "last_nonempty_line": evidence["last_nonempty_line"],
            },
        }
        (bundle / f"{probe_id}.json").write_text(json.dumps(sidecar, indent=2))
        rows.append({
            "probe_id": probe_id,
            "rc": str(rc),
            "pass": "1" if passed else "0",
            "log_path": str(log_path),
        })
        manifest_row = {
            "probe_id": probe_id,
            "pass": detected_pass,
            "rc": rc,
            "log_path": str(log_path),
            "detect_kind": detect_kind,
        }
        if not detected_pass or rc != 0:
            final_json = evidence["final_json"]
            classification = (
                final_json.get("classification")
                if isinstance(final_json, dict)
                else None
            ) or "unclassified"
            from ses_coverage_a1_integrity import classify_failure
            manifest_row["classification"] = classification
            manifest_row["classification_category"] = classify_failure(classification)
        manifest_probes.append(manifest_row)

    tsv_path = bundle / "probe_results.tsv"
    with tsv_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["probe_id", "rc", "pass", "log_path"],
                                delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)

    (bundle / "all_green.txt").write_text("1\n" if all_green else "0\n")
    (bundle / "failure_classifications.json").write_text(json.dumps(failures_payload))
    (bundle / "run_manifest.json").write_text(json.dumps({
        "schema_version": "1",
        "source_sha": "a" * 40,
        "billing_month": "2026-07",
        "n": len(manifest_probes),
        "all_green": all_green,
        "probes": manifest_probes,
        "integrity_status": "validated",
        "hygiene_status": "clean",
        "cleanup_status": "clean",
        "integrity_library_source": "scripts/lib/ses_coverage_a1_integrity.py",
        "owner_digests": {"integrity_library": "b" * 64},
    }, indent=2))

    for placeholder_name in _BUNDLE_PLACEHOLDER_FILES:
        path = bundle / placeholder_name
        if not path.exists():
            path.write_text(f"placeholder content for {placeholder_name}\n")
    return bundle


def _build_green_bundle(tmp: Path) -> Path:
    """Build a synthetic 6/6 green bundle in tmp."""
    probes = [
        ("verify_email_clickthrough", 0, True, "terminus_email_verified",
         "TERMINUS: email_verified=true"),
        ("password_reset_clickthrough", 0, True, "terminus_password_reset_login",
         "TERMINUS: login succeeded with new password"),
        ("dunning_email_inbox", 0, True, "terminus_and_result_json",
         'TERMINUS: body contains hosted invoice url\n{"result": "passed"}'),
        ("ses_bounce", 0, True, "final_json_passed_true",
         '{"passed": true, "steps": []}'),
        ("ses_complaint", 0, True, "final_json_passed_true",
         '{"passed": true, "steps": []}'),
        ("staging_dunning_delivery", 0, True, "final_json_result_passed",
         '{"result": "passed", "steps": []}'),
    ]
    return _build_bundle(tmp, "green_bundle", probes, all_green=True,
                         failures_payload={"failures": [], "all_green": True})


def _build_four_of_six_bundle(tmp: Path) -> Path:
    """Build a 4/6 bundle mirroring the IAM-gap shape."""
    probes = [
        ("verify_email_clickthrough", 0, True, "terminus_email_verified",
         "TERMINUS: email_verified=true"),
        ("password_reset_clickthrough", 0, True, "terminus_password_reset_login",
         "TERMINUS: login succeeded with new password"),
        ("dunning_email_inbox", 1, False, "terminus_and_result_json",
         '{"result": "failed", "classification": "rehearsal_failed"}'),
        ("ses_bounce", 0, True, "final_json_passed_true",
         '{"passed": true, "steps": []}'),
        ("ses_complaint", 0, True, "final_json_passed_true",
         '{"passed": true, "steps": []}'),
        ("staging_dunning_delivery", 1, False, "final_json_result_passed",
         '{"result": "failed", "classification": "invoice_email_ses_query_failed"}'),
    ]
    failures_payload = {
        "all_green": False,
        "failures": [
            {
                "probe_id": "staging_dunning_delivery",
                "observed_classification": "invoice_email_ses_query_failed",
                "rc": 1,
            },
            {
                "probe_id": "dunning_email_inbox",
                "observed_classification": "rehearsal_failed",
                "rc": 1,
            },
        ],
    }
    return _build_bundle(tmp, "four_six_bundle", probes, all_green=False,
                         failures_payload=failures_payload)


class TestDetectFromLog(unittest.TestCase):
    """Test detect_from_log for each probe type."""

    def test_verify_email_clickthrough_pass(self):
        from ses_coverage_a1_integrity import detect_from_log
        passed, ev = detect_from_log(
            "verify_email_clickthrough",
            "some setup\nTERMINUS: email_verified=true\n")
        self.assertTrue(passed)
        self.assertIn("TERMINUS", ev["terminus_line"])

    def test_verify_email_clickthrough_fail(self):
        from ses_coverage_a1_integrity import detect_from_log
        passed, ev = detect_from_log(
            "verify_email_clickthrough",
            "some setup\nno terminus here\n")
        self.assertFalse(passed)
        self.assertIsNone(ev["terminus_line"])

    def test_password_reset_clickthrough_pass(self):
        from ses_coverage_a1_integrity import detect_from_log
        passed, ev = detect_from_log(
            "password_reset_clickthrough",
            "TERMINUS: login succeeded with new password\n")
        self.assertTrue(passed)

    def test_password_reset_clickthrough_fail(self):
        from ses_coverage_a1_integrity import detect_from_log
        passed, ev = detect_from_log(
            "password_reset_clickthrough", "no terminus\n")
        self.assertFalse(passed)

    def test_dunning_email_inbox_pass(self):
        from ses_coverage_a1_integrity import detect_from_log
        passed, ev = detect_from_log(
            "dunning_email_inbox",
            'TERMINUS: body contains hosted invoice url\n{"result": "passed"}')
        self.assertTrue(passed)

    def test_dunning_email_inbox_fail_no_terminus(self):
        from ses_coverage_a1_integrity import detect_from_log
        passed, ev = detect_from_log(
            "dunning_email_inbox",
            '{"result": "passed"}')
        self.assertFalse(passed)

    def test_dunning_email_inbox_fail_no_result(self):
        from ses_coverage_a1_integrity import detect_from_log
        passed, ev = detect_from_log(
            "dunning_email_inbox",
            'TERMINUS: body contains hosted invoice url\n{"result": "failed"}')
        self.assertFalse(passed)

    def test_ses_bounce_pass(self):
        from ses_coverage_a1_integrity import detect_from_log
        passed, ev = detect_from_log(
            "ses_bounce", '{"passed": true, "steps": []}')
        self.assertTrue(passed)

    def test_ses_bounce_fail(self):
        from ses_coverage_a1_integrity import detect_from_log
        passed, ev = detect_from_log(
            "ses_bounce", '{"passed": false}')
        self.assertFalse(passed)

    def test_ses_complaint_pass(self):
        from ses_coverage_a1_integrity import detect_from_log
        passed, ev = detect_from_log(
            "ses_complaint", '{"passed": true}')
        self.assertTrue(passed)

    def test_staging_dunning_delivery_pass(self):
        from ses_coverage_a1_integrity import detect_from_log
        passed, ev = detect_from_log(
            "staging_dunning_delivery", '{"result": "passed", "steps": []}')
        self.assertTrue(passed)

    def test_staging_dunning_delivery_fail(self):
        from ses_coverage_a1_integrity import detect_from_log
        passed, ev = detect_from_log(
            "staging_dunning_delivery", '{"result": "failed"}')
        self.assertFalse(passed)

    def test_unexpected_probe_id_exits(self):
        from ses_coverage_a1_integrity import detect_from_log
        with self.assertRaises(SystemExit) as ctx:
            detect_from_log("unknown_probe", "some log")
        self.assertEqual(ctx.exception.code, 1)


class TestExpectedProbeIds(unittest.TestCase):
    """Verify the EXPECTED list matches the canonical six probes."""

    def test_expected_probe_ids(self):
        from ses_coverage_a1_integrity import EXPECTED
        self.assertEqual(EXPECTED, [
            "verify_email_clickthrough",
            "password_reset_clickthrough",
            "dunning_email_inbox",
            "ses_bounce",
            "ses_complaint",
            "staging_dunning_delivery",
        ])
        self.assertEqual(len(EXPECTED), 6)


class TestClassificationTaxonomy(unittest.TestCase):
    """Test the KAT-derived per-probe classification set."""

    def test_setup_infra_classifications(self):
        from ses_coverage_a1_integrity import classify_failure
        self.assertEqual(classify_failure("invoice_email_ses_query_failed"), "setup_infra")
        self.assertEqual(classify_failure("rehearsal_failed"), "setup_infra")
        self.assertEqual(
            classify_failure("probe_side_residual_requires_green_deployed_bundle"),
            "setup_infra")

    def test_real_defect_classifications(self):
        from ses_coverage_a1_integrity import classify_failure
        self.assertEqual(classify_failure("reset_stripe_list_invalid"), "real_defect")
        self.assertEqual(classify_failure("rehearsal_reset_failed"), "real_defect")

    def test_unrecognized_maps_to_investigate(self):
        from ses_coverage_a1_integrity import classify_failure
        self.assertEqual(classify_failure("some_unknown_value"), "investigate")
        self.assertEqual(classify_failure(""), "investigate")
        self.assertEqual(classify_failure("brand_new_failure_mode"), "investigate")

    def test_classification_map_completeness(self):
        """Every member in CLASSIFICATION_MAP maps to setup_infra or real_defect."""
        from ses_coverage_a1_integrity import CLASSIFICATION_MAP
        for key, value in CLASSIFICATION_MAP.items():
            self.assertIn(value, ("setup_infra", "real_defect"),
                          f"{key} maps to unexpected category {value}")

    def test_all_kat_bundle_classifications_are_mapped(self):
        """All classification values from both KAT bundles are in the map."""
        from ses_coverage_a1_integrity import CLASSIFICATION_MAP
        kat_values = {
            "invoice_email_ses_query_failed",
            "rehearsal_failed",
            "probe_side_residual_requires_green_deployed_bundle",
            "reset_stripe_list_invalid",
            "rehearsal_reset_failed",
        }
        for val in kat_values:
            self.assertIn(val, CLASSIFICATION_MAP,
                          f"KAT value {val} missing from CLASSIFICATION_MAP")


class TestGreenBundleIntegrity(unittest.TestCase):
    """Test main() against a synthetic 6/6 green bundle."""

    def test_green_bundle_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = _build_green_bundle(Path(tmp))
            result = subprocess.run(
                [sys.executable, str(LIB_PATH), str(bundle)],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("all_green=1", result.stdout)

    def test_bundle_mode_rejects_tampered_deployable_currency(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = _build_green_bundle(Path(tmp))
            manifest = bundle / "run_manifest.json"
            manifest_data = json.loads(manifest.read_text())
            manifest_data["deployable_currency"] = {
                "schema_version": "1",
                "source_sha": "c" * 40,
                "dev_sha": "b" * 40,
                "deployable_drift": False,
                "doc_only_ahead": True,
            }
            manifest.write_text(json.dumps(manifest_data))

            result = subprocess.run(
                [sys.executable, str(LIB_PATH), str(bundle)],
                capture_output=True, text=True)

            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "deployable_currency.source_sha must match manifest source_sha",
                result.stderr)


class TestFourOfSixBundleIntegrity(unittest.TestCase):
    """Test main() against a 4/6 IAM-gap bundle."""

    def test_four_six_bundle_passes_integrity(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = _build_four_of_six_bundle(Path(tmp))
            result = subprocess.run(
                [sys.executable, str(LIB_PATH), str(bundle)],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("all_green=0", result.stdout)


class TestErrorConditions(unittest.TestCase):
    """Test error handling for missing/empty/escaped paths."""

    def test_required_file_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "incomplete"
            bundle.mkdir()
            result = subprocess.run(
                [sys.executable, str(LIB_PATH), str(bundle)],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("required file missing", result.stderr)

    def test_empty_required_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = _build_green_bundle(Path(tmp))
            (bundle / "GAP_SPEC.md").write_text("")
            result = subprocess.run(
                [sys.executable, str(LIB_PATH), str(bundle)],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("required file is empty", result.stderr)

    def test_log_path_escapes_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = _build_green_bundle(Path(tmp))
            escape_log = Path(tmp) / "escaped.log"
            escape_log.write_text("TERMINUS: email_verified=true")
            tsv = bundle / "probe_results.tsv"
            rows_text = tsv.read_text()
            first_log = str(bundle / "verify_email_clickthrough.log")
            rows_text = rows_text.replace(first_log, str(escape_log))
            tsv.write_text(rows_text)
            result = subprocess.run(
                [sys.executable, str(LIB_PATH), str(bundle)],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("escapes bundle", result.stderr)

    def test_no_args_exits_1(self):
        result = subprocess.run(
            [sys.executable, str(LIB_PATH)],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("usage:", result.stderr)

    def test_nonexistent_bundle_exits_1(self):
        result = subprocess.run(
            [sys.executable, str(LIB_PATH), "/nonexistent/bundle"],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("not found", result.stderr)


class TestValidateSubcommand(unittest.TestCase):
    """Test the validate --manifest subcommand."""

    def _make_manifest(self, tmp: Path, sha: str = "a" * 40,
                       billing_month: str = "2026-07",
                       deployable_currency=None) -> Path:
        bundle = _build_green_bundle(tmp)
        manifest = bundle / "run_manifest.json"
        manifest_data = {
            "schema_version": "1",
            "source_sha": sha,
            "billing_month": billing_month,
            "n": 6,
            "rows": [],
        }
        if deployable_currency is not None:
            manifest_data["deployable_currency"] = deployable_currency
        manifest.write_text(json.dumps(manifest_data))
        return manifest

    def _write_raw_manifest(self, tmp: Path, raw_json: str) -> Path:
        bundle = _build_green_bundle(tmp)
        manifest = bundle / "run_manifest.json"
        manifest.write_text(raw_json)
        return manifest

    def _validate_manifest(self, manifest: Path, output_path: Path,
                           sha: str = "a" * 40,
                           billing_month: str = "2026-07"):
        return subprocess.run([
            sys.executable, str(LIB_PATH),
            "validate",
            f"--manifest={manifest}",
            f"--sha={sha}",
            f"--billing-month={billing_month}",
            f"--validation-output={output_path}",
        ], capture_output=True, text=True)

    def _assert_valid_receipt(self, manifest: Path, output_path: Path,
                              sha: str = "a" * 40,
                              billing_month: str = "2026-07") -> None:
        self.assertTrue(output_path.exists())
        receipt = json.loads(output_path.read_text())
        self.assertEqual(receipt["sha"], sha)
        self.assertEqual(receipt["billing_month"], billing_month)
        self.assertEqual(receipt["status"], "validated")
        expected_digest = hashlib.sha256(manifest.read_bytes()).hexdigest()
        self.assertEqual(receipt["manifest_digest"], expected_digest)

    def _assert_rejected(self, result, output_path: Path,
                         stderr_fragment: str) -> None:
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(stderr_fragment, result.stderr)
        self.assertFalse(output_path.exists())

    def test_validate_writes_receipt(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            manifest = self._make_manifest(tmp_path)
            output_path = tmp_path / "receipt.json"
            result = self._validate_manifest(manifest, output_path)
            self.assertEqual(result.returncode, 0, result.stderr)
            self._assert_valid_receipt(manifest, output_path)

    def test_validate_accepts_enriched_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            sha = "a" * 40
            deployable_currency = {
                "schema_version": "1",
                "source_sha": sha,
                "dev_sha": "b" * 40,
                "deployable_drift": False,
                "doc_only_ahead": True,
            }
            manifest = self._make_manifest(
                tmp_path, sha=sha, deployable_currency=deployable_currency)
            output_path = tmp_path / "receipt.json"
            result = self._validate_manifest(manifest, output_path, sha=sha)
            self.assertEqual(result.returncode, 0, result.stderr)
            saved_manifest = json.loads(manifest.read_text())
            self.assertEqual(saved_manifest["deployable_currency"],
                             deployable_currency)
            self._assert_valid_receipt(manifest, output_path, sha=sha)

    def test_validate_keeps_historical_manifest_compatible(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            manifest = self._make_manifest(tmp_path)
            output_path = tmp_path / "receipt.json"
            result = self._validate_manifest(manifest, output_path)
            self.assertEqual(result.returncode, 0, result.stderr)
            saved_manifest = json.loads(manifest.read_text())
            self.assertEqual(saved_manifest["schema_version"], "1")
            self.assertNotIn("deployable_currency", saved_manifest)
            self._assert_valid_receipt(manifest, output_path)

    def test_validate_accepts_all_legal_currency_flag_pairs(self):
        cases = [
            (True, False),
            (False, False),
        ]
        for deployable_drift, doc_only_ahead in cases:
            with self.subTest(deployable_drift=deployable_drift,
                              doc_only_ahead=doc_only_ahead):
                with tempfile.TemporaryDirectory() as tmp:
                    tmp_path = Path(tmp)
                    deployable_currency = {
                        "schema_version": "1",
                        "source_sha": "a" * 40,
                        "dev_sha": "b" * 40,
                        "deployable_drift": deployable_drift,
                        "doc_only_ahead": doc_only_ahead,
                    }
                    manifest = self._make_manifest(
                        tmp_path, deployable_currency=deployable_currency)
                    output_path = tmp_path / "receipt.json"
                    result = self._validate_manifest(manifest, output_path)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self._assert_valid_receipt(manifest, output_path)

    def test_validate_rejects_deployable_currency_shape_errors(self):
        base = {
            "schema_version": "1",
            "source_sha": "a" * 40,
            "dev_sha": "b" * 40,
            "deployable_drift": False,
            "doc_only_ahead": True,
        }
        cases = [
            ("not_object", "not-an-object",
             "deployable_currency must be a JSON object"),
            ("missing_schema_version",
             {k: v for k, v in base.items() if k != "schema_version"},
             "deployable_currency missing required key: schema_version"),
            ("missing_source_sha",
             {k: v for k, v in base.items() if k != "source_sha"},
             "deployable_currency missing required key: source_sha"),
            ("missing_dev_sha",
             {k: v for k, v in base.items() if k != "dev_sha"},
             "deployable_currency missing required key: dev_sha"),
            ("missing_deployable_drift",
             {k: v for k, v in base.items() if k != "deployable_drift"},
             "deployable_currency missing required key: deployable_drift"),
            ("missing_doc_only_ahead",
             {k: v for k, v in base.items() if k != "doc_only_ahead"},
             "deployable_currency missing required key: doc_only_ahead"),
            ("extra_key", {**base, "unexpected": "value"},
             "deployable_currency has unexpected key: unexpected"),
            ("schema_version_int", {**base, "schema_version": 1},
             'deployable_currency.schema_version must be string "1"'),
            ("schema_version_other", {**base, "schema_version": "2"},
             'deployable_currency.schema_version must be string "1"'),
        ]
        for name, deployable_currency, stderr_fragment in cases:
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as tmp:
                    tmp_path = Path(tmp)
                    manifest = self._make_manifest(
                        tmp_path, deployable_currency=deployable_currency)
                    output_path = tmp_path / "receipt.json"
                    result = self._validate_manifest(manifest, output_path)
                    self._assert_rejected(result, output_path,
                                          stderr_fragment)

    def test_validate_rejects_duplicate_deployable_currency_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_json = textwrap.dedent(f"""\
                {{
                  "schema_version": "1",
                  "source_sha": "{"a" * 40}",
                  "billing_month": "2026-07",
                  "n": 6,
                  "rows": [],
                  "deployable_currency": {{
                    "schema_version": "1",
                    "source_sha": "{"a" * 40}",
                    "source_sha": "{"a" * 40}",
                    "dev_sha": "{"b" * 40}",
                    "deployable_drift": false,
                    "doc_only_ahead": true
                  }}
                }}
                """)
            manifest = self._write_raw_manifest(tmp_path, raw_json)
            output_path = tmp_path / "receipt.json"
            result = self._validate_manifest(manifest, output_path)
            self._assert_rejected(
                result, output_path,
                "duplicate JSON key in manifest: source_sha")

    def test_validate_rejects_deployable_currency_value_errors(self):
        base = {
            "schema_version": "1",
            "source_sha": "a" * 40,
            "dev_sha": "b" * 40,
            "deployable_drift": False,
            "doc_only_ahead": True,
        }
        cases = [
            ("source_sha_non_string", {**base, "source_sha": 7},
             "deployable_currency.source_sha must be a lowercase 40-hex string"),
            ("source_sha_short", {**base, "source_sha": "a" * 39},
             "deployable_currency.source_sha must be a lowercase 40-hex string"),
            ("source_sha_uppercase", {**base, "source_sha": "A" * 40},
             "deployable_currency.source_sha must be a lowercase 40-hex string"),
            ("source_sha_non_hex", {**base, "source_sha": "g" * 40},
             "deployable_currency.source_sha must be a lowercase 40-hex string"),
            ("dev_sha_non_string", {**base, "dev_sha": 7},
             "deployable_currency.dev_sha must be a lowercase 40-hex string"),
            ("dev_sha_short", {**base, "dev_sha": "b" * 39},
             "deployable_currency.dev_sha must be a lowercase 40-hex string"),
            ("dev_sha_uppercase", {**base, "dev_sha": "B" * 40},
             "deployable_currency.dev_sha must be a lowercase 40-hex string"),
            ("dev_sha_non_hex", {**base, "dev_sha": "z" * 40},
             "deployable_currency.dev_sha must be a lowercase 40-hex string"),
            ("deployable_drift_string",
             {**base, "deployable_drift": "false"},
             "deployable_currency.deployable_drift must be a boolean"),
            ("deployable_drift_int", {**base, "deployable_drift": 0},
             "deployable_currency.deployable_drift must be a boolean"),
            ("deployable_drift_null", {**base, "deployable_drift": None},
             "deployable_currency.deployable_drift must be a boolean"),
            ("doc_only_ahead_string", {**base, "doc_only_ahead": "true"},
             "deployable_currency.doc_only_ahead must be a boolean"),
            ("doc_only_ahead_int", {**base, "doc_only_ahead": 1},
             "deployable_currency.doc_only_ahead must be a boolean"),
            ("doc_only_ahead_null", {**base, "doc_only_ahead": None},
             "deployable_currency.doc_only_ahead must be a boolean"),
            ("impossible_true_true",
             {**base, "deployable_drift": True, "doc_only_ahead": True},
             "deployable_currency cannot set both deployable_drift and doc_only_ahead"),
            ("source_sha_mismatch", {**base, "source_sha": "c" * 40},
             "deployable_currency.source_sha must match manifest source_sha"),
        ]
        for name, deployable_currency, stderr_fragment in cases:
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as tmp:
                    tmp_path = Path(tmp)
                    manifest = self._make_manifest(
                        tmp_path, deployable_currency=deployable_currency)
                    output_path = tmp_path / "receipt.json"
                    result = self._validate_manifest(manifest, output_path)
                    self._assert_rejected(result, output_path,
                                          stderr_fragment)

    def test_validate_sha_mismatch_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            manifest = self._make_manifest(tmp_path, sha="a" * 40)
            output_path = tmp_path / "receipt.json"
            result = self._validate_manifest(manifest, output_path,
                                             sha="b" * 40)
            self.assertNotEqual(result.returncode, 0)

    def test_validate_billing_month_mismatch_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            manifest = self._make_manifest(tmp_path, billing_month="2026-07")
            output_path = tmp_path / "receipt.json"
            result = self._validate_manifest(manifest, output_path,
                                             billing_month="2026-08")
            self.assertNotEqual(result.returncode, 0)

    def test_validate_refuses_output_inside_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            manifest = self._make_manifest(tmp_path)
            bundle_dir = manifest.parent
            output_path = bundle_dir / "receipt.json"
            result = self._validate_manifest(manifest, output_path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("inside the bundle", result.stderr)

    def test_validate_receipt_binds_manifest_digest(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            manifest = self._make_manifest(tmp_path)
            output_path = tmp_path / "receipt.json"
            manifest_bytes = manifest.read_bytes()
            expected_digest = hashlib.sha256(manifest_bytes).hexdigest()
            self._validate_manifest(manifest, output_path).check_returncode()
            receipt = json.loads(output_path.read_text())
            self.assertEqual(receipt["manifest_digest"], expected_digest)

    def test_validate_bad_sha_format(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            manifest = self._make_manifest(tmp_path)
            output_path = tmp_path / "receipt.json"
            result = self._validate_manifest(
                manifest, output_path, sha="not-a-hex-sha")
            self.assertNotEqual(result.returncode, 0)

    def test_validate_bad_billing_month_format(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            manifest = self._make_manifest(tmp_path)
            output_path = tmp_path / "receipt.json"
            result = self._validate_manifest(
                manifest, output_path, billing_month="July2026")
            self.assertNotEqual(result.returncode, 0)


class TestParseJsonObjects(unittest.TestCase):
    """Test the JSON-from-log-lines parser."""

    def test_mixed_lines(self):
        from ses_coverage_a1_integrity import parse_json_objects
        text = 'setup line\n{"key": "val"}\nnoise\n[1, 2, 3]\n'
        objects = parse_json_objects(text)
        self.assertEqual(len(objects), 2)
        self.assertEqual(objects[0], {"key": "val"})
        self.assertEqual(objects[1], [1, 2, 3])

    def test_no_json(self):
        from ses_coverage_a1_integrity import parse_json_objects
        self.assertEqual(parse_json_objects("just text\nmore text\n"), [])

    def test_malformed_json_skipped(self):
        from ses_coverage_a1_integrity import parse_json_objects
        self.assertEqual(parse_json_objects("{broken json\n"), [])


if __name__ == "__main__":
    unittest.main()
