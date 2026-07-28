#!/usr/bin/env bash
# Deterministic classifier for launch-verification evidence bundle ages.

set -uo pipefail

usage() {
    echo "usage: probe_launch_evidence_freshness.sh [--evidence-root <directory>]" >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
evidence_root="$REPO_ROOT/docs/runbooks/evidence"

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

# LAUNCH.md:27 defines fresh launch evidence as strictly less than 14 days old.
max_age_days="${LAUNCH_EVIDENCE_MAX_AGE_DAYS:-14}"
if [[ ! "$max_age_days" =~ ^[0-9]+$ ]]; then
    echo "probe_launch_evidence_freshness: LAUNCH_EVIDENCE_MAX_AGE_DAYS must be a non-negative integer" >&2
    exit 2
fi
if [ ! -d "$evidence_root" ] || [ ! -r "$evidence_root" ]; then
    echo "probe_launch_evidence_freshness: evidence root is not a readable directory" >&2
    exit 2
fi

matrix_path="$REPO_ROOT/docs/launch_verification_matrix.md"
if [ ! -f "$matrix_path" ] || [ ! -r "$matrix_path" ]; then
    echo "probe_launch_evidence_freshness: launch matrix is not readable" >&2
    exit 2
fi

classification="$(
    python3 - "$evidence_root" "$matrix_path" "$max_age_days" <<'PY'
from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


@dataclass(frozen=True)
class Section:
    label: str
    evidence_directory: str
    required_completion_files: tuple[str, ...] = ()


HA_SOAK_COMPLETION_FILES = (
    "soak_exit_code.txt",
    "writes_attempted.count",
    "visible_in_search_after.count",
    "cross_tenant_leaks.count",
    "noisy_neighbor_violations.count",
    "fail_fast_during_restart_window.count",
)


@dataclass(frozen=True)
class BundleDiagnostic:
    bundle_name: str
    category: str
    reason: str
    files: tuple[str, ...] = ()


SECTIONS = (
    # A1's consolidated in-VPC SES run is the accepted email delivery corpus.
    Section("1. Email/SES delivery", "ses-coverage-a1"),
    # A2 owns the end-to-end billing, Stripe, and webhook evidence bundles.
    Section("2. Billing / Stripe / webhook", "billing_coverage_a2"),
    # A3 collects the cross-surface security boundary contract results.
    Section("3. Security boundaries", "security-coverage-a3"),
    # A4's restore drills own backup, restore, and database-integrity evidence.
    Section("4. Backup / restore + DB integrity", "database-recovery"),
    # A5 accepts completed soak measurements, regardless of GREEN/NONGREEN verdict.
    Section(
        "5. HA / multi-tenant isolation",
        "ha_coverage_a5",
        HA_SOAK_COMPLETION_FILES,
    ),
    # The paid-beta RC bundles aggregate the cross-cutting full-stack gate.
    Section("6. Cross-cutting full-stack", "launch-rc-runs"),
)

BUNDLE_NAME_PATTERN = re.compile(
    r"^(?P<timestamp>[0-9]{8}T[0-9]{6}Z)_(?P<name>.+)$"
)
MATRIX_SECTION_PATTERN = re.compile(r"^\|\s*(?P<label>[1-9][0-9]*\.\s*[^|]+?)\s*\|")


def matrix_section_labels(matrix_path: Path) -> list[str]:
    lines = matrix_path.read_text(encoding="utf-8").splitlines()
    try:
        section_start = lines.index("## Section status")
    except ValueError:
        return []

    labels: list[str] = []
    for line in lines[section_start + 1 :]:
        if line == "---" or (line.startswith("## ") and labels):
            break
        match = MATRIX_SECTION_PATTERN.match(line)
        if match:
            labels.append(match.group("label").strip())
    return labels


def validate_matrix_mapping(matrix_path: Path) -> None:
    expected = [section.label for section in SECTIONS]
    actual = matrix_section_labels(matrix_path)
    if actual != expected:
        print(
            "probe_launch_evidence_freshness: matrix sections differ from "
            f"canonical mapping: expected={expected!r} actual={actual!r}",
            file=sys.stderr,
        )
        raise SystemExit(2)


def parse_bundle_timestamp(bundle_name: str, now: datetime) -> tuple[datetime | None, str]:
    match = BUNDLE_NAME_PATTERN.fullmatch(bundle_name)
    if match is None:
        return (None, "malformed_name")
    try:
        timestamp = datetime.strptime(
            match.group("timestamp"), "%Y%m%dT%H%M%SZ"
        ).replace(tzinfo=timezone.utc)
    except ValueError:
        return (None, "invalid_timestamp")
    if timestamp > now:
        return (None, "future_timestamp")
    return (timestamp, "")


def completion_rejection(
    bundle_path: Path, section: Section
) -> BundleDiagnostic | None:
    missing_files = tuple(
        filename
        for filename in section.required_completion_files
        if not (bundle_path / filename).is_file()
    )
    if missing_files:
        return BundleDiagnostic(
            bundle_path.name,
            "rejected",
            "missing_required_files",
            missing_files,
        )

    empty_files = tuple(
        filename
        for filename in section.required_completion_files
        if (bundle_path / filename).stat().st_size == 0
    )
    if empty_files:
        return BundleDiagnostic(
            bundle_path.name,
            "rejected",
            "empty_required_files",
            empty_files,
        )
    return None


def classify_section(
    evidence_root: Path,
    section: Section,
    now: datetime,
    max_age_days: int,
) -> tuple[str, str, list[BundleDiagnostic]]:
    section_path = evidence_root / section.evidence_directory
    if not section_path.is_dir():
        return (f"{section.label} - age=unknown MISSING_SECTION", "missing_section", [])

    bundle_names = sorted(child.name for child in section_path.iterdir() if child.is_dir())
    if not bundle_names:
        return (f"{section.label} - age=unknown MISSING", "missing", [])

    valid_bundles: list[tuple[datetime, str]] = []
    diagnostics: list[BundleDiagnostic] = []
    for bundle_name in bundle_names:
        timestamp, reason = parse_bundle_timestamp(bundle_name, now)
        if timestamp is None:
            diagnostics.append(BundleDiagnostic(bundle_name, "malformed", reason))
            continue

        rejection = completion_rejection(
            section_path / bundle_name,
            section,
        )
        if rejection is not None:
            diagnostics.append(rejection)
            continue
        valid_bundles.append((timestamp, bundle_name))

    if not valid_bundles:
        selected_name = diagnostics[0].bundle_name
        verdict = f"{section.label} {selected_name} age=unknown UNPARSEABLE"
        return (verdict, "unparseable", diagnostics)

    timestamp, selected_name = max(valid_bundles)
    age_days = int((now - timestamp).total_seconds() // 86400)
    state = "fresh" if age_days < max_age_days else "stale"
    verdict = f"{section.label} {selected_name} age={age_days}d {state.upper()}"
    return (verdict, state, diagnostics)


def main() -> int:
    evidence_root = Path(sys.argv[1])
    matrix_path = Path(sys.argv[2])
    max_age_days = int(sys.argv[3])
    validate_matrix_mapping(matrix_path)

    now = datetime.now(timezone.utc)
    counts = {
        "fresh": 0,
        "stale": 0,
        "missing": 0,
        "missing_section": 0,
        "unparseable": 0,
    }
    verdicts: list[str] = []
    malformed_count = 0
    rejected_count = 0
    for section in SECTIONS:
        verdict, state, diagnostics = classify_section(
            evidence_root, section, now, max_age_days
        )
        verdicts.append(verdict)
        counts[state] += 1
        malformed_count += sum(
            diagnostic.category == "malformed" for diagnostic in diagnostics
        )
        rejected_count += sum(
            diagnostic.category == "rejected" for diagnostic in diagnostics
        )
        for diagnostic in diagnostics:
            files = (
                f" files={','.join(diagnostic.files)}"
                if diagnostic.files
                else ""
            )
            print(
                f"probe_launch_evidence_freshness: {diagnostic.category} bundle "
                f"{section.label}/{diagnostic.bundle_name} "
                f"reason={diagnostic.reason}{files}",
                file=sys.stderr,
            )

    print("\n".join(verdicts))
    print(
        f"sections={len(SECTIONS)} fresh={counts['fresh']} stale={counts['stale']} "
        f"missing={counts['missing']} missing_section={counts['missing_section']} "
        f"unparseable={counts['unparseable']} malformed_names={malformed_count} "
        f"rejected_bundles={rejected_count}"
    )
    has_failure = (
        len(SECTIONS) == 0
        or counts["fresh"] != len(SECTIONS)
        or malformed_count > 0
        or rejected_count > 0
    )
    return 10 if has_failure else 0


raise SystemExit(main())
PY
)"
classifier_rc=$?

case "$classifier_rc" in
    0)
        printf '%s\n' "$classification"
        exit 0
        ;;
    10)
        printf '%s\n' "$classification"
        exit 1
        ;;
    2)
        exit 2
        ;;
    *)
        echo "probe_launch_evidence_freshness: classifier failed internally" >&2
        exit 2
        ;;
esac
