#!/usr/bin/env bash
# Tests for scripts/check_roadmap_v2_shape.sh.
#
# The check asserts ROADMAP.md follows the v2 owner contract:
#   - required `## Active`, `## Planned`, `## Archive` headings present;
#   - retired `## Current Focus`, `## Feature Status`, `## Planned (Next Up)`,
#     `## Open / Not Yet Implemented` headings absent;
#   - each captured live-item title from the script's registry appears
#     verbatim;
#   - file is <= 200 lines.
#   - each row is within the byte-length contract.
#   - the archive pointer names the canonical implemented/ directory.
#
# All tests are content-deterministic. Each fixture stages a temporary
# tmpdir with a crafted ROADMAP.md, runs the script with FJCLOUD_DOC_ROOT
# pointed at it, and asserts the expected exit code + stderr.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK_SCRIPT="$REPO_ROOT/scripts/check_roadmap_v2_shape.sh"
MAX_ROW_BYTES=4000
OVER_BOUND_ROW_BYTES=$((MAX_ROW_BYTES + 1))
UTF8_ROW_CHARACTERS=2001
UTF8_ROW_BYTES=$((UTF8_ROW_CHARACTERS * 2))
BYTE_BUDGET_ROW_LINE=38
RETIRED_IMPLEMENTED_PATH="roadmap/""implemented"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

# The script's REQUIRED_LIVE_TITLES list is the source of truth for what
# must survive verbatim. The fixture below embeds every title so a valid
# v2-shaped ROADMAP.md fixture stays a single SSOT-aligned blob.
write_valid_roadmap() {
    local out_path="$1"
    cat > "$out_path" <<'ROADMAP'
# Flapjack Cloud (fjcloud) — Roadmap

**Last updated:** test fixture

## Active

Test fixture active body.

## Planned

| Priority | Feature | Notes |
| --- | --- | --- |
| P1 | Public-release completion (active orchestration) | n |
| P1 | Execute staging billing rehearsal rerun | n |
| P1 | Web-plane deploy automation | n |
| P1 | AWS live-infra E2E remaining guardrails | n |
| P1 | Live RDS restore proof (2026-04-23 captured) | n |
| P2 | `panics_total` monitoring alarm wiring | n |
| P2 | SES deliverability proof | n |
| P3 | Reintroduce Linux-Playwright Firefox/WebKit | n |

- **DictionariesTab size override remains.** owner.
- **Pricing legal disclaimer follow-up remains open.** owner.
- **Prod-env OAuth staging-app follow-ups remain open.** owner.
- **SES bounce/complaint live probe rerun remains open.** owner.
- **Account-retention automation implemented.** owner.
- **AWS live-infra E2E destructive-proof gap remains open.** owner.
- **AWS live-infra E2E current-main wrapper evidence passed.** owner.
- **Runtime-smoke wrapper needs fresh current-main artifact.** owner.
- **Staging billing rehearsal current-main rerun remains open.** owner.
- **Playwright CI local Stripe-mode regression remains open.** owner.
- **June 3 customer-release rerun follow-ups remain open (narrowed).** owner.
- **`e2e-deployed` deploy-currency gate remains open.** owner.

## Archive

Historical implementation details: [`implemented/`](implemented/).
ROADMAP
}

build_fixture() {
    local tmpdir; tmpdir="$(mktemp -d)"
    write_valid_roadmap "$tmpdir/ROADMAP.md"
    echo "$tmpdir"
}

append_repeated_row() {
    local out_path="$1"
    local character="$2"
    local repetitions="$3"
    python3 - "$out_path" "$character" "$repetitions" <<'PY'
from pathlib import Path
import sys

out_path = Path(sys.argv[1])
character = sys.argv[2]
repetitions = int(sys.argv[3])
with out_path.open("a", encoding="utf-8") as roadmap:
    roadmap.write(character * repetitions + "\n")
PY
}

last_row_counts() {
    local roadmap_path="$1"
    python3 - "$roadmap_path" <<'PY'
from pathlib import Path
import sys

last_row = Path(sys.argv[1]).read_bytes().splitlines()[-1]
print(len(last_row.decode("utf-8")), len(last_row))
PY
}

run_check() {
    local doc_root="$1"
    RUN_EXIT_CODE=0
    RUN_STDERR="$(FJCLOUD_DOC_ROOT="$doc_root" bash "$CHECK_SCRIPT" 2>&1 1>/dev/null)" || RUN_EXIT_CODE=$?
    RUN_STDOUT="$(FJCLOUD_DOC_ROOT="$doc_root" bash "$CHECK_SCRIPT" 2>/dev/null)" || true
}

live_doc_script_paths() {
    local repo_root="$1"
    git -C "$repo_root" ls-files --cached --others --exclude-standard -- '*.md' '*.sh' '*.toml' \
        | sed -e '/^chatting\//d' -e '/^chats\//d'
}

legacy_implemented_path_matches() {
    local repo_root="$1"
    local retired_path="$2"
    local relative_paths
    local relative_path

    if ! relative_paths="$(live_doc_script_paths "$repo_root")"; then
        return 1
    fi
    if [ -z "$relative_paths" ]; then
        return 0
    fi

    while IFS= read -r relative_path; do
        local grep_exit_code=0
        grep -nH "$retired_path" "$repo_root/$relative_path" || grep_exit_code=$?
        if [ "$grep_exit_code" -gt 1 ]; then
            return "$grep_exit_code"
        fi
    done <<< "$relative_paths"
}

# ============================================================
# Test 1 — Valid v2-shaped fixture passes.
# ============================================================
test_valid_v2_passes() {
    local dir; dir="$(build_fixture)"
    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "0" "valid v2 ROADMAP.md fixture should pass"
}

# ============================================================
# Test 2 — Missing required heading fails.
# ============================================================
test_missing_active_heading_fails() {
    local dir; dir="$(build_fixture)"
    # Drop the `## Active` heading.
    sed -i.bak '/^## Active$/d' "$dir/ROADMAP.md" && rm "$dir/ROADMAP.md.bak"
    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "1" "missing '## Active' should fail"
    assert_contains "$RUN_STDERR" "## Active" "stderr should name the missing heading"
}

# ============================================================
# Test 3 — Retired heading still present fails.
# ============================================================
test_retired_current_focus_fails() {
    local dir; dir="$(build_fixture)"
    # Append a retired heading to a per-test copy.
    printf '\n## Current Focus\n\nleftover\n' >> "$dir/ROADMAP.md"
    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "1" "retained '## Current Focus' should fail"
    assert_contains "$RUN_STDERR" "Current Focus" "stderr should name the retired heading"
}

test_retired_feature_status_fails() {
    local dir; dir="$(build_fixture)"
    printf '\n## Feature Status\n\nleftover table\n' >> "$dir/ROADMAP.md"
    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "1" "retained '## Feature Status' should fail"
    assert_contains "$RUN_STDERR" "Feature Status" "stderr should name the retired heading"
}

test_retired_planned_next_up_fails() {
    local dir; dir="$(build_fixture)"
    printf '\n## Planned (Next Up)\n\nleftover\n' >> "$dir/ROADMAP.md"
    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "1" "retained '## Planned (Next Up)' should fail"
    assert_contains "$RUN_STDERR" "Planned (Next Up)" "stderr should name the retired heading"
}

test_retired_open_not_yet_implemented_fails() {
    local dir; dir="$(build_fixture)"
    printf '\n## Open / Not Yet Implemented\n\nleftover bullets\n' >> "$dir/ROADMAP.md"
    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "1" "retained '## Open / Not Yet Implemented' should fail"
    assert_contains "$RUN_STDERR" "Open / Not Yet Implemented" "stderr should name the retired heading"
}

# ============================================================
# Test 4 — Live title removed from fixture fails.
# ============================================================
test_missing_live_title_fails() {
    local dir; dir="$(build_fixture)"
    # Remove one captured live title.
    sed -i.bak '/DictionariesTab size override remains\./d' "$dir/ROADMAP.md" && rm "$dir/ROADMAP.md.bak"
    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "1" "removing a captured live title should fail"
    assert_contains "$RUN_STDERR" "DictionariesTab size override remains." "stderr should name the missing live title"
}

# ============================================================
# Test 5 — Over the 200-line budget fails.
# ============================================================
test_over_line_budget_fails() {
    local dir; dir="$(build_fixture)"
    # Pad to > 200 lines.
    for _ in $(seq 1 250); do echo "padding line" >> "$dir/ROADMAP.md"; done
    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "1" "over 200 lines should fail"
    assert_contains "$RUN_STDERR" "lines" "stderr should explain the line-count failure"
}

# ============================================================
# Test 6 — A row exactly at the byte budget passes.
# ============================================================
test_row_at_exact_byte_budget_passes() {
    local dir; dir="$(build_fixture)"
    append_repeated_row "$dir/ROADMAP.md" "x" "$MAX_ROW_BYTES"

    local row_characters row_bytes
    read -r row_characters row_bytes <<< "$(last_row_counts "$dir/ROADMAP.md")"
    assert_eq "$row_characters" "$MAX_ROW_BYTES" "boundary fixture row should contain exactly $MAX_ROW_BYTES ASCII characters"
    assert_eq "$row_bytes" "$MAX_ROW_BYTES" "boundary fixture row should be exactly $MAX_ROW_BYTES bytes"

    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "0" "ROADMAP.md row at the exact byte budget should pass"
}

# ============================================================
# Test 7 — An ASCII row over the byte budget fails.
# ============================================================
test_over_row_byte_budget_fails() {
    local dir; dir="$(build_fixture)"
    append_repeated_row "$dir/ROADMAP.md" "x" "$OVER_BOUND_ROW_BYTES"

    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "1" "over-bound ROADMAP.md row should fail"
    assert_contains "$RUN_STDERR" "line $BYTE_BUDGET_ROW_LINE" "stderr should name the over-bound line number"
    assert_contains "$RUN_STDERR" "$OVER_BOUND_ROW_BYTES bytes" "stderr should name the over-bound row byte count"
}

# ============================================================
# Test 8 — A multibyte row is measured in bytes, not characters.
# ============================================================
test_multibyte_row_over_byte_budget_fails() {
    local dir; dir="$(build_fixture)"
    append_repeated_row "$dir/ROADMAP.md" "é" "$UTF8_ROW_CHARACTERS"

    local row_characters row_bytes
    read -r row_characters row_bytes <<< "$(last_row_counts "$dir/ROADMAP.md")"
    assert_eq "$row_characters" "$UTF8_ROW_CHARACTERS" "multibyte fixture should contain fewer than $MAX_ROW_BYTES characters"
    assert_eq "$row_bytes" "$UTF8_ROW_BYTES" "multibyte fixture should exceed the byte budget"

    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "1" "over-bound multibyte ROADMAP.md row should fail"
    assert_contains "$RUN_STDERR" "line $BYTE_BUDGET_ROW_LINE" "stderr should name the multibyte row line number"
    assert_contains "$RUN_STDERR" "$UTF8_ROW_BYTES bytes" "stderr should name the multibyte row byte count"
}

# ============================================================
# Test 9 — Legacy archive pointer fails.
# ============================================================
test_legacy_archive_pointer_fails() {
    local dir; dir="$(build_fixture)"
    python3 - "$dir/ROADMAP.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(
    path.read_text().replace(
        "[`implemented/`](implemented/)",
        "`roadmap/" "implemented.md`",
    )
)
PY
    run_check "$dir"
    assert_eq "$RUN_EXIT_CODE" "1" "legacy implemented archive pointer should fail"
    assert_contains "$RUN_STDERR" "implemented/" "stderr should name the canonical archive owner"
}

# ============================================================
# Test 10 — Live docs/scripts do not reference the retired path.
# ============================================================
test_live_docs_and_scripts_avoid_legacy_implemented_path() {
    local matches
    if ! matches="$(legacy_implemented_path_matches "$REPO_ROOT" "$RETIRED_IMPLEMENTED_PATH")"; then
        fail "live docs/scripts could not be enumerated from Git"
        return
    fi
    if [ -n "$matches" ]; then
        printf '%s\n' "$matches"
        fail "live docs/scripts should not reference the retired implemented path"
    else
        pass "live docs/scripts avoid the retired implemented path"
    fi
}

test_tracked_live_doc_legacy_reference_is_detected() {
    local dir; dir="$(mktemp -d)"

    git -C "$dir" init -q
    printf 'live document mentions %s\n' "$RETIRED_IMPLEMENTED_PATH" > "$dir/tracked.md"
    git -C "$dir" add tracked.md

    local matches
    if ! matches="$(legacy_implemented_path_matches "$dir" "$RETIRED_IMPLEMENTED_PATH")"; then
        fail "tracked live-doc fixture could not be enumerated from Git"
        return
    fi
    assert_contains "$matches" "tracked.md:1" "tracked live-doc legacy references should be detected"
}

test_untracked_live_doc_legacy_reference_is_detected() {
    local dir; dir="$(mktemp -d)"

    git -C "$dir" init -q
    printf 'new live document mentions %s\n' "$RETIRED_IMPLEMENTED_PATH" > "$dir/untracked.md"

    local matches
    if ! matches="$(legacy_implemented_path_matches "$dir" "$RETIRED_IMPLEMENTED_PATH")"; then
        fail "untracked live-doc fixture could not be enumerated from Git"
        return
    fi
    assert_contains "$matches" "untracked.md:1" "non-ignored untracked live-doc legacy references should be detected"
}

test_ignored_local_dependency_docs_are_not_live_docs() {
    local dir; dir="$(mktemp -d)"

    git -C "$dir" init -q
    printf '.local/\n' > "$dir/.gitignore"
    printf 'tracked document is clean\n' > "$dir/tracked.md"
    mkdir -p "$dir/.local/flapjack-v1.0.10"
    printf 'ignored dependency mentions %s\n' "$RETIRED_IMPLEMENTED_PATH" > "$dir/.local/flapjack-v1.0.10/README.md"
    git -C "$dir" add .gitignore tracked.md

    local raw_matches
    raw_matches="$(grep -rn "$RETIRED_IMPLEMENTED_PATH" "$dir" --include='*.md' | grep -v '/.git/' || true)"
    assert_contains "$raw_matches" ".local/flapjack-v1.0.10/README.md" "fixture should fail under an unbounded repo grep"

    local matches
    matches="$(legacy_implemented_path_matches "$dir" "$RETIRED_IMPLEMENTED_PATH")"
    assert_eq "$matches" "" "ignored .local dependency docs should not count as live fjcloud documentation"
}

test_live_doc_enumeration_failure_fails_closed() {
    local dir; dir="$(mktemp -d)"
    local command_exit_code=0

    legacy_implemented_path_matches "$dir" "$RETIRED_IMPLEMENTED_PATH" >/dev/null 2>&1 \
        || command_exit_code=$?

    assert_ne "$command_exit_code" "0" "live-doc scan should fail when its root is not a Git repository"
}

test_tracked_live_doc_read_failure_fails_closed() {
    local dir; dir="$(mktemp -d)"

    git -C "$dir" init -q
    printf 'tracked document\n' > "$dir/unreadable.md"
    git -C "$dir" add unreadable.md
    rm "$dir/unreadable.md"

    local command_exit_code=0
    legacy_implemented_path_matches "$dir" "$RETIRED_IMPLEMENTED_PATH" >/dev/null 2>&1 \
        || command_exit_code=$?

    assert_ne "$command_exit_code" "0" "live-doc scan should fail when a tracked document cannot be read"
}

# ============================================================
# Test 11 — Missing ROADMAP.md fails cleanly.
# ============================================================
test_missing_file_fails() {
    local tmpdir; tmpdir="$(mktemp -d)"
    run_check "$tmpdir"
    assert_eq "$RUN_EXIT_CODE" "1" "missing ROADMAP.md should exit 1"
    assert_contains "$RUN_STDERR" "ROADMAP.md not found" "stderr should explain the missing file"
}

# ============================================================
# Test 12 — Live repo satisfies the complete shape contract.
# ============================================================
test_repo_actual_state_passes() {
    run_check "$REPO_ROOT"
    assert_eq "$RUN_EXIT_CODE" "0" "actual repo ROADMAP.md should satisfy the v2 shape contract"
    assert_contains "$RUN_STDOUT" "OK: ROADMAP.md satisfies v2 shape contract" "stdout should report a passing live-repo contract"
}

test_valid_v2_passes
test_missing_active_heading_fails
test_retired_current_focus_fails
test_retired_feature_status_fails
test_retired_planned_next_up_fails
test_retired_open_not_yet_implemented_fails
test_missing_live_title_fails
test_over_line_budget_fails
test_row_at_exact_byte_budget_passes
test_over_row_byte_budget_fails
test_multibyte_row_over_byte_budget_fails
test_legacy_archive_pointer_fails
test_live_docs_and_scripts_avoid_legacy_implemented_path
test_tracked_live_doc_legacy_reference_is_detected
test_untracked_live_doc_legacy_reference_is_detected
test_ignored_local_dependency_docs_are_not_live_docs
test_live_doc_enumeration_failure_fails_closed
test_tracked_live_doc_read_failure_fails_closed
test_missing_file_fails
test_repo_actual_state_passes

run_test_summary
