#!/usr/bin/env bash
# Contract tests for the canonical Stage 1 transition gate block in
# chats/icg/jun01_pm_4_customer_release_verification_and_closeout.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CANONICAL_STAGE_FILE="$REPO_ROOT/chats/icg/jun01_pm_4_customer_release_verification_and_closeout.md"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

extract_stage1_gate_block() {
    awk '
        /^## Stage 1 — Wave 1 artifact-presence sanity \(transition gate re-run\)$/ { in_stage=1; next }
        in_stage && /^```bash$/ { in_block=1; next }
        in_block && /^```$/ { exit }
        in_block { print }
    ' "$CANONICAL_STAGE_FILE"
}

test_stage1_gate_targets_shipped_l2_artifacts() {
    local block
    block="$(extract_stage1_gate_block)"

    assert_contains \
        "$block" \
        "web/src/routes/console/indexes/[name]/tabs/DataManagementCard.svelte" \
        "Stage 1 gate checks shipped DataManagementCard path"

    assert_not_contains \
        "$block" \
        "web/src/routes/console/indexes/[name]/tabs/overview/DataManagementCard.svelte" \
        "Stage 1 gate does not reference stale overview/DataManagementCard path"

    assert_contains \
        "$block" \
        "scripts/canary/contracts/index_export_browser_path_probe.sh" \
        "Stage 1 gate checks shipped index export browser probe script"

    assert_not_contains \
        "$block" \
        "web/src/lib/index-export-helpers.ts" \
        "Stage 1 gate does not reference removed index-export helper path"
}

test_stage1_gate_avoids_pipefail_sensitive_ls_tree_grep_q_pipeline() {
    local block
    block="$(extract_stage1_gate_block)"

    assert_not_contains \
        "$block" \
        "git ls-tree -r origin/main --name-only \\" \
        "Stage 1 gate avoids ls-tree full-tree pipeline form that can false-negative under pipefail"
}

test_stage1_gate_avoids_pipefail_sensitive_show_grep_q_pipeline() {
    local block
    block="$(extract_stage1_gate_block)"

    assert_not_contains \
        "$block" \
        "| grep -q" \
        "Stage 1 gate avoids grep -q pipelines under pipefail"
}

test_stage1_gate_targets_real_origin_main_artifacts() {
    local repo_root
    repo_root="$REPO_ROOT"

    local metrics_path
    metrics_path='web/src/routes/console/indexes/[name]/tabs/MetricsTab.svelte'
    local metrics_match
    metrics_match="$(cd "$repo_root" && git ls-tree -r origin/main --name-only -- "$metrics_path")"
    assert_eq "$metrics_match" "$metrics_path" "origin/main contains MetricsTab artifact path"

    local data_management_path
    data_management_path='web/src/routes/console/indexes/[name]/tabs/DataManagementCard.svelte'
    local data_management_match
    data_management_match="$(cd "$repo_root" && git ls-tree -r origin/main --name-only -- "$data_management_path")"
    assert_eq "$data_management_match" "$data_management_path" "origin/main contains DataManagementCard artifact path"

    local export_probe_path
    export_probe_path='scripts/canary/contracts/index_export_browser_path_probe.sh'
    local export_probe_match
    export_probe_match="$(cd "$repo_root" && git ls-tree -r origin/main --name-only -- "$export_probe_path")"
    assert_eq "$export_probe_match" "$export_probe_path" "origin/main contains index export probe artifact path"
}

test_stage1_gate_targets_no_removed_l2_helper_path() {
    local repo_root
    repo_root="$REPO_ROOT"

    local removed_path
    removed_path='web/src/lib/index-export-helpers.ts'
    local removed_match
    removed_match="$(cd "$repo_root" && git ls-tree -r origin/main --name-only -- "$removed_path")"

    assert_eq "$removed_match" "" "origin/main does not contain removed index-export helper path"
}

test_stage1_gate_targets_no_stale_overview_subpath() {
    local repo_root
    repo_root="$REPO_ROOT"

    local stale_path
    stale_path='web/src/routes/console/indexes/[name]/tabs/overview/DataManagementCard.svelte'
    local stale_match
    stale_match="$(cd "$repo_root" && git ls-tree -r origin/main --name-only -- "$stale_path")"

    assert_eq "$stale_match" "" "origin/main does not contain stale overview/DataManagementCard path"
}

test_stage1_gate_targets_shipped_overview_mount_owner() {
    local overview_file
    overview_file="$(cd "$REPO_ROOT" && git show origin/main:web/src/routes/console/indexes/[name]/tabs/OverviewTab.svelte 2>/dev/null || true)"

    assert_contains \
        "$overview_file" \
        "<DataManagementCard" \
        "origin/main OverviewTab mounts DataManagementCard"
}

test_stage1_gate_targets_shipped_metrics_type_owner() {
    local types_file
    types_file="$(cd "$REPO_ROOT" && git show origin/main:web/src/lib/api/types.ts 2>/dev/null || true)"

    assert_contains \
        "$types_file" \
        "IndexMetricsResponse" \
        "origin/main types include IndexMetricsResponse"
}

test_stage1_gate_keeps_l3_owner_checks_in_contract() {
    local block
    block="$(extract_stage1_gate_block)"
    local implemented_archive_path
    implemented_archive_path="implemented/2026-06-05_roadmap_v2_reshape_archive.md"
    local retired_implemented_path
    retired_implemented_path="roadmap/""implemented.md"

    assert_contains \
        "$block" \
        "ROADMAP_OPEN_LINES=\"\$(awk '/^## Open \\/ Not Yet Implemented/,/^## Archive|^## Planned|^## Feature Status/' ROADMAP.md | wc -l)\"" \
        "Stage 1 gate keeps ROADMAP line-count check owner"

    assert_contains \
        "$block" \
        "grep -qE 'jun01_pm_3 reconciliation pass' \"\$L3_IMPLEMENTED_ARCHIVE_PATH\"" \
        "Stage 1 gate keeps reconciliation anchor presence check owner"

    assert_contains \
        "$block" \
        "$implemented_archive_path" \
        "Stage 1 gate checks the canonical implemented archive path"

    assert_not_contains \
        "$block" \
        "$retired_implemented_path" \
        "Stage 1 gate does not reference retired implemented path"
}

test_stage1_gate_targets_full_eight_check_set() {
    local block
    block="$(extract_stage1_gate_block)"

    local expected_checks=8
    local actual_checks
    actual_checks="$(printf '%s\n' "$block" | rg -n '^\s*\|\| \{ echo "' | wc -l | tr -d ' ')"

    assert_eq "$actual_checks" "$expected_checks" "Stage 1 gate block defines exactly eight artifact checks"
}

test_stage1_gate_targets_shipped_l2_artifacts
test_stage1_gate_avoids_pipefail_sensitive_ls_tree_grep_q_pipeline
test_stage1_gate_avoids_pipefail_sensitive_show_grep_q_pipeline
test_stage1_gate_targets_real_origin_main_artifacts
test_stage1_gate_targets_no_removed_l2_helper_path
test_stage1_gate_targets_no_stale_overview_subpath
test_stage1_gate_targets_shipped_overview_mount_owner
test_stage1_gate_targets_shipped_metrics_type_owner
test_stage1_gate_keeps_l3_owner_checks_in_contract
test_stage1_gate_targets_full_eight_check_set

run_test_summary
