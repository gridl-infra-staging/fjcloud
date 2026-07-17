#!/usr/bin/env bash
# RED first, then GREEN after reconciliation blocks are appended.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

CLOSEOUT_FILE="$REPO_ROOT/chatting/20260531T215558Z_launch_drive_closeout.md"
ORCH_FILE="$REPO_ROOT/chats/icg/may31_pm_1_post_launch_closeout_and_durability_orchestrator.md"

extract_reconciliation_section() {
    local path="$1"
    awk '
        /^## Reconciliation 2026-06-01$/ {in_block=1; next}
        /^## / && in_block {exit}
        in_block {print}
    ' "$path"
}

test_reconciliation_headings_exist() {
    local closeout_has_heading orch_has_heading
    closeout_has_heading="$(grep -c '^## Reconciliation 2026-06-01$' "$CLOSEOUT_FILE" || true)"
    orch_has_heading="$(grep -c '^## Reconciliation 2026-06-01$' "$ORCH_FILE" || true)"

    assert_eq "$closeout_has_heading" "1" "closeout should contain one 2026-06-01 reconciliation heading"
    assert_eq "$orch_has_heading" "1" "orchestrator should contain one 2026-06-01 reconciliation heading"
}

test_closeout_block_has_canonical_detailed_evidence() {
    local closeout_block
    closeout_block="$(extract_reconciliation_section "$CLOSEOUT_FILE")"

    assert_contains "$closeout_block" "pre-sync prod" "closeout reconciliation should include pre-sync evidence"
    assert_contains "$closeout_block" "post-sync prod" "closeout reconciliation should include post-sync evidence"
    assert_contains "$closeout_block" "prod mirror CI" "closeout reconciliation should include prod-mirror CI confirmation"
    assert_contains "$closeout_block" "prod /version" "closeout reconciliation should include prod /version facts"
}

test_orchestrator_block_is_superseding_pointer_only() {
    local orch_block
    orch_block="$(extract_reconciliation_section "$ORCH_FILE")"

    assert_contains "$orch_block" "incorrect at authoring time" "orchestrator block should mark stale claim as incorrect"
    assert_contains "$orch_block" "canonical correction" "orchestrator block should point to canonical closeout correction"
    assert_contains "$orch_block" "chatting/20260531T215558Z_launch_drive_closeout.md" "orchestrator block should reference closeout artifact"

    assert_not_contains "$orch_block" "pre-sync prod" "orchestrator block should not duplicate detailed pre-sync evidence"
    assert_not_contains "$orch_block" "post-sync prod" "orchestrator block should not duplicate detailed post-sync evidence"
    assert_not_contains "$orch_block" "prod mirror CI" "orchestrator block should not duplicate CI evidence"
}

test_matt_guard_misclassification_suggestion_exists_with_required_content() {
    local suggestion_glob suggestion_matches suggestion_path suggestion_content
    suggestion_glob="$REPO_ROOT/chats/suggestions/*_matt_branch_merged_guard_misclassification.md"

    shopt -s nullglob
    suggestion_matches=( $suggestion_glob )
    shopt -u nullglob

    assert_eq "${#suggestion_matches[@]}" "1" "exactly one matt-guard misclassification suggestion should exist"

    if [ "${#suggestion_matches[@]}" -ne 1 ]; then
        return
    fi

    suggestion_path="${suggestion_matches[0]:-}"
    assert_file_exists "$suggestion_path" "matt-guard misclassification suggestion file should exist"

    suggestion_content="$(cat "$suggestion_path")"
    assert_contains "$suggestion_content" "matt_root/batman/lifecycle_candidates.py" "suggestion should cite lifecycle candidates owner path"
    assert_contains "$suggestion_content" "matt_root/batman/lifecycle_discovery.py" "suggestion should cite lifecycle discovery owner path"
    assert_contains "$suggestion_content" "matt_root/matt/epilogue.py" "suggestion should cite epilogue owner path"
    assert_contains "$suggestion_content" "completed_stages == num_stages" "suggestion should include completed-stages gate phrase"
}

test_reconciliation_headings_exist
test_closeout_block_has_canonical_detailed_evidence
test_orchestrator_block_is_superseding_pointer_only
test_matt_guard_misclassification_suggestion_exists_with_required_content

run_test_summary
