#!/usr/bin/env bash
# Compare probe_launch_evidence_freshness.sh's rejected/malformed diagnostics
# against the closed baseline registry, in BOTH directions.
#
# Reads the probe's stderr on stdin. Exits 0 when the observed diagnostic set is
# exactly the registry, non-zero otherwise, naming every discrepancy.
#
# WHY a baseline instead of requiring zero: the counts can never reach zero
# without deleting preserved NONGREEN HA soak evidence and pre-convention 2026-05
# directories. Requiring zero made gate_launch_evidence_freshness_contract
# permanently red on main, which meant it could not distinguish "evidence is old"
# from "evidence is malformed" — the entire purpose of the instrument.
#
# WHY it is still a real guard: the comparison is exact both ways. A diagnostic
# outside the registry fails (new corpus rot is caught on its first run), and a
# registry line the probe no longer reports also fails (a curated bundle must
# have its line deleted in the same commit, so the registry cannot rot into an
# unconditional pass). See scripts/tests/launch_evidence_legacy_bundles.txt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINE_FILE="${LAUNCH_EVIDENCE_BASELINE_FILE:-$REPO_ROOT/scripts/tests/launch_evidence_legacy_bundles.txt}"

if [ ! -f "$BASELINE_FILE" ]; then
    echo "check_launch_evidence_corpus_baseline: baseline registry missing: ${BASELINE_FILE#"$REPO_ROOT/"}" >&2
    exit 2
fi

observed="$(awk -F' reason=' '
    /^probe_launch_evidence_freshness: (malformed|rejected) bundle /{
        sub(/^probe_launch_evidence_freshness: (malformed|rejected) bundle /, "", $1)
        print $1
    }' | sort -u)"

expected="$(sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' \
    "$BASELINE_FILE" | sort -u)"

unexpected="$(comm -23 <(printf '%s\n' "$observed" | sed '/^$/d') \
                       <(printf '%s\n' "$expected" | sed '/^$/d'))"
disappeared="$(comm -13 <(printf '%s\n' "$observed" | sed '/^$/d') \
                        <(printf '%s\n' "$expected" | sed '/^$/d'))"

status=0

if [ -n "$unexpected" ]; then
    echo "check_launch_evidence_corpus_baseline: NEW non-conforming evidence bundle(s) not in the baseline registry:" >&2
    printf '  %s\n' "$unexpected" >&2
    echo "  Fix the bundle: name it <UTCTIMESTAMP>_<name> and include its section's completion files." >&2
    echo "  Do NOT add it to the baseline registry — that baseline is closed to the 2026-05 corpus." >&2
    status=1
fi

if [ -n "$disappeared" ]; then
    echo "check_launch_evidence_corpus_baseline: baseline registry lists bundle(s) the probe no longer reports:" >&2
    printf '  %s\n' "$disappeared" >&2
    echo "  If these were curated or retired, delete their lines from the baseline registry in the same commit." >&2
    status=1
fi

if [ "$status" -eq 0 ]; then
    printf 'OK: %s legacy bundle(s) matched the closed baseline registry exactly\n' \
        "$(printf '%s\n' "$expected" | sed '/^$/d' | wc -l | tr -d ' ')"
fi

exit "$status"
