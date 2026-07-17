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
#   - the archive pointer names the canonical implemented/ directory.
#
# All tests are content-deterministic. Each fixture stages a temporary
# tmpdir with a crafted ROADMAP.md, runs the script with FJCLOUD_DOC_ROOT
# pointed at it, and asserts the expected exit code + stderr.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK_SCRIPT="$REPO_ROOT/scripts/check_roadmap_v2_shape.sh"

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

run_check() {
    local doc_root="$1"
    RUN_EXIT_CODE=0
    RUN_STDERR="$(FJCLOUD_DOC_ROOT="$doc_root" bash "$CHECK_SCRIPT" 2>&1 1>/dev/null)" || RUN_EXIT_CODE=$?
    RUN_STDOUT="$(FJCLOUD_DOC_ROOT="$doc_root" bash "$CHECK_SCRIPT" 2>/dev/null)" || true
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
# Test 6 — Legacy archive pointer fails.
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
# Test 7 — Live docs/scripts do not reference the retired path.
# ============================================================
test_live_docs_and_scripts_avoid_legacy_implemented_path() {
    local retired_path
    retired_path="roadmap/""implemented"
    if grep -rn "$retired_path" "$REPO_ROOT" \
        --include='*.md' --include='*.sh' --include='*.toml' \
        | grep -v '/.git/' | grep -v '/chatting/' | grep -v '/chats/'; then
        fail "live docs/scripts should not reference the retired implemented path"
    else
        pass "live docs/scripts avoid the retired implemented path"
    fi
}

# ============================================================
# Test 8 — Missing ROADMAP.md fails cleanly.
# ============================================================
test_missing_file_fails() {
    local tmpdir; tmpdir="$(mktemp -d)"
    run_check "$tmpdir"
    assert_eq "$RUN_EXIT_CODE" "1" "missing ROADMAP.md should exit 1"
    assert_contains "$RUN_STDERR" "ROADMAP.md not found" "stderr should explain the missing file"
}

# ============================================================
# Test 9 — Live repo state passes (self-host check).
# ============================================================
test_repo_actual_state_passes() {
    RUN_EXIT_CODE=0
    RUN_STDERR="$(bash "$CHECK_SCRIPT" 2>&1 1>/dev/null)" || RUN_EXIT_CODE=$?
    assert_eq "$RUN_EXIT_CODE" "0" "actual repo ROADMAP.md should pass the gate"
}

test_valid_v2_passes
test_missing_active_heading_fails
test_retired_current_focus_fails
test_retired_feature_status_fails
test_retired_planned_next_up_fails
test_retired_open_not_yet_implemented_fails
test_missing_live_title_fails
test_over_line_budget_fails
test_legacy_archive_pointer_fails
test_live_docs_and_scripts_avoid_legacy_implemented_path
test_missing_file_fails
test_repo_actual_state_passes

run_test_summary
