#!/usr/bin/env bash
# Structural regression guard for shell suites invoked by local-ci gate bodies.
#
# RUST_LINT_PIN: aws_identity_test.sh
# RUST_LINT_PIN: ci_deploy_web_contract_test.sh
# RUST_LINT_PIN: ci_e2e_deployed_pages_parity_test.sh
# RUST_LINT_PIN: ci_lane24_deploy_contract_test.sh
# RUST_LINT_PIN: ci_stripe_local_mode_test.sh
# RUST_LINT_PIN: ci_workflow_test.sh
# RUST_LINT_PIN: customer_loop_synthetic_probe_env_gap_test.sh
# RUST_LINT_PIN: customer_metrics_endpoint_authenticated_probe_env_gap_test.sh
# RUST_LINT_PIN: customer_metrics_authenticated_probe_test.sh
# RUST_LINT_PIN: e2e_deployed_pages_parity_probe_test.sh
# RUST_LINT_PIN: e2e_preflight_test.sh
# RUST_LINT_PIN: generate_ssm_env_test.sh
# RUST_LINT_PIN: integration_test_layout_test.sh
# RUST_LINT_PIN: local_ci_env_local_isolation_test.sh
# RUST_LINT_PIN: local_ci_gate_set_e_test.sh
# RUST_LINT_PIN: local_ci_migration_isolated_db_test.sh
# RUST_LINT_PIN: local_ci_node_modules_guard_test.sh
# RUST_LINT_PIN: local_ci_parallel_safety_test.sh
# RUST_LINT_PIN: local_stack_contract_test.sh
# RUST_LINT_PIN: playwright_local_stack_test.sh
# RUST_LINT_PIN: probe_stage2_email_coverage_test.sh
# RUST_LINT_PIN: support_email_deliverability_test.sh
# RUST_LINT_PIN: test_inbox_helpers_test.sh
# RUST_LINT_PIN: validate_inbound_email_roundtrip_test.sh
# RUST_LINT_PIN: validate_vm_autorepair_detection_test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_CI="${FJCLOUD_LOCAL_CI_UNDER_TEST:-$REPO_ROOT/scripts/local-ci.sh}"
SELF_PATH="${BASH_SOURCE[0]}"
PINNED_EXPECTED_COUNT=25
FAIL_COUNT=0

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fjcloud-gate-suite-coverage.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
GATE_SUITE_MAP="$WORK_DIR/gate_suite_map.txt"
PARALLEL_SCHEDULE="$WORK_DIR/parallel_schedule.txt"
DEFAULT_SEQUENTIAL_FLAGS="$WORK_DIR/default_sequential_flags.txt"
SEQUENTIAL_SCHEDULE="$WORK_DIR/sequential_schedule.txt"
DEFAULT_SCHEDULE="$WORK_DIR/default_schedule.txt"
PARALLEL_DISPATCH_MAP="$WORK_DIR/parallel_dispatch_map.txt"
SEQUENTIAL_DISPATCH_MAP="$WORK_DIR/sequential_dispatch_map.txt"
DISPATCH_MAP="$WORK_DIR/dispatch_map.txt"
PINNED_SUITES="$WORK_DIR/pinned_suites.txt"
DEAD_DISPATCH_FIXTURE="$WORK_DIR/local-ci-dead-dispatch.sh"
DEAD_DISPATCH_OUTPUT="$WORK_DIR/dead-dispatch-output.txt"
UNREACHABLE_SUITE_FIXTURE="$WORK_DIR/local-ci-unreachable-suite.sh"
UNREACHABLE_SUITE_OUTPUT="$WORK_DIR/unreachable-suite-output.txt"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

extract_gate_suite_map() {
    awk '
        /^gate_[[:alnum:]_]+\(\)[[:space:]]*\{$/ {
            gate = $1
            sub(/\(\)$/, "", gate)
            in_gate = 1
            dead_depth = 0
            next
        }
        in_gate && /^}/ {
            gate = ""
            in_gate = 0
            dead_depth = 0
            next
        }
        in_gate {
            line = $0
            trimmed = line
            sub(/^[[:space:]]*/, "", trimmed)
            if (dead_depth > 0) {
                if (trimmed ~ /^if[[:space:]].*;[[:space:]]*then([[:space:]]*(#.*)?)?$/) {
                    dead_depth++
                }
                if (trimmed ~ /^fi([[:space:]]*(#.*)?)?$/) {
                    dead_depth--
                }
                next
            }
            if (trimmed ~ /^if[[:space:]]+false[[:space:]]*;[[:space:]]*then([[:space:]]*(#.*)?)?$/) {
                dead_depth = 1
                next
            }
            if (trimmed !~ /^bash[[:space:]]+"\$REPO_ROOT\/scripts\/tests\/[[:alnum:]_.-]+_test\.sh"/) {
                next
            }
            if (match(line, /scripts\/tests\/[[:alnum:]_.-]+_test\.sh/)) {
                path = substr(line, RSTART, RLENGTH)
                print gate "|" path
            }
        }
    ' "$LOCAL_CI" | LC_ALL=C sort -u > "$GATE_SUITE_MAP"
}

extract_default_schedule() {
    awk '
        /^schedule\(\)[[:space:]]*\{$/ {
            in_schedule_function = 1
            next
        }
        in_schedule_function && /^}/ {
            in_schedule_function = 0
            in_runtime_schedule = 1
            next
        }
        !in_runtime_schedule {
            next
        }
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
        }
        line ~ /^if[[:space:]].*;[[:space:]]*then$/ {
            conditional_depth++
            next
        }
        line ~ /^fi([[:space:]]*(#.*)?)?$/ {
            if (conditional_depth > 0) {
                conditional_depth--
            }
            next
        }
        conditional_depth == 0 && line ~ /^schedule[[:space:]]+[[:alnum:]-]+([[:space:]]*(#.*)?)?$/ {
            split(line, fields, /[[:space:]]+/)
            print fields[2]
        }
    ' "$LOCAL_CI" > "$PARALLEL_SCHEDULE"

    awk '
        /^[[:space:]]*if \[ -z "\$SINGLE_GATE" \] \|\|/ {
            default_block = 1
            next
        }
        default_block && /^[[:space:]]*RUN_[A-Z_]+_SEQUENTIAL=1$/ {
            flag = $0
            sub(/^[[:space:]]*/, "", flag)
            sub(/=1$/, "", flag)
            print flag
            default_block = 0
            next
        }
        default_block && /^[[:space:]]*fi$/ {
            default_block = 0
        }
    ' "$LOCAL_CI" > "$DEFAULT_SEQUENTIAL_FLAGS"

    awk '
        NR == FNR {
            default_flag[$1] = 1
            next
        }
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
        }
        line ~ /^if \[ "\$RUN_[A-Z_]+_SEQUENTIAL" -eq 1 \]; then$/ {
            condition = line
            if (match(condition, /RUN_[A-Z_]+_SEQUENTIAL/)) {
                flag = substr(condition, RSTART, RLENGTH)
                in_default_sequential = default_flag[flag]
                conditional_depth = 1
            }
            next
        }
        in_default_sequential && line ~ /^if[[:space:]]/ {
            conditional_depth++
            next
        }
        in_default_sequential && line ~ /^fi([[:space:]]*(#.*)?)?$/ {
            conditional_depth--
            if (conditional_depth == 0) {
                in_default_sequential = 0
            }
            next
        }
        in_default_sequential && conditional_depth == 1 && \
            line ~ /^run_gate[[:space:]]+[[:alnum:]-]+[[:space:]]+gate_[[:alnum:]_]+([[:space:]]*(#.*)?)?$/ {
            split(line, fields, /[[:space:]]+/)
            print fields[2] "|" fields[3]
        }
    ' "$DEFAULT_SEQUENTIAL_FLAGS" "$LOCAL_CI" > "$SEQUENTIAL_DISPATCH_MAP"

    cut -d'|' -f1 "$SEQUENTIAL_DISPATCH_MAP" > "$SEQUENTIAL_SCHEDULE"

    LC_ALL=C sort -u "$PARALLEL_SCHEDULE" "$SEQUENTIAL_SCHEDULE" > "$DEFAULT_SCHEDULE"
}

extract_dispatch_map() {
    awk '
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
        }
        line == "case \"$gate\" in" {
            in_gate_case = 1
            next
        }
        in_gate_case && line == "esac" {
            in_gate_case = 0
            next
        }
        in_gate_case && line ~ /^[[:alnum:]-]+\)[[:space:]]+run_gate[[:space:]]+[[:alnum:]-]+[[:space:]]+gate_[[:alnum:]_]+[[:space:]]*;;([[:space:]]*#.*)?$/ {
            owner = line
            sub(/\).*/, "", owner)
            dispatch = line
            sub(/^[^)]*\)[[:space:]]*/, "", dispatch)
            split(dispatch, fields, /[[:space:]]+/)
            if (owner == fields[2]) {
                print fields[2] "|" fields[3]
            }
        }
    ' "$LOCAL_CI" > "$PARALLEL_DISPATCH_MAP"

    LC_ALL=C sort -u "$PARALLEL_DISPATCH_MAP" "$SEQUENTIAL_DISPATCH_MAP" > "$DISPATCH_MAP"
}

check_derived_gate_wiring() {
    local mapping_count gate path basename owner_label
    mapping_count="$(wc -l < "$GATE_SUITE_MAP" | tr -d '[:space:]')"
    if [ "$mapping_count" -eq 0 ]; then
        fail "Half A: derived 0 suite-to-gate mappings from $LOCAL_CI"
        return
    fi

    while IFS='|' read -r gate path; do
        [ -n "$gate" ] || continue
        basename="${path##*/}"
        owner_label="${gate#gate_}"
        owner_label="$(printf '%s' "$owner_label" | tr '_' '-')"

        if ! grep -Fxq -- "$owner_label" "$DEFAULT_SCHEDULE"; then
            fail "Half A: $basename owner $gate is not in the default parallel or sequential schedule"
        fi
        if ! grep -Fxq -- "$owner_label|$gate" "$DISPATCH_MAP"; then
            fail "Half A: $basename owner $gate lacks matching dispatch: run_gate $owner_label $gate"
        fi
    done < "$GATE_SUITE_MAP"

    printf 'Half A: %s derived suite-to-gate mappings checked against default scheduling and dispatch\n' \
        "$mapping_count"
}

load_pinned_suites() {
    sed -n 's/^# RUST_LINT_PIN: //p' "$SELF_PATH" | LC_ALL=C sort > "$PINNED_SUITES"
}

check_pinned_snapshot() {
    local pin_count distinct_count hits=0 basename
    pin_count="$(wc -l < "$PINNED_SUITES" | tr -d '[:space:]')"
    distinct_count="$(LC_ALL=C sort -u "$PINNED_SUITES" | wc -l | tr -d '[:space:]')"

    if [ "$pin_count" -ne "$PINNED_EXPECTED_COUNT" ]; then
        fail "Half B: pin declares $pin_count/$PINNED_EXPECTED_COUNT basenames"
    fi
    if [ "$distinct_count" -ne "$PINNED_EXPECTED_COUNT" ]; then
        fail "Half B: pin contains $distinct_count/$PINNED_EXPECTED_COUNT distinct basenames"
    fi

    while IFS= read -r basename; do
        [ -n "$basename" ] || continue
        if awk -F'|' -v wanted="scripts/tests/$basename" '$2 == wanted { found=1 } END { exit !found }' \
            "$GATE_SUITE_MAP"; then
            hits=$((hits + 1))
        else
            fail "Half B: missing pinned basename: $basename"
        fi
    done < "$PINNED_SUITES"

    printf 'Half B: %s/%s pinned rust-lint suite basenames present in derived global map\n' \
        "$hits" "$PINNED_EXPECTED_COUNT"
}

check_dead_dispatch_regression() {
    local fixture_rc guard_rc

    if [ "${FJCLOUD_SKIP_DEAD_DISPATCH_SPECIMEN:-0}" -eq 1 ]; then
        return
    fi

    awk '
        {
            line = $0
            trimmed = line
            sub(/^[[:space:]]*/, "", trimmed)
        }
        trimmed == "run_gate local-ci-contracts gate_local_ci_contracts" {
            indent = substr(line, 1, length(line) - length(trimmed))
            print indent "if false; then"
            print indent "    " trimmed
            print indent "fi"
            replacements++
            next
        }
        { print }
        END {
            if (replacements != 1) {
                exit 42
            }
        }
    ' "$LOCAL_CI" > "$DEAD_DISPATCH_FIXTURE"
    fixture_rc=$?
    if [ "$fixture_rc" -ne 0 ]; then
        fail "dead-dispatch specimen setup replaced an unexpected number of local-ci-contracts dispatches"
        return
    fi

    FJCLOUD_LOCAL_CI_UNDER_TEST="$DEAD_DISPATCH_FIXTURE" \
        FJCLOUD_SKIP_DEAD_DISPATCH_SPECIMEN=1 \
        FJCLOUD_SKIP_UNREACHABLE_SUITE_SPECIMEN=1 \
        bash "$SELF_PATH" > "$DEAD_DISPATCH_OUTPUT" 2>&1
    guard_rc=$?

    if [ "$guard_rc" -eq 0 ]; then
        fail "dead-dispatch specimen: unreachable local-ci-contracts dispatch under if false passed Half A"
        return
    fi
    if ! grep -Eq 'Half A: .*owner gate_local_ci_contracts lacks matching dispatch' "$DEAD_DISPATCH_OUTPUT"; then
        fail "dead-dispatch specimen: Half A did not name gate_local_ci_contracts as lacking dispatch"
        return
    fi
    if ! grep -Fq 'Half B: 25/25 pinned rust-lint suite basenames present' "$DEAD_DISPATCH_OUTPUT"; then
        fail "dead-dispatch specimen: mutation unexpectedly changed Half B coverage"
        return
    fi

    echo "Regression: unreachable local-ci-contracts dispatch under if false is rejected"
}

check_unreachable_suite_regression() {
    local fixture_rc guard_rc

    if [ "${FJCLOUD_SKIP_UNREACHABLE_SUITE_SPECIMEN:-0}" -eq 1 ]; then
        return
    fi

    awk '
        {
            line = $0
            trimmed = line
            sub(/^[[:space:]]*/, "", trimmed)
        }
        trimmed == "bash \"\$REPO_ROOT/scripts/tests/aws_identity_test.sh\" || return $?" {
            indent = substr(line, 1, length(line) - length(trimmed))
            print indent "if false; then"
            print indent "    " trimmed
            print indent "fi"
            replacements++
            next
        }
        { print }
        END {
            if (replacements != 1) {
                exit 42
            }
        }
    ' "$LOCAL_CI" > "$UNREACHABLE_SUITE_FIXTURE"
    fixture_rc=$?
    if [ "$fixture_rc" -ne 0 ]; then
        fail "unreachable-suite specimen setup replaced an unexpected number of aws_identity invocations"
        return
    fi

    FJCLOUD_LOCAL_CI_UNDER_TEST="$UNREACHABLE_SUITE_FIXTURE" \
        FJCLOUD_SKIP_DEAD_DISPATCH_SPECIMEN=1 \
        FJCLOUD_SKIP_UNREACHABLE_SUITE_SPECIMEN=1 \
        bash "$SELF_PATH" > "$UNREACHABLE_SUITE_OUTPUT" 2>&1
    guard_rc=$?

    if [ "$guard_rc" -eq 0 ]; then
        fail "unreachable-suite specimen: aws_identity_test.sh under if false passed Half B"
        return
    fi
    if ! grep -Fq 'Half B: missing pinned basename: aws_identity_test.sh' "$UNREACHABLE_SUITE_OUTPUT"; then
        fail "unreachable-suite specimen: Half B did not name missing aws_identity_test.sh"
        return
    fi
    if ! grep -Fq 'Half B: 24/25 pinned rust-lint suite basenames present' "$UNREACHABLE_SUITE_OUTPUT"; then
        fail "unreachable-suite specimen: Half B did not report 24/25 pinned coverage"
        return
    fi

    echo "Regression: unreachable aws_identity_test.sh invocation under if false is rejected"
}

if [ ! -f "$LOCAL_CI" ]; then
    fail "local-ci source not found: $LOCAL_CI"
else
    extract_gate_suite_map
    extract_default_schedule
    extract_dispatch_map
    load_pinned_suites
    check_derived_gate_wiring
    check_pinned_snapshot
    check_dead_dispatch_regression
    check_unreachable_suite_regression
fi

if [ "$FAIL_COUNT" -ne 0 ]; then
    printf 'local-ci gate suite coverage: %s defect(s)\n' "$FAIL_COUNT" >&2
    exit 1
fi

echo "OK: local-ci gate suite coverage is complete"
