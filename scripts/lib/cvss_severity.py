#!/usr/bin/env python3
"""Classify a `cargo audit --json` report into a suite verdict.

Usage:
    python3 cvss_severity.py <audit_json_file>

Contract (consumed by check_dep_audit in
scripts/reliability/lib/security_checks.sh):
  - stdout is exactly one of `pass`, `warn`, or `fail`.
  - stderr carries a "Blocking advisories: <id>(<band>), ..." line when any
    advisory is blocking, so the caller can name the offenders.
  - exit 0 on a successful classification (verdict is on stdout); exit 2 on an
    unreadable/unparsable report — including one whose `vulnerabilities` object
    does not hold together (see extract_vulnerabilities) — so the caller fails
    closed rather than treating an uninterpretable audit as clean.

This lived as a heredoc inside a `$( ... )` command substitution in the shell
library. bash 3.2 scans the substitution region for quote balance even inside a
quoted heredoc, so a single apostrophe anywhere in the Python — including a
comment — broke the entire security library at PARSE time. Extracting it to a
real file removes that hazard by construction and lets these known-answer cases
be exercised as direct unit tests.

Real cargo-audit JSON has NO `severity` key — severity is only derivable from
the `cvss` vector string (verified against cargo-audit output 2026-07-30;
advisory keys are aliases/categories/collection/cvss/date/.../withdrawn).
Reading `severity` alone classified every real advisory as "unknown" and
downgraded it to warn, so the check could never fail on the thing it exists to
detect. We derive severity from the CVSS vector, and still read `severity`
first for any tool version that does emit it.
"""

import json
import sys
from datetime import date

AV_WEIGHTS = {"N": 0.85, "A": 0.62, "L": 0.55, "P": 0.2}
AC_WEIGHTS = {"L": 0.77, "H": 0.44}
PR_WEIGHTS_SCOPE_UNCHANGED = {"N": 0.85, "L": 0.62, "H": 0.27}
PR_WEIGHTS_SCOPE_CHANGED = {"N": 0.85, "L": 0.68, "H": 0.50}
UI_WEIGHTS = {"N": 0.85, "R": 0.62}
CIA_WEIGHTS = {"H": 0.56, "L": 0.22, "N": 0.0}


def roundup(value):
    # CVSS v3.1 specification, Appendix A: round up to one decimal place.
    scaled = int(round(value * 100000))
    if scaled % 10000 == 0:
        return scaled / 100000.0
    return (scaled // 10000 + 1) / 10.0


def cvss_base_score(vector):
    """CVSS v3.x base score for a vector string, or None if underivable."""
    if not isinstance(vector, str):
        return None
    parts = vector.split("/")
    if not parts or parts[0] not in {"CVSS:3.0", "CVSS:3.1"}:
        return None
    metrics = {}
    for part in parts[1:]:
        key, sep, value = part.partition(":")
        if not sep or key in metrics:
            return None
        metrics[key] = value
    try:
        scope = metrics["S"]
        if scope not in {"U", "C"}:
            return None
        pr_weights = (
            PR_WEIGHTS_SCOPE_CHANGED if scope == "C" else PR_WEIGHTS_SCOPE_UNCHANGED
        )
        exploitability = (
            8.22
            * AV_WEIGHTS[metrics["AV"]]
            * AC_WEIGHTS[metrics["AC"]]
            * pr_weights[metrics["PR"]]
            * UI_WEIGHTS[metrics["UI"]]
        )
        impact_sub_score = 1 - (
            (1 - CIA_WEIGHTS[metrics["C"]])
            * (1 - CIA_WEIGHTS[metrics["I"]])
            * (1 - CIA_WEIGHTS[metrics["A"]])
        )
    except KeyError:
        return None

    if scope == "C":
        impact = 7.52 * (impact_sub_score - 0.029) - 3.25 * (
            impact_sub_score - 0.02
        ) ** 15
    else:
        impact = 6.42 * impact_sub_score

    if impact <= 0:
        return 0.0
    total = impact + exploitability
    if scope == "C":
        total *= 1.08
    return roundup(min(total, 10.0))


def severity_band(score):
    # CVSS v3.1 qualitative severity rating scale.
    if score >= 9.0:
        return "critical"
    if score >= 7.0:
        return "high"
    if score >= 4.0:
        return "medium"
    if score > 0.0:
        return "low"
    return "none"


# Qualitative-band rank so we can take the MORE severe of the tool-declared
# severity and the CVSS-derived one. This is the fail-closed invariant: a
# vulnerability carrying MORE information (a declared label AND a scorable
# vector) must never be treated more leniently than one carrying less. A
# declared "low"/"none" label therefore cannot mask a scorable critical vector,
# and an unrecognized label (e.g. a future tool version emitting "unknown")
# simply contributes no rank rather than short-circuiting to warn.
SEVERITY_RANK = {"none": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}
BLOCKING_RANK = SEVERITY_RANK["high"]


def classify(vulnerabilities):
    """Return (verdict, blocking_ids) for a list of vulnerability dicts."""
    critical_or_high = 0
    warn_or_lower = 0
    unrated = 0
    blocking_ids = []
    for vuln in vulnerabilities:
        if not isinstance(vuln, dict):
            continue
        advisory = vuln.get("advisory", {})
        if not isinstance(advisory, dict):
            advisory = {}
        if advisory.get("withdrawn"):
            continue
        advisory_id = str(advisory.get("id", "unknown-advisory"))

        # Read the tool-declared severity FIRST (for any tool version that emits
        # one), but only honor it when it is a value on the CVSS qualitative
        # scale.
        declared = str(advisory.get("severity") or "").lower()
        score = cvss_base_score(advisory.get("cvss"))
        derived = severity_band(score) if score is not None else None

        ranks = []
        if declared in SEVERITY_RANK:
            ranks.append(SEVERITY_RANK[declared])
        if derived is not None:
            ranks.append(SEVERITY_RANK[derived])

        if not ranks:
            # A real vulnerability with neither a recognized severity nor a
            # scorable CVSS vector. Its severity is unknown, not low — do not
            # downgrade it.
            unrated += 1
            blocking_ids.append(advisory_id + "(unrated)")
            continue

        effective_rank = max(ranks)
        if effective_rank >= BLOCKING_RANK:
            critical_or_high += 1
            band = "critical" if effective_rank == SEVERITY_RANK["critical"] else "high"
            blocking_ids.append(advisory_id + "(" + band + ")")
        else:
            warn_or_lower += 1

    if critical_or_high or unrated:
        return "fail", blocking_ids
    if warn_or_lower:
        return "warn", blocking_ids
    return "pass", blocking_ids


class ReportError(Exception):
    """The report cannot be interpreted, so no verdict may be derived from it."""


def extract_vulnerabilities(data):
    """Return the advisory list from a cargo-audit report.

    Raises ReportError on any schema drift. cargo audit emits
    `vulnerabilities` as `{count, found, list}` (verified 2026-07-30 against a
    live run: count=5, found=True, len(list)=5). Reading `list` alone and
    defaulting to `[]` meant a rename or restructure of that one key read as a
    clean report — the caller printed SECURITY_DEP_AUDIT_PASS and returned 0
    while vulnerabilities were present. The corroborating fields cost nothing
    (they are in the same object), so a disagreement is treated as an
    unreadable report, which the caller already fails closed on.
    """
    if not isinstance(data, dict):
        raise ReportError("report root is not a JSON object")
    if "vulnerabilities" not in data:
        raise ReportError("report has no `vulnerabilities` object")
    container = data["vulnerabilities"]
    if not isinstance(container, dict):
        raise ReportError("`vulnerabilities` is not a JSON object")

    vulnerabilities = container.get("list")
    if not isinstance(vulnerabilities, list):
        raise ReportError("`vulnerabilities.list` is missing or is not a list")

    if "count" in container:
        count = container["count"]
        # bool is a subclass of int; a JSON `true` here is drift, not a count.
        if not isinstance(count, int) or isinstance(count, bool):
            raise ReportError("`vulnerabilities.count` is not an integer")
        if count != len(vulnerabilities):
            raise ReportError(
                "`vulnerabilities.count` is %d but the list holds %d entries"
                % (count, len(vulnerabilities))
            )

    if "found" in container:
        found = container["found"]
        if not isinstance(found, bool):
            raise ReportError("`vulnerabilities.found` is not a boolean")
        if found != bool(vulnerabilities):
            raise ReportError(
                "`vulnerabilities.found` is %s but the list holds %d entries"
                % (str(found).lower(), len(vulnerabilities))
            )

    for index, vulnerability in enumerate(vulnerabilities):
        if not isinstance(vulnerability, dict):
            raise ReportError(
                "`vulnerabilities.list[%d]` is not a JSON object" % index
            )
        advisory = vulnerability.get("advisory")
        if not isinstance(advisory, dict):
            raise ReportError(
                "`vulnerabilities.list[%d].advisory` is not a JSON object" % index
            )
        withdrawn = advisory.get("withdrawn")
        if withdrawn is not None:
            if not isinstance(withdrawn, str):
                raise ReportError(
                    "`vulnerabilities.list[%d].advisory.withdrawn` is not a date string or null"
                    % index
                )
            try:
                date.fromisoformat(withdrawn)
            except ValueError as exc:
                raise ReportError(
                    "`vulnerabilities.list[%d].advisory.withdrawn` is not an ISO date"
                    % index
                ) from exc

    return vulnerabilities


def main():
    path = sys.argv[1]
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        print("parse_error")
        sys.stderr.write("Unusable cargo audit report: not readable as JSON\n")
        return 2

    try:
        vulnerabilities = extract_vulnerabilities(data)
    except ReportError as exc:
        print("parse_error")
        sys.stderr.write("Unusable cargo audit report: " + str(exc) + "\n")
        return 2

    verdict, blocking_ids = classify(vulnerabilities)
    if blocking_ids:
        sys.stderr.write("Blocking advisories: " + ", ".join(blocking_ids) + "\n")
    print(verdict)
    return 0


if __name__ == "__main__":
    sys.exit(main())
