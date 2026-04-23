#!/usr/bin/env bash
# Tests for scripts/reliability/seed-test-profiles.sh harness.
# Validates: generation produces non-empty JSON, deterministic structure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROFILES_DIR="$REPO_ROOT/scripts/reliability/profiles"
HARNESS_SCRIPT="$REPO_ROOT/scripts/reliability/seed-test-profiles.sh"

PASS_COUNT=0
FAIL_COUNT=0

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

# Run a test function with profile directory backup/restore.
# This guarantees original profile artifacts are restored even if the test fails.
run_with_profile_backup() {
    local temp_dir backup_dir had_profiles
    temp_dir="$(mktemp -d)"
    backup_dir="$temp_dir/profiles_backup"
    had_profiles=0

    if [ -d "$PROFILES_DIR" ]; then
        cp -R "$PROFILES_DIR" "$backup_dir"
        had_profiles=1
    fi

    set +e
    "$@"
    local test_status=$?
    set -e

    rm -rf "$PROFILES_DIR"
    if [ "$had_profiles" -eq 1 ] && [ -d "$backup_dir" ]; then
        cp -R "$backup_dir" "$PROFILES_DIR"
    fi
    rm -rf "$temp_dir"
    return "$test_status"
}

# ============================================================================
# Test: harness produces non-empty JSON for each tier/metric
# ============================================================================

test_harness_produces_non_empty_json_impl() {
    # Run harness
    if ! bash "$HARNESS_SCRIPT" >/dev/null 2>&1; then
        fail "harness execution failed"
        return 1
    fi
    
    # Validate each artifact exists and is non-empty
    local tiers=("1k" "10k" "100k")
    local metrics=("cpu" "mem" "disk" "latency")
    
    for tier in "${tiers[@]}"; do
        for metric in "${metrics[@]}"; do
            local artifact="$PROFILES_DIR/${tier}_${metric}.json"
            if [ ! -f "$artifact" ]; then
                fail "harness did not produce ${tier}_${metric}.json"
                continue
            fi
            
            local size
            size="$(wc -c < "$artifact" | tr -d ' ')"
            if [ "$size" -eq 0 ]; then
                fail "harness produced empty ${tier}_${metric}.json"
            else
                pass "harness produced non-empty ${tier}_${metric}.json (${size} bytes)"
            fi
            
            # Validate it's valid JSON
            if ! python3 -m json.tool "$artifact" >/dev/null 2>&1; then
                fail "harness produced invalid JSON: ${tier}_${metric}.json"
            fi
        done
    done
    
    # Validate summary.json
    local summary="$PROFILES_DIR/summary.json"
    if [ ! -f "$summary" ]; then
        fail "harness did not produce summary.json"
    else
        local summary_size
        summary_size="$(wc -c < "$summary" | tr -d ' ')"
        if [ "$summary_size" -eq 0 ]; then
            fail "harness produced empty summary.json"
        else
            pass "harness produced non-empty summary.json (${summary_size} bytes)"
        fi
        
        if ! python3 -m json.tool "$summary" >/dev/null 2>&1; then
            fail "harness produced invalid JSON: summary.json"
        fi
    fi
}

test_harness_produces_non_empty_json() {
    run_with_profile_backup test_harness_produces_non_empty_json_impl
}

# ============================================================================
# Test: harness produces deterministic structure (same fields, types)
# ============================================================================

test_harness_produces_deterministic_structure_impl() {
    local temp_dir
    temp_dir="$(mktemp -d)"

    # Run harness twice
    if ! bash "$HARNESS_SCRIPT" >/dev/null 2>&1; then
        fail "first harness execution failed"
        rm -rf "$temp_dir"
        return 1
    fi
    cp -r "$PROFILES_DIR" "$temp_dir/run1"
    
    rm -rf "$PROFILES_DIR"
    if ! bash "$HARNESS_SCRIPT" >/dev/null 2>&1; then
        fail "second harness execution failed"
        rm -rf "$temp_dir"
        return 1
    fi
    cp -r "$PROFILES_DIR" "$temp_dir/run2"
    
    # Compare structure (ignore timestamp differences)
    local tiers=("1k" "10k" "100k")
    local metrics=("cpu" "mem" "disk" "latency")
    
    for tier in "${tiers[@]}"; do
        for metric in "${metrics[@]}"; do
            local file1="$temp_dir/run1/${tier}_${metric}.json"
            local file2="$temp_dir/run2/${tier}_${metric}.json"
            
            # Extract structure without timestamps
            local struct1 struct2
            if ! struct1="$(python3 -c "
import json
with open('$file1') as f:
    d = json.load(f)
    d.pop('timestamp', None)
    print(json.dumps(d, sort_keys=True))
" 2>&1)"; then
                fail "failed to parse run1 structure for ${tier}_${metric}.json: $struct1"
                continue
            fi
            
            if ! struct2="$(python3 -c "
import json
with open('$file2') as f:
    d = json.load(f)
    d.pop('timestamp', None)
    print(json.dumps(d, sort_keys=True))
" 2>&1)"; then
                fail "failed to parse run2 structure for ${tier}_${metric}.json: $struct2"
                continue
            fi
            
            if [ "$struct1" = "$struct2" ]; then
                pass "harness produces deterministic structure for ${tier}_${metric}.json"
            else
                fail "harness produces non-deterministic structure for ${tier}_${metric}.json"
                echo "  Run1 structure: $struct1" >&2
                echo "  Run2 structure: $struct2" >&2
            fi
        done
    done

    rm -rf "$temp_dir"
}

test_harness_produces_deterministic_structure() {
    run_with_profile_backup test_harness_produces_deterministic_structure_impl
}

# ============================================================================
# Test: seeded mem/disk values match capacity_profiles.rs constants exactly
# ============================================================================

test_seeded_mem_disk_match_capacity_constants_impl() {
    if ! bash "$HARNESS_SCRIPT" >/dev/null 2>&1; then
        fail "harness execution failed for drift check"
        return 1
    fi

    local check_output
    if ! check_output="$(python3 - "$PROFILES_DIR" "$REPO_ROOT/infra/api/tests/common/capacity_profiles.rs" "$REPO_ROOT/scripts/reliability/lib/parse_capacity_profiles.py" <<'PYEOF'
import json
import os
import subprocess
import sys

profiles_dir = sys.argv[1]
capacity_profiles_path = sys.argv[2]
capacity_parser_path = sys.argv[3]
expected = json.loads(
    subprocess.check_output(
        [sys.executable, capacity_parser_path, capacity_profiles_path],
        text=True,
    )
)

for tier in ("1k", "10k", "100k"):
    with open(os.path.join(profiles_dir, f"{tier}_mem.json")) as f:
        mem = json.load(f)
    with open(os.path.join(profiles_dir, f"{tier}_disk.json")) as f:
        disk = json.load(f)

    measured_mem = mem["envelope"]["query_load"]["rss_bytes"]
    measured_disk = disk["envelope"]["post_seed"]["disk_bytes"]

    if measured_mem != expected[tier]["mem_rss_bytes"]:
        raise RuntimeError(
            f"mem mismatch for {tier}: expected {expected[tier]['mem_rss_bytes']} got {measured_mem}"
        )
    if measured_disk != expected[tier]["disk_bytes"]:
        raise RuntimeError(
            f"disk mismatch for {tier}: expected {expected[tier]['disk_bytes']} got {measured_disk}"
        )

print("OK")
PYEOF
    )"; then
        fail "seeded mem/disk drift check failed: $check_output"
        return 1
    fi

    if [ "$check_output" = "OK" ]; then
        pass "seeded mem/disk values exactly match capacity_profiles constants"
    else
        fail "unexpected drift check output: $check_output"
    fi
}

test_seeded_mem_disk_match_capacity_constants() {
    run_with_profile_backup test_seeded_mem_disk_match_capacity_constants_impl
}

# ============================================================================
# Run tests
# ============================================================================

echo "=== reliability harness tests ==="
echo ""
echo "--- harness produces non-empty JSON ---"
test_harness_produces_non_empty_json
echo ""
echo "--- harness produces deterministic structure ---"
test_harness_produces_deterministic_structure
echo ""
echo "--- seeded values match capacity constants ---"
test_seeded_mem_disk_match_capacity_constants
echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
