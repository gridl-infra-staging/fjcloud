#!/usr/bin/env bash
# Fail-closed execution-evidence guard for the three routine-local P0 skip rows.
#
# The guard is hermetic: it validates committed receipt/raw-log evidence and
# in-process mutation specimens without starting the browser stack.
set -uo pipefail

usage() {
    echo "usage: p0_coverage_execution_receipt_test.sh [--evidence-root <directory>]" >&2
    echo "       p0_coverage_execution_receipt_test.sh --write-mutation <name> <evidence-root>" >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
evidence_root="$REPO_ROOT/docs/runbooks/evidence/local-p0-coverage"
mode="validate"
mutation_name=""

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
    3)
        if [ "${1:-}" != "--write-mutation" ] || [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
            usage
            exit 2
        fi
        mode="write_mutation"
        mutation_name="$2"
        evidence_root="$3"
        ;;
    *)
        usage
        exit 2
        ;;
esac

python3 - \
    "$mode" \
    "$mutation_name" \
    "$evidence_root" \
    "$REPO_ROOT/docs/runbooks/evidence/local-p0-coverage" \
    "$REPO_ROOT/scripts/probe_launch_evidence_freshness.sh" \
    "$REPO_ROOT/scripts/launch/run_browser_lane_locally.sh" <<'PY'
from __future__ import annotations

import json
import os
import re
import shutil
import shlex
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


MODE = sys.argv[1]
MUTATION_NAME = sys.argv[2]
EVIDENCE_ROOT = Path(sys.argv[3])
DEFAULT_EVIDENCE_ROOT = Path(sys.argv[4])
FRESHNESS_OWNER = Path(sys.argv[5])
LOCAL_LAUNCHER = Path(sys.argv[6])
EXPECTED_SPECS = {
    "B2": "web/tests/e2e-ui/full/billing_portal_payment_method_update.spec.ts",
    "B7": "web/tests/e2e-ui/full/upgrade_to_shared_unmocked.spec.ts",
    "B21": "web/tests/e2e-ui/full/auth-end-effects.spec.ts",
}
# Exact spec/project/title binding remains in each raw pass line below. The
# launcher static test owns the corresponding lane -> spec/project/grep pins.
ROW_LANES = {
    "B2": "billing_portal_payment_method_update",
    "B7": "upgrade_to_shared_unmocked",
    "B21": "b21_verify_email",
}
EXPECTED_ROW_TITLES = {
    "B2": (
        "row 8 @p0_coverage: setup flow attaches a distinct card via the Stripe "
        "Payment Element on /console/billing/setup"
    ),
    "B7": "downgraded free customer with default card upgrades to Paid via real Stripe",
    "B21": "valid verification token shows success heading and login CTA",
}
B21_EXPECTED_PROJECT = "chromium:email-verification"
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
EXIT_TRAILER = re.compile(r"^exit=-?[0-9]+$")


@dataclass(frozen=True)
class ShellSegment:
    operator_before: str | None
    parts: list[str]


@dataclass(frozen=True)
class MutationSpec:
    row_id: str
    expected_diagnostic: str
    raw_text: str | None = None
    receipt_field_overrides: dict[str, str] | None = None


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
        elif character == "#" and (not current or current[-1].isspace()):
            # Bash begins a comment at a '#' that opens a word (start of input
            # or after whitespace) and discards the rest of the line. Skip to
            # the next newline so a commented-out `#; launcher` tail cannot be
            # certified as a command Bash never runs.
            while index + 1 < len(command) and command[index + 1] != "\n":
                index += 1
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
                # A newline immediately after an AND-OR operator continues the
                # same list in Bash; it does not replace that operator. Only a
                # separator that actually terminates a command can become the
                # next command's operator_before value.
                pending_operator = operator
            elif operator != "\n":
                # Newlines (including the newline terminating a comment) may
                # continue a pending AND-OR list. Any other operator without a
                # command on its left is invalid shell syntax, so fail closed
                # instead of silently retaining the previous operator.
                return None
            current = []
        else:
            current.append(character)
        index += 1
    if quote is not None or escaped:
        return None
    segment = "".join(current).strip()
    if segment:
        raw_segments.append((pending_operator, segment))
    elif pending_operator in ("&&", "||", "|"):
        # Bash rejects AND-OR and pipeline operators without a command on the
        # right. Do not silently discard the trailing operator and certify an
        # earlier launcher that Bash never dispatches because parsing fails.
        return None

    try:
        return [
            ShellSegment(operator_before=operator, parts=shlex.split(segment))
            for operator, segment in raw_segments
        ]
    except ValueError:
        return None


def shell_command_start(parts: list[str]) -> int:
    command_start = 0
    while (
        command_start < len(parts)
        and SHELL_ASSIGNMENT.fullmatch(parts[command_start]) is not None
    ):
        command_start += 1
    return command_start


def playwright_test_argument_start(parts: list[str]) -> int | None:
    command_start = shell_command_start(parts)
    command = parts[command_start:]
    if command[:3] == ["npx", "playwright", "test"]:
        return command_start + 3
    if command[:2] == ["playwright", "test"]:
        return command_start + 2
    if command[:4] == ["npm", "exec", "playwright", "test"]:
        return command_start + 4
    return None


def launcher_argument_start(
    parts: list[str],
    *,
    allow_relative_path: bool,
) -> int | None:
    command_start = shell_command_start(parts)
    command = parts[command_start:]

    def is_owned_launcher_path(argument: str) -> bool:
        candidate = Path(argument)
        if not candidate.is_absolute():
            if not allow_relative_path:
                return False
            candidate = LOCAL_LAUNCHER.parents[2] / candidate
        return candidate.resolve() == LOCAL_LAUNCHER.resolve()

    if command and is_owned_launcher_path(command[0]):
        return command_start + 1
    if (
        len(command) >= 2
        and is_supported_shell_interpreter(command[0])
        and is_owned_launcher_path(command[1])
    ):
        return command_start + 2
    return None


def is_supported_shell_interpreter(command_name: str) -> bool:
    # An arbitrary or nonexistent path whose basename happens to be "bash"
    # (e.g. /definitely/missing/bash) makes real Bash exit 127 before the owned
    # launcher ever dispatches, so basename alone must not certify provenance.
    # Accept only the bare interpreter command name resolved on PATH or the exact
    # canonical system shell paths, matching deterministic_command_name()'s
    # treatment of system true/false paths.
    if "/" not in command_name:
        return command_name == "bash"
    return Path(command_name) in (Path("/bin/bash"), Path("/usr/bin/bash"))


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


def reachable_segments(segments: list[ShellSegment]) -> list[tuple[bool, bool]]:
    # Forward pass over the AND-OR list tracking the set of cumulative exit
    # statuses (can_succeed, can_fail) reaching each boundary, exactly as Bash
    # evaluates `a && b || c`: an `&&` segment runs only when the prior
    # cumulative status was success, a `||` segment only when it was failure,
    # and a skipped segment passes the prior status through unchanged. This
    # models fallbacks correctly (`false && : || launcher` reaches the launcher
    # because the failing `false` propagates past the skipped `:` to the `||`)
    # while never certifying a segment Bash would skip.
    #
    # Each entry is (possibly_runs, definitely_runs). The two differ only when
    # the prior cumulative status is non-deterministic — e.g. an unmodeled
    # command like `test 1 = 2` yields (can_succeed=True, can_fail=True), so a
    # following `&& launcher` *might* run but is not *provably* reached. Callers
    # fail closed by direction: launcher provenance is accepted only when the
    # launcher definitely runs, while a forbidden direct Playwright command is
    # rejected when it possibly runs.
    statuses: list[tuple[bool, bool]] = []
    can_succeed = False
    can_fail = False
    for index, segment in enumerate(segments):
        operator = segment.operator_before
        succeeds, fails = segment_control_flow(segment)
        if index == 0:
            possibly = True
            definitely = True
            out_succeed, out_fail = succeeds, fails
        elif operator == "&&":
            possibly = can_succeed
            definitely = can_succeed and not can_fail
            out_succeed = succeeds and can_succeed
            out_fail = (fails and can_succeed) or can_fail
        elif operator == "||":
            possibly = can_fail
            definitely = can_fail and not can_succeed
            out_succeed = (succeeds and can_fail) or can_succeed
            out_fail = fails and can_fail
        else:  # ";", "\n", "&", "|" — the prior status is discarded
            reached = can_succeed or can_fail
            possibly = reached
            definitely = reached
            out_succeed = succeeds and reached
            out_fail = fails and reached
        statuses.append((possibly, definitely))
        can_succeed, can_fail = out_succeed, out_fail
    return statuses


def segment_command(segment: ShellSegment) -> list[str]:
    command_start = shell_command_start(segment.parts)
    return segment.parts[command_start:]


def segment_may_change_working_directory(segment: ShellSegment) -> bool:
    command = segment_command(segment)
    if not command:
        return False
    return command[0] in (
        "cd",
        "pushd",
        "popd",
        ".",
        "source",
        "eval",
        # Shell grouping and command prefixes can mask a cwd-changing builtin
        # from this deliberately small parser (`{ cd /`, `time cd /`,
        # `! cd /`, `command eval 'cd /'`). Receipt commands need no such
        # constructs, so fail closed instead of certifying a later relative
        # launcher against the repository root after Bash has changed cwd.
        "{",
        "if",
        "then",
        "elif",
        "else",
        "while",
        "until",
        "for",
        "select",
        "case",
        "do",
        "time",
        "!",
        "builtin",
        "command",
    )


def shell_token_has_redirection(parts: list[str]) -> bool:
    return any(
        re.fullmatch(r"(?:[0-9]*)[<>].*", part) is not None
        for part in parts
    )


def deterministic_command_name(command_name: str) -> str | None:
    command_path = Path(command_name)
    if "/" not in command_name:
        return command_name if command_name in (":", "true", "false", "exit") else None

    deterministic_paths = {
        Path("/bin/true"): "true",
        Path("/usr/bin/true"): "true",
        Path("/bin/false"): "false",
        Path("/usr/bin/false"): "false",
    }
    return deterministic_paths.get(command_path)


def segment_control_flow(segment: ShellSegment) -> tuple[bool, bool]:
    command = segment_command(segment)
    if not command:
        return True, True
    if shell_token_has_redirection(command):
        return True, True
    # These builtins ignore any operands and always return a fixed status, so
    # their reachability contribution is deterministic regardless of trailing
    # arguments: `false ignored` still exits non-zero, `true x` / `: x` still
    # exit zero. Only shell names and exact system true/false paths are
    # deterministic; arbitrary `./true` / `./false` lookalikes may be absent or
    # do something else, so those fail closed as unknown commands.
    name = deterministic_command_name(command[0])
    if name in (":", "true"):
        return True, False
    if name == "false":
        return False, True
    if name == "exit":
        return False, False
    return True, True


def selected_launcher_lane(arguments: list[str]) -> str | None:
    lane: str | None = None
    index = 0
    while index < len(arguments):
        part = arguments[index]
        if part in ("--help", "-h"):
            return None
        if part == "--lane":
            if index + 1 >= len(arguments):
                return None
            index += 1
            if lane is not None or arguments[index].startswith("-"):
                return None
            lane = arguments[index]
        elif part == "--evidence-dir":
            if index + 1 >= len(arguments):
                return None
            index += 1
            if not arguments[index] or arguments[index].startswith("-"):
                return None
        else:
            return None
        index += 1
    return lane


def command_binds_launcher_lane(
    command: str,
    expected_lane: str,
) -> bool:
    segments = shell_command_segments(command)
    if segments is None:
        return False
    # Each launcher occurrence Bash could reach is (definitely_runs, args). We
    # reject duplicates by counting every *possibly*-reachable launcher, but
    # accept only when the sole occurrence *definitely* runs — a launcher gated
    # behind an unmodeled or deterministically-failing command is never proof
    # the lane executed.
    launcher_occurrences: list[tuple[bool, list[str]]] = []
    has_reachable_direct_playwright = False
    prior_segment_may_change_cwd = False
    statuses = reachable_segments(segments)
    for index, segment in enumerate(segments):
        possibly, definitely = statuses[index]
        if not possibly:
            continue
        if playwright_test_argument_start(segment.parts) is not None:
            has_reachable_direct_playwright = True
        argument_start = launcher_argument_start(
            segment.parts,
            allow_relative_path=not prior_segment_may_change_cwd,
        )
        if argument_start is not None:
            launcher_occurrences.append((definitely, segment.parts[argument_start:]))
        if segment_may_change_working_directory(segment):
            prior_segment_may_change_cwd = True
    return (
        len(launcher_occurrences) == 1
        and launcher_occurrences[0][0]
        and selected_launcher_lane(launcher_occurrences[0][1]) == expected_lane
        and not has_reachable_direct_playwright
    )


def launcher_provenance_diagnostic(row_label: str, lane: str) -> str:
    return (
        f"{row_label}.runner_command must invoke exactly one reachable "
        "run_browser_lane_locally.sh with "
        f"--lane {lane!r} and no reachable direct Playwright command"
    )


def raw_log_has_pass_line(
    raw_text: str,
    spec_path: str,
    expected_title: str,
    expected_project: str | None = None,
) -> bool:
    for raw_line in raw_text.splitlines():
        line = ANSI_ESCAPE.sub("", raw_line)
        if (
            line_mentions_spec_path(line, spec_path)
            and (
                expected_project is None
                or f"[{expected_project}]" in line
            )
            and line_has_exact_title(line, expected_title)
            and PASS_MARKER.search(line) is not None
            and NON_PASS_MARKER.search(line) is None
        ):
            return True
    return False


def require_condition(errors: list[str], condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def row_for_raw_log_validation(row_id: str, raw_log: str) -> dict[str, str]:
    return {
        "row_id": row_id,
        "spec_path": EXPECTED_SPECS[row_id],
        "runner_command": "unused by raw log validation self-test",
        "outcome": "executed_pass",
        "recorded_at": "2026-07-29T20:48:38Z",
        "raw_log": raw_log,
    }


def validation_errors_for_raw_log(row_id: str, raw_text: str) -> list[str]:
    with tempfile.TemporaryDirectory() as scratch:
        bundle = Path(scratch)
        raw_dir = bundle / "raw"
        raw_dir.mkdir()
        raw_path = raw_dir / f"{row_id.lower()}.log"
        raw_path.write_text(raw_text, encoding="utf-8")
        validation_errors: list[str] = []
        validate_raw_log(
            row_for_raw_log_validation(row_id, f"raw/{raw_path.name}"),
            f"self_test_{row_id}",
            bundle,
            validation_errors,
        )
    return validation_errors


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
        f"Verify email end-effect › {EXPECTED_ROW_TITLES['B21']} @p0_coverage"
    )
    explicit_b2_pass = (
        "✓  2 [chromium] › "
        "tests/e2e-ui/full/billing_portal_payment_method_update.spec.ts:210:2 › "
        f"Billing in-app payment-method updates › {EXPECTED_ROW_TITLES['B2']} "
        "@p0_coverage (14.3s)"
    )
    explicit_b7_pass = (
        "✓  1 [chromium] › "
        "tests/e2e-ui/full/upgrade_to_shared_unmocked.spec.ts:12:2 › "
        f"Upgrade-to-shared end-to-end (unmocked Stripe) › {EXPECTED_ROW_TITLES['B7']} "
        "@p0_coverage (20.5s)"
    )
    explicit_spec_pass_with_duration = f"{explicit_spec_pass} (1.9s)"
    sibling_b2_pass = (
        "✓  1 [chromium] › "
        "tests/e2e-ui/full/billing_portal_payment_method_update.spec.ts:138:2 › "
        "Billing in-app payment-method updates › updates default payment method "
        "in-app and keeps billing page stable (14.2s)"
    )
    sibling_b7_pass = (
        "✓  1 [chromium] › "
        "tests/e2e-ui/full/upgrade_to_shared_unmocked.spec.ts:12:2 › "
        "Upgrade-to-shared end-to-end (unmocked Stripe) › unrelated same-spec "
        "title @p0_coverage (20.5s)"
    )
    sibling_b21_reset_pass = (
        "✓  1 [chromium:email-verification] › "
        "tests/e2e-ui/full/auth-end-effects.spec.ts:15:2 › "
        "Reset password end-effect › valid reset token redeems password and "
        "allows login with new credentials @p0_coverage (3.7s)"
    )
    sibling_b21_forgot_pass = (
        "✓  1 [chromium:email-verification] › "
        "tests/e2e-ui/full/auth-end-effects.spec.ts:112:2 › "
        "Forgot password email delivery › forgot-password email is delivered "
        "with a valid reset link @p0_coverage (3.7s)"
    )
    rejected_validator_logs = (
        ("B2", sibling_b2_pass, "B2 sibling raw pass was accepted by validator"),
        ("B7", sibling_b7_pass, "B7 same-spec sibling raw pass was accepted"),
        (
            "B21",
            sibling_b21_reset_pass,
            "B21 reset-password sibling raw pass was accepted",
        ),
        (
            "B21",
            sibling_b21_forgot_pass,
            "B21 forgot-password sibling raw pass was accepted",
        ),
    )
    for row_id, raw_log, message in rejected_validator_logs:
        require_condition(
            errors,
            validation_errors_for_raw_log(row_id, raw_log),
            message,
        )
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
            f"Verify email end-effect › {EXPECTED_ROW_TITLES['B21']} @p0_coverage",
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
            f"Verify email end-effect › {EXPECTED_ROW_TITLES['B21']} with extra suffix "
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
                EXPECTED_ROW_TITLES["B21"],
                B21_EXPECTED_PROJECT,
            ),
            message,
        )
    for row_id, raw_log, message in (
        ("B2", explicit_b2_pass, "runner pass marker bound to B2 was not accepted"),
        ("B7", explicit_b7_pass, "runner pass marker bound to B7 was not accepted"),
        ("B21", explicit_spec_pass, "runner pass marker bound to B21 was not accepted"),
        (
            "B21",
            explicit_spec_pass_with_duration,
            "runner pass marker with list-reporter duration was not accepted",
        ),
    ):
        require_condition(
            errors,
            raw_log_has_pass_line(
                raw_log,
                EXPECTED_SPECS[row_id],
                EXPECTED_ROW_TITLES[row_id],
                B21_EXPECTED_PROJECT if row_id == "B21" else None,
            ),
            message,
        )


def verify_launcher_command_binding(errors: list[str]) -> None:
    base_command = (
        "npx playwright test tests/e2e-ui/full/auth-end-effects.spec.ts "
        f"--grep \"{EXPECTED_ROW_TITLES['B21']} @p0_coverage\""
    )
    invalid_consecutive_operator_command = (
        "false || && bash scripts/launch/run_browser_lane_locally.sh "
        "--lane b21_verify_email"
    )
    dangling_operator_commands = (
        (
            "bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email &&",
            "launcher command with dangling AND operator was accepted",
        ),
        (
            "bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email ||",
            "launcher command with dangling OR operator was accepted",
        ),
        (
            "bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email && # no following command",
            "launcher command with commented dangling AND operator was accepted",
        ),
    )
    rejected_commands = (
        (base_command, "direct B21 runner command without project was accepted"),
        (
            f"{base_command} --project=chromium",
            "direct B21 runner command with generic chromium project was accepted",
        ),
        (
            f"echo --project=chromium:email-verification && {base_command}",
            "direct B21 runner command after separate project output was accepted",
        ),
        (
            "false && npx playwright test "
            "tests/e2e-ui/full/auth-end-effects.spec.ts "
            f"--grep \"{EXPECTED_ROW_TITLES['B21']} @p0_coverage\" "
            "--project=chromium:email-verification",
            "unreachable B21 Playwright command was accepted",
        ),
        (
            "npx playwright test "
            "tests/e2e-ui/full/auth-end-effects.spec.ts.backup "
            f"--grep \"{EXPECTED_ROW_TITLES['B21']} @p0_coverage\" "
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
            f"--grep \"{EXPECTED_ROW_TITLES['B21']} with extra suffix @p0_coverage\" "
            "--project=chromium:email-verification",
            "substring B21 grep title was accepted",
        ),
        (
            f"{base_command} --project=chromium:email-verification --project=chromium",
            "direct B21 runner with repeated mixed projects was accepted",
        ),
        (
            f"{base_command} --project=chromium --project=chromium:email-verification",
            "repeated-flag mixed B21 project selection was accepted",
        ),
        (
            f"{base_command} --project chromium:email-verification chromium",
            "direct B21 runner with variadic mixed projects was accepted",
        ),
        (
            f"{base_command} --project=chromium:email-verification",
            "former equals-project direct B21 runner was accepted",
        ),
        (
            f"{base_command} --project chromium:email-verification",
            "former separated-project direct B21 runner was accepted",
        ),
        (
            "cd web && npx playwright test "
            "tests/e2e-ui/full/auth-end-effects.spec.ts "
            f"--grep \"{EXPECTED_ROW_TITLES['B21']} @p0_coverage\" "
            "--project chromium:email-verification; cd ..",
            "former cd-web direct B21 runner was accepted",
        ),
        (
            "CI=1 npx playwright test "
            "tests/e2e-ui/full/auth-end-effects.spec.ts "
            f"--grep \"{EXPECTED_ROW_TITLES['B21']} @p0_coverage\" "
            "--project=chromium:email-verification",
            "former inline-environment direct B21 runner was accepted",
        ),
        (
            "npx playwright test tests/e2e-ui/full/auth-end-effects.spec.ts "
            f"-g \"{EXPECTED_ROW_TITLES['B21']} @p0_coverage\" "
            "--project=chromium:email-verification",
            "former short-grep direct B21 runner was accepted",
        ),
        (
            "false && bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "unreachable launcher occurrence was accepted",
        ),
        (
            "false && true && bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "chained unreachable launcher occurrence was accepted",
        ),
        (
            "false ignored && bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "launcher after failing command with operands was accepted",
        ),
        (
            ": || bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "launcher after successful no-op fallback was accepted",
        ),
        (
            "/usr/bin/false && bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "launcher after path-qualified deterministic-failure builtin was accepted",
        ),
        (
            "/bin/true || bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "launcher after path-qualified deterministic-success fallback was accepted",
        ),
        (
            "./true && bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "launcher after nonexistent true-path lookalike was accepted",
        ),
        (
            "./false || bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "launcher after nonexistent false-path lookalike was accepted",
        ),
        (
            "true >/definitely/missing/path && "
            "bash scripts/launch/run_browser_lane_locally.sh --lane b21_verify_email",
            "launcher after redirected deterministic gate was accepted",
        ),
        (
            "test 1 = 2 && bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "launcher gated by an unmodeled non-builtin command was accepted",
        ),
        (
            "false &&\nbash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "launcher after trailing AND operator before newline was accepted",
        ),
        (
            "false && # note\nbash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "launcher after commented trailing AND operator was accepted",
        ),
        (
            invalid_consecutive_operator_command,
            "launcher after invalid consecutive control operators was accepted",
        ),
        *dangling_operator_commands,
        (
            "bash /definitely/missing/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "missing absolute launcher-path lookalike was accepted",
        ),
        (
            "/definitely/missing/bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "missing interpreter-path lookalike was accepted",
        ),
        (
            "/definitely/missing/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "direct missing launcher-path lookalike was accepted",
        ),
        (
            "cd /; scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "direct relative launcher after cwd change was accepted",
        ),
        (
            "cd /; bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "bash-invoked relative launcher after cwd change was accepted",
        ),
        (
            "{ cd /; scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email; }",
            "relative launcher after brace-group cwd change was accepted",
        ),
        (
            "if cd /; then :; fi; bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "relative launcher after conditional cwd change was accepted",
        ),
        (
            "time cd /; scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "relative launcher after timed cwd change was accepted",
        ),
        (
            "! cd /; scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "relative launcher after negated cwd change was accepted",
        ),
        (
            "command eval 'cd /'; scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "relative launcher after command-eval cwd change was accepted",
        ),
        (
            "echo 'scripts/launch/run_browser_lane_locally.sh --lane "
            "b21_verify_email'",
            "quoted launcher argument was accepted",
        ),
        (
            "# bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "commented launcher occurrence was accepted",
        ),
        (
            "true #; bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "launcher hidden behind an inline comment tail was accepted",
        ),
        (
            "bash scripts/launch/run_browser_lane_locally.sh "
            "--lane upgrade_to_shared_unmocked",
            "wrong launcher lane was accepted for B21",
        ),
        (
            "bash scripts/launch/run_browser_lane_locally.sh --lane b21_verify_email; "
            "bash ./scripts/launch/run_browser_lane_locally.sh --lane=b21_verify_email",
            "duplicate launcher invocations were accepted",
        ),
        (
            "bash scripts/launch/run_browser_lane_locally.sh --lane b21_verify_email && "
            "bash ./scripts/launch/run_browser_lane_locally.sh --lane=b21_verify_email",
            "conditional duplicate launcher invocations were accepted",
        ),
        (
            "bash scripts/launch/run_browser_lane_locally.sh --help "
            "--lane b21_verify_email",
            "help-mode launcher command was accepted",
        ),
        (
            "bash scripts/launch/run_browser_lane_locally.sh -h "
            "--lane b21_verify_email",
            "short-help launcher command was accepted",
        ),
        (
            "bash scripts/launch/run_browser_lane_locally.sh --lane b21_verify_email "
            "--unknown",
            "launcher command with unknown option was accepted",
        ),
        (
            "bash scripts/launch/run_browser_lane_locally.sh --lane",
            "launcher command with missing lane value was accepted",
        ),
        (
            "bash scripts/launch/run_browser_lane_locally.sh --lane b21_verify_email "
            "--evidence-dir",
            "launcher command with missing evidence-dir value was accepted",
        ),
        (
            "bash scripts/launch/run_browser_lane_locally.sh "
            "--lane=b21_verify_email",
            "launcher command with unsupported equals lane form was accepted",
        ),
        (
            "bash scripts/launch/run_browser_lane_locally.sh --lane b21_verify_email; "
            "npx playwright test tests/e2e-ui/full/auth-end-effects.spec.ts",
            "launcher command with reachable direct Playwright was accepted",
        ),
    )
    accepted_commands = (
        (
            "bash scripts/launch/run_browser_lane_locally.sh "
            "--lane billing_portal_payment_method_update",
            ROW_LANES["B2"],
            "B2 launcher command was rejected",
        ),
        (
            "bash ./scripts/launch/run_browser_lane_locally.sh "
            "--lane upgrade_to_shared_unmocked",
            ROW_LANES["B7"],
            "relative-path B7 launcher command was rejected",
        ),
        (
            "scripts/launch/run_browser_lane_locally.sh --lane b21_verify_email",
            ROW_LANES["B21"],
            "direct relative-path B21 launcher command was rejected",
        ),
        (
            f"bash {shlex.quote(str(LOCAL_LAUNCHER))} --lane b21_verify_email",
            ROW_LANES["B21"],
            "owned absolute-path B21 launcher command was rejected",
        ),
        (
            f"cd /; bash {shlex.quote(str(LOCAL_LAUNCHER))} "
            "--lane b21_verify_email",
            ROW_LANES["B21"],
            "owned absolute launcher after cwd change was rejected",
        ),
        (
            "false && cd /; bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            ROW_LANES["B21"],
            "relative launcher after unreachable cwd change was rejected",
        ),
        (
            "false && : || bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            ROW_LANES["B21"],
            "launcher Bash reaches via && / || fallback was rejected",
        ),
        (
            "false ||\nbash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            ROW_LANES["B21"],
            "launcher Bash reaches after trailing OR operator was rejected",
        ),
    )
    for command, message in rejected_commands:
        require_condition(
            errors,
            not command_binds_launcher_lane(command, ROW_LANES["B21"]),
            message,
        )
    require_condition(
        errors,
        subprocess.run(
            ["bash", "-n", "-c", invalid_consecutive_operator_command],
            check=False,
            capture_output=True,
        ).returncode
        != 0,
        "invalid consecutive control-operator specimen was accepted by Bash",
    )
    for command, _ in dangling_operator_commands:
        require_condition(
            errors,
            subprocess.run(
                ["bash", "-n", "-c", command],
                check=False,
                capture_output=True,
            ).returncode
            != 0,
            f"dangling control-operator specimen was accepted by Bash: {command!r}",
        )
    missing_launcher_probe = subprocess.run(
        [
            "bash",
            "-c",
            "bash /definitely/missing/run_browser_lane_locally.sh --lane b21_verify_email",
        ],
        check=False,
        capture_output=True,
    )
    require_condition(
        errors,
        missing_launcher_probe.returncode == 127,
        "missing launcher-path specimen did not fail before lane dispatch",
    )
    missing_interpreter_probe = subprocess.run(
        [
            "bash",
            "-c",
            "/definitely/missing/bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
        ],
        check=False,
        capture_output=True,
    )
    require_condition(
        errors,
        missing_interpreter_probe.returncode == 127,
        "missing interpreter-path specimen did not fail before lane dispatch",
    )
    for command, description in (
        (
            "cd /; scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "direct relative launcher after cwd change",
        ),
        (
            "cd /; bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "bash-invoked relative launcher after cwd change",
        ),
        (
            "{ cd /; scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email; }",
            "relative launcher after brace-group cwd change",
        ),
        (
            "if cd /; then :; fi; bash scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "relative launcher after conditional cwd change",
        ),
        (
            "time cd /; scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "relative launcher after timed cwd change",
        ),
        (
            "! cd /; scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "relative launcher after negated cwd change",
        ),
        (
            "command eval 'cd /'; scripts/launch/run_browser_lane_locally.sh "
            "--lane b21_verify_email",
            "relative launcher after command-eval cwd change",
        ),
    ):
        cwd_change_probe = subprocess.run(
            ["bash", "-c", command],
            cwd=LOCAL_LAUNCHER.parents[2],
            check=False,
            capture_output=True,
        )
        require_condition(
            errors,
            cwd_change_probe.returncode == 127,
            f"{description} specimen did not fail before lane dispatch",
        )
    with tempfile.TemporaryDirectory() as scratch:
        probe = subprocess.run(
            [
                "bash",
                "-c",
                (
                    "cd \"$1\" && ./true && printf launcher-ran"
                ),
                "bash",
                scratch,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        require_condition(
            errors,
            probe.returncode != 0 and "launcher-ran" not in probe.stdout,
            "absent ./true specimen unexpectedly reached its launcher marker",
        )
    help_probe = subprocess.run(
        [
            "bash",
            str(LOCAL_LAUNCHER),
            "--help",
            "--lane",
            ROW_LANES["B2"],
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    require_condition(
        errors,
        help_probe.returncode == 0 and "Default evidence dir:" in help_probe.stdout,
        "launcher help-mode specimen did not exit through usage",
    )
    require_condition(
        errors,
        "captured=" not in help_probe.stdout and "exit=" not in help_probe.stdout,
        "launcher help-mode specimen emitted lane-capture output",
    )
    for command, expected_lane, message in accepted_commands:
        require_condition(
            errors,
            command_binds_launcher_lane(command, expected_lane),
            message,
        )


def verify_guard_contracts(errors: list[str]) -> None:
    verify_raw_log_pass_binding(errors)
    verify_launcher_command_binding(errors)


def validate_row_lane_referential_integrity(errors: list[str]) -> None:
    try:
        launcher_source = LOCAL_LAUNCHER.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        errors.append(f"local browser launcher is unreadable: {exc}")
        return
    for row_id, lane in ROW_LANES.items():
        if lane not in launcher_source:
            errors.append(
                f"ROW_LANES[{row_id!r}] lane {lane!r} is missing from "
                "scripts/launch/run_browser_lane_locally.sh"
            )


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
    runner_command = row.get("runner_command")
    expected_lane = ROW_LANES.get(row_id)
    if not isinstance(runner_command, str) or expected_lane is None:
        return
    if not command_binds_launcher_lane(runner_command, expected_lane):
        errors.append(launcher_provenance_diagnostic(label, expected_lane))


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
    validate_exit_trailer(raw_text, label, errors)
    expected_project = B21_EXPECTED_PROJECT if row_id == "B21" else None
    expected_title = EXPECTED_ROW_TITLES.get(row_id)
    if (
        isinstance(spec_path, str)
        and isinstance(expected_title, str)
        and not raw_log_has_pass_line(
        raw_text,
        spec_path,
        expected_title,
        expected_project,
        )
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


def validate_exit_trailer(
    raw_text: str,
    label: str,
    errors: list[str],
) -> None:
    lines = raw_text.splitlines()
    nonempty_lines = [line for line in lines if line.strip()]
    trailer_candidates = [
        line for line in lines if line.strip().startswith("exit=")
    ]
    valid_trailers = [
        line for line in trailer_candidates if EXIT_TRAILER.fullmatch(line)
    ]
    malformed_trailers = [
        line for line in trailer_candidates if EXIT_TRAILER.fullmatch(line) is None
    ]

    if not trailer_candidates:
        errors.append(f"{label}.raw_log is missing an exit trailer")
    for trailer in malformed_trailers:
        errors.append(f"{label}.raw_log has malformed exit trailer: {trailer!r}")
    if len(valid_trailers) > 1:
        errors.append(f"{label}.raw_log has multiple exit trailers")
    if len(valid_trailers) == 1:
        trailer = valid_trailers[0]
        if not nonempty_lines or nonempty_lines[-1] != trailer:
            errors.append(
                f"{label}.raw_log exit trailer is not the last non-empty line"
            )
        if trailer != "exit=0":
            errors.append(
                f"{label}.raw_log reports nonzero runner status: {trailer}"
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


def mutation_passing_raw_log(row_id: str, *trailing_lines: str) -> str:
    project = (
        B21_EXPECTED_PROJECT if row_id == "B21" else "chromium"
    )
    return "\n".join(
        (
            f"  ✓  1 [{project}] › {EXPECTED_SPECS[row_id].removeprefix('web/')}:1:1 › "
            f"{EXPECTED_ROW_TITLES[row_id]} @p0_coverage (1.0s)",
            "",
            "  1 passed (1.0s)",
            *trailing_lines,
            "",
        )
    )


MUTATION_RAW_LOGS = {
    "b2_sibling_pass": MutationSpec(
        row_id="B2",
        raw_text="\n".join(
            (
                "Running 2 tests using 1 worker",
                "",
                "  ✓  1 [chromium] › tests/e2e-ui/full/"
                "billing_portal_payment_method_update.spec.ts:138:2 › "
                "Billing in-app payment-method updates › updates default payment "
                "method in-app and keeps billing page stable (14.2s)",
                "  ✘  2 [chromium] › tests/e2e-ui/full/"
                "billing_portal_payment_method_update.spec.ts:210:2 › "
                f"Billing in-app payment-method updates › {EXPECTED_ROW_TITLES['B2']} "
                "@p0_coverage (14.3s)",
                "",
                "  1 failed",
                "  1 passed (35.9s)",
                "exit=0",
            )
        ),
        expected_diagnostic="rows[0].raw_log lacks a runner pass line for "
        f"{EXPECTED_SPECS['B2']!r} with title {EXPECTED_ROW_TITLES['B2']!r}",
    ),
    "b7_sibling_title": MutationSpec(
        row_id="B7",
        raw_text="  ✓  1 [chromium] › tests/e2e-ui/full/"
        "upgrade_to_shared_unmocked.spec.ts:12:2 › Upgrade-to-shared "
        "end-to-end (unmocked Stripe) › unrelated same-spec title "
        "@p0_coverage (20.5s)\n\n  1 passed (26.2s)\nexit=0\n",
        expected_diagnostic="rows[1].raw_log lacks a runner pass line for "
        f"{EXPECTED_SPECS['B7']!r} with title {EXPECTED_ROW_TITLES['B7']!r}",
    ),
    "b21_reset_sibling": MutationSpec(
        row_id="B21",
        raw_text="  ✓  1 [chromium:email-verification] › tests/e2e-ui/full/"
        "auth-end-effects.spec.ts:15:2 › Reset password end-effect › valid reset "
        "token redeems password and allows login with new credentials "
        "@p0_coverage (3.7s)\n\n  1 passed (54.7s)\nexit=0\n",
        expected_diagnostic="rows[2].raw_log lacks a runner pass line for "
        f"{EXPECTED_SPECS['B21']!r} in project {B21_EXPECTED_PROJECT!r} "
        f"with title {EXPECTED_ROW_TITLES['B21']!r}",
    ),
    "b21_forgot_sibling": MutationSpec(
        row_id="B21",
        raw_text="  ✓  1 [chromium:email-verification] › tests/e2e-ui/full/"
        "auth-end-effects.spec.ts:112:2 › Forgot password email delivery › "
        "forgot-password email is delivered with a valid reset link "
        "@p0_coverage (3.7s)\n\n  1 passed (54.7s)\nexit=0\n",
        expected_diagnostic="rows[2].raw_log lacks a runner pass line for "
        f"{EXPECTED_SPECS['B21']!r} in project {B21_EXPECTED_PROJECT!r} "
        f"with title {EXPECTED_ROW_TITLES['B21']!r}",
    ),
    "b21_missing_exit_trailer": MutationSpec(
        row_id="B21",
        raw_text=mutation_passing_raw_log("B21"),
        expected_diagnostic="rows[2].raw_log is missing an exit trailer",
    ),
    "b2_nonzero_exit_trailer": MutationSpec(
        row_id="B2",
        raw_text=mutation_passing_raw_log("B2", "exit=1"),
        expected_diagnostic=(
            "rows[0].raw_log reports nonzero runner status: exit=1"
        ),
    ),
    "b7_duplicate_exit_trailer": MutationSpec(
        row_id="B7",
        raw_text=mutation_passing_raw_log("B7", "exit=0", "exit=0"),
        expected_diagnostic="rows[1].raw_log has multiple exit trailers",
    ),
    "b2_malformed_exit_trailer": MutationSpec(
        row_id="B2",
        raw_text=mutation_passing_raw_log("B2", "exit=success"),
        expected_diagnostic="rows[0].raw_log has malformed exit trailer: 'exit=success'",
    ),
    "b7_midfile_exit_trailer": MutationSpec(
        row_id="B7",
        raw_text=mutation_passing_raw_log("B7", "exit=0", "postscript"),
        expected_diagnostic=(
            "rows[1].raw_log exit trailer is not the last non-empty line"
        ),
    ),
    "b7_direct_runner_command": MutationSpec(
        row_id="B7",
        receipt_field_overrides={
            "runner_command": (
                "cd web && npx playwright test "
                "tests/e2e-ui/full/upgrade_to_shared_unmocked.spec.ts "
                "--project=chromium --reporter=list --no-deps"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[1]", "upgrade_to_shared_unmocked"
        ),
    ),
    "b2_wrong_launcher_lane": MutationSpec(
        row_id="B2",
        receipt_field_overrides={
            "runner_command": (
                "bash scripts/launch/run_browser_lane_locally.sh "
                "--lane upgrade_to_shared_unmocked"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[0]", "billing_portal_payment_method_update"
        ),
    ),
    "b21_chained_unreachable_launcher": MutationSpec(
        row_id="B21",
        receipt_field_overrides={
            "runner_command": (
                "false && true && bash scripts/launch/run_browser_lane_locally.sh "
                "--lane b21_verify_email"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[2]", "b21_verify_email"
        ),
    ),
    "b21_colon_or_unreachable_launcher": MutationSpec(
        row_id="B21",
        receipt_field_overrides={
            "runner_command": (
                ": || bash scripts/launch/run_browser_lane_locally.sh "
                "--lane b21_verify_email"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[2]", "b21_verify_email"
        ),
    ),
    "b21_false_operand_unreachable_launcher": MutationSpec(
        row_id="B21",
        receipt_field_overrides={
            # `false ignored` exits non-zero regardless of its operand, so Bash
            # never reaches the `&&` launcher; the guard must reject it rather
            # than treat the operand-bearing `false` as possibly successful.
            "runner_command": (
                "false ignored && bash scripts/launch/run_browser_lane_locally.sh "
                "--lane b21_verify_email"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[2]", "b21_verify_email"
        ),
    ),
    "b2_true_path_lookalike_unreachable_launcher": MutationSpec(
        row_id="B2",
        receipt_field_overrides={
            "runner_command": (
                "./true && bash scripts/launch/run_browser_lane_locally.sh "
                "--lane billing_portal_payment_method_update"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[0]", "billing_portal_payment_method_update"
        ),
    ),
    "b2_redirected_gate_unproven_launcher": MutationSpec(
        row_id="B2",
        receipt_field_overrides={
            "runner_command": (
                "true >/definitely/missing/path && "
                "bash scripts/launch/run_browser_lane_locally.sh "
                "--lane billing_portal_payment_method_update"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[0]", "billing_portal_payment_method_update"
        ),
    ),
    "b2_help_mode_launcher": MutationSpec(
        row_id="B2",
        receipt_field_overrides={
            "runner_command": (
                "bash scripts/launch/run_browser_lane_locally.sh --help "
                "--lane billing_portal_payment_method_update"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[0]", "billing_portal_payment_method_update"
        ),
    ),
    "b2_unknown_launcher_option": MutationSpec(
        row_id="B2",
        receipt_field_overrides={
            "runner_command": (
                "bash scripts/launch/run_browser_lane_locally.sh "
                "--lane billing_portal_payment_method_update --unknown"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[0]", "billing_portal_payment_method_update"
        ),
    ),
    "b2_missing_lane_value": MutationSpec(
        row_id="B2",
        receipt_field_overrides={
            "runner_command": "bash scripts/launch/run_browser_lane_locally.sh --lane"
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[0]", "billing_portal_payment_method_update"
        ),
    ),
    "b21_dangling_and_launcher": MutationSpec(
        row_id="B21",
        receipt_field_overrides={
            "runner_command": (
                "bash scripts/launch/run_browser_lane_locally.sh "
                "--lane b21_verify_email &&"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[2]", "b21_verify_email"
        ),
    ),
    "b2_missing_path_launcher_lookalike": MutationSpec(
        row_id="B2",
        receipt_field_overrides={
            "runner_command": (
                "bash /definitely/missing/run_browser_lane_locally.sh "
                "--lane billing_portal_payment_method_update"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[0]", "billing_portal_payment_method_update"
        ),
    ),
    "b2_missing_interpreter_launcher_lookalike": MutationSpec(
        row_id="B2",
        receipt_field_overrides={
            "runner_command": (
                "/definitely/missing/bash "
                "scripts/launch/run_browser_lane_locally.sh "
                "--lane billing_portal_payment_method_update"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[0]", "billing_portal_payment_method_update"
        ),
    ),
    "b21_direct_relative_launcher_after_cwd_change": MutationSpec(
        row_id="B21",
        receipt_field_overrides={
            "runner_command": (
                "cd /; scripts/launch/run_browser_lane_locally.sh "
                "--lane b21_verify_email"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[2]", "b21_verify_email"
        ),
    ),
    "b21_bash_relative_launcher_after_cwd_change": MutationSpec(
        row_id="B21",
        receipt_field_overrides={
            "runner_command": (
                "cd /; bash scripts/launch/run_browser_lane_locally.sh "
                "--lane b21_verify_email"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[2]", "b21_verify_email"
        ),
    ),
    "b21_brace_group_cwd_change_launcher": MutationSpec(
        row_id="B21",
        receipt_field_overrides={
            "runner_command": (
                "{ cd /; scripts/launch/run_browser_lane_locally.sh "
                "--lane b21_verify_email; }"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[2]", "b21_verify_email"
        ),
    ),
    "b21_conditional_cwd_change_launcher": MutationSpec(
        row_id="B21",
        receipt_field_overrides={
            "runner_command": (
                "if cd /; then :; fi; "
                "bash scripts/launch/run_browser_lane_locally.sh "
                "--lane b21_verify_email"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[2]", "b21_verify_email"
        ),
    ),
    "b21_time_cwd_change_launcher": MutationSpec(
        row_id="B21",
        receipt_field_overrides={
            "runner_command": (
                "time cd /; scripts/launch/run_browser_lane_locally.sh "
                "--lane b21_verify_email"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[2]", "b21_verify_email"
        ),
    ),
    "b21_negated_cwd_change_launcher": MutationSpec(
        row_id="B21",
        receipt_field_overrides={
            "runner_command": (
                "! cd /; scripts/launch/run_browser_lane_locally.sh "
                "--lane b21_verify_email"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[2]", "b21_verify_email"
        ),
    ),
    "b21_command_eval_cwd_change_launcher": MutationSpec(
        row_id="B21",
        receipt_field_overrides={
            "runner_command": (
                "command eval 'cd /'; "
                "scripts/launch/run_browser_lane_locally.sh "
                "--lane b21_verify_email"
            )
        },
        expected_diagnostic=launcher_provenance_diagnostic(
            "rows[2]", "b21_verify_email"
        ),
    ),
}


def latest_bundle(root: Path, errors: list[str]) -> tuple[datetime, Path] | None:
    if not root.is_dir():
        errors.append(f"receipt root is missing: {root}")
        return None

    bundles: list[tuple[datetime, Path]] = []
    for child in sorted(root.iterdir()):
        if not child.is_dir():
            continue
        timestamp = parse_utc_timestamp(child.name, "bundle", errors)
        if timestamp is not None:
            bundles.append((timestamp, child))
    if not bundles:
        errors.append("no UTC-stamped receipt bundle exists")
        return None
    return max(bundles)


def mutation_target_error(
    target_root: Path,
    evidence_root: Path = DEFAULT_EVIDENCE_ROOT,
) -> str | None:
    resolved_target = target_root.resolve()
    resolved_evidence = evidence_root.resolve()
    if (
        resolved_target == resolved_evidence
        or resolved_evidence in resolved_target.parents
        or resolved_target in resolved_evidence.parents
    ):
        return (
            "mutation target must not overlap committed evidence root: "
            f"{target_root}"
        )
    if target_root.exists() or target_root.is_symlink():
        return f"mutation target must not already exist: {target_root}"
    return None


def write_mutation_bundle(
    mutation_name: str,
    target_root: Path,
    *,
    announce: bool,
    evidence_root: Path = DEFAULT_EVIDENCE_ROOT,
) -> None:
    if mutation_name not in MUTATION_RAW_LOGS:
        names = ", ".join(sorted(MUTATION_RAW_LOGS))
        raise SystemExit(f"unknown mutation {mutation_name!r}; expected one of: {names}")

    target_error = mutation_target_error(target_root, evidence_root)
    if target_error is not None:
        raise SystemExit(target_error)

    errors: list[str] = []
    source = latest_bundle(evidence_root, errors)
    if source is None:
        for message in errors:
            print(f"FAIL: {message}", file=sys.stderr)
        raise SystemExit(1)

    _, source_bundle = source
    target_root.mkdir(parents=True)
    target_bundle = target_root / source_bundle.name
    shutil.copytree(source_bundle, target_bundle)

    mutation = MUTATION_RAW_LOGS[mutation_name]
    receipt_path = target_bundle / "receipt.json"
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    for row in receipt["rows"]:
        if row.get("row_id") == mutation.row_id:
            if mutation.raw_text is not None:
                raw_path = target_bundle / row["raw_log"]
                raw_path.write_text(mutation.raw_text, encoding="utf-8")
            if mutation.receipt_field_overrides is not None:
                row.update(mutation.receipt_field_overrides)
                receipt_path.write_text(
                    json.dumps(receipt, indent=2) + "\n",
                    encoding="utf-8",
                )
            if announce:
                print(f"wrote_mutation={mutation_name}")
            return
    raise SystemExit(f"source receipt does not contain row {mutation.row_id}")


def copy_latest_bundle(source_root: Path, target_root: Path) -> bool:
    source_errors: list[str] = []
    source = latest_bundle(source_root, source_errors)
    if source is None:
        return False
    _, source_bundle = source
    target_root.mkdir(parents=True)
    shutil.copytree(source_bundle, target_root / source_bundle.name)
    return True


def require_mutation_target_rejection(
    errors: list[str],
    target_root: Path,
    evidence_root: Path,
    description: str,
) -> None:
    expected_message = "mutation target must not overlap committed evidence root"
    try:
        write_mutation_bundle(
            "b2_sibling_pass",
            target_root,
            announce=False,
            evidence_root=evidence_root,
        )
    except SystemExit as exc:
        require_condition(
            errors,
            expected_message in str(exc),
            f"{description} returned the wrong rejection: {exc}",
        )
        return
    except Exception as exc:
        require_condition(
            errors,
            False,
            f"{description} reached mutation work instead of overlap rejection: {exc}",
        )
        return
    require_condition(errors, False, f"{description} was accepted: {target_root}")


def verify_mutation_target_safety(errors: list[str]) -> None:
    committed_evidence_root = DEFAULT_EVIDENCE_ROOT.resolve()
    with tempfile.TemporaryDirectory() as overlap_scratch:
        safe_evidence_root = Path(overlap_scratch) / "evidence"
        require_condition(
            errors,
            copy_latest_bundle(committed_evidence_root, safe_evidence_root),
            "could not seed temporary evidence root for mutation target safety test",
        )
        for target, description in (
            (safe_evidence_root, "evidence-root mutation target"),
            (safe_evidence_root.parent, "evidence-ancestor mutation target"),
            (safe_evidence_root / "guardprobe", "evidence-descendant mutation target"),
        ):
            require_mutation_target_rejection(
                errors,
                target,
                safe_evidence_root,
                description,
            )

    with tempfile.TemporaryDirectory() as scratch:
        scratch_root = Path(scratch)
        existing_target = scratch_root / "existing"
        existing_target.mkdir()
        sentinel = existing_target / "sentinel"
        sentinel.write_text("preserve", encoding="utf-8")
        target_was_rejected = False
        try:
            write_mutation_bundle(
                "b2_sibling_pass",
                existing_target,
                announce=False,
            )
        except SystemExit:
            target_was_rejected = True
        require_condition(
            errors,
            target_was_rejected,
            "pre-existing mutation target was accepted",
        )
        require_condition(
            errors,
            sentinel.read_text(encoding="utf-8") == "preserve",
            "mutation target validation changed an existing target",
        )
        require_condition(
            errors,
            mutation_target_error(scratch_root / "guardprobe") is None,
            "new mutation target under a temporary directory was rejected",
        )


def verify_mutation_rejections(errors: list[str]) -> None:
    for mutation_name, mutation in MUTATION_RAW_LOGS.items():
        with tempfile.TemporaryDirectory() as scratch:
            scratch_root = Path(scratch) / "guardprobe"
            write_mutation_bundle(mutation_name, scratch_root, announce=False)
            mutation_errors, rows_checked = validate_evidence_root(
                scratch_root,
                run_self_tests=False,
            )
        require_condition(
            errors,
            rows_checked == len(EXPECTED_SPECS),
            f"{mutation_name} mutation did not preserve all required rows",
        )
        require_condition(
            errors,
            mutation.expected_diagnostic in mutation_errors,
            f"{mutation_name} mutation did not produce its expected diagnostic",
        )


def validate_evidence_root(
    evidence_root: Path,
    *,
    run_self_tests: bool,
) -> tuple[list[str], int]:
    errors: list[str] = []
    validate_row_lane_referential_integrity(errors)
    if run_self_tests:
        verify_guard_contracts(errors)
        verify_mutation_target_safety(errors)
        verify_mutation_rejections(errors)
    max_age_days = freshness_days(errors)
    if max_age_days is None:
        return errors, 0

    now = datetime.now(timezone.utc)
    newest = latest_bundle(evidence_root, errors)
    if newest is None:
        return errors, 0

    bundle_timestamp, bundle = newest
    is_fresh(bundle_timestamp, "newest bundle", now, max_age_days, errors)
    receipt_path = bundle / "receipt.json"
    if not receipt_path.is_file():
        errors.append(f"newest bundle has no receipt.json: {bundle.name}")
        return errors, 0

    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        errors.append(f"receipt.json is malformed or unreadable: {exc}")
        return errors, 0

    if not isinstance(receipt, dict) or not isinstance(receipt.get("rows"), list):
        errors.append("receipt.json must be an object with a rows array")
        return errors, 0

    rows = receipt["rows"]
    rows_checked = len(rows)
    if rows_checked == 0:
        errors.append("receipt rows are empty")
        return errors, rows_checked

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

    return errors, rows_checked


def main() -> None:
    if MODE == "write_mutation":
        write_mutation_bundle(MUTATION_NAME, EVIDENCE_ROOT, announce=True)
        return
    errors, rows_checked = validate_evidence_root(EVIDENCE_ROOT, run_self_tests=True)
    finish(errors, rows_checked)


main()
PY
