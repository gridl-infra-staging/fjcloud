#!/usr/bin/env python3
"""Known-answer tests for the Wave 3 launch closeout validator."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent.parent
VALIDATOR = REPO_ROOT / "scripts" / "launch" / "validate_launch_closeout.py"
SHA = "a" * 40
BILLING_MONTH = "2026-07"
ACCOUNT_ID = "123456789012"
PROFILE = "fjcloud-staging"
ROLE = "fjcloud-instance-role"
ON_HOST_ARN = f"arn:aws:sts::{ACCOUNT_ID}:assumed-role/{ROLE}/i-0123456789abcdef0"
API_NAMES = {
    "DescribeLogGroups": "describe_log_groups",
    "FilterLogEvents": "filter_log_events",
    "DescribeLogStreams": "describe_log_streams",
    "GetLogEvents": "get_log_events",
}
SECTION1_PROBE_IDS = (
    "verify_email_clickthrough",
    "password_reset_clickthrough",
    "dunning_email_inbox",
    "ses_bounce",
    "ses_complaint",
    "staging_dunning_delivery",
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n")


class CloseoutFixture:
    """Hermetic checkout-shaped fixture for the exact Wave 3 argv contract."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.launch = root / "LAUNCH.md"
        self.roadmap = root / "ROADMAP.md"
        self.matrix = root / "docs/launch_verification_matrix.md"
        self.iam_owner = root / (
            "docs/runbooks/evidence/ses-iam-read/fixture/summary.json"
        )
        self.manifest_owner = root / (
            "docs/runbooks/evidence/ses-coverage-a1/fixture/run_manifest.json"
        )
        self.rc_owner = root / (
            "docs/runbooks/evidence/invite-ready-rc/fixture/verdict.json"
        )
        self.rc_summary_owner = root / (
            "docs/runbooks/evidence/invite-ready-rc/fixture/summary.json"
        )
        self.rc_run_receipt_owner = root / (
            "docs/runbooks/evidence/invite-ready-rc/fixture/run_receipt.json"
        )
        self.manifest = root / "section1_bundle/run_manifest.json"
        self.rc_verdict = root / "rc/verdict.json"
        self.iam_validation = root / "preflight/iam_verify_final/summary.json"
        self.section1_validation = root / "preflight/section1_validation.json"
        self.rc_validation = root / "rc/validation.json"
        self.closeout = root / "chatting/jul13_iam_s1_rc_launch_closeout.json"
        self._build()

    def _build(self) -> None:
        self._write_status_owners()
        self._write_evidence_sources()
        self._write_validation_receipts()
        self.rewrite_closeout()

    def _write_status_owners(self) -> None:
        self.launch.parent.mkdir(parents=True, exist_ok=True)
        self.launch.write_text(
            "# Launch\n\n## STATUS — append at end of each work session\n\n"
            "### 2026-07-15 jul13_iam Wave 3 RC verdict — LAUNCH-READY\n"
        )
        self.roadmap.write_text(
            "# Roadmap\n\n## Active\n\nCurrent work.\n\n## Planned\n\n"
            "| P1 | Public-release completion (active orchestration) | Wave 3 RC: LAUNCH-READY |\n"
        )
        self.matrix.parent.mkdir(parents=True, exist_ok=True)
        self.matrix.write_text(
            "# Launch Verification Matrix\n\n## Section status\n\n"
            "not the section state). **Aggregate rule:** all sections `live` → `LAUNCH-READY`; the only\n"
            "*pre-authorized-shippable* not-live shape is §1's `NOT-READY-on-section-1`.\n"
            "**Blocking rule:** a classified product defect yields `NOT-READY-real-defects`.\n"
        )

    def _write_evidence_sources(self) -> None:
        iam = {
            "status": "success",
            "source_sha": SHA,
            "account_id": ACCOUNT_ID,
            "profile_name": PROFILE,
            "bound_role_name": ROLE,
            "onhost_role_arn_sanitized": ON_HOST_ARN,
            "api_probes": {key: "ok" for key in API_NAMES.values()},
        }
        manifest = {
            "schema_version": 1,
            "source_sha": SHA,
            "billing_month": BILLING_MONTH,
            "all_green": True,
            "n": 6,
            "probes": [
                {"probe_id": probe_id, "pass": True, "rc": 0}
                for probe_id in SECTION1_PROBE_IDS
            ],
        }
        verdict = {
            "verdict": "LAUNCH-READY",
            "pre_authorized_shape_match": True,
            "other_real_count": 0,
            "summary_required_set_complete": True,
            "non_pass_steps": [],
        }
        write_json(self.iam_owner, iam)
        write_json(self.manifest, manifest)
        write_json(self.rc_verdict, verdict)
        write_json(self.manifest_owner, manifest)
        write_json(self.rc_owner, verdict)
        write_json(self.rc_summary_owner, {"ready": True, "steps": []})
        write_json(self.rc_run_receipt_owner, {"status": "complete", "sha": SHA})
        write_json(self.iam_validation, iam)

    def _write_validation_receipts(self) -> None:
        write_json(
            self.section1_validation,
            {
                "status": "validated",
                "manifest_digest": digest(self.manifest),
                "sha": SHA,
                "billing_month": BILLING_MONTH,
                "manifest_path": str(self.manifest),
            },
        )
        write_json(
            self.rc_validation,
            {
                "status": "validated",
                "sha": SHA,
                "section1_manifest_digest": digest(self.manifest),
                "verdict_digest": digest(self.rc_verdict),
                "summary_digest": digest(self.rc_summary_owner),
                "run_receipt_digest": digest(self.rc_run_receipt_owner),
                "verdict_path": str(self.rc_verdict),
            },
        )

    def relative(self, path: Path) -> str:
        return path.relative_to(self.root).as_posix()

    def rewrite_closeout(self, mutate=None) -> None:
        payload = {
            "schema_version": 1,
            "sha": SHA,
            "billing_month": BILLING_MONTH,
            "final_verdict": "LAUNCH-READY",
            "committed_evidence": {
                "iam": {
                    "path": self.relative(self.iam_owner),
                    "digest": digest(self.iam_owner),
                },
                "section1": {
                    "path": self.relative(self.manifest_owner),
                    "digest": digest(self.manifest_owner),
                },
                "rc": {
                    "path": self.relative(self.rc_owner),
                    "digest": digest(self.rc_owner),
                    "summary_path": self.relative(self.rc_summary_owner),
                    "summary_digest": digest(self.rc_summary_owner),
                    "run_receipt_path": self.relative(self.rc_run_receipt_owner),
                    "run_receipt_digest": digest(self.rc_run_receipt_owner),
                },
            },
            "source_paths": {
                "section1_manifest": str(self.manifest.resolve()),
                "rc_verdict": str(self.rc_verdict.resolve()),
            },
            "validation_paths": {
                "iam": str(self.iam_validation.resolve()),
                "section1": str(self.section1_validation.resolve()),
                "rc": str(self.rc_validation.resolve()),
            },
            "iam_identity": {
                "account_id": ACCOUNT_ID,
                "profile_name": PROFILE,
                "bound_role_name": ROLE,
                "onhost_role_arn_sanitized": ON_HOST_ARN,
            },
            "status_owners": {
                "launch": {
                    "path": "LAUNCH.md",
                    "digest": digest(self.launch),
                    "expected_text": "### 2026-07-15 jul13_iam Wave 3 RC verdict — LAUNCH-READY",
                },
                "roadmap": {
                    "path": "ROADMAP.md",
                    "digest": digest(self.roadmap),
                    "expected_text": "| P1 | Public-release completion (active orchestration) | Wave 3 RC: LAUNCH-READY |",
                },
                "matrix": {
                    "path": "docs/launch_verification_matrix.md",
                    "digest": digest(self.matrix),
                    "expected_text": (
                        "not the section state). **Aggregate rule:** all sections `live` → `LAUNCH-READY`; the only"
                    ),
                },
            },
        }
        if mutate:
            mutate(payload)
        write_json(self.closeout, payload)

    def argv(self) -> list[str]:
        return [
            sys.executable,
            str(VALIDATOR),
            f"--closeout={self.closeout}",
            f"--launch={self.launch}",
            f"--roadmap={self.roadmap}",
            f"--matrix={self.matrix}",
            f"--iam-validation={self.iam_validation}",
            f"--section1-manifest={self.manifest}",
            f"--section1-validation={self.section1_validation}",
            f"--rc-verdict={self.rc_verdict}",
            f"--rc-validation={self.rc_validation}",
        ]

    def refresh_manifest_bindings(self) -> None:
        self.manifest_owner.write_bytes(self.manifest.read_bytes())
        manifest_digest = digest(self.manifest)
        section1_receipt = json.loads(self.section1_validation.read_text())
        section1_receipt["manifest_digest"] = manifest_digest
        write_json(self.section1_validation, section1_receipt)
        rc_receipt = json.loads(self.rc_validation.read_text())
        rc_receipt["section1_manifest_digest"] = manifest_digest
        write_json(self.rc_validation, rc_receipt)

    def refresh_verdict_bindings(self) -> None:
        self.rc_owner.write_bytes(self.rc_verdict.read_bytes())
        rc_receipt = json.loads(self.rc_validation.read_text())
        rc_receipt["verdict_digest"] = digest(self.rc_verdict)
        write_json(self.rc_validation, rc_receipt)

    def set_real_defect_verdict(self, **updates: object) -> None:
        verdict = {
            "verdict": "NOT-READY-real-defects",
            "pre_authorized_shape_match": False,
            "other_real_count": 1,
            "summary_required_set_complete": True,
            "non_pass_steps": [
                {
                    "name": "cargo_workspace_tests",
                    "status": "fail",
                    "reason": "workspace_tests_failed",
                    "section": 6,
                    "classification": "other_real",
                }
            ],
        }
        verdict.update(updates)
        write_json(self.rc_verdict, verdict)
        self.refresh_verdict_bindings()
        self.launch.write_text(
            self.launch.read_text().replace("LAUNCH-READY", "NOT-READY-real-defects")
        )
        self.roadmap.write_text(
            self.roadmap.read_text().replace("LAUNCH-READY", "NOT-READY-real-defects")
        )

        def mutate(payload):
            payload["final_verdict"] = "NOT-READY-real-defects"
            for name in ("launch", "roadmap"):
                owner = payload["status_owners"][name]
                owner["expected_text"] = owner["expected_text"].replace(
                    "LAUNCH-READY", "NOT-READY-real-defects"
                )
            payload["status_owners"]["matrix"]["expected_text"] = (
                "**Blocking rule:** a classified product defect yields "
                "`NOT-READY-real-defects`."
            )

        self.rewrite_closeout(mutate)

    def run(self, argv: list[str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            argv or self.argv(), capture_output=True, text=True, check=False
        )


class ValidateLaunchCloseoutTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.fixture = CloseoutFixture(Path(self.tempdir.name))

    def assert_failure(self, reason: str, argv: list[str] | None = None) -> None:
        result = self.fixture.run(argv)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(reason, result.stderr)
        self.assertNotIn('"status":"pass"', result.stdout.replace(" ", ""))

    def test_exact_wave3_contract_passes(self) -> None:
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "pass")
        self.assertEqual(payload["sha"], SHA)
        self.assertEqual(payload["final_verdict"], "LAUNCH-READY")
        self.assertEqual(payload["section1_manifest_digest"], digest(self.fixture.manifest))
        self.assertEqual(payload["rc_verdict_digest"], digest(self.fixture.rc_verdict))
        self.assertEqual(payload["closeout_path"], str(self.fixture.closeout.resolve()))

    def test_pointer_only_closeout_does_not_require_narrative(self) -> None:
        self.fixture.rewrite_closeout()
        self.assertEqual(self.fixture.run().returncode, 0)

    def test_narrative_cannot_override_source_artifact(self) -> None:
        def add_narrative(payload):
            payload["evidence_narrative"] = "All IAM API calls passed."

        self.fixture.rewrite_closeout(add_narrative)
        iam = json.loads(self.fixture.iam_validation.read_text())
        iam["status"] = "failed"
        write_json(self.fixture.iam_validation, iam)
        self.assert_failure("IAM validation status")

    def test_missing_required_arg_fails(self) -> None:
        self.assert_failure("missing required flag", self.fixture.argv()[:-1])

    def test_missing_file_fails(self) -> None:
        self.fixture.rc_validation.unlink()
        self.assert_failure("rc-validation file not found")

    def test_malformed_json_fails(self) -> None:
        self.fixture.closeout.write_text("{broken")
        self.assert_failure("closeout contains malformed JSON")

    def test_closeout_sha_drift_fails(self) -> None:
        self.fixture.rewrite_closeout(lambda payload: payload.update(sha="b" * 40))
        self.assert_failure("closeout SHA")

    def test_stale_section1_validation_digest_fails(self) -> None:
        receipt = json.loads(self.fixture.section1_validation.read_text())
        receipt["manifest_digest"] = "0" * 64
        write_json(self.fixture.section1_validation, receipt)
        self.assert_failure("Section 1 validation manifest digest")

    def test_non_green_section1_manifest_fails(self) -> None:
        manifest = json.loads(self.fixture.manifest.read_text())
        manifest["all_green"] = False
        write_json(self.fixture.manifest, manifest)
        self.fixture.refresh_manifest_bindings()
        self.fixture.rewrite_closeout()
        self.assert_failure("Section 1 manifest all_green")

    def test_failed_probe_row_fails(self) -> None:
        manifest = json.loads(self.fixture.manifest.read_text())
        manifest["probes"][2]["pass"] = False
        write_json(self.fixture.manifest, manifest)
        self.fixture.refresh_manifest_bindings()
        self.fixture.rewrite_closeout()
        self.assert_failure("all_green/probe state is neither green nor complete-red")

    def test_duplicate_section1_probe_inventory_fails(self) -> None:
        manifest = json.loads(self.fixture.manifest.read_text())
        manifest["probes"].append(dict(manifest["probes"][0]))
        write_json(self.fixture.manifest, manifest)
        self.fixture.refresh_manifest_bindings()
        self.fixture.rewrite_closeout()
        self.assert_failure("probe inventory contradicts canonical owner")

    def test_missing_section1_probe_inventory_fails(self) -> None:
        manifest = json.loads(self.fixture.manifest.read_text())
        manifest["probes"].pop()
        write_json(self.fixture.manifest, manifest)
        self.fixture.refresh_manifest_bindings()
        self.fixture.rewrite_closeout()
        self.assert_failure("probe inventory contradicts canonical owner")

    def test_iam_validation_not_passed_fails(self) -> None:
        iam = json.loads(self.fixture.iam_validation.read_text())
        iam["status"] = "failed"
        write_json(self.fixture.iam_validation, iam)
        self.assert_failure("IAM validation status")

    def test_committed_iam_owner_not_passed_fails(self) -> None:
        owner = json.loads(self.fixture.iam_owner.read_text())
        owner["status"] = "failed"
        write_json(self.fixture.iam_owner, owner)
        self.fixture.rewrite_closeout()
        self.assert_failure("committed IAM status")

    def test_missing_iam_identity_fails(self) -> None:
        iam = json.loads(self.fixture.iam_validation.read_text())
        del iam["onhost_role_arn_sanitized"]
        write_json(self.fixture.iam_validation, iam)
        self.assert_failure("IAM onhost_role_arn_sanitized")

    def test_missing_iam_api_binding_fails(self) -> None:
        iam = json.loads(self.fixture.iam_validation.read_text())
        del iam["api_probes"]["filter_log_events"]
        write_json(self.fixture.iam_validation, iam)
        self.assert_failure("IAM API FilterLogEvents")

    def test_unallowed_rc_verdict_fails(self) -> None:
        verdict = json.loads(self.fixture.rc_verdict.read_text())
        verdict["verdict"] = "NOT-READY"
        write_json(self.fixture.rc_verdict, verdict)
        self.fixture.refresh_verdict_bindings()
        self.fixture.rewrite_closeout(lambda payload: payload.update(final_verdict="NOT-READY"))
        self.assert_failure("RC verdict is not launch-allowed")

    def test_non_product_terminal_rc_verdicts_fail(self) -> None:
        for terminal_verdict in (
            "NOT-READY-setup",
            "NOT-READY-env",
            "NOT-READY-harness",
            "NOT-READY-investigate",
        ):
            with self.subTest(verdict=terminal_verdict):
                fixture = CloseoutFixture(Path(self.tempdir.name) / terminal_verdict)
                verdict = json.loads(fixture.rc_verdict.read_text())
                verdict["verdict"] = terminal_verdict
                write_json(fixture.rc_verdict, verdict)
                fixture.refresh_verdict_bindings()
                fixture.rewrite_closeout(
                    lambda payload: payload.update(final_verdict=terminal_verdict)
                )
                result = fixture.run()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("RC verdict is not launch-allowed", result.stderr)

    def test_real_defect_verdict_passes(self) -> None:
        self.fixture.set_real_defect_verdict()
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "pass")
        self.assertEqual(payload["sha"], SHA)
        self.assertEqual(payload["final_verdict"], "NOT-READY-real-defects")
        self.assertEqual(
            payload["section1_manifest_digest"], digest(self.fixture.manifest)
        )
        self.assertEqual(payload["rc_verdict_digest"], digest(self.fixture.rc_verdict))
        self.assertEqual(payload["closeout_path"], str(self.fixture.closeout.resolve()))

    def test_real_defect_requires_complete_required_step_registry(self) -> None:
        self.fixture.set_real_defect_verdict(summary_required_set_complete=False)
        self.assert_failure("required step registry is incomplete")

    def test_real_defect_count_must_match_classified_rows(self) -> None:
        self.fixture.set_real_defect_verdict(other_real_count=2)
        self.assert_failure("other_real_count")

    def test_setup_failure_cannot_masquerade_as_real_defect(self) -> None:
        self.fixture.set_real_defect_verdict(
            non_pass_steps=[
                {
                    "name": "browser_auth_setup",
                    "status": "external_secret_missing",
                    "reason": "missing_browser_credentials",
                    "section": 1,
                    "classification": "other_real",
                }
            ]
        )
        self.assert_failure("masquerades as a product defect")

    def test_investigate_failure_cannot_masquerade_as_real_defect(self) -> None:
        self.fixture.set_real_defect_verdict(
            non_pass_steps=[
                {
                    "name": "staging_runtime_smoke",
                    "status": "investigate",
                    "reason": "unknown_runtime_failure",
                    "section": 6,
                    "classification": "other_real",
                }
            ]
        )
        self.assert_failure("masquerades as a product defect")

    def test_pre_authorized_section1_verdict_passes(self) -> None:
        manifest = json.loads(self.fixture.manifest.read_text())
        manifest["all_green"] = False
        for probe in manifest["probes"]:
            probe.update({"pass": False, "rc": 1})
        write_json(self.fixture.manifest, manifest)
        self.fixture.refresh_manifest_bindings()
        verdict = json.loads(self.fixture.rc_verdict.read_text())
        verdict["verdict"] = "NOT-READY-on-section-1"
        verdict["pre_authorized_shape_match"] = True
        write_json(self.fixture.rc_verdict, verdict)
        self.fixture.refresh_verdict_bindings()
        self.fixture.launch.write_text(self.fixture.launch.read_text().replace("LAUNCH-READY", "NOT-READY-on-section-1"))
        self.fixture.roadmap.write_text(self.fixture.roadmap.read_text().replace("LAUNCH-READY", "NOT-READY-on-section-1"))

        def mutate(payload):
            payload["final_verdict"] = "NOT-READY-on-section-1"
            for name in ("launch", "roadmap"):
                owner = payload["status_owners"][name]
                owner["expected_text"] = owner["expected_text"].replace(
                    "LAUNCH-READY", "NOT-READY-on-section-1"
                )
            payload["status_owners"]["matrix"]["expected_text"] = (
                "*pre-authorized-shippable* not-live shape is §1's "
                "`NOT-READY-on-section-1`."
            )

        self.fixture.rewrite_closeout(mutate)
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_pre_authorized_section1_verdict_with_green_manifest_fails(self) -> None:
        verdict = json.loads(self.fixture.rc_verdict.read_text())
        verdict.update(
            verdict="NOT-READY-on-section-1",
            pre_authorized_shape_match=True,
        )
        write_json(self.fixture.rc_verdict, verdict)
        self.fixture.refresh_verdict_bindings()
        self.fixture.launch.write_text(
            self.fixture.launch.read_text().replace(
                "LAUNCH-READY", "NOT-READY-on-section-1"
            )
        )
        self.fixture.roadmap.write_text(
            self.fixture.roadmap.read_text().replace(
                "LAUNCH-READY", "NOT-READY-on-section-1"
            )
        )

        def mutate(payload):
            payload["final_verdict"] = "NOT-READY-on-section-1"
            for name in ("launch", "roadmap"):
                owner = payload["status_owners"][name]
                owner["expected_text"] = owner["expected_text"].replace(
                    "LAUNCH-READY", "NOT-READY-on-section-1"
                )
            payload["status_owners"]["matrix"]["expected_text"] = (
                "*pre-authorized-shippable* not-live shape is §1's "
                "`NOT-READY-on-section-1`."
            )

        self.fixture.rewrite_closeout(mutate)
        self.assert_failure("contradicts green Section 1 manifest")

    def test_section1_verdict_requires_pre_authorization_fails(self) -> None:
        verdict = json.loads(self.fixture.rc_verdict.read_text())
        verdict.update(verdict="NOT-READY-on-section-1", pre_authorized_shape_match=False)
        write_json(self.fixture.rc_verdict, verdict)
        self.fixture.refresh_verdict_bindings()
        self.fixture.rewrite_closeout(lambda payload: payload.update(final_verdict="NOT-READY-on-section-1"))
        self.assert_failure("RC verdict is not launch-allowed")

    def test_rc_other_real_count_fails(self) -> None:
        verdict = json.loads(self.fixture.rc_verdict.read_text())
        verdict["other_real_count"] = 1
        write_json(self.fixture.rc_verdict, verdict)
        self.fixture.refresh_verdict_bindings()
        self.fixture.rewrite_closeout()
        self.assert_failure("other_real_count")

    def test_stale_status_text_fails(self) -> None:
        self.fixture.launch.write_text(self.fixture.launch.read_text().replace("LAUNCH-READY", "NOT-READY"))
        self.assert_failure("launch status owner digest")

    def test_bare_verdict_status_owner_citations_fail(self) -> None:
        for owner_name in ("launch", "roadmap", "matrix"):
            with self.subTest(owner=owner_name):
                self.fixture.rewrite_closeout(
                    lambda payload: payload["status_owners"][owner_name].update(
                        expected_text="LAUNCH-READY"
                    )
                )
                self.assert_failure(
                    f"{owner_name} status owner expected_text must cite a complete line"
                )

    def test_contradictory_status_owner_lines_fail(self) -> None:
        owner_cases = {
            "launch": (
                self.fixture.launch,
                "### 2026-07-15 jul13_iam duplicate Wave 3 RC verdict — NOT-READY-on-section-1",
            ),
            "roadmap": (
                self.fixture.roadmap,
                "| P1 | Public-release completion duplicate | Wave 3 RC: NOT-READY-on-section-1 |",
            ),
            "matrix": (
                self.fixture.matrix,
                "**Aggregate rule:** duplicate state yields `NOT-READY-on-section-1`.",
            ),
        }
        original_text = {name: path.read_text() for name, (path, _) in owner_cases.items()}
        for owner_name, (path, contradictory_line) in owner_cases.items():
            with self.subTest(owner=owner_name):
                for name, (owner_path, _) in owner_cases.items():
                    owner_path.write_text(original_text[name])
                path.write_text(f"{path.read_text()}{contradictory_line}\n")
                self.fixture.rewrite_closeout()
                self.assert_failure(f"{owner_name} status owner has contradictory lines")

    def test_absolute_committed_path_fails(self) -> None:
        self.fixture.rewrite_closeout(lambda payload: payload["committed_evidence"]["iam"].update(path=str(self.fixture.iam_owner)))
        self.assert_failure("committed IAM path must be repo-relative")

    def test_dot_committed_path_fails(self) -> None:
        self.fixture.rewrite_closeout(
            lambda payload: payload["committed_evidence"]["iam"].update(
                path="docs/runbooks/evidence/ses-iam-read/./fixture/summary.json"
            )
        )
        self.assert_failure("committed IAM path contains forbidden component")

    def test_dotdot_committed_path_fails(self) -> None:
        self.fixture.rewrite_closeout(lambda payload: payload["committed_evidence"]["section1"].update(path="docs/../run_manifest.json"))
        self.assert_failure("committed Section 1 path contains forbidden component")

    def test_symlink_committed_path_fails(self) -> None:
        link = self.fixture.root / "docs/runbooks/evidence/ses-iam-read/link"
        link.symlink_to(self.fixture.iam_owner.parent, target_is_directory=True)
        self.fixture.rewrite_closeout(lambda payload: payload["committed_evidence"]["iam"].update(path="docs/runbooks/evidence/ses-iam-read/link/summary.json"))
        self.assert_failure("committed IAM path traverses symlink")

    def test_closeout_validation_path_substitution_fails(self) -> None:
        substitute = self.fixture.root / "preflight/substitute.json"
        substitute.write_bytes(self.fixture.section1_validation.read_bytes())
        argv = [
            f"--section1-validation={substitute}" if arg.startswith("--section1-validation=") else arg
            for arg in self.fixture.argv()
        ]
        self.assert_failure("Section 1 validation path substitution", argv)

    def test_closeout_committed_path_substitution_fails(self) -> None:
        substitute = self.fixture.root / "docs/runbooks/evidence/ses-coverage-a1/substitute/run_manifest.json"
        substitute.parent.mkdir(parents=True)
        substitute.write_bytes(self.fixture.manifest.read_bytes())
        argv = [
            f"--section1-manifest={substitute}" if arg.startswith("--section1-manifest=") else arg
            for arg in self.fixture.argv()
        ]
        self.assert_failure("Section 1 manifest path substitution", argv)

    def test_valid_root_committed_path_substitution_fails(self) -> None:
        substitute = self.fixture.root / (
            "docs/runbooks/evidence/ses-coverage-a1/substitute/run_manifest.json"
        )
        substitute.parent.mkdir(parents=True)
        substitute_payload = json.loads(self.fixture.manifest.read_text())
        substitute_payload["source_sha"] = "b" * 40
        write_json(substitute, substitute_payload)
        self.fixture.rewrite_closeout(
            lambda payload: payload["committed_evidence"]["section1"].update(
                path=self.fixture.relative(substitute), digest=digest(substitute)
            )
        )
        self.assert_failure("Section 1 source digest")

    def test_stale_committed_evidence_digest_fails(self) -> None:
        self.fixture.rewrite_closeout(
            lambda payload: payload["committed_evidence"]["iam"].update(
                digest="0" * 64
            )
        )
        self.assert_failure("committed IAM digest")

    def test_stale_committed_rc_summary_digest_fails(self) -> None:
        receipt = json.loads(self.fixture.rc_validation.read_text())
        receipt["summary_digest"] = "0" * 64
        write_json(self.fixture.rc_validation, receipt)
        self.assert_failure("RC validation summary digest")

    def test_unknown_flag_fails(self) -> None:
        self.assert_failure("unknown flag", self.fixture.argv() + ["--surprise=value"])

    def test_repeated_flag_fails(self) -> None:
        self.assert_failure("repeated flag", self.fixture.argv() + [f"--closeout={self.fixture.closeout}"])


if __name__ == "__main__":
    unittest.main()
