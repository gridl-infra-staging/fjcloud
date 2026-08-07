#!/usr/bin/env bash
# probe_ssot_currency.sh — report how far `ROADMAP.md` is behind `origin/main`.
#
# WHY THIS EXISTS
#
# `ROADMAP.md` is this repo's open-work ledger and it is reconciled by a
# terminal "batch close" lane that dispatches only after every sibling it
# summarizes has merged. Whatever stops a batch therefore stops the one lane
# that would have recorded what the batch did, and the ledger silently
# describes a tree that no longer exists. Measured instances:
#
#   - aug02_5am  — reconcile lane `aug02_5am_6` never dispatched.
#   - aug02_11am — reconcile lane `aug02_11am_9` stopped at stage 2 of 3.
#   - aug03_11am — reconcile lane `aug03_11am_6` never dispatched; `grep -c
#                  aug03_11am ROADMAP.md` was `0` while the whole batch was on
#                  `main`.
#   - aug05_12pm — both pricing lanes merged without writing the
#                  `ROADMAP CORRECTION REQUIRED` section their stages required,
#                  and the ledger kept asserting `2 of 5` providers verified
#                  and a `$5` paid-plan minimum after both had changed.
#
# Every one of those was found by a human reading the ledger against the code,
# days late. Nothing in the tree reported it.
#
# WHY THIS ORACLE AND NOT THE OBVIOUS ONE
#
# `scripts/check_handover_consumption.sh` is the sibling owner and the two are
# complementary, not redundant — check both before assuming either subsumes the
# other. It asks "did a correction someone WROTE get applied?", and `2359fce7d`
# extended it beyond `chatting/*handover*.md` to the in-checklist
# `## ROADMAP CORRECTION REQUIRED` sections the aug05 batches switched to. Its
# denominator is still, by construction, corrections a lane chose to write.
#
# That is the half it cannot cover, measured on this tree 2026-08-06: the two
# `aug05_12pm` pricing lanes were required by their own stages to write that
# section, wrote none, and merged. `grep -c '^## ROADMAP CORRECTION REQUIRED'`
# is `0` for both, so they contribute nothing to that probe's denominator and it
# reports clean while the ledger keeps asserting `2 of 5` providers verified and
# a `$5` paid-plan minimum after both had changed.
#
# This probe keys on the tree instead: batman records a lane merge whether or
# not any lane cooperated, so its denominator cannot be emptied by a lane
# skipping a step. A lane that writes and applies its correction shows up
# consumed there and current here; a lane that writes nothing is invisible there
# and still counted here.
#
# WHY IT IS NOT WIRED INTO `local-ci --fast`
#
# Deliberate. Every batch forbids its feature lanes from editing `ROADMAP.md`
# ("One SSOT writer per batch"), so a gate that refuses a lane's push for a
# stale ledger would block work on a defect that lane is not permitted to
# repair. The actor who both sees this and may act on it is the supervisor,
# which runs this directly. Wiring it into the pre-push gate would move the
# signal to the one audience that cannot use it.
#
# ORACLE
#
# `ROADMAP.md` carries dated reconciliation headers, each naming the
# `origin/main` SHA it was written against. The distance from the *closest*
# such SHA to `origin/main`, counted in batman lane merges, is how many lanes
# have landed since anyone last reconciled the ledger. Ordinary commits are not
# counted: docs, fixes and bookkeeping do not change what the ledger owes.
#
# The closest header wins rather than the first or last line matched, because
# header order in the file is a convention this probe must not depend on.
#
# Exit codes:
#   0 — the ledger is within the threshold of `origin/main`
#   1 — STALE: more lane merges have landed than the threshold allows
#   2 — the currency could not be measured; never a clean pass
#
# Env vars:
#   FJCLOUD_REPO_ROOT                    override the repo root (contract test)
#   FJCLOUD_SSOT_CURRENCY_MAX_LANE_MERGES  threshold, default below

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FJCLOUD_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ROADMAP_MD="$REPO_ROOT/ROADMAP.md"

# Subject marker batman writes on every lifecycle merge. Matching the subject
# rather than counting merge commits keeps a hand `git merge` of two topic
# branches from reading as a landed lane.
LANE_MERGE_MARKER='batman merge_worktree'

# Default staleness threshold, in lane merges.
#
# WHY 5, and it is a measurement rather than a preference. On 2026-08-06 the
# ledger was 6 lane merges past its newest header and carried five claims that
# live probing contradicted, so 6 is known-too-stale and the threshold has to
# sit below it. The three earlier instances above had drifted 6, 13 and 19 lane
# merges by the time a human caught them. Below that, a wave of 3-4 lanes
# landing between two supervisor ticks is ordinary and must not cry wolf. That
# leaves 5 as the only value both under the smallest observed failure and over
# routine wave churn. Re-measure before changing it; do not round it up because
# it fired.
DEFAULT_MAX_LANE_MERGES=5

fail_unmeasurable() {
    # One exit path for every arm that could not produce a number, so no future
    # edit can add an arm that quietly returns 0 instead.
    printf 'ssot_currency UNMEASURABLE reason=%s\n' "$1"
    exit 2
}

# Resolved inline rather than in a `THRESHOLD="$(resolve_threshold)"` helper.
# In that shape `fail_unmeasurable`'s message is written to the subshell's
# stdout and captured into the variable, so the run exits 2 having printed
# nothing and the operator sees a bare failure with no reason.
THRESHOLD="${FJCLOUD_SSOT_CURRENCY_MAX_LANE_MERGES:-$DEFAULT_MAX_LANE_MERGES}"
# An unparseable override is a caller error, not a licence to fall back to the
# default: falling back would let a typo silently loosen the gate.
case "$THRESHOLD" in
    '' | *[!0-9]*) fail_unmeasurable "invalid_threshold=$THRESHOLD" ;;
esac

[ -f "$ROADMAP_MD" ] || fail_unmeasurable "no_roadmap"

git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
    || fail_unmeasurable "not_a_git_repo"

# Measure against the remote-tracking ref, never local `main`. A clone whose
# local main carries unpushed lane merges is not evidence that those lanes
# reached the tree everyone else reads.
git -C "$REPO_ROOT" show-ref --verify --quiet refs/remotes/origin/main \
    || fail_unmeasurable "no_origin_main"

# Reconciliation headers name their SHA in backticks after `origin/main`. The
# hex run is bounded at 7..40 so an abbreviated header SHA still parses while a
# longer backticked token cannot be mistaken for one.
#
# Collected through a while-read loop rather than `mapfile`: this host's
# `/bin/bash` is 3.2, where `mapfile` does not exist and `${#arr[@]}` on an
# empty array is an unbound-variable error under `set -u`. A plain counter
# keeps the probe runnable on the oldest bash any lane might invoke it with.
BACKTICK='`'
# Built from $BACKTICK rather than written literally: the pattern has to survive
# both this file and any heredoc a caller wraps it in, and an escaped backtick
# inside a quoted string is the kind of thing a later edit silently breaks.
HEADER_SHA_PATTERN="RECONCILED[^${BACKTICK}]*${BACKTICK}origin/main${BACKTICK}[^${BACKTICK}]*${BACKTICK}[0-9a-f]{7,40}${BACKTICK}"

HEADER_SHAS=""
HEADER_COUNT=0
while IFS= read -r parsed_sha; do
    [ -n "$parsed_sha" ] || continue
    HEADER_SHAS="$HEADER_SHAS$parsed_sha
"
    HEADER_COUNT=$((HEADER_COUNT + 1))
done < <(
    grep -oE "$HEADER_SHA_PATTERN" "$ROADMAP_MD" 2>/dev/null \
        | grep -oE "${BACKTICK}[0-9a-f]{7,40}${BACKTICK}\$" \
        | tr -d "$BACKTICK"
)

[ "$HEADER_COUNT" -gt 0 ] || fail_unmeasurable "no_reconciliation_header"

best_sha=""
best_distance=""
unresolvable=0
unresolvable_first=""

while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    # An old header can name a SHA a pruned or shallow clone no longer holds.
    # Count it, name the first one, and keep going: one stale citation must not
    # blind the probe to the headers that are still usable.
    if ! git -C "$REPO_ROOT" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        unresolvable=$((unresolvable + 1))
        [ -n "$unresolvable_first" ] || unresolvable_first="$sha"
        continue
    fi
    distance="$(git -C "$REPO_ROOT" rev-list --count \
        --grep="$LANE_MERGE_MARKER" "${sha}..refs/remotes/origin/main" 2>/dev/null)" || continue
    case "$distance" in
        '' | *[!0-9]*) continue ;;
    esac
    # Smallest distance = the reconciliation that describes the most recent
    # tree. Deriving "newest" from the count rather than from line order means
    # reordering or inserting headers cannot change the verdict.
    if [ -z "$best_distance" ] || [ "$distance" -lt "$best_distance" ]; then
        best_distance="$distance"
        best_sha="$(git -C "$REPO_ROOT" rev-parse "${sha}^{commit}")"
    fi
done < <(printf '%s' "$HEADER_SHAS")

if [ -z "$best_distance" ]; then
    fail_unmeasurable "unresolvable_ledger_sha=${unresolvable_first:-unknown}"
fi

verdict="CURRENT"
exit_code=0
if [ "$best_distance" -gt "$THRESHOLD" ]; then
    verdict="STALE"
    exit_code=1
fi

printf 'ssot_currency %s ledger_sha=%s lane_merges_since=%s threshold=%s headers=%s unresolvable_headers=%s\n' \
    "$verdict" "$best_sha" "$best_distance" "$THRESHOLD" "$HEADER_COUNT" "$unresolvable"

if [ "$exit_code" -ne 0 ]; then
    printf 'ROADMAP.md describes a tree %s batman lane merges old. Reconcile it against origin/main and add a dated reconciliation header naming the SHA measured.\n' \
        "$best_distance"
    printf 'Lanes landed since that header:\n'
    git -C "$REPO_ROOT" log --format='  %h %s' \
        --grep="$LANE_MERGE_MARKER" "${best_sha}..refs/remotes/origin/main"
fi

exit "$exit_code"
