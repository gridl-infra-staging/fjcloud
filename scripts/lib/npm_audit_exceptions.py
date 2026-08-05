#!/usr/bin/env python3
"""Classify an `npm audit --json` report against a committed GHSA exception list.

Usage:
    python3 npm_audit_exceptions.py <audit_json_file> <exception_file>

Contract (consumed by gate_web_audit in scripts/local-ci.sh), mirroring
scripts/lib/cvss_severity.py:
  - stdout is exactly `pass` or `fail` (or `parse_error` on unreadable input).
  - stderr carries a "Blocking advisories: ..." line naming every high/critical
    entry that is not fully covered by the exception list, so the caller can
    name the offenders in its summary.
  - exit 0 on a successful classification (verdict is on stdout); exit 2 on an
    unreadable/unparsable/schema-drifted report OR an unreadable exception list,
    so the caller fails closed rather than treating an uninterpretable audit as
    clean.

npm audit v2 (verified against `npm --version` 11.x) emits `vulnerabilities` as
an object keyed by package name. Each entry carries `severity`
(info|low|moderate|high|critical) and `via[]`, whose members are EITHER an
object describing a concrete advisory (with a GitHub advisory `url`) OR a string
naming another vulnerable package in the SAME report (a transitive edge).
Verified live 2026-08-04 in web/:
  - vulnerabilities.undici: severity=high, via = 5 advisory objects whose urls
    end in GHSA-8xcm-r25x-g524, GHSA-4cwx-7wf7-3272, GHSA-m8rv-5g2x-5cg5,
    GHSA-jr45-8vmc-qm54, GHSA-v3r7-h72x-cjcm.
  - vulnerabilities.miniflare / .wrangler: severity=moderate, via = ["undici"] /
    ["miniflare"] (string edges, carrying no advisory id of their own).

Blocking rule: for every entry at high or critical severity, gather the set of
implicated GHSA ids by extracting the id from each object via member's url and
resolving each string via member to the named package's own entry
(transitively, cycle-guarded). The entry blocks unless EVERY implicated id is on
the exception list. An entry whose implicated-id set is empty — a high/critical
finding with no extractable GHSA id — always blocks, because an id that cannot
be named can never be excepted and must not silently vanish. Every via member
that yields no extractable id likewise contributes a non-matchable token, so a
partially-unreadable chain can never be excepted by its readable half. A via
chain that loops back on itself is one such unreadable edge: it too contributes
a non-matchable token, so a cycle cannot quietly drop out beside a readable,
excepted advisory in the same entry.

Schema-drift detector: the count of enumerated high+critical entries must equal
metadata.vulnerabilities.high + .critical. Any mismatch, or a missing/malformed
metadata block, is treated as an unreadable report and fails closed. A negative
band count is malformed for this purpose: summing it would let one band cancel
another and make a report claiming a critical vulnerability match an empty
enumeration. A severity
value outside npm's closed band set is drift too: an unrecognised band is
counted nowhere in `metadata`, so the cross-check cannot see it, and treating it
as "below high" would let a renamed band walk straight past the gate.
"""

import json
import re
import sys

GHSA_RE = re.compile(r"GHSA-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}")
# The exception policy authorises named advisories only, so a policy value must
# match a GHSA id end to end. That is also what keeps the internal
# UNRESOLVED_PREFIX tokens below non-matchable: they can never be listed.
GHSA_ONLY_RE = re.compile(r"\A" + GHSA_RE.pattern + r"\Z")
BLOCKING_SEVERITIES = ("high", "critical")
VALID_SEVERITIES = ("info", "low", "moderate", "high", "critical")
UNRESOLVED_PREFIX = "unresolved:"


class ReportError(Exception):
    """The report cannot be interpreted, so no verdict may be derived from it."""


def count_blocking_entries(vulnerabilities):
    """Validate every entry's shape and return the high+critical entry count.

    Each entry must be an object carrying a `severity` drawn from npm's closed
    band set and a list `via`. An unrecognised band is rejected rather than
    treated as below-high: `metadata` counts no such band, so the cross-check in
    extract_vulnerabilities could not catch a renamed one.
    """
    blocking = 0
    for name, entry in vulnerabilities.items():
        if not isinstance(entry, dict):
            raise ReportError("`vulnerabilities.%s` is not a JSON object" % name)
        severity = entry.get("severity")
        if not isinstance(severity, str):
            raise ReportError(
                "`vulnerabilities.%s.severity` is missing or not a string" % name
            )
        if severity not in VALID_SEVERITIES:
            raise ReportError(
                "`vulnerabilities.%s.severity` is %r, outside npm's bands (%s)"
                % (name, severity, "|".join(VALID_SEVERITIES))
            )
        if not isinstance(entry.get("via"), list):
            raise ReportError(
                "`vulnerabilities.%s.via` is missing or not a list" % name
            )
        if severity in BLOCKING_SEVERITIES:
            blocking += 1
    return blocking


def extract_vulnerabilities(data):
    """Return the `vulnerabilities` object, raising ReportError on schema drift.

    A missing `vulnerabilities` key is drift (distinct from an explicit clean
    `"vulnerabilities": {}`). Every entry's severity must be one of npm's five
    bands, and the enumerated high+critical entry count is cross-checked against
    `metadata.vulnerabilities`, so neither a renamed band nor a restructure that
    hides a blocking entry can read as a clean report.
    """
    if not isinstance(data, dict):
        raise ReportError("report root is not a JSON object")
    if "vulnerabilities" not in data:
        raise ReportError("report has no `vulnerabilities` object")
    vulnerabilities = data["vulnerabilities"]
    if not isinstance(vulnerabilities, dict):
        raise ReportError("`vulnerabilities` is not a JSON object")

    metadata = data.get("metadata")
    if not isinstance(metadata, dict):
        raise ReportError("report has no `metadata` object")
    meta_counts = metadata.get("vulnerabilities")
    if not isinstance(meta_counts, dict):
        raise ReportError("`metadata.vulnerabilities` is not a JSON object")
    meta_blocking = 0
    for band in BLOCKING_SEVERITIES:
        value = meta_counts.get(band)
        # bool is a subclass of int; a JSON `true` here is drift, not a count.
        if not isinstance(value, int) or isinstance(value, bool):
            raise ReportError("`metadata.vulnerabilities.%s` is not an integer" % band)
        # Each band is a tally and can never be negative. Validating before the
        # sum is what stops one band's negative value cancelling another's
        # positive one: high=-1 with critical=1 aggregates to the zero
        # enumerated entries of an empty report, so the cross-check below would
        # agree with metadata that itself reports a critical vulnerability.
        if value < 0:
            raise ReportError(
                "`metadata.vulnerabilities.%s` is negative (%d)" % (band, value)
            )
        meta_blocking += value

    enumerated_blocking = count_blocking_entries(vulnerabilities)
    if enumerated_blocking != meta_blocking:
        raise ReportError(
            "enumerated high+critical entries (%d) disagree with "
            "metadata.vulnerabilities (%d)" % (enumerated_blocking, meta_blocking)
        )

    return vulnerabilities


def implicated_tokens(package, vulnerabilities, chain, resolved):
    """Tokens implicated by `package`'s advisory chain.

    Object via members contribute their GHSA id when one is extractable, else a
    non-matchable `unresolved:<pkg>` token. String via members are resolved to
    the named package's own entry and walked transitively. A non-matchable token
    can never be on the exception list, so any unreadable edge forces the
    enclosing high/critical entry to block.

    `chain` is the set of packages currently on the traversal stack and `resolved`
    memoises completed packages. The two are distinct on purpose: re-entering a
    package still on the stack is a genuine cycle whose edge resolves to no
    advisory, so it yields a non-matchable token rather than an empty set that
    would let the unresolved edge vanish beside a readable, excepted advisory in
    the same entry. Re-reaching an already-completed package is merely a diamond
    in the dependency graph and must still contribute that package's real ids.
    """
    if package in chain:
        return {UNRESOLVED_PREFIX + "cycle:" + str(package)}
    if package in resolved:
        return resolved[package]

    tokens = set()
    entry = vulnerabilities.get(package)
    if not isinstance(entry, dict):
        return {UNRESOLVED_PREFIX + str(package)}

    chain.add(package)
    for member in entry.get("via", []):
        if isinstance(member, dict):
            url = member.get("url")
            match = GHSA_RE.search(url) if isinstance(url, str) else None
            if match:
                tokens.add(match.group(0))
            else:
                tokens.add(UNRESOLVED_PREFIX + str(package))
        elif isinstance(member, str):
            tokens |= implicated_tokens(member, vulnerabilities, chain, resolved)
        else:
            tokens.add(UNRESOLVED_PREFIX + str(package))
    chain.discard(package)

    # Memoising a set computed under an active cycle can only over-report
    # unresolved tokens, never drop one, so the cache stays fail-closed.
    resolved[package] = tokens
    return tokens


def classify(vulnerabilities, exceptions):
    """Return (verdict, blocking_labels) for the audit against the exceptions."""
    blocking = []
    for package, entry in vulnerabilities.items():
        if entry.get("severity") not in BLOCKING_SEVERITIES:
            continue
        # Fresh traversal state per top-level entry: a cycle token cached under
        # one entry's walk must not colour another entry's classification.
        tokens = implicated_tokens(package, vulnerabilities, set(), {})
        if not tokens:
            blocking.append(package + "(no-advisory-id)")
            continue
        uncovered = sorted(token for token in tokens if token not in exceptions)
        if uncovered:
            blocking.append(package + "[" + ", ".join(uncovered) + "]")
    verdict = "fail" if blocking else "pass"
    return verdict, blocking


def load_exceptions(path):
    """Read one GHSA id per line; `#` starts a comment, blank lines ignored.

    Every value must be exactly one GHSA id. A malformed line raises ReportError
    so the caller fails closed instead of silently authorising something that is
    not a named advisory — an internal `unresolved:*` token most of all, since
    accepting one would except an advisory that has no extractable id.
    """
    exceptions = set()
    with open(path, "r", encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            stripped = line.split("#", 1)[0].strip()
            if not stripped:
                continue
            if not GHSA_ONLY_RE.match(stripped):
                raise ReportError(
                    "line %d is %r, which is not a single GHSA advisory id"
                    % (number, stripped)
                )
            exceptions.add(stripped)
    return exceptions


def main():
    if len(sys.argv) != 3:
        sys.stderr.write(
            "usage: npm_audit_exceptions.py <audit_json_file> <exception_file>\n"
        )
        return 2

    audit_path, exception_path = sys.argv[1], sys.argv[2]

    try:
        with open(audit_path, "rb") as handle:
            data = json.loads(handle.read().decode("utf-8"))
    except Exception:
        print("parse_error")
        sys.stderr.write("Unusable npm audit report: not readable as JSON\n")
        return 2

    try:
        exceptions = load_exceptions(exception_path)
    except ReportError as exc:
        print("parse_error")
        sys.stderr.write(
            "Malformed exception list " + exception_path + ": " + str(exc) + "\n"
        )
        return 2
    except Exception:
        print("parse_error")
        sys.stderr.write("Unreadable exception list: " + exception_path + "\n")
        return 2

    try:
        vulnerabilities = extract_vulnerabilities(data)
    except ReportError as exc:
        print("parse_error")
        sys.stderr.write("Unusable npm audit report: " + str(exc) + "\n")
        return 2

    verdict, blocking = classify(vulnerabilities, exceptions)
    if blocking:
        sys.stderr.write("Blocking advisories: " + ", ".join(blocking) + "\n")
    print(verdict)
    return 0


if __name__ == "__main__":
    sys.exit(main())
