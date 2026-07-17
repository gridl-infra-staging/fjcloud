#!/usr/bin/env python3
"""Regression tests for Stage 1 preflight state bootstrap."""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BOOTSTRAP_SCRIPT = REPO_ROOT / "scripts/w3_triage/bootstrap_preflight_state.sh"
STATE_FILE = Path("/tmp/w3_triage_state.env")


class BootstrapPreflightStateTests(unittest.TestCase):
    _state_backup: str | None = None

    @classmethod
    def setUpClass(cls) -> None:
        if STATE_FILE.exists():
            cls._state_backup = STATE_FILE.read_text(encoding="utf-8")

    @classmethod
    def tearDownClass(cls) -> None:
        if cls._state_backup is None:
            if STATE_FILE.exists():
                STATE_FILE.unlink()
            return
        STATE_FILE.write_text(cls._state_backup, encoding="utf-8")

    def setUp(self) -> None:
        self.assertTrue(
            BOOTSTRAP_SCRIPT.exists(),
            f"Missing bootstrap script under test: {BOOTSTRAP_SCRIPT}",
        )
        if STATE_FILE.exists():
            STATE_FILE.unlink()

    def _temp_repo(self) -> tuple[tempfile.TemporaryDirectory[str], Path]:
        tmp_dir = tempfile.TemporaryDirectory()
        root = Path(tmp_dir.name)
        (root / "scripts").mkdir(parents=True, exist_ok=True)
        (root / "scripts" / "w3_triage").mkdir(parents=True, exist_ok=True)
        (root / "docs" / "audits" / "feature-parity").mkdir(parents=True, exist_ok=True)
        (root / "docs" / "audits" / "test-coverage").mkdir(parents=True, exist_ok=True)

        (root / "scripts" / "probe_live_state.sh").write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                echo "probe-live-state-stub"
                """
            ),
            encoding="utf-8",
        )
        os.chmod(root / "scripts" / "probe_live_state.sh", 0o755)

        shutil.copy2(
            BOOTSTRAP_SCRIPT,
            root / "scripts" / "w3_triage" / "bootstrap_preflight_state.sh",
        )
        return tmp_dir, root

    def _write_summary(self, root: Path, rel_dir: str) -> Path:
        summary_path = root / rel_dir / "SUMMARY.md"
        summary_path.parent.mkdir(parents=True, exist_ok=True)
        summary_path.write_text("# summary\n", encoding="utf-8")
        return summary_path

    def _run_bootstrap(self, root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "scripts/w3_triage/bootstrap_preflight_state.sh"],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )

    def _to_repo_relative(self, path: Path, root: Path) -> str:
        return path.relative_to(root).as_posix()

    def _read_state(self) -> dict[str, str]:
        values: dict[str, str] = {}
        for raw_line in STATE_FILE.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line:
                continue
            if line.startswith("export "):
                line = line[len("export ") :]
            key, value = line.split("=", 1)
            values[key] = value
        return values

    def _source_state(self, cwd: Path | None = None) -> dict[str, str]:
        child = subprocess.run(
            [
                "bash",
                "-lc",
                textwrap.dedent(
                    """\
                    source /tmp/w3_triage_state.env
                    python3 - <<'PY'
                    import json
                    import os

                    print(
                        json.dumps(
                            {
                                "PARITY_SUMMARY": os.environ["PARITY_SUMMARY"],
                                "COVERAGE_SUMMARY": os.environ["COVERAGE_SUMMARY"],
                                "TS": os.environ["TS"],
                                "TRIAGE_DIR": os.environ["TRIAGE_DIR"],
                            }
                        )
                    )
                    PY
                    """
                ),
            ],
            cwd=cwd,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(child.returncode, 0, child.stderr)
        return json.loads(child.stdout)

    def test_resolves_newest_summary_paths(self) -> None:
        temp, root = self._temp_repo()
        with temp:
            older_parity = self._write_summary(
                root,
                "docs/audits/feature-parity/20260523T101010Z_fjcloud_vs_engine_dashboard",
            )
            newest_parity = self._write_summary(
                root,
                "docs/audits/feature-parity/20260524T101010Z_fjcloud_vs_engine_dashboard",
            )
            older_coverage = self._write_summary(
                root,
                "docs/audits/test-coverage/20260523T101010Z_console_index_tabs",
            )
            newest_coverage = self._write_summary(
                root,
                "docs/audits/test-coverage/20260524T101010Z_console_index_tabs",
            )

            result = self._run_bootstrap(root)
            self.assertEqual(result.returncode, 0, result.stderr)

            state = self._read_state()
            self.assertEqual(
                state["PARITY_SUMMARY"], self._to_repo_relative(newest_parity, root)
            )
            self.assertEqual(
                state["COVERAGE_SUMMARY"],
                self._to_repo_relative(newest_coverage, root),
            )
            self.assertNotEqual(
                state["PARITY_SUMMARY"], self._to_repo_relative(older_parity, root)
            )
            self.assertNotEqual(
                state["COVERAGE_SUMMARY"],
                self._to_repo_relative(older_coverage, root),
            )

    def test_missing_summary_fails_non_zero(self) -> None:
        temp, root = self._temp_repo()
        with temp:
            self._write_summary(
                root,
                "docs/audits/feature-parity/20260524T101010Z_fjcloud_vs_engine_dashboard",
            )

            result = self._run_bootstrap(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("MISSING:", result.stderr)

    def test_success_writes_only_required_state_keys(self) -> None:
        temp, root = self._temp_repo()
        with temp:
            self._write_summary(
                root,
                "docs/audits/feature-parity/20260524T101010Z_fjcloud_vs_engine_dashboard",
            )
            self._write_summary(
                root,
                "docs/audits/test-coverage/20260524T101010Z_console_index_tabs",
            )

            result = self._run_bootstrap(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(STATE_FILE.exists(), "state file was not written")

            state = self._read_state()
            self.assertEqual(
                set(state.keys()),
                {"PARITY_SUMMARY", "COVERAGE_SUMMARY", "TS", "TRIAGE_DIR"},
            )
            self.assertRegex(state["TS"], r"^\d{8}T\d{6}Z$")
            self.assertEqual(state["TRIAGE_DIR"], f"docs/audits/triage/{state['TS']}")

    def test_sourced_state_exports_values_to_child_processes(self) -> None:
        temp, root = self._temp_repo()
        with temp:
            self._write_summary(
                root,
                "docs/audits/feature-parity/20260524T101010Z_fjcloud_vs_engine_dashboard",
            )
            self._write_summary(
                root,
                "docs/audits/test-coverage/20260524T202020Z_console_index_tabs",
            )

            result = self._run_bootstrap(root)
            self.assertEqual(result.returncode, 0, result.stderr)

            sourced = self._source_state()
            state = self._read_state()
            self.assertEqual(sourced["TS"], state["TS"])
            self.assertEqual(sourced["TRIAGE_DIR"], state["TRIAGE_DIR"])

    def test_state_file_shell_escapes_summary_paths(self) -> None:
        temp, root = self._temp_repo()
        with temp:
            parity = self._write_summary(
                root,
                "docs/audits/feature-parity/20260524T101010Z $(touch hacked)_fjcloud_vs_engine_dashboard",
            )
            coverage = self._write_summary(
                root,
                "docs/audits/test-coverage/20260524T202020Z space $(touch hacked)_console_index_tabs",
            )
            injected_path = root / "hacked"

            result = self._run_bootstrap(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(injected_path.exists(), "path content executed during bootstrap")

            sourced = self._source_state(root)
            self.assertFalse(injected_path.exists(), "path content executed while sourcing state")
            self.assertEqual(
                sourced["PARITY_SUMMARY"],
                self._to_repo_relative(parity, root),
            )
            self.assertEqual(
                sourced["COVERAGE_SUMMARY"],
                self._to_repo_relative(coverage, root),
            )

    def test_state_file_permissions_are_owner_only(self) -> None:
        temp, root = self._temp_repo()
        with temp:
            self._write_summary(
                root,
                "docs/audits/feature-parity/20260524T101010Z_fjcloud_vs_engine_dashboard",
            )
            self._write_summary(
                root,
                "docs/audits/test-coverage/20260524T202020Z_console_index_tabs",
            )

            result = self._run_bootstrap(root)
            self.assertEqual(result.returncode, 0, result.stderr)

            mode = stat.S_IMODE(STATE_FILE.stat().st_mode)
            self.assertEqual(mode & 0o077, 0, oct(mode))


if __name__ == "__main__":
    unittest.main()
