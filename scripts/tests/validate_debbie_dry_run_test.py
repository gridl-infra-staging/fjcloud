#!/usr/bin/env python3
"""Known-answer tests for the Debbie staging dry-run validator."""

from __future__ import annotations

import builtins
import importlib.util
import json
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parent.parent.parent
VALIDATOR = REPO_ROOT / "scripts" / "launch" / "validate_debbie_dry_run.py"


class DryRunFixture:
    """Hermetic Debbie config and hand-authored non-TTY transcript."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.config = root / "fixture.debbie.toml"
        self.transcript = root / "debbie_dry_run.txt"
        self._write_sources()
        self.write_config()
        self.write_transcript(self.good_lines())

    def _write_sources(self) -> None:
        for directory in ("src", "docs", "config", "public"):
            (self.root / directory).mkdir(parents=True)
        for relative_path in (
            "README.md",
            "config/settings.json",
            "legacy.txt",
        ):
            (self.root / relative_path).write_text(f"fixture: {relative_path}\n")

    def config_text(self) -> str:
        return f'''[project]
name = "fixture-project"

[repos.dev]
path = "{self.root.as_posix()}"

[repos.staging]
path = "{(self.root / 'staging').as_posix()}"
downstream = "fixture-ci"

[sync]
files = ["README.md", "config/settings.json"]

[[sync.dirs]]
path = "src/"
exclude = ["build", "*.secret"]

[[sync.dirs]]
path = "docs/"

[[sync.remap]]
from = "legacy.txt"
to = "public/legacy.txt"
'''

    def write_config(self, text: str | None = None) -> None:
        self.config.write_text(text if text is not None else self.config_text())

    def good_lines(self) -> list[str]:
        return [
            "debbie sync -> staging",
            "  project: fixture-project",
            f"  config:  {self.config.resolve()}",
            "  DOWNSTREAM: fixture-ci",
            "",
            "DRY RUN",
            "",
            "  dir  src/",
            "        exclude: ['build', '*.secret']",
            "  dir  docs/",
            "  file README.md",
            "  file config/settings.json",
            "  remap legacy.txt -> public/legacy.txt",
        ]

    def write_transcript(self, lines: list[str]) -> None:
        self.transcript.write_text("\n".join(lines) + "\n")

    def argv(self) -> list[str]:
        return [
            sys.executable,
            str(VALIDATOR),
            f"--config={self.config}",
            f"--input={self.transcript}",
        ]

    def run(self, argv: list[str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(argv or self.argv(), capture_output=True, text=True)


class ValidateDebbieDryRunTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.fixture = DryRunFixture(Path(self.temp_dir.name))

    def assert_failure(
        self,
        reason: str,
        *,
        lines: list[str] | None = None,
        argv: list[str] | None = None,
    ) -> None:
        if lines is not None:
            self.fixture.write_transcript(lines)
        result = self.fixture.run(argv)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(reason, result.stderr)
        if result.stdout.strip():
            try:
                payload = json.loads(result.stdout)
            except json.JSONDecodeError:
                payload = {}
            self.assertNotEqual(payload.get("status"), "pass", result.stdout)

    def test_known_good_transcript_emits_exact_normalized_scope(self) -> None:
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            {
                "status": "pass",
                "target": "staging",
                "project": "fixture-project",
                "config": str(self.fixture.config.resolve()),
                "downstream": "fixture-ci",
                "scope": {
                    "directories": [
                        {"path": "src", "excludes": ["build", "*.secret"]},
                        {"path": "docs", "excludes": []},
                    ],
                    "files": ["README.md", "config/settings.json"],
                    "remaps": [
                        {
                            "source": "legacy.txt",
                            "destination": "public/legacy.txt",
                        }
                    ],
                },
            },
        )

    def test_rich_wrapped_resolved_config_metadata_passes(self) -> None:
        lines = self.fixture.good_lines()
        config_line = f"  config:  {self.fixture.config.resolve()}"
        config_path = str(self.fixture.config.resolve())
        continuation_lines = [
            config_path[index : index + 80]
            for index in range(0, len(config_path), 80)
        ]
        config_index = lines.index(config_line)
        lines[config_index : config_index + 1] = ["  config:  ", *continuation_lines]
        self.fixture.write_transcript(lines)

        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["config"], config_path)

    def test_canonical_web_excludes_wrapped_by_rich_pass(self) -> None:
        canonical_excludes = [
            "node_modules",
            ".svelte-kit",
            "build",
            "dist",
            "playwright-report",
            "test-results",
        ]
        self.fixture.write_config(
            self.fixture.config_text().replace(
                'exclude = ["build", "*.secret"]',
                f"exclude = {json.dumps(canonical_excludes)}",
            )
        )
        lines = self.fixture.good_lines()
        exclude_index = lines.index("        exclude: ['build', '*.secret']")
        lines[exclude_index : exclude_index + 1] = [
            "        exclude: ['node_modules', '.svelte-kit', 'build', 'dist', ",
            "'playwright-report', 'test-results']",
        ]
        self.fixture.write_transcript(lines)

        result = self.fixture.run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout)["scope"]["directories"][0]["excludes"],
            canonical_excludes,
        )

    def test_rich_continuations_are_reconstructed_for_every_producer_field(self) -> None:
        module = self._load_validator_module()
        project_line = "  project: " + "p" * 80
        config_path = "/" + "c" * 88 + "/config.toml"
        config_line = "  config:  " + config_path
        downstream_line = "  DOWNSTREAM: " + "d" * 80
        dir_line = "  dir  " + "directory/" * 9
        file_line = "  file " + "nested/" * 11 + "file.txt"
        remap_line = (
            "  remap " + "source/" * 8 + "item -> " + "destination/" * 6 + "item"
        )
        physical_lines = [
            (1, "debbie sync -> staging"),
            *self._numbered_segments(2, project_line),
            *self._numbered_segments(5, config_line),
            *self._numbered_segments(8, downstream_line),
            (11, "DRY RUN"),
            *self._numbered_segments(12, dir_line),
            (14, "        exclude: ['node_modules', '.svelte-kit', 'build', 'dist', "),
            (15, "'playwright-report', 'test-results']"),
            *self._numbered_segments(16, file_line),
            *self._numbered_segments(18, remap_line),
        ]

        self.assertEqual(
            module._reconstruct_rich_lines(physical_lines),
            [
                (1, "debbie sync -> staging"),
                (2, project_line),
                (5, config_line),
                (8, downstream_line),
                (11, "DRY RUN"),
                (12, dir_line),
                (
                    14,
                    "        exclude: ['node_modules', '.svelte-kit', "
                    "'build', 'dist', 'playwright-report', 'test-results']",
                ),
                (16, file_line),
                (18, remap_line),
            ],
        )

    def test_short_prefix_only_rich_splits_fail_closed(self) -> None:
        good = self.fixture.good_lines()
        cases = {
            "project": (
                self._replace_one(
                    good,
                    "  project: fixture-project",
                    ["  project: ", "fixture-project"],
                ),
                "expected project metadata",
            ),
            "downstream": (
                self._replace_one(
                    good,
                    "  DOWNSTREAM: fixture-ci",
                    ["  DOWNSTREAM: ", "fixture-ci"],
                ),
                "expected DOWNSTREAM metadata",
            ),
            "dir": (
                self._replace_one(good, "  dir  src/", ["  dir  ", "src/"]),
                "unrecognized line",
            ),
            "file": (
                self._replace_one(good, "  file README.md", ["  file ", "README.md"]),
                "unrecognized line",
            ),
            "remap": (
                self._replace_one(
                    good,
                    "  remap legacy.txt -> public/legacy.txt",
                    ["  remap ", "legacy.txt -> public/legacy.txt"],
                ),
                "unrecognized line",
            ),
        }
        for label, (lines, reason) in cases.items():
            with self.subTest(label=label):
                self.assert_failure(reason, lines=lines)

    def test_string_staging_target_has_no_downstream(self) -> None:
        table_targets = f'''[repos.dev]
path = "{self.fixture.root.as_posix()}"

[repos.staging]
path = "{(self.fixture.root / 'staging').as_posix()}"
downstream = "fixture-ci"'''
        string_targets = f'''[repos]
dev = "{self.fixture.root.as_posix()}"
staging = "{(self.fixture.root / 'staging').as_posix()}"'''
        self.fixture.write_config(
            self.fixture.config_text().replace(table_targets, string_targets)
        )
        lines = [
            line
            for line in self.fixture.good_lines()
            if line != "  DOWNSTREAM: fixture-ci"
        ]
        self.fixture.write_transcript(lines)

        result = self.fixture.run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["downstream"], "")

    def test_scope_record_mutations_fail_closed(self) -> None:
        good = self.fixture.good_lines()
        cases = {
            "omitted configured file": (
                [line for line in good if line != "  file README.md"],
                "scope mismatch at record 3",
            ),
            "extra directory": (
                good + ["  dir  extra/"],
                "scope mismatch at record 6",
            ),
            "extra file": (
                good + ["  file EXTRA.md"],
                "scope mismatch at record 6",
            ),
            "extra remap": (
                good + ["  remap more.txt -> public/more.txt"],
                "scope mismatch at record 6",
            ),
            "reordered records": (
                self._swap(good, "  file README.md", "  file config/settings.json"),
                "scope mismatch at record 3",
            ),
            "duplicate directory": (
                good + ["  dir  docs/"],
                "duplicate scope record",
            ),
            "duplicate file": (
                good + ["  file README.md"],
                "duplicate scope record",
            ),
            "duplicate remap": (
                good + ["  remap legacy.txt -> public/legacy.txt"],
                "duplicate scope record",
            ),
        }
        for label, (lines, reason) in cases.items():
            with self.subTest(label=label):
                self.assert_failure(reason, lines=lines)

    def test_exclude_mutations_fail_closed(self) -> None:
        good = self.fixture.good_lines()
        exclude = "        exclude: ['build', '*.secret']"
        cases = {
            "configured exclude omitted": (
                [line for line in good if line != exclude],
                "scope mismatch at record 1",
            ),
            "exclude added to plain directory": (
                self._insert_after(good, "  dir  docs/", "        exclude: ['tmp']"),
                "scope mismatch at record 2",
            ),
            "exclude detached": (
                [line for line in good if line != exclude] + [exclude],
                "exclude line must immediately follow a dir record",
            ),
            "exclude moved to wrong directory": (
                self._insert_after(
                    [line for line in good if line != exclude],
                    "  dir  docs/",
                    exclude,
                ),
                "scope mismatch at record 1",
            ),
            "exclude is not a Python list": (
                ["        exclude: build" if line == exclude else line for line in good],
                "exclude payload must be a Python list of strings",
            ),
        }
        for label, (lines, reason) in cases.items():
            with self.subTest(label=label):
                self.assert_failure(reason, lines=lines)

    def test_metadata_mutations_fail_closed(self) -> None:
        good = self.fixture.good_lines()
        cases = {
            "target": ("debbie sync -> staging", "debbie sync -> prod", "target must be staging"),
            "project": ("  project: fixture-project", "  project: other", "project metadata mismatch"),
            "config": (
                f"  config:  {self.fixture.config.resolve()}",
                f"  config:  {self.fixture.root / 'other.toml'}",
                "config metadata mismatch",
            ),
            "downstream": ("  DOWNSTREAM: fixture-ci", "  DOWNSTREAM: manual", "downstream metadata mismatch"),
            "missing downstream": ("  DOWNSTREAM: fixture-ci", None, "missing DOWNSTREAM metadata"),
        }
        for label, (old, new, reason) in cases.items():
            with self.subTest(label=label):
                lines = [line for line in good if line != old]
                if new is not None:
                    lines.insert(good.index(old), new)
                self.assert_failure(reason, lines=lines)

    def test_unconfigured_downstream_line_fails(self) -> None:
        self.fixture.write_config(self.fixture.config_text().replace('downstream = "fixture-ci"\n', ""))
        self.assert_failure("unexpected DOWNSTREAM metadata", lines=self.fixture.good_lines())

    def test_unknown_malformed_and_format_drift_lines_fail(self) -> None:
        good = self.fixture.good_lines()
        cases = {
            "unknown line": (self._insert_after(good, "DRY RUN", "warning: maybe"), "unrecognized line"),
            "malformed record": (["  file" if line == "  file README.md" else line for line in good], "unrecognized line"),
            "changed dir delimiter": (["  dir: src/" if line == "  dir  src/" else line for line in good], "unrecognized line"),
            "changed record indentation": ([" dir  src/" if line == "  dir  src/" else line for line in good], "unrecognized line"),
            "changed metadata indentation": ([" project: fixture-project" if line == "  project: fixture-project" else line for line in good], "expected project metadata"),
            "changed remap delimiter": (["  remap legacy.txt => public/legacy.txt" if line.startswith("  remap ") else line for line in good], "unrecognized line"),
            "repeated dry-run marker": (good + ["DRY RUN"], "unexpected DRY RUN marker"),
        }
        for label, (lines, reason) in cases.items():
            with self.subTest(label=label):
                self.assert_failure(reason, lines=lines)

    def test_malformed_toml_and_invalid_config_shapes_fail(self) -> None:
        cases = {
            "invalid TOML": ("[project\n", "invalid TOML"),
            "project name type": (self.fixture.config_text().replace('name = "fixture-project"', "name = 7"), "project.name must be a nonempty string"),
            "repos type": (self.fixture.config_text().replace("[repos.dev]", "[[repos.dev]]"), "repos must be a table"),
            "files type": (self.fixture.config_text().replace('files = ["README.md", "config/settings.json"]', 'files = "README.md"'), "sync.files must be a list"),
            "directory type": (self.fixture.config_text().replace('path = "src/"', "path = 7", 1), "sync.dirs[0].path must be a nonempty string"),
            "exclude type": (self.fixture.config_text().replace('exclude = ["build", "*.secret"]', 'exclude = "build"'), "sync.dirs[0].exclude must be a list"),
            "remap shape": (self.fixture.config_text().replace('from = "legacy.txt"', "from = 7"), "sync.remap[0].from must be a nonempty string"),
            "downstream type": (self.fixture.config_text().replace('downstream = "fixture-ci"', "downstream = 7"), "repos.staging.downstream must be a string"),
            "empty string staging target": (
                self.fixture.config_text().replace(
                    f'''[repos.dev]
path = "{self.fixture.root.as_posix()}"

[repos.staging]
path = "{(self.fixture.root / 'staging').as_posix()}"
downstream = "fixture-ci"''',
                    f'''[repos]
dev = "{self.fixture.root.as_posix()}"
staging = ""''',
                ),
                "repos.staging must be a nonempty string",
            ),
        }
        for label, (config_text, reason) in cases.items():
            with self.subTest(label=label):
                self.fixture.write_config(config_text)
                self.assert_failure(reason)

    def test_unsafe_and_duplicate_config_scope_fails(self) -> None:
        base = self.fixture.config_text()
        cases = {
            "absolute file": (base.replace('"README.md"', '"/README.md"'), "sync.files[0] must be repo-relative"),
            "dotdot directory": (base.replace('path = "src/"', 'path = "src/../secret"', 1), "contains forbidden component"),
            "dot file component": (base.replace('"README.md"', '"./README.md"'), "contains forbidden component"),
            "backslash path": (base.replace('"README.md"', '"docs\\\\README.md"'), "must use POSIX separators"),
            "duplicate file": (base.replace('"README.md", "config/settings.json"', '"README.md", "README.md"'), "duplicate ownership record"),
            "duplicate directory": (base.replace('path = "docs/"', 'path = "src/"'), "duplicate ownership record"),
            "duplicate cross-kind ownership": (base.replace('"README.md", "config/settings.json"', '"src", "config/settings.json"'), "duplicate ownership record"),
        }
        for label, (config_text, reason) in cases.items():
            with self.subTest(label=label):
                self.fixture.write_config(config_text)
                self.assert_failure(reason)

    def test_missing_inputs_and_invalid_cli_flags_fail(self) -> None:
        base = self.fixture.argv()
        missing = self.fixture.root / "missing.txt"
        cases = {
            "missing config flag": (base[0:2] + [base[3]], "missing required flag: --config"),
            "missing input flag": (base[0:3], "missing required flag: --input"),
            "missing config file": ([base[0], base[1], f"--config={missing}", base[3]], "config file does not exist"),
            "missing transcript file": (base[0:3] + [f"--input={missing}"], "input file does not exist"),
            "unknown flag": (base + ["--surprise=value"], "unknown flag: --surprise"),
            "repeated flag": (base + [base[2]], "repeated flag: --config"),
            "empty config": ([base[0], base[1], "--config=", base[3]], "--config must not be empty"),
            "empty input": (base[0:3] + ["--input="], "--input must not be empty"),
            "separated flag": ([base[0], base[1], "--config", str(self.fixture.config), base[3]], "flags must use --name=value"),
        }
        for label, (argv, reason) in cases.items():
            with self.subTest(label=label):
                self.assert_failure(reason, argv=argv)

    def test_tomli_fallback_is_used_when_tomllib_is_unavailable(self) -> None:
        module = self._load_validator_module()
        fake_tomli = types.SimpleNamespace(load=object())
        real_import = builtins.__import__

        def import_with_fallback(name, *args, **kwargs):
            if name == "tomllib":
                raise ModuleNotFoundError("no tomllib")
            if name == "tomli":
                return fake_tomli
            return real_import(name, *args, **kwargs)

        with mock.patch("builtins.__import__", side_effect=import_with_fallback):
            self.assertIs(module.load_toml_module(), fake_tomli)

    def test_missing_toml_dependency_has_actionable_error(self) -> None:
        module = self._load_validator_module()
        real_import = builtins.__import__

        def import_without_toml(name, *args, **kwargs):
            if name in {"tomllib", "tomli"}:
                raise ModuleNotFoundError(f"no {name}")
            return real_import(name, *args, **kwargs)

        with mock.patch("builtins.__import__", side_effect=import_without_toml):
            with self.assertRaisesRegex(module.ValidationError, "install the 'tomli' package"):
                module.load_toml_module()

    @staticmethod
    def _swap(lines: list[str], first: str, second: str) -> list[str]:
        changed = list(lines)
        first_index, second_index = changed.index(first), changed.index(second)
        changed[first_index], changed[second_index] = changed[second_index], changed[first_index]
        return changed

    @staticmethod
    def _insert_after(lines: list[str], anchor: str, value: str) -> list[str]:
        changed = list(lines)
        changed.insert(changed.index(anchor) + 1, value)
        return changed

    @staticmethod
    def _replace_one(lines: list[str], old: str, replacements: list[str]) -> list[str]:
        changed = list(lines)
        index = changed.index(old)
        changed[index : index + 1] = replacements
        return changed

    @staticmethod
    def _numbered_segments(start_line: int, value: str) -> list[tuple[int, str]]:
        return [
            (start_line + index, value[offset : offset + 80])
            for index, offset in enumerate(range(0, len(value), 80))
        ]

    @staticmethod
    def _load_validator_module():
        spec = importlib.util.spec_from_file_location("validate_debbie_dry_run", VALIDATOR)
        if spec is None or spec.loader is None:
            raise AssertionError("could not load validator module")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module


if __name__ == "__main__":
    unittest.main()
