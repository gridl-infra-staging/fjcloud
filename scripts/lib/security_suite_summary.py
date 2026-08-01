#!/usr/bin/env python3
"""Build the consolidated security-suite JSON summary from classified TSV rows."""

import json
import sys
from pathlib import Path


class SummaryError(ValueError):
    """The classified suite data cannot produce a trustworthy verdict."""


def read_results(data_path: Path) -> list[dict[str, object]]:
    results: list[dict[str, object]] = []
    for line_number, raw_line in enumerate(
        data_path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if not raw_line:
            continue
        parts = raw_line.split("\t")
        if len(parts) != 5:
            raise SummaryError(f"line {line_number}: expected 5 TSV columns")
        name, status, elapsed_raw, reason, error_class = parts
        if not name:
            raise SummaryError(f"line {line_number}: check name is empty")
        if status not in {"pass", "fail", "skipped"}:
            raise SummaryError(
                f"line {line_number}: unsupported check status {status!r}"
            )
        try:
            elapsed_ms = int(elapsed_raw)
        except ValueError as exc:
            raise SummaryError(
                f"line {line_number}: elapsed_ms is not an integer"
            ) from exc
        if elapsed_ms < 0:
            raise SummaryError(f"line {line_number}: elapsed_ms is negative")

        result: dict[str, object] = {
            "elapsed_ms": elapsed_ms,
            "name": name,
            "reason": reason,
            "status": status,
        }
        if error_class:
            result["error_class"] = error_class
        results.append(result)
    return results


def build_summary(
    check_results: list[dict[str, object]], elapsed_ms: int
) -> dict[str, object]:
    failures: list[str] = []
    checks_run = 0
    checks_failed = 0
    checks_blocked = 0
    checks_skipped = 0

    for result in check_results:
        status = result["status"]
        error_class = result.get("error_class", "")
        if status == "fail":
            failures.append(str(result["name"]))
            checks_failed += 1
            if error_class == "precondition":
                checks_blocked += 1
            else:
                checks_run += 1
        elif status == "pass":
            checks_run += 1
        else:
            checks_skipped += 1

    passed = checks_failed == 0
    return {
        "check_results": check_results,
        "checks_blocked": checks_blocked,
        "checks_failed": checks_failed,
        "checks_run": checks_run,
        "checks_skipped": checks_skipped,
        "elapsed_ms": elapsed_ms,
        "failures": failures,
        "passed": passed,
    }


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "Usage: security_suite_summary.py <classified_tsv> <elapsed_ms>",
            file=sys.stderr,
        )
        return 2
    try:
        elapsed_ms = int(sys.argv[2])
        if elapsed_ms < 0:
            raise SummaryError("suite elapsed_ms is negative")
        summary = build_summary(read_results(Path(sys.argv[1])), elapsed_ms)
    except (OSError, SummaryError, ValueError) as exc:
        print(f"Unusable security suite data: {exc}", file=sys.stderr)
        return 2

    print(json.dumps(summary, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
