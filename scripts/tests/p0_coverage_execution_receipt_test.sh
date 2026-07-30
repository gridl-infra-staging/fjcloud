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
import shlex
import sys
from dataclasses import dataclass
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
B21_EXPECTED_PROJECT = "chromium:email-verification"
B21_EXPECTED_TITLE = "valid verification token shows success heading and login CTA"
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
PLAYWRIGHT_DURATION_SUFFIX = re.compile(
    r"\s+\([0-9]+(?:\.[0-9]+)?(?:ms|s|m)\)$"
)
SHELL_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", re.DOTALL)


@dataclass(frozen=True)
class ShellSegment:
    operator_before: str | None
    parts: list[str]


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


def shell_command_segments(command: str) -> list[ShellSegment] | None:
    # Preserve quoted separators so log/prose arguments cannot masquerade as
    # additional commands when we bind evidence to the Playwright invocation.
    raw_segments: list[tuple[str | None, str]] = []
    current: list[str] = []
    quote: str | None = None
    escaped = False
    pending_operator: str | None = None
    index = 0
    while index < len(command):
        character = command[index]
        if escaped:
            current.append(character)
            escaped = False
        elif character == "\\" and quote != "'":
            current.append(character)
            escaped = True
        elif quote is not None:
            current.append(character)
            if character == quote:
                quote = None
        elif character in ("'", '"'):
            current.append(character)
            quote = character
        elif character in ";&|\n":
            if (
                character in ("&", "|")
                and index + 1 < len(command)
                and command[index + 1] == character
            ):
                operator = character * 2
                index += 1
            else:
                operator = character
            segment = "".join(current).strip()
            if segment:
                raw_segments.append((pending_operator, segment))
            current = []
            pending_operator = operator
        else:
            current.append(character)
        index += 1
    if quote is not None or escaped:
        return None
    segment = "".join(current).strip()
    if segment:
        raw_segments.append((pending_operator, segment))

    try:
        return [
            ShellSegment(operator_before=operator, parts=shlex.split(segment))
            for operator, segment in raw_segments
        ]
    except ValueError:
        return None


def playwright_test_argument_start(parts: list[str]) -> int | None:
    command_start = 0
    while (
        command_start < len(parts)
        and SHELL_ASSIGNMENT.fullmatch(parts[command_start]) is not None
    ):
        command_start += 1
    command = parts[command_start:]
    if command[:3] == ["npx", "playwright", "test"]:
        return command_start + 3
    if command[:2] == ["playwright", "test"]:
        return command_start + 2
    if command[:4] == ["npm", "exec", "playwright", "test"]:
        return command_start + 4
    return None


def argument_matches_spec(argument: str, spec_path: str) -> bool:
    return argument in {spec_path, spec_path.removeprefix("web/")}


def line_mentions_spec_path(line: str, spec_path: str) -> bool:
    alternatives = [re.escape(spec_path), re.escape(spec_path.removeprefix("web/"))]
    pattern = re.compile(
        r"(?<![\w./-])(?:" + "|".join(alternatives) + r")(?=[:\s]|$)"
    )
    return pattern.search(line) is not None


def title_matches_expected(candidate: str, expected_title: str) -> bool:
    normalized = " ".join(candidate.split())
    if normalized == expected_title:
        return True
    if not normalized.startswith(f"{expected_title} "):
        return False
    suffix = normalized.removeprefix(f"{expected_title} ")
    return bool(suffix) and all(part.startswith("@") for part in suffix.split())


def line_has_exact_title(line: str, expected_title: str) -> bool:
    title_candidate = PLAYWRIGHT_DURATION_SUFFIX.sub("", line.rsplit("›", 1)[-1])
    return title_matches_expected(title_candidate, expected_title)


def segment_is_reachable_playwright_invocation(
    segments: list[ShellSegment],
    index: int,
) -> bool:
    operator = segments[index].operator_before
    if operator in (None, ";", "\n"):
        return True
    if operator != "&&" or index == 0:
        return False
    previous = segments[index - 1]
    return previous.parts == ["cd", "web"] and previous.operator_before in (
        None,
        ";",
        "\n",
    )


def selected_playwright_projects(arguments: list[str]) -> list[str]:
    projects: list[str] = []
    index = 0
    while index < len(arguments):
        part = arguments[index]
        if part == "--project":
            index += 1
            while index < len(arguments) and not arguments[index].startswith("-"):
                projects.append(arguments[index])
                index += 1
            continue
        if part.startswith("--project="):
            projects.append(part.removeprefix("--project="))
        index += 1
    return projects


def command_binds_b21(
    command: str,
    spec_path: str,
    expected_project: str,
    expected_title: str,
) -> bool:
    segments = shell_command_segments(command)
    if segments is None:
        return False
    for index, segment in enumerate(segments):
        parts = segment.parts
        argument_start = playwright_test_argument_start(parts)
        if argument_start is None:
            continue
        if not segment_is_reachable_playwright_invocation(segments, index):
            continue
        arguments = parts[argument_start:]
        if not any(argument_matches_spec(argument, spec_path) for argument in arguments):
            continue
        selected_project = selected_playwright_projects(arguments) == [expected_project]
        selected_title = False
        for index, part in enumerate(arguments):
            if part in ("--grep", "-g") and index + 1 < len(arguments):
                if title_matches_expected(arguments[index + 1], expected_title):
                    selected_title = True
            elif part.startswith("--grep=") and title_matches_expected(
                part.removeprefix("--grep="),
                expected_title,
            ):
                selected_title = True
        if selected_project and selected_title:
            return True
    return False


def raw_log_has_pass_line(
    raw_text: str,
    spec_path: str,
    expected_project: str | None = None,
    expected_title: str | None = None,
) -> bool:
    for raw_line in raw_text.splitlines():
        line = ANSI_ESCAPE.sub("", raw_line)
        if (
            line_mentions_spec_path(line, spec_path)
            and (
                expected_project is None
                or f"[{expected_project}]" in line
            )
            and (
                expected_title is None
                or line_has_exact_title(line, expected_title)
            )
            and PASS_MARKER.search(line) is not None
            and NON_PASS_MARKER.search(line) is None
        ):
            return True
    return False


def require_condition(errors: list[str], condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def verify_raw_log_pass_binding(errors: list[str]) -> None:
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
    explicit_spec_pass = (
        "✓ [chromium:email-verification] › "
        "tests/e2e-ui/full/auth-end-effects.spec.ts:66:2 › "
        f"Verify email end-effect › {B21_EXPECTED_TITLE} @p0_coverage"
    )
    explicit_spec_pass_with_duration = f"{explicit_spec_pass} (1.9s)"
    rejected_logs = (
        (
            ambiguous_log,
            "line-reporter mutation attributed setup:user aggregate pass to B21",
        ),
        (
            "✓ [chromium] › "
            "tests/e2e-ui/full/auth-end-effects.spec.ts:66:2 › B21",
            "generic chromium B21 pass was accepted for B21",
        ),
        (
            "✓ [chromium:email-verification] › "
            "tests/e2e-ui/full/auth-end-effects.spec.ts.backup:66:2 › "
            f"Verify email end-effect › {B21_EXPECTED_TITLE} @p0_coverage",
            "longer B21 spec path was accepted in raw log",
        ),
        (
            "✓ [chromium:email-verification] › "
            "tests/e2e-ui/full/auth-end-effects.spec.ts:66:2 › "
            "Verify email end-effect › unrelated passing test @p0_coverage",
            "unrelated same-file B21 raw pass was accepted",
        ),
        (
            "✓ [chromium:email-verification] › "
            "tests/e2e-ui/full/auth-end-effects.spec.ts:66:2 › "
            f"Verify email end-effect › {B21_EXPECTED_TITLE} with extra suffix "
            "@p0_coverage",
            "substring B21 raw title was accepted",
        ),
    )
    for raw_log, message in rejected_logs:
        require_condition(
            errors,
            not raw_log_has_pass_line(
                raw_log,
                EXPECTED_SPECS["B21"],
                B21_EXPECTED_PROJECT,
                B21_EXPECTED_TITLE,
            ),
            message,
        )
    for raw_log, message in (
        (explicit_spec_pass, "runner pass marker bound to B21 was not accepted"),
        (
            explicit_spec_pass_with_duration,
            "runner pass marker with list-reporter duration was not accepted",
        ),
    ):
        require_condition(
            errors,
            raw_log_has_pass_line(
                raw_log,
                EXPECTED_SPECS["B21"],
                B21_EXPECTED_PROJECT,
                B21_EXPECTED_TITLE,
            ),
            message,
        )


def verify_command_binding(errors: list[str]) -> None:
    base_command = (
        "npx playwright test tests/e2e-ui/full/auth-end-effects.spec.ts "
        f"--grep \"{B21_EXPECTED_TITLE} @p0_coverage\""
    )
    rejected_commands = (
        (base_command, "B21 runner command without project was accepted"),
        (
            f"{base_command} --project=chromium",
            "B21 runner command with generic chromium project was accepted",
        ),
        (
            f"echo --project=chromium:email-verification && {base_command}",
            "B21 project option from a separate shell command was accepted",
        ),
        (
            "false && npx playwright test "
            "tests/e2e-ui/full/auth-end-effects.spec.ts "
            f"--grep \"{B21_EXPECTED_TITLE} @p0_coverage\" "
            "--project=chromium:email-verification",
            "unreachable B21 Playwright command was accepted",
        ),
        (
            "npx playwright test "
            "tests/e2e-ui/full/auth-end-effects.spec.ts.backup "
            f"--grep \"{B21_EXPECTED_TITLE} @p0_coverage\" "
            "--project=chromium:email-verification",
            "longer B21 spec path was accepted in runner command",
        ),
        (
            "npx playwright test tests/e2e-ui/full/auth-end-effects.spec.ts "
            "--grep \"unrelated passing test @p0_coverage\" "
            "--project=chromium:email-verification",
            "unrelated same-file B21 runner command was accepted",
        ),
        (
            "npx playwright test tests/e2e-ui/full/auth-end-effects.spec.ts "
            f"--grep \"{B21_EXPECTED_TITLE} with extra suffix @p0_coverage\" "
            "--project=chromium:email-verification",
            "substring B21 grep title was accepted",
        ),
        (
            f"{base_command} --project=chromium:email-verification --project=chromium",
            "repeated-flag mixed B21 project selection was accepted",
        ),
        (
            f"{base_command} --project=chromium --project=chromium:email-verification",
            "repeated-flag mixed B21 project selection was accepted",
        ),
        (
            f"{base_command} --project chromium:email-verification chromium",
            "variadic mixed B21 project selection was accepted",
        ),
    )
    accepted_commands = (
        (
            f"{base_command} --project=chromium:email-verification",
            "B21 runner command with equals project form was rejected",
        ),
        (
            f"{base_command} --project chromium:email-verification",
            "B21 runner command with separated project form was rejected",
        ),
        (
            "cd web && npx playwright test "
            "tests/e2e-ui/full/auth-end-effects.spec.ts "
            f"--grep \"{B21_EXPECTED_TITLE} @p0_coverage\" "
            "--project chromium:email-verification; cd ..",
            "B21 runner command after cd web was rejected",
        ),
        (
            "CI=1 npx playwright test "
            "tests/e2e-ui/full/auth-end-effects.spec.ts "
            f"--grep \"{B21_EXPECTED_TITLE} @p0_coverage\" "
            "--project=chromium:email-verification",
            "B21 runner command with inline environment was rejected",
        ),
        (
            "npx playwright test tests/e2e-ui/full/auth-end-effects.spec.ts "
            f"-g \"{B21_EXPECTED_TITLE} @p0_coverage\" "
            "--project=chromium:email-verification",
            "B21 runner command with short grep option was rejected",
        ),
    )
    for command, message in rejected_commands:
        require_condition(
            errors,
            not command_binds_b21(
                command,
                EXPECTED_SPECS["B21"],
                B21_EXPECTED_PROJECT,
                B21_EXPECTED_TITLE,
            ),
            message,
        )
    for command, message in accepted_commands:
        require_condition(
            errors,
            command_binds_b21(
                command,
                EXPECTED_SPECS["B21"],
                B21_EXPECTED_PROJECT,
                B21_EXPECTED_TITLE,
            ),
            message,
        )


def verify_line_reporter_pass_binding(errors: list[str]) -> None:
    verify_raw_log_pass_binding(errors)
    verify_command_binding(errors)


def validate_required_row_fields(row: Any, label: str, errors: list[str]) -> bool:
    if not isinstance(row, dict):
        errors.append(f"{label} must be an object")
        return False
    for field in REQUIRED_FIELDS:
        value = row.get(field)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{label}.{field} must be a non-empty string")
    return True


def validate_row_identity(row: dict[str, Any], label: str, errors: list[str]) -> None:
    row_id = row.get("row_id")
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


def validate_runner_command(row: dict[str, Any], label: str, errors: list[str]) -> None:
    row_id = row.get("row_id")
    spec_path = row.get("spec_path")
    runner_command = row.get("runner_command")
    if not isinstance(runner_command, str) or not isinstance(spec_path, str):
        return
    if not command_mentions_spec(runner_command, spec_path):
        errors.append(f"{label}.runner_command does not name its spec_path")
    if row_id != "B21":
        return
    if not command_binds_b21(
        runner_command,
        spec_path,
        B21_EXPECTED_PROJECT,
        B21_EXPECTED_TITLE,
    ):
        errors.append(
            f"{label}.runner_command for B21 must run reachable Playwright "
            f"evidence for {spec_path!r}, --project={B21_EXPECTED_PROJECT}, "
            f"and title {B21_EXPECTED_TITLE!r}"
        )


def validate_recorded_at(
    row: dict[str, Any],
    label: str,
    now: datetime,
    max_age_days: int,
    errors: list[str],
) -> None:
    recorded_at = row.get("recorded_at")
    if not isinstance(recorded_at, str):
        return
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


def validate_raw_log(
    row: dict[str, Any],
    label: str,
    bundle: Path,
    errors: list[str],
) -> None:
    row_id = row.get("row_id")
    spec_path = row.get("spec_path")
    raw_log = row.get("raw_log")
    if not isinstance(raw_log, str) or not raw_log.strip():
        return

    raw_relative = Path(raw_log)
    if raw_relative.is_absolute():
        errors.append(f"{label}.raw_log must be bundle-relative")
        return

    raw_root = (bundle / "raw").resolve()
    raw_path = (bundle / raw_relative).resolve()
    try:
        raw_path.relative_to(raw_root)
    except ValueError:
        errors.append(f"{label}.raw_log escapes the bundle raw/ directory")
        return

    if not raw_path.is_file():
        errors.append(f"{label}.raw_log does not exist: {raw_log!r}")
        return
    if raw_path.stat().st_size == 0:
        errors.append(f"{label}.raw_log is empty: {raw_log!r}")
        return

    try:
        raw_text = raw_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        errors.append(f"{label}.raw_log is unreadable text: {exc}")
        return
    expected_project = B21_EXPECTED_PROJECT if row_id == "B21" else None
    expected_title = B21_EXPECTED_TITLE if row_id == "B21" else None
    if isinstance(spec_path, str) and not raw_log_has_pass_line(
        raw_text,
        spec_path,
        expected_project,
        expected_title,
    ):
        project_requirement = (
            f" in project {expected_project!r}"
            if expected_project is not None
            else ""
        )
        title_requirement = (
            f" with title {expected_title!r}"
            if expected_title is not None
            else ""
        )
        errors.append(
            f"{label}.raw_log lacks a runner pass line for "
            f"{spec_path!r}{project_requirement}{title_requirement}"
        )


def validate_row(
    row: Any,
    index: int,
    bundle: Path,
    now: datetime,
    max_age_days: int,
    errors: list[str],
) -> str | None:
    label = f"rows[{index}]"
    if not validate_required_row_fields(row, label, errors):
        return None

    row_id = row.get("row_id")
    if not isinstance(row_id, str):
        return None

    validate_row_identity(row, label, errors)
    validate_runner_command(row, label, errors)
    validate_recorded_at(row, label, now, max_age_days, errors)
    validate_raw_log(row, label, bundle, errors)
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
