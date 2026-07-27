#!/usr/bin/env bash
# Hermetic known-answer tests for scripts/local_multinode_migration_probe.sh.
#
# These tests cover pure evidence classification and the Stage 2 live-owner
# wiring without starting Docker, Flapjack, Postgres, AWS, SSH, or live HTTP.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

PROBE="$REPO_ROOT/scripts/local_multinode_migration_probe.sh"
RUNBOOK="$REPO_ROOT/docs/runbooks/local_multinode_migration_probe.md"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/local_multinode_migration_probe"
TMP_PATHS=()
KNOWN_ANSWER_CASES=0
COVERED_REASONS=""
LEAK_GUARD_REGEX='(/tmp/|/private/|/Users/|postgres(ql)?://|sk_live|whsec_|eyJ|stage1_secret|authorization|x-algolia-api-key)'

cleanup() {
    if [ "${#TMP_PATHS[@]}" -gt 0 ]; then
        rm -rf "${TMP_PATHS[@]}"
    fi
}
trap cleanup EXIT

register_tmp_path() {
    TMP_PATHS+=("$1")
}

run_probe_fixture() {
    local fixture="$1" out_path="$2" err_path="$3" rc_path="$4"
    local effective_fixture="$fixture"
    if [ "${PRESERVE_FIXTURE_REPO_SHA:-0}" != "1" ]; then
        effective_fixture="$(mktemp)"
        register_tmp_path "$effective_fixture"
        FIXTURE_SOURCE="$fixture" FIXTURE_DESTINATION="$effective_fixture" \
            REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import os
import re
import subprocess
from pathlib import Path

source = Path(os.environ["FIXTURE_SOURCE"])
destination = Path(os.environ["FIXTURE_DESTINATION"])
raw = source.read_text(encoding="utf-8")
head = subprocess.check_output(
    ["git", "-C", os.environ["REPO_ROOT"], "rev-parse", "HEAD"],
    text=True,
).strip()
# Byte-preserving repo_sha rewrite: swap only the 40-hex value so the malformed
# structure under test (duplicate keys, key ordering, whitespace) survives
# verbatim. A full json.loads/json.dumps round-trip would canonicalize duplicate
# keys and mask the very defect the malformed fixtures exercise. Fixtures without a
# repo_sha (and non-JSON fixtures) pass through unchanged.
patched = re.sub(
    r'("repo_sha"\s*:\s*")[0-9a-fA-F]{40}(")',
    lambda match: match.group(1) + head + match.group(2),
    raw,
)
destination.write_text(patched, encoding="utf-8")
PY
    fi
    set +e
    bash "$PROBE" --assert-evidence "$effective_fixture" >"$out_path" 2>"$err_path"
    printf '%s\n' "$?" > "$rc_path"
    set -e
}

stdout_matches_single_status_line() {
    local out_path="$1" expected_line="$2" expected_path
    expected_path="$(mktemp)"
    register_tmp_path "$expected_path"
    printf '%s\n' "$expected_line" > "$expected_path"
    cmp -s "$expected_path" "$out_path"
}

assert_stdout_exact_status_line() {
    local out_path="$1" expected_line="$2" msg="$3"
    if stdout_matches_single_status_line "$out_path" "$expected_line"; then
        pass "$msg"
    else
        fail "$msg (stdout must be exactly one status line ending in one newline)"
    fi
}

assert_file_empty_bytes() {
    local abs_path="$1" msg="$2" byte_count
    byte_count="$(wc -c < "$abs_path" | tr -d ' ')"
    assert_eq "$byte_count" "0" "$msg"
}

assert_probe_file_result() {
    local fixture="$1" fixture_label="$2" expected_line="$3"
    local tmp out err rc expected_rc
    expected_rc=1
    if [[ "$expected_line" == *": PASS reason="* ]]; then
        expected_rc=0
    fi
    assert_file_exists "$fixture" "fixture $fixture_label exists"
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/out.txt"
    err="$tmp/err.txt"
    rc="$tmp/rc.txt"

    run_probe_fixture "$fixture" "$out" "$err" "$rc"
    KNOWN_ANSWER_CASES=$((KNOWN_ANSWER_CASES + 1))
    COVERED_REASONS+=" ${expected_line##*reason=}"

    assert_eq "$(cat "$rc")" "$expected_rc" "$fixture_label exits with expected status"
    assert_stdout_exact_status_line "$out" "$expected_line" \
        "$fixture_label emits the exact status token"
    assert_eq \
        "$(grep -Ec '^LOCAL_MULTINODE_MIGRATION_STATUS: (PASS|FAIL) reason=[a-z_]+$' "$out" || true)" \
        "1" \
        "$fixture_label emits exactly one complete status token"
    assert_file_not_matching_regex "$out" "$LEAK_GUARD_REGEX" \
        "$fixture_label stdout omits paths and secret-like material"
    assert_file_not_matching_regex "$err" "$LEAK_GUARD_REGEX" \
        "$fixture_label stderr omits paths and secret-like material"
}

assert_probe_result() {
    local fixture_name="$1" expected_line="$2"
    assert_probe_file_result "$FIXTURE_DIR/$fixture_name" "$fixture_name" "$expected_line"
}

test_pass_and_fail_branch_contract() {
    local stale_overwrite_fixture malformed_terminal_fixture
    assert_probe_result pass_valid_known_answer.json \
        "LOCAL_MULTINODE_MIGRATION_STATUS: PASS reason=verified"
    assert_probe_result pass_valid_with_ha_overwrite_refusal.json \
        "LOCAL_MULTINODE_MIGRATION_STATUS: PASS reason=verified"
    assert_probe_result fail_generic_503_ha.json \
        "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=generic_ha_refusal"
    assert_probe_result fail_wrong_mig7_tuple.json \
        "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=ha_contract_mismatch"
    assert_probe_result fail_ha_peer_count_zero.json \
        "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=ha_peer_count_invalid"
    assert_probe_result fail_stale_destination_survivor.json \
        "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=stale_destination_survivors"
    assert_probe_result fail_parity_mismatch.json \
        "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=parity_mismatch"
    assert_probe_result fail_cleanup_residue.json \
        "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=cleanup_residue"
    assert_probe_result malformed_missing_denominator.json \
        "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=malformed"
    assert_probe_result fail_duplicate_object_ids.json \
        "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=duplicate_object_ids"
    assert_probe_result fail_indeterminate_result.json \
        "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=indeterminate"
    assert_probe_result malformed_nested_indeterminate.json \
        "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=malformed"
    assert_probe_result malformed_duplicate_keys.json \
        "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=malformed"
    # A clean success omits `warnings` (Flapjack skips empty Vec on the wire);
    # an explicit empty array is an off-wire shape and must be rejected.
    assert_probe_result malformed_empty_warnings_present.json \
        "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=malformed"
    # Real Algolia GET /settings always returns default warning-owned fields, so a
    # genuine migration always warns; the benign settings-passthrough set is a PASS.
    assert_probe_result pass_valid_with_benign_settings_warnings.json \
        "LOCAL_MULTINODE_MIGRATION_STATUS: PASS reason=verified"
    # A non-benign warning code (e.g. a replica-topology warning on a replica-free
    # source) is a migration-fidelity failure and must fail closed.
    assert_probe_result fail_unexpected_migration_warning.json \
        "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=unexpected_migration_warning"

    stale_overwrite_fixture="$(mktemp)"
    register_tmp_path "$stale_overwrite_fixture"
    FIXTURE_SOURCE="$FIXTURE_DIR/pass_valid_with_ha_overwrite_refusal.json" \
        FIXTURE_DESTINATION="$stale_overwrite_fixture" \
        python3 - <<'PY'
import json
import os
from pathlib import Path

document = json.loads(Path(os.environ["FIXTURE_SOURCE"]).read_text(encoding="utf-8"))
document["ha_overwrite_refusal"] = {
    "peer_count": 1,
    "http_status": 400,
    "response": {
        "message": (
            "Algolia migration import is unavailable on HA clusters until MIG-7 "
            "supplies a costed convergence protocol."
        ),
        "status": 400,
        "code": "migration_overwrite_unsupported",
    },
}
Path(os.environ["FIXTURE_DESTINATION"]).write_text(
    json.dumps(document), encoding="utf-8"
)
PY
    assert_probe_file_result "$stale_overwrite_fixture" "stale HA overwrite tuple" \
        "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=ha_overwrite_contract_mismatch"

    malformed_terminal_fixture="$(mktemp)"
    register_tmp_path "$malformed_terminal_fixture"
    FIXTURE_SOURCE="$FIXTURE_DIR/pass_valid_known_answer.json" \
        FIXTURE_DESTINATION="$malformed_terminal_fixture" \
        python3 - <<'PY'
import json
import os
from pathlib import Path

document = json.loads(Path(os.environ["FIXTURE_SOURCE"]).read_text(encoding="utf-8"))
document["node_local_create"]["response"]["terminal_at"] = "not-a-timestamp"
Path(os.environ["FIXTURE_DESTINATION"]).write_text(
    json.dumps(document), encoding="utf-8"
)
PY
    assert_probe_file_result "$malformed_terminal_fixture" "malformed terminal timestamp" \
        "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=malformed"
}

# These sourced files contain cohesive live and cleanup/evidence cases while this
# file remains the single canonical test entrypoint and result reporter.
# shellcheck source=scripts/tests/lib/local_multinode_migration_live_test_cases.sh
source "$REPO_ROOT/scripts/tests/lib/local_multinode_migration_live_test_cases.sh"
# shellcheck source=scripts/tests/lib/local_multinode_migration_cleanup_test_cases.sh
source "$REPO_ROOT/scripts/tests/lib/local_multinode_migration_cleanup_test_cases.sh"

test_cli_failure_contract() {
    local tmp out err rc
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/out.txt"
    err="$tmp/err.txt"

    set +e
    bash "$PROBE" >"$out" 2>"$err"
    rc=$?
    set -e
    assert_eq "$rc" "2" "zero-argument mode is a Stage 1 usage failure"
    assert_file_empty_bytes "$out" "zero-argument usage failure emits no stdout bytes"
    assert_contains "$(cat "$err")" "usage:" "zero-argument usage failure emits usage"

    set +e
    bash "$PROBE" --bogus-flag >"$out" 2>"$err"
    rc=$?
    set -e
    assert_eq "$rc" "2" "unknown flag is a usage failure"
    assert_file_empty_bytes "$out" "unknown-flag usage failure emits no stdout bytes"

    set +e
    bash "$PROBE" --assert-evidence "$tmp/missing.json" >"$out" 2>"$err"
    rc=$?
    set -e
    assert_eq "$rc" "2" "unreadable evidence is a CLI failure"
    assert_file_empty_bytes "$out" "unreadable evidence emits no stdout bytes"
    assert_file_not_matching_regex "$err" "$LEAK_GUARD_REGEX" \
        "unreadable evidence diagnostic omits supplied host path"

    set +e
    bash "$PROBE" --assert-evidence "$FIXTURE_DIR/pass_valid_known_answer.json" extra >"$out" 2>"$err"
    rc=$?
    set -e
    assert_eq "$rc" "2" "extra argument is a usage failure"
    assert_file_empty_bytes "$out" "extra-argument usage failure emits no stdout bytes"

    set +e
    bash "$PROBE" --run-live >"$out" 2>"$err"
    rc=$?
    set -e
    assert_eq "$rc" "2" "missing --run-live evidence path is a usage failure"
    assert_file_empty_bytes "$out" "missing --run-live path emits no stdout bytes"
    assert_contains "$(cat "$err")" "usage:" "missing --run-live path emits usage"

    set +e
    bash "$PROBE" --run-live "$tmp/live.json" extra >"$out" 2>"$err"
    rc=$?
    set -e
    assert_eq "$rc" "2" "extra --run-live argument is a usage failure"
    assert_file_empty_bytes "$out" "extra --run-live argument emits no stdout bytes"

    for mode in --negative-ha-vs-standalone --negative-stale-survivor; do
        set +e
        bash "$PROBE" "$mode" >"$out" 2>"$err"
        rc=$?
        set -e
        assert_eq "$rc" "2" "missing $mode evidence path is a usage failure"
        assert_file_empty_bytes "$out" "missing $mode path emits no stdout bytes"
        assert_contains "$(cat "$err")" "usage:" "missing $mode path emits usage"
        assert_file_not_matching_regex "$err" "$LEAK_GUARD_REGEX" \
            "missing $mode usage omits paths and secret-like material"

        set +e
        bash "$PROBE" "$mode" "$tmp/${mode#--}.json" extra >"$out" 2>"$err"
        rc=$?
        set -e
        assert_eq "$rc" "2" "extra $mode argument is a usage failure"
        assert_file_empty_bytes "$out" "extra $mode argument emits no stdout bytes"
        assert_contains "$(cat "$err")" "usage:" "extra $mode argument emits usage"
        assert_file_not_matching_regex "$err" "$LEAK_GUARD_REGEX" \
            "extra $mode usage omits paths and secret-like material"
    done
}

test_classifier_has_no_live_side_effects() {
    local tmp stub_dir log out err rc command_name
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    stub_dir="$tmp/bin"
    mkdir -p "$stub_dir"
    log="$tmp/live_calls.log"
    : > "$log"

    for command_name in docker curl aws psql ssh; do
        write_mock_script "$stub_dir/$command_name" \
            "printf '%s\\n' '$command_name called' >> '$log'; exit 99"
    done

    out="$tmp/out.txt"
    err="$tmp/err.txt"
    rc="$tmp/rc.txt"
    SENTINEL_SECRET="stage1_secret_should_not_leak" \
        DATABASE_URL="postgresql://secret-user:secret-password@private-db/fjcloud" \
        PATH="$stub_dir:$PATH" \
        run_probe_fixture "$FIXTURE_DIR/pass_valid_known_answer.json" "$out" "$err" "$rc"

    assert_eq "$(cat "$rc")" "0" "classifier stays green with live-command stubs first on PATH"
    assert_eq "$(cat "$log")" "" "classifier invokes no live command"
    assert_file_not_matching_regex "$out" "$LEAK_GUARD_REGEX" \
        "side-effect guard stdout omits sentinel secrets and paths"
    assert_file_not_matching_regex "$err" "$LEAK_GUARD_REGEX" \
        "side-effect guard stderr omits sentinel secrets and paths"
}

test_named_branch_denominator_is_complete() {
    local required_reason
    for required_reason in \
        verified \
        generic_ha_refusal \
        ha_contract_mismatch \
        ha_overwrite_contract_mismatch \
        ha_peer_count_invalid \
        stale_destination_survivors \
        parity_mismatch \
        cleanup_residue \
        malformed \
        duplicate_object_ids \
        unexpected_migration_warning \
        indeterminate; do
        assert_contains " $COVERED_REASONS " " $required_reason " \
            "denominator proves the $required_reason branch ran"
    done
    assert_eq "$KNOWN_ANSWER_CASES" "22" "known-answer denominator covers every fixture"
}

# The leak guard is only trustworthy if it can actually fail: prove the regex
# fires on representative host paths and secret-like material before we rely on
# it to assert the classifier stays silent.
test_leak_guard_is_fail_capable() {
    local specimen
    for specimen in \
        "/Users/stuart/repos/fjcloud" \
        "/tmp/evidence.json" \
        "/private/var/secret" \
        "postgresql://user:pass@host/db" \
        "sk_live_deadbeef" \
        "whsec_deadbeef" \
        "x-algolia-api-key: abc" \
        "stage1_secret_should_not_leak"; do
        if printf '%s\n' "$specimen" | grep -Eq "$LEAK_GUARD_REGEX"; then
            pass "leak guard catches host/secret specimen: $specimen"
        else
            fail "leak guard failed to catch specimen: $specimen"
        fi
    done
    # A benign status line must NOT trip the guard, or the guard would be useless.
    if printf '%s\n' "LOCAL_MULTINODE_MIGRATION_STATUS: PASS reason=verified" \
        | grep -Eq "$LEAK_GUARD_REGEX"; then
        fail "leak guard false-positives on a clean status line"
    else
        pass "leak guard ignores a clean status line"
    fi
}

test_stage4_runbook_publication_contract() {
    assert_file_exists "$RUNBOOK" "Stage 4 runbook exists"
    local runbook_text
    runbook_text="$(cat "$RUNBOOK")"

    assert_contains "$runbook_text" \
        'export LOCAL_MULTINODE_ALLOW_UNAUTHENTICATED_HA_BIND=1' \
        "runbook requires explicit HA no-auth bind opt-in"
    assert_contains "$runbook_text" \
        'bash scripts/local_multinode_migration_probe.sh --run-live "$evidence_dir/positive.json"' \
        "runbook names the single unattended positive command"
    assert_contains "$runbook_text" \
        'bash scripts/local_multinode_migration_probe.sh --negative-ha-vs-standalone "$evidence_dir/negative_ha_vs_standalone.json"' \
        "runbook names the HA-vs-standalone expected-RED command"
    assert_contains "$runbook_text" \
        'bash scripts/local_multinode_migration_probe.sh --negative-stale-survivor "$evidence_dir/negative_stale_survivor.json"' \
        "runbook names the stale-survivor expected-RED command"
    assert_contains "$runbook_text" \
        "positive exits 0 and emits exactly LOCAL_MULTINODE_MIGRATION_STATUS: PASS reason=verified" \
        "runbook states exact positive status semantics"
    assert_contains "$runbook_text" \
        "negative HA proof exits 1 and emits exactly LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=ha_peer_count_invalid" \
        "runbook states exact HA negative status semantics"
    assert_contains "$runbook_text" \
        "negative stale-survivor proof exits 1 and emits exactly LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=stale_destination_survivors" \
        "runbook states exact stale-survivor status semantics"
    assert_contains "$runbook_text" \
        "scripts/lib/local_multinode_migration_evidence.py::classify_document" \
        "runbook routes evidence interpretation to the classifier owner"
    assert_contains "$runbook_text" '`repo_sha`' \
        "runbook names the emitted repo_sha evidence owner"
    assert_contains "$runbook_text" '`flapjack_identity`' \
        "runbook names the emitted flapjack_identity evidence owner"
    assert_not_contains "$runbook_text" '`identity`' \
        "runbook does not invent a wrapper identity evidence section"
    assert_contains "$runbook_text" "same exact MIG-7 refusal tuple" \
        "runbook keeps HA overwrite on the executable MIG-7 contract"
    assert_contains "$runbook_text" '`migration_ha_unsupported` 503' \
        "runbook names the accepted HA refusal status and code"
    assert_contains "$runbook_text" "trusted local/private network" \
        "runbook warns that HA live mode is limited to a trusted private network"
    assert_not_contains "$runbook_text" "unsupported-overwrite refusal contract" \
        "runbook does not publish a distinct unsupported-overwrite contract"
    assert_not_contains "$runbook_text" "migration_overwrite_unsupported" \
        "runbook excludes the rejected stale HA overwrite code"
    assert_contains "$runbook_text" "resume=false" \
        "runbook preserves fixed resume=false boundary"

    if grep -Eq 'Resume|/resume|resume=true' "$RUNBOOK"; then
        fail "runbook exposes no Resume action, route, or resume=true path"
    else
        pass "runbook exposes no Resume action, route, or resume=true path"
    fi
}

test_local_ci_registration_is_complete() {
    local local_ci="${LOCAL_MULTINODE_MIGRATION_LOCAL_CI:-$REPO_ROOT/scripts/local-ci.sh}"
    local gate_name="local-multinode-migration-contract"
    local gate_body

    assert_eq \
        "$(grep -Fxc '#                    local-multinode-migration-contract,' "$local_ci" || true)" \
        "1" \
        "local-ci usage help names the local-multinode-migration gate exactly once"
    assert_eq \
        "$(grep -Fxc 'gate_local_multinode_migration_contract() {' "$local_ci" || true)" \
        "1" \
        "local-ci defines the local-multinode-migration gate function exactly once"
    assert_eq \
        "$(grep -Fxc 'schedule local-multinode-migration-contract' "$local_ci" || true)" \
        "1" \
        "local-ci fast scheduler names the local-multinode-migration gate exactly once"
    assert_eq \
        "$(grep -Fxc '            local-multinode-migration-contract) run_gate local-multinode-migration-contract gate_local_multinode_migration_contract ;;' "$local_ci" || true)" \
        "1" \
        "local-ci dispatches the local-multinode-migration gate exactly once"
    assert_eq \
        "$(grep -F "    printf 'Known gates:" "$local_ci" | grep -Fc "$gate_name" || true)" \
        "1" \
        "local-ci summary-only inventory names the local-multinode-migration gate exactly once"
    assert_eq \
        "$(grep -F '        echo "Known gates:' "$local_ci" | grep -Fc "$gate_name" || true)" \
        "1" \
        "local-ci unknown-gate help names the local-multinode-migration gate exactly once"
    assert_eq "$(grep -Fo "$gate_name" "$local_ci" | wc -l | tr -d ' ')" "6" \
        "local-ci has exactly the six intended local-multinode-migration gate registrations"

    gate_body="$(sed -n '/^gate_local_multinode_migration_contract()/,/^}/p' "$local_ci")"
    assert_contains "$gate_body" 'scripts/tests/local_multinode_migration_probe_test.sh' \
        "local-multinode-migration gate runs the hermetic contract suite"
    assert_not_contains "$gate_body" '--run-live' \
        "local-multinode-migration gate does not invoke positive live mode"
    assert_not_contains "$gate_body" '--negative-ha-vs-standalone' \
        "local-multinode-migration gate does not invoke HA negative live mode"
    assert_not_contains "$gate_body" '--negative-stale-survivor' \
        "local-multinode-migration gate does not invoke stale-survivor live mode"
}

test_leak_guard_is_fail_capable
test_stage4_runbook_publication_contract
test_local_ci_registration_is_complete
test_pass_and_fail_branch_contract
test_indeterminate_validates_all_nested_owners
test_cli_failure_contract
test_classifier_has_no_live_side_effects
test_run_live_preflight_failures_are_side_effect_free
test_run_live_rejects_malformed_captured_json
test_run_live_fails_closed_on_unsupported_overwrite_owner
test_live_source_fixtures_have_exact_object_ids
test_live_plan_reuses_identity_and_secret_config_owners
test_live_helper_rejects_public_peer_host
test_standalone_starter_reuses_local_stack_launch_shape
test_algolia_seeding_tracks_every_remote_owner
test_secure_temp_files_are_tracked_in_parent_shell
test_standalone_specimens_use_async_owner_and_parity_oracle
test_negative_modes_reuse_live_runner_and_expected_red_finalizer
test_expected_red_finalizer_preserves_failing_evidence
test_standalone_specimens_browse_live_sources_before_parity
test_peer_connected_live_branch_contract
test_peer_connected_startup_executes_reachable_parallel_topology
test_peer_count_accepts_standalone_peers_array_contract
test_live_evidence_assembly_and_cleanup_contract
test_live_evidence_uses_observed_source_browse_files
test_cleanup_verifies_flapjack_absence_before_stopping_processes
test_cleanup_accepts_empty_owned_resource_arrays_under_nounset
test_cleanup_waits_for_algolia_key_absence_before_counting_residue
test_run_live_preserves_evidence_inputs_until_after_assembly
test_run_live_records_cleanup_after_evidence_inputs_are_released
test_capture_outcome_preserves_warnings_and_fails_closed
test_live_helper_cli_rejects_wrong_arity_without_partial_output
test_live_evidence_assembly_carries_captured_warnings
test_run_live_rejects_fixture_bypass_environment
test_assert_evidence_rejects_stale_repo_sha
test_duplicate_key_guard_is_load_bearing
test_probe_keeps_evidence_classifier_in_focused_module
test_named_branch_denominator_is_complete

run_test_summary
