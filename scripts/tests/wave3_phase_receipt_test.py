#!/usr/bin/env python3
"""Tests for scripts/launch/wave3_phase_receipt.py."""

from __future__ import annotations

import json
import hashlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Callable


REPO_ROOT = Path(__file__).resolve().parent.parent.parent
OWNER = REPO_ROOT / "scripts" / "launch" / "wave3_phase_receipt.py"
BASE_SHA = "a" * 40

ALPHA_SHA256 = "b6a98d9ce9a2d9149288fa3df42d377c3e42737afdcdaf714e33c0a100b51060"
BRAVO_SHA256 = "5da8f23decf397b13f4f55b6fb8a61936238bfe08ed9d901132974f1beccc45c"
COPY_SHA256 = "4d00967e353d87ca937a76b4b1dafe6a72fd872e4f8370534972ec111cb86c0e"
CHANGED_ALPHA_SHA256 = "7f8b1dfc466b6249f06cbe55c9174df2578e7754da793fded244ef5cba2a38f1"


def run_owner(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(OWNER), *args],
        capture_output=True,
        text=True,
    )


def write_fixture_files(lane_root: Path) -> None:
    (lane_root / "phase_a").mkdir(parents=True)
    (lane_root / "copies").mkdir()
    (lane_root / "phase_a" / "alpha.txt").write_text("alpha\n")
    (lane_root / "phase_a" / "bravo.txt").write_text("bravo\n")
    (lane_root / "phase_a" / "source.txt").write_text("copy\n")
    shutil.copyfile(lane_root / "phase_a" / "source.txt", lane_root / "copies" / "source.txt")


def receipt_path(lane_root: Path, phase: str) -> Path:
    name_by_phase = {
        "preflight": "preflight_pass.json",
        "section1": "section1_pass.json",
        "rc": "rc_pass.json",
    }
    return receipt_root(lane_root) / name_by_phase[phase]


def receipt_root(lane_root: Path) -> Path:
    return lane_root / "tmp" / f"jul13_wave3_phases_{BASE_SHA}"


def base_args(lane_root: Path, phase: str = "preflight") -> list[str]:
    return [
        "--lane-root", str(lane_root),
        "--base-sha", BASE_SHA,
        "--phase", phase,
    ]


def path_only_inventory_args() -> list[str]:
    return [
        "--inventory", "evidence=phase_a/alpha.txt",
        "--inventory", "evidence=phase_a/bravo.txt",
        "--inventory", "lane_copy_source=phase_a/source.txt",
        "--inventory", "lane_copy=copies/source.txt",
    ]


def canonical_json_bytes(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def inventory_digest(inventories: dict[str, list[dict[str, object]]]) -> str:
    return sha256_bytes(canonical_json_bytes(inventories))


def receipt_digest(receipt: dict[str, object]) -> str:
    return sha256_bytes(canonical_json_bytes({
        "schema_version": receipt["schema_version"],
        "phase": receipt["phase"],
        "sha": receipt["sha"],
        "exit_code": receipt["exit_code"],
        "selected_arm": receipt["selected_arm"],
        "inventories": receipt["inventories"],
        "inventory_digest": receipt["inventory_digest"],
        "cleanup_authorization": receipt["cleanup_authorization"],
    }))


def rewrite_receipt(
    lane_root: Path,
    update: Callable[[dict[str, object]], None],
    *,
    recompute_digest: bool = False,
) -> None:
    path = receipt_path(lane_root, "preflight")
    receipt = json.loads(path.read_text())
    update(receipt)
    if recompute_digest:
        receipt["receipt_digest"] = receipt_digest(receipt)
    path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")


def write_receipt(lane_root: Path, phase: str = "preflight") -> subprocess.CompletedProcess[str]:
    return run_owner(
        "write",
        *base_args(lane_root, phase),
        "--exit-code", "17",
        "--selected-arm", "rerun-section1",
        *path_only_inventory_args(),
    )


def validate_receipt(
    lane_root: Path,
    phase: str = "preflight",
    *,
    copies: bool = False,
    include_inventory: bool = False,
) -> subprocess.CompletedProcess[str]:
    args = [
        "validate",
        *base_args(lane_root, phase),
    ]
    if include_inventory:
        args.extend(path_only_inventory_args())
    if copies:
        args.extend(["--lane-copy", "phase_a/source.txt:copies/source.txt"])
    return run_owner(*args)


class Wave3PhaseReceiptTest(unittest.TestCase):
    def test_write_then_validate_restores_exit_code_arm_and_exact_inventory(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane_root = Path(tmp) / "lane"
            lane_root.mkdir()
            write_fixture_files(lane_root)

            write_result = write_receipt(lane_root)
            self.assertEqual(write_result.returncode, 0, write_result.stderr)
            receipt = json.loads(receipt_path(lane_root, "preflight").read_text())
            self.assertEqual(receipt["schema_version"], 1)
            self.assertEqual(receipt["phase"], "preflight")
            self.assertEqual(receipt["sha"], BASE_SHA)
            self.assertEqual(receipt["exit_code"], 17)
            self.assertEqual(receipt["selected_arm"], "rerun-section1")
            self.assertEqual(
                receipt["inventories"],
                {
                    "evidence": [
                        {"path": "phase_a/alpha.txt", "size": 6, "sha256": ALPHA_SHA256},
                        {"path": "phase_a/bravo.txt", "size": 6, "sha256": BRAVO_SHA256},
                    ],
                    "lane_copy": [
                        {"path": "copies/source.txt", "size": 5, "sha256": COPY_SHA256},
                    ],
                    "lane_copy_source": [
                        {"path": "phase_a/source.txt", "size": 5, "sha256": COPY_SHA256},
                    ],
                },
            )

            validate_result = validate_receipt(lane_root, copies=True)
            self.assertEqual(validate_result.returncode, 0, validate_result.stderr)
            restored = json.loads(validate_result.stdout)
            self.assertEqual(restored["exit_code"], 17)
            self.assertEqual(restored["selected_arm"], "rerun-section1")
            self.assertEqual(restored["inventory_digest"], receipt["inventory_digest"])
            self.assertEqual(restored["inventories"], receipt["inventories"])
            self.assertEqual(restored["cleanup_authorized"], True)

    def test_validate_rejects_stale_file_digest(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane_root = Path(tmp) / "lane"
            lane_root.mkdir()
            write_fixture_files(lane_root)
            self.assertEqual(write_receipt(lane_root).returncode, 0)
            (lane_root / "phase_a" / "alpha.txt").write_text("changed\n")

            result = validate_receipt(lane_root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("digest mismatch", result.stderr)

    def test_validate_rejects_cross_phase_receipt_substitution(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane_root = Path(tmp) / "lane"
            lane_root.mkdir()
            write_fixture_files(lane_root)
            self.assertEqual(write_receipt(lane_root, "preflight").returncode, 0)
            section1_receipt = receipt_path(lane_root, "section1")
            section1_receipt.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(receipt_path(lane_root, "preflight"), section1_receipt)

            result = validate_receipt(lane_root, "section1")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("phase mismatch", result.stderr)

    def test_validate_rejects_duplicate_inventory_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane_root = Path(tmp) / "lane"
            lane_root.mkdir()
            write_fixture_files(lane_root)
            self.assertEqual(write_receipt(lane_root).returncode, 0)
            path = receipt_path(lane_root, "preflight")
            receipt = json.loads(path.read_text())
            receipt["inventories"]["evidence"].append(receipt["inventories"]["evidence"][0])
            path.write_text(json.dumps(receipt, indent=2) + "\n")

            result = validate_receipt(lane_root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("duplicate inventory path", result.stderr)

    def test_validate_rejects_omitted_inventory_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane_root = Path(tmp) / "lane"
            lane_root.mkdir()
            write_fixture_files(lane_root)
            self.assertEqual(write_receipt(lane_root).returncode, 0)
            path = receipt_path(lane_root, "preflight")
            receipt = json.loads(path.read_text())
            receipt["inventories"]["evidence"] = receipt["inventories"]["evidence"][:1]
            path.write_text(json.dumps(receipt, indent=2) + "\n")

            result = validate_receipt(lane_root, include_inventory=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("inventory mismatch", result.stderr)

    def test_validate_rejects_lane_copy_byte_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane_root = Path(tmp) / "lane"
            lane_root.mkdir()
            write_fixture_files(lane_root)
            self.assertEqual(write_receipt(lane_root).returncode, 0)
            self.assertEqual(validate_receipt(lane_root, copies=True).returncode, 0)
            (lane_root / "copies" / "source.txt").write_text("copy!\n")

            result = validate_receipt(lane_root, copies=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("lane copy byte drift", result.stderr)

    def test_validate_rejects_tampered_restore_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane_root = Path(tmp) / "lane"
            lane_root.mkdir()
            write_fixture_files(lane_root)
            self.assertEqual(write_receipt(lane_root).returncode, 0)
            path = receipt_path(lane_root, "preflight")
            receipt = json.loads(path.read_text())
            receipt["exit_code"] = 0
            receipt["selected_arm"] = "skip-section1"
            path.write_text(json.dumps(receipt, indent=2) + "\n")

            result = validate_receipt(lane_root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("receipt_digest mismatch", result.stderr)

    def test_validate_rejects_rehashed_tampered_restore_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane_root = Path(tmp) / "lane"
            lane_root.mkdir()
            write_fixture_files(lane_root)
            self.assertEqual(write_receipt(lane_root).returncode, 0)

            def forge_restore_fields(receipt: dict[str, object]) -> None:
                receipt["exit_code"] = 0
                receipt["selected_arm"] = "skip-section1"

            rewrite_receipt(lane_root, forge_restore_fields, recompute_digest=True)

            result = validate_receipt(lane_root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("receipt anchor mismatch", result.stderr)

    def test_validate_rejects_rehashed_inventory_digest_after_lane_byte_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane_root = Path(tmp) / "lane"
            lane_root.mkdir()
            write_fixture_files(lane_root)
            self.assertEqual(write_receipt(lane_root).returncode, 0)
            (lane_root / "phase_a" / "alpha.txt").write_text("changed\n")

            def forge_inventory_digest(receipt: dict[str, object]) -> None:
                alpha = receipt["inventories"]["evidence"][0]
                alpha["size"] = 8
                alpha["sha256"] = CHANGED_ALPHA_SHA256
                receipt["inventory_digest"] = inventory_digest(receipt["inventories"])

            rewrite_receipt(lane_root, forge_inventory_digest, recompute_digest=True)

            result = validate_receipt(lane_root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("receipt anchor mismatch", result.stderr)

    def test_write_rejects_inventory_that_points_at_receipt_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane_root = Path(tmp) / "lane"
            lane_root.mkdir()
            write_fixture_files(lane_root)
            stale_receipt = receipt_path(lane_root, "preflight")
            stale_receipt.parent.mkdir(parents=True)
            stale_receipt.write_text('{"old": true}\n')

            result = run_owner(
                "write",
                *base_args(lane_root),
                "--exit-code", "0",
                "--selected-arm", "preflight",
                "--inventory", "receipt=tmp/jul13_wave3_phases_"
                f"{BASE_SHA}/preflight_pass.json",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("owner-managed receipt root", result.stderr)
            self.assertEqual(stale_receipt.read_text(), '{"old": true}\n')

    def test_write_rejects_inventory_under_receipt_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane_root = Path(tmp) / "lane"
            lane_root.mkdir()
            write_fixture_files(lane_root)
            managed_file = receipt_root(lane_root) / "nested" / "evidence.txt"
            managed_file.parent.mkdir(parents=True)
            managed_file.write_text("managed\n")

            result = run_owner(
                "write",
                *base_args(lane_root),
                "--exit-code", "0",
                "--selected-arm", "preflight",
                "--inventory", "receipt=tmp/jul13_wave3_phases_"
                f"{BASE_SHA}/nested/evidence.txt",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("owner-managed receipt root", result.stderr)
            self.assertFalse(receipt_path(lane_root, "preflight").exists())

    def test_write_rejects_symlinked_tmp_receipt_escape(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            lane_root = tmp_path / "lane"
            outside = tmp_path / "outside"
            lane_root.mkdir()
            outside.mkdir()
            write_fixture_files(lane_root)
            (lane_root / "tmp").symlink_to(outside)

            result = write_receipt(lane_root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("receipt path escapes lane root", result.stderr)
            self.assertFalse((outside / f"jul13_wave3_phases_{BASE_SHA}").exists())

    def test_validate_rejects_symlinked_tmp_receipt_escape(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            lane_root = tmp_path / "lane"
            outside = tmp_path / "outside"
            clean_lane = tmp_path / "clean_lane"
            lane_root.mkdir()
            outside.mkdir()
            clean_lane.mkdir()
            write_fixture_files(lane_root)
            write_fixture_files(clean_lane)
            self.assertEqual(write_receipt(clean_lane).returncode, 0)
            escaped_dir = outside / f"jul13_wave3_phases_{BASE_SHA}"
            escaped_dir.mkdir()
            shutil.copyfile(
                receipt_path(clean_lane, "preflight"),
                escaped_dir / "preflight_pass.json",
            )
            (lane_root / "tmp").symlink_to(outside)

            result = validate_receipt(lane_root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("receipt path escapes lane root", result.stderr)

    def test_write_rejects_in_lane_symlinked_tmp_receipt_substitution(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane_root = Path(tmp) / "lane"
            lane_root.mkdir()
            write_fixture_files(lane_root)
            (lane_root / "receipts_alt").mkdir()
            (lane_root / "tmp").symlink_to(lane_root / "receipts_alt")

            result = write_receipt(lane_root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlink components are not allowed", result.stderr)
            self.assertFalse((lane_root / "receipts_alt" / f"jul13_wave3_phases_{BASE_SHA}").exists())

    def test_validate_rejects_in_lane_symlinked_tmp_receipt_substitution(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane_root = Path(tmp) / "lane"
            clean_lane = Path(tmp) / "clean_lane"
            lane_root.mkdir()
            clean_lane.mkdir()
            write_fixture_files(lane_root)
            write_fixture_files(clean_lane)
            self.assertEqual(write_receipt(clean_lane).returncode, 0)
            receipt_alt = lane_root / "receipts_alt" / f"jul13_wave3_phases_{BASE_SHA}"
            receipt_alt.mkdir(parents=True)
            shutil.copyfile(
                receipt_path(clean_lane, "preflight"),
                receipt_alt / "preflight_pass.json",
            )
            (lane_root / "tmp").symlink_to(lane_root / "receipts_alt")

            result = validate_receipt(lane_root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlink components are not allowed", result.stderr)

    def test_write_rejects_absolute_inventory_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane_root = Path(tmp) / "lane"
            lane_root.mkdir()
            absolute_file = lane_root / "absolute.txt"
            absolute_file.write_text("alpha\n")

            result = run_owner(
                "write",
                *base_args(lane_root),
                "--exit-code", "0",
                "--selected-arm", "preflight",
                "--inventory", f"evidence={absolute_file}",
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("absolute paths are not allowed", result.stderr)

    def test_write_rejects_parent_traversal_inventory_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane_root = Path(tmp) / "lane"
            lane_root.mkdir()

            result = run_owner(
                "write",
                *base_args(lane_root),
                "--exit-code", "0",
                "--selected-arm", "preflight",
                "--inventory", "evidence=../escape.txt",
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("parent traversal", result.stderr)

    def test_write_rejects_symlink_escape(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            lane_root = tmp_path / "lane"
            outside = tmp_path / "outside"
            lane_root.mkdir()
            outside.mkdir()
            (outside / "secret.txt").write_text("alpha\n")
            (lane_root / "linked").symlink_to(outside)

            result = run_owner(
                "write",
                *base_args(lane_root),
                "--exit-code", "0",
                "--selected-arm", "preflight",
                "--inventory", "evidence=linked/secret.txt",
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("escapes lane root", result.stderr)

    def test_write_rejects_in_lane_inventory_symlink_substitution(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane_root = Path(tmp) / "lane"
            lane_root.mkdir()
            write_fixture_files(lane_root)
            (lane_root / "aliases").mkdir()
            (lane_root / "aliases" / "alpha.txt").symlink_to(lane_root / "phase_a" / "alpha.txt")

            result = run_owner(
                "write",
                *base_args(lane_root),
                "--exit-code", "0",
                "--selected-arm", "preflight",
                "--inventory", "evidence=aliases/alpha.txt",
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlink components are not allowed", result.stderr)

    def test_validate_rejects_in_lane_lane_copy_symlink_substitution(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane_root = Path(tmp) / "lane"
            lane_root.mkdir()
            write_fixture_files(lane_root)
            self.assertEqual(write_receipt(lane_root).returncode, 0)
            (lane_root / "aliases").mkdir()
            (lane_root / "aliases" / "source.txt").symlink_to(lane_root / "copies" / "source.txt")

            result = run_owner(
                "validate",
                *base_args(lane_root),
                "--lane-copy", "phase_a/source.txt:aliases/source.txt",
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlink components are not allowed", result.stderr)


if __name__ == "__main__":
    unittest.main()
