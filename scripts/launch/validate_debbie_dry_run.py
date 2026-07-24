#!/usr/bin/env python3
"""Validate a captured Debbie staging dry run against its TOML sync scope.

This owner validates only Debbie's advertised top-level scope and exclusions.
Debbie remains responsible for directory enumeration and exclude matching.
"""

from __future__ import annotations

import ast
import json
import re
import sys
from itertools import zip_longest
from pathlib import Path, PurePosixPath
from typing import Any, NamedTuple, Sequence


class ValidationError(Exception):
    """Raised when config, transcript, or CLI input fails closed."""


class Arguments(NamedTuple):
    config: Path
    input: Path


class ScopeRecord(NamedTuple):
    kind: str
    source: str
    destination: str
    excludes: tuple[str, ...]
    displayed_source: str
    displayed_destination: str


class ConfigScope(NamedTuple):
    project: str
    downstream: str
    records: tuple[ScopeRecord, ...]


class ParsedTranscript(NamedTuple):
    target: str
    project: str
    config: str
    downstream: str | None
    records: tuple[ScopeRecord, ...]


RICH_LOGICAL_LINE_PREFIXES = (
    "debbie sync -> ",
    "  project: ",
    "  config:  ",
    "  DOWNSTREAM: ",
    "  dir  ",
    "        exclude: ",
    "  file ",
    "  remap ",
)


def parse_args(argv: Sequence[str]) -> Arguments:
    """Parse exactly one nonempty --config= and --input= argument."""
    values: dict[str, str] = {}
    allowed = {"config", "input"}
    for argument in argv:
        if not argument.startswith("--") or "=" not in argument:
            raise ValidationError("flags must use --name=value")
        name, value = argument[2:].split("=", 1)
        if name not in allowed:
            raise ValidationError(f"unknown flag: --{name}")
        if name in values:
            raise ValidationError(f"repeated flag: --{name}")
        if not value:
            raise ValidationError(f"--{name} must not be empty")
        values[name] = value

    for name in ("config", "input"):
        if name not in values:
            raise ValidationError(f"missing required flag: --{name}")

    config_path = Path(values["config"])
    input_path = Path(values["input"])
    if not config_path.is_file():
        raise ValidationError(f"config file does not exist: {config_path}")
    if not input_path.is_file():
        raise ValidationError(f"input file does not exist: {input_path}")
    return Arguments(config=config_path.resolve(), input=input_path.resolve())


def load_toml_module() -> Any:
    """Return the standard TOML parser, with Python 3.9's tomli fallback."""
    try:
        import tomllib

        return tomllib
    except ModuleNotFoundError:
        try:
            import tomli

            return tomli
        except ModuleNotFoundError as exc:
            raise ValidationError(
                "TOML support unavailable; install the 'tomli' package on Python 3.9"
            ) from exc


def require_table(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValidationError(f"{label} must be a table")
    return value


def require_nonempty_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValidationError(f"{label} must be a nonempty string")
    return value


def require_string_list(value: object, label: str) -> list[str]:
    if not isinstance(value, list):
        raise ValidationError(f"{label} must be a list")
    for index, item in enumerate(value):
        if not isinstance(item, str) or not item:
            raise ValidationError(f"{label}[{index}] must be a nonempty string")
    return value


def normalize_scope_path(value: object, label: str) -> tuple[str, str]:
    """Validate a Debbie scope path and return normalized plus displayed forms."""
    displayed = require_nonempty_string(value, label)
    if "\\" in displayed:
        raise ValidationError(f"{label} must use POSIX separators")
    path = PurePosixPath(displayed)
    if path.is_absolute():
        raise ValidationError(f"{label} must be repo-relative")
    components = displayed.split("/")
    if any(component in {".", ".."} for component in components):
        raise ValidationError(f"{label} contains forbidden component")
    if any(component == "" for component in components[:-1]):
        raise ValidationError(f"{label} contains an empty path component")
    normalized = path.as_posix()
    if normalized in {"", "."}:
        raise ValidationError(f"{label} must identify a repo-relative path")
    return normalized, displayed


def load_config_scope(config_path: Path) -> ConfigScope:
    """Load and validate the Debbie-owned top-level sync scope."""
    toml = load_toml_module()
    try:
        with config_path.open("rb") as config_file:
            raw = toml.load(config_file)
    except Exception as exc:
        raise ValidationError(f"invalid TOML: {exc}") from exc

    root = require_table(raw, "config root")
    project = require_table(root.get("project"), "project")
    project_name = require_nonempty_string(project.get("name"), "project.name")
    repos = require_table(root.get("repos"), "repos")
    _validate_repo_targets(repos)
    staging_target = repos.get("staging")
    staging = (
        {}
        if isinstance(staging_target, str)
        else require_table(staging_target, "repos.staging")
    )
    downstream_value = staging.get("downstream", "")
    if not isinstance(downstream_value, str):
        raise ValidationError("repos.staging.downstream must be a string")

    sync = require_table(root.get("sync", {}), "sync")
    records = _load_scope_records(sync)
    _reject_duplicate_ownership(records)
    return ConfigScope(project_name, downstream_value, tuple(records))


def _validate_repo_targets(repos: dict[str, Any]) -> None:
    if "dev" not in repos:
        raise ValidationError("repos.dev is required")
    for name, target in repos.items():
        if isinstance(target, str):
            require_nonempty_string(target, f"repos.{name}")
            continue
        if not isinstance(target, dict):
            raise ValidationError("repos must be a table of string or table targets")
        for field in ("path", "github", "downstream"):
            if field in target and not isinstance(target[field], str):
                raise ValidationError(f"repos.{name}.{field} must be a string")


def _load_scope_records(sync: dict[str, Any]) -> list[ScopeRecord]:
    raw_files = require_string_list(sync.get("files", []), "sync.files")
    raw_dirs = sync.get("dirs", [])
    raw_remaps = sync.get("remap", [])
    if not isinstance(raw_dirs, list):
        raise ValidationError("sync.dirs must be a list")
    if not isinstance(raw_remaps, list):
        raise ValidationError("sync.remap must be a list")

    records: list[ScopeRecord] = []
    for index, item in enumerate(raw_dirs):
        directory = require_table(item, f"sync.dirs[{index}]")
        source, displayed = normalize_scope_path(
            directory.get("path"), f"sync.dirs[{index}].path"
        )
        excludes = require_string_list(
            directory.get("exclude", []), f"sync.dirs[{index}].exclude"
        )
        records.append(ScopeRecord("dir", source, "", tuple(excludes), displayed, ""))
    for index, item in enumerate(raw_files):
        source, displayed = normalize_scope_path(item, f"sync.files[{index}]")
        records.append(ScopeRecord("file", source, "", (), displayed, ""))
    for index, item in enumerate(raw_remaps):
        remap = require_table(item, f"sync.remap[{index}]")
        source, displayed_source = normalize_scope_path(
            remap.get("from"), f"sync.remap[{index}].from"
        )
        destination, displayed_destination = normalize_scope_path(
            remap.get("to"), f"sync.remap[{index}].to"
        )
        records.append(
            ScopeRecord(
                "remap",
                source,
                destination,
                (),
                displayed_source,
                displayed_destination,
            )
        )
    return records


def _reject_duplicate_ownership(records: Sequence[ScopeRecord]) -> None:
    owned_sources: set[str] = set()
    for record in records:
        if record.source in owned_sources:
            raise ValidationError(f"duplicate ownership record: {record.source}")
        owned_sources.add(record.source)


def parse_transcript(input_path: Path) -> ParsedTranscript:
    """Parse every nonempty line in Debbie's plain-text dry-run grammar."""
    physical_lines = [
        (number, line)
        for number, line in enumerate(input_path.read_text().splitlines(), start=1)
        if line
    ]
    if not physical_lines:
        raise ValidationError("input transcript is empty")
    numbered_lines = _reconstruct_rich_lines(physical_lines)

    cursor = 0
    target = _metadata_value(numbered_lines, cursor, r"debbie sync -> (.+)", "sync header")
    if target != "staging":
        raise ValidationError(f"target must be staging, got {target!r}")
    cursor += 1
    project = _metadata_value(numbered_lines, cursor, r"  project: (.+)", "project metadata")
    cursor += 1
    config, cursor = _parse_config_metadata(numbered_lines, cursor)

    downstream: str | None = None
    if cursor < len(numbered_lines) and numbered_lines[cursor][1].startswith("  DOWNSTREAM: "):
        downstream = _metadata_value(
            numbered_lines, cursor, r"  DOWNSTREAM: (.+)", "DOWNSTREAM metadata"
        )
        cursor += 1
    if cursor >= len(numbered_lines) or numbered_lines[cursor][1] != "DRY RUN":
        raise ValidationError("expected DRY RUN marker")
    cursor += 1

    records = _parse_scope_lines(numbered_lines[cursor:])
    return ParsedTranscript(target, project, config, downstream, tuple(records))


def _reconstruct_rich_lines(
    physical_lines: Sequence[tuple[int, str]],
) -> list[tuple[int, str]]:
    """Join continuation lines emitted by Rich's width-80 plain console."""
    logical_lines: list[tuple[int, str]] = []
    previous_segment = ""
    for number, line in physical_lines:
        previous_logical_line = logical_lines[-1][1] if logical_lines else ""
        if _starts_logical_line(line) or not _is_rich_continuation(
            previous_logical_line, previous_segment, line
        ):
            logical_lines.append((number, line))
        else:
            start_number, value = logical_lines[-1]
            logical_lines[-1] = (start_number, value + line)
        previous_segment = line
    return logical_lines


def _starts_logical_line(line: str) -> bool:
    return line == "DRY RUN" or line.startswith(RICH_LOGICAL_LINE_PREFIXES)


def _is_rich_continuation(
    previous_logical_line: str, previous_segment: str, current_segment: str
) -> bool:
    if not previous_segment:
        return False
    if len(previous_segment) == 80 and _starts_logical_line(previous_logical_line):
        return True
    return _is_exclude_list_continuation(
        previous_logical_line, previous_segment, current_segment
    )


def _is_exclude_list_continuation(
    previous_logical_line: str, previous_segment: str, current_segment: str
) -> bool:
    if not previous_logical_line.startswith("        exclude: "):
        return False
    if not previous_segment.endswith(", "):
        return False
    if "[" not in previous_logical_line:
        return False
    return current_segment.startswith(("'", '"'))


def _parse_config_metadata(
    lines: Sequence[tuple[int, str]], cursor: int
) -> tuple[str, int]:
    """Parse Rich's single-line or width-80-folded resolved config path."""
    if cursor >= len(lines):
        raise ValidationError("missing config metadata")
    number, line = lines[cursor]
    match = re.fullmatch(r"  config:  (.*)", line)
    if not match:
        raise ValidationError(f"expected config metadata on line {number}")
    if match.group(1):
        return match.group(1), cursor + 1

    continuation: list[str] = []
    cursor += 1
    while cursor < len(lines):
        _, candidate = lines[cursor]
        if candidate == "DRY RUN" or candidate.startswith("  DOWNSTREAM: "):
            break
        continuation.append(candidate)
        cursor += 1
    if not continuation:
        raise ValidationError("missing resolved config path after config metadata")
    if any(len(chunk) != 80 for chunk in continuation[:-1]) or len(continuation[-1]) > 80:
        raise ValidationError("invalid width-80 config metadata wrapping")
    return "".join(continuation), cursor


def _metadata_value(
    lines: Sequence[tuple[int, str]], cursor: int, pattern: str, label: str
) -> str:
    if cursor >= len(lines):
        raise ValidationError(f"missing {label}")
    number, line = lines[cursor]
    match = re.fullmatch(pattern, line)
    if not match:
        raise ValidationError(f"expected {label} on line {number}")
    return match.group(1)


def _parse_scope_lines(lines: Sequence[tuple[int, str]]) -> list[ScopeRecord]:
    records: list[ScopeRecord] = []
    seen: set[tuple[str, str, str]] = set()
    cursor = 0
    while cursor < len(lines):
        number, line = lines[cursor]
        if line == "DRY RUN":
            raise ValidationError(f"unexpected DRY RUN marker on line {number}")
        directory_match = re.fullmatch(r"  dir  (.+)", line)
        file_match = re.fullmatch(r"  file (.+)", line)
        remap_match = re.fullmatch(r"  remap (.+) -> (.+)", line)
        if directory_match:
            record, consumed = _parse_directory_record(lines, cursor, directory_match.group(1))
        elif file_match:
            source, displayed = normalize_scope_path(file_match.group(1), f"line {number} file")
            record, consumed = ScopeRecord("file", source, "", (), displayed, ""), 1
        elif remap_match:
            record = _parse_remap_record(number, remap_match.group(1), remap_match.group(2))
            consumed = 1
        elif re.fullmatch(r"        exclude: .+", line):
            raise ValidationError(
                f"exclude line must immediately follow a dir record (line {number})"
            )
        else:
            raise ValidationError(f"unrecognized line {number}: {line!r}")
        identity = (record.kind, record.source, record.destination)
        if identity in seen:
            raise ValidationError(f"duplicate scope record on line {number}")
        seen.add(identity)
        records.append(record)
        cursor += consumed
    return records


def _parse_directory_record(
    lines: Sequence[tuple[int, str]], cursor: int, displayed_path: str
) -> tuple[ScopeRecord, int]:
    number, _ = lines[cursor]
    source, displayed = normalize_scope_path(displayed_path, f"line {number} dir")
    excludes: tuple[str, ...] = ()
    consumed = 1
    if cursor + 1 < len(lines):
        exclude_number, exclude_line = lines[cursor + 1]
        exclude_match = re.fullmatch(r"        exclude: (.+)", exclude_line)
        if exclude_match:
            excludes = tuple(_parse_exclude_payload(exclude_match.group(1), exclude_number))
            consumed = 2
    return ScopeRecord("dir", source, "", excludes, displayed, ""), consumed


def _parse_exclude_payload(payload: str, line_number: int) -> list[str]:
    try:
        value = ast.literal_eval(payload)
    except (SyntaxError, ValueError) as exc:
        raise ValidationError(
            f"exclude payload must be a Python list of strings on line {line_number}"
        ) from exc
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise ValidationError(
            f"exclude payload must be a Python list of strings on line {line_number}"
        )
    return value


def _parse_remap_record(number: int, source_value: str, destination_value: str) -> ScopeRecord:
    source, displayed_source = normalize_scope_path(source_value, f"line {number} remap source")
    destination, displayed_destination = normalize_scope_path(
        destination_value, f"line {number} remap destination"
    )
    return ScopeRecord(
        "remap", source, destination, (), displayed_source, displayed_destination
    )


def validate_scope(
    config_path: Path, expected: ConfigScope, actual: ParsedTranscript
) -> None:
    """Bind transcript metadata and ordered records to the supplied config."""
    if actual.project != expected.project:
        raise ValidationError("project metadata mismatch")
    if actual.config != str(config_path.resolve()):
        raise ValidationError("config metadata mismatch")
    if expected.downstream:
        if actual.downstream is None:
            raise ValidationError("missing DOWNSTREAM metadata")
        if actual.downstream != expected.downstream:
            raise ValidationError("downstream metadata mismatch")
    elif actual.downstream is not None:
        raise ValidationError("unexpected DOWNSTREAM metadata")

    for index, (expected_record, actual_record) in enumerate(
        zip_longest(expected.records, actual.records), start=1
    ):
        if expected_record != actual_record:
            raise ValidationError(
                f"scope mismatch at record {index}: expected "
                f"{_describe_record(expected_record)}, got {_describe_record(actual_record)}"
            )


def _describe_record(record: ScopeRecord | None) -> str:
    if record is None:
        return "end of scope"
    if record.kind == "remap":
        return f"remap {record.displayed_source} -> {record.displayed_destination}"
    return f"{record.kind} {record.displayed_source} excludes={list(record.excludes)!r}"


def render_scope(records: Sequence[ScopeRecord]) -> dict[str, object]:
    return {
        "directories": [
            {"path": record.source, "excludes": list(record.excludes)}
            for record in records
            if record.kind == "dir"
        ],
        "files": [record.source for record in records if record.kind == "file"],
        "remaps": [
            {"source": record.source, "destination": record.destination}
            for record in records
            if record.kind == "remap"
        ],
    }


def main(argv: Sequence[str] | None = None) -> int:
    try:
        arguments = parse_args(sys.argv[1:] if argv is None else argv)
        expected = load_config_scope(arguments.config)
        actual = parse_transcript(arguments.input)
        validate_scope(arguments.config, expected, actual)
    except (OSError, UnicodeError, ValidationError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    payload = {
        "status": "pass",
        "target": actual.target,
        "project": actual.project,
        "config": actual.config,
        "downstream": expected.downstream,
        "scope": render_scope(actual.records),
    }
    print(json.dumps(payload, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
