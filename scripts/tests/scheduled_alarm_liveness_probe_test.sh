#!/usr/bin/env bash
# Hermetic known-answer contract for scheduled-alarm liveness and health.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE="$REPO_ROOT/scripts/probe_scheduled_alarm_liveness.sh"
# shellcheck source=scripts/lib/scheduled_workflows.sh
source "$REPO_ROOT/scripts/lib/scheduled_workflows.sh"
NOW_EPOCH=1786010400
PASS_COUNT=0
FAIL_COUNT=0
OUTPUT=""
RC=0
TMP_PATHS=()

cleanup() {
    [ "${#TMP_PATHS[@]}" -eq 0 ] || rm -rf "${TMP_PATHS[@]}"
}
trap cleanup EXIT

pass() { printf 'PASS: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

assert_eq() {
    if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$2', got '$1')"; fi
}

assert_contains() {
    if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (missing '$2')"; fi
}

assert_not_contains() {
    if [[ "$1" == *"$2"* ]]; then fail "$3 (unexpected '$2')"; else pass "$3"; fi
}

run_command() {
    set +e
    OUTPUT="$("$@" 2>&1)"
    RC=$?
    set -e
}

new_fixture_repo() {
    local result_var="$1" created_root
    created_root="$(mktemp -d)"
    TMP_PATHS+=("$created_root")
    mkdir -p "$created_root/.github/workflows" "$created_root/scripts/tests" "$created_root/chats/icg" "$created_root/fixtures"
    cp "$REPO_ROOT/scripts/tests/scheduled_alarm_workflows.txt" "$created_root/scripts/tests/"
    cp "$REPO_ROOT/scripts/tests/scheduled_alarm_acknowledgements.txt" "$created_root/scripts/tests/"
    cp "$REPO_ROOT/chats/icg/aug05_12pm_2_pricing_registry_verification.md" "$created_root/chats/icg/"
    cp "$REPO_ROOT/.github/workflows/deploy_currency.yml" "$created_root/.github/workflows/"
    cp "$REPO_ROOT/.github/workflows/nightly.yml" "$created_root/.github/workflows/"
    cp "$REPO_ROOT/.github/workflows/outside_aws_health.yml" "$created_root/.github/workflows/"
    write_baseline_fixtures "$created_root/fixtures"
    printf -v "$result_var" '%s' "$created_root"
}

write_run() {
    local fixture_dir="$1" mirror="$2" workflow="$3" run_id="$4" run_state="$5" created_at="$6" status conclusion
    read -r status conclusion <<< "$run_state"
    printf '{"total_count":1,"workflow_runs":[{"id":%s,"status":"%s","conclusion":"%s","created_at":"%s"}]}\n' \
        "$run_id" "$status" "$conclusion" "$created_at" > "$fixture_dir/${mirror}_${workflow}.runs.json"
}

write_run_null_conclusion() {
    local fixture_dir="$1" mirror="$2" workflow="$3" run_id="$4" status="$5" created_at="$6"
    printf '{"total_count":1,"workflow_runs":[{"id":%s,"status":"%s","conclusion":null,"created_at":"%s"}]}\n' \
        "$run_id" "$status" "$created_at" > "$fixture_dir/${mirror}_${workflow}.runs.json"
}

write_jobs() {
    local fixture_dir="$1" mirror="$2" workflow="$3" job_name="$4" conclusion="$5"
    printf '{"total_count":1,"jobs":[{"name":"%s","conclusion":"%s"}]}\n' \
        "$job_name" "$conclusion" > "$fixture_dir/${mirror}_${workflow}.jobs.json"
}

write_baseline_fixtures() {
    local fixture_dir="$1" mirror
    write_run "$fixture_dir" staging deploy_currency.yml 101 "completed success" 2026-08-06T09:59:00Z
    write_run "$fixture_dir" prod deploy_currency.yml 102 "completed skipped" 2026-08-06T09:59:00Z
    for mirror in staging prod; do
        write_run "$fixture_dir" "$mirror" nightly.yml 103 "completed failure" 2026-08-06T09:59:00Z
        write_jobs "$fixture_dir" "$mirror" nightly.yml pricing-freshness failure
        write_run "$fixture_dir" "$mirror" outside_aws_health.yml 104 "completed success" 2026-08-06T09:59:00Z
    done
}

run_fixture_probe() {
    local fixture_root="$1"
    run_command env FJCLOUD_REPO_ROOT="$fixture_root" bash "$PROBE" \
        --fixture-dir "$fixture_root/fixtures" --now-epoch "$NOW_EPOCH"
}

assert_baseline() {
    local fixture_root
    new_fixture_repo fixture_root
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 0 "healthy and acknowledged six-pair fixture passes"
    assert_contains "$OUTPUT" "mirror=prod workflow=deploy_currency.yml run_id=102 status=completed conclusion=skipped age_seconds=60 failing_job=none reason=skip_expected" "prod deploy skip is expected"
    assert_contains "$OUTPUT" "mirror=staging workflow=nightly.yml run_id=103 status=completed conclusion=failure age_seconds=60 failing_job=pricing-freshness reason=red_acknowledged" "acknowledged red prints exact failing job"
    assert_contains "$OUTPUT" "summary checked=6 passed=6 failed=0" "all six declared pairs are enumerated"
}

assert_no_runs_fails() {
    local fixture_root
    new_fixture_repo fixture_root
    printf '{"total_count":0,"workflow_runs":[]}\n' > "$fixture_root/fixtures/staging_deploy_currency.yml.runs.json"
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "missing schedule run fails"
    assert_contains "$OUTPUT" "mirror=staging workflow=deploy_currency.yml run_id=none status=none conclusion=none age_seconds=unknown failing_job=none reason=schedule_run_missing" "missing run verdict is exact"
}

assert_stale_fails() {
    local fixture_root
    new_fixture_repo fixture_root
    write_run "$fixture_root/fixtures" staging outside_aws_health.yml 201 "completed success" 2026-08-06T05:59:59Z
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "stale newest schedule run fails"
    assert_contains "$OUTPUT" "mirror=staging workflow=outside_aws_health.yml run_id=201 status=completed conclusion=success age_seconds=14401 failing_job=none reason=stale" "stale verdict includes hand-calculated age"
}

assert_stale_conclusion_is_red() {
    local fixture_root
    new_fixture_repo fixture_root
    write_run "$fixture_root/fixtures" staging outside_aws_health.yml 202 "completed stale" 2026-08-06T09:59:00Z
    write_jobs "$fixture_root/fixtures" staging outside_aws_health.yml outside-aws-health failure
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "stale workflow-run conclusion is a terminal red run"
    assert_contains "$OUTPUT" "mirror=staging workflow=outside_aws_health.yml run_id=202 status=completed conclusion=stale age_seconds=60 failing_job=outside-aws-health reason=red_unacknowledged" "stale workflow-run conclusion preserves run and job evidence"
    assert_not_contains "$OUTPUT" "mirror=staging workflow=outside_aws_health.yml run_id=none status=none conclusion=none age_seconds=unknown failing_job=none reason=api_failure" "stale workflow-run conclusion is not an API failure"
}

assert_not_completed_fails() {
    local fixture_root
    new_fixture_repo fixture_root
    write_run_null_conclusion "$fixture_root/fixtures" staging outside_aws_health.yml 203 in_progress 2026-08-06T09:59:00Z
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "newest schedule run must be completed"
    assert_contains "$OUTPUT" "run_id=203 status=in_progress conclusion=none age_seconds=60 failing_job=none reason=not_completed" "incomplete verdict is exact"
}

assert_skip_rules() {
    local fixture_root
    new_fixture_repo fixture_root
    write_run "$fixture_root/fixtures" staging deploy_currency.yml 202 "completed skipped" 2026-08-06T09:59:00Z
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "unexpected skipped run fails"
    assert_contains "$OUTPUT" "mirror=staging workflow=deploy_currency.yml run_id=202 status=completed conclusion=skipped age_seconds=60 failing_job=none reason=unexpected_skip" "unexpected skip reason is exact"
}

assert_unacknowledged_red_fails() {
    local fixture_root
    new_fixture_repo fixture_root
    : > "$fixture_root/scripts/tests/scheduled_alarm_acknowledgements.txt"
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "red newest run without acknowledgement fails"
    assert_contains "$OUTPUT" "failing_job=pricing-freshness reason=red_unacknowledged" "unacknowledged red names failing job"
}

assert_acknowledgement_key_is_exact() {
    local fixture_root
    new_fixture_repo fixture_root
    write_jobs "$fixture_root/fixtures" staging nightly.yml stripe-test-clock-live failure
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "different failing job cannot inherit workflow acknowledgement"
    assert_contains "$OUTPUT" "mirror=staging workflow=nightly.yml run_id=103 status=completed conclusion=failure age_seconds=60 failing_job=stripe-test-clock-live reason=red_unacknowledged" "acknowledgement key includes exact failing job"
}

assert_deploy_red_cannot_be_acknowledged() {
    local fixture_root
    new_fixture_repo fixture_root
    write_run "$fixture_root/fixtures" staging deploy_currency.yml 301 "completed failure" 2026-08-06T09:59:00Z
    write_jobs "$fixture_root/fixtures" staging deploy_currency.yml deploy-currency failure
    printf 'staging deploy_currency.yml deploy-currency # chats/icg/aug05_12pm_2_pricing_registry_verification.md\n' >> "$fixture_root/scripts/tests/scheduled_alarm_acknowledgements.txt"
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "deploy-currency red cannot be acknowledged"
    assert_contains "$OUTPUT" "failing_job=deploy-currency reason=red_unacknowledged" "self-clearing deploy red remains actionable"
}

assert_indeterminate_fails() {
    local fixture_root
    new_fixture_repo fixture_root
    printf '{not-json\n' > "$fixture_root/fixtures/staging_outside_aws_health.yml.runs.json"
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "indeterminate fixture API data fails closed"
    assert_contains "$OUTPUT" "mirror=staging workflow=outside_aws_health.yml run_id=none status=none conclusion=none age_seconds=unknown failing_job=none reason=api_failure" "indeterminate verdict is exact"
}

assert_malformed_run_entry_fails_per_pair() {
    local fixture_root
    new_fixture_repo fixture_root
    printf '{"total_count":1,"workflow_runs":[{"id":401,"status":"completed","conclusion":"success","created_at":1786010340}]}\n' > "$fixture_root/fixtures/staging_outside_aws_health.yml.runs.json"
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "malformed run entry fails only its pair"
    assert_contains "$OUTPUT" "mirror=staging workflow=outside_aws_health.yml run_id=none status=none conclusion=none age_seconds=unknown failing_job=none reason=api_failure" "malformed run entry is api failure"
    assert_contains "$OUTPUT" "mirror=prod workflow=outside_aws_health.yml run_id=104 status=completed conclusion=success age_seconds=60 failing_job=none reason=green" "enumeration continues after malformed run entry"
    assert_contains "$OUTPUT" "summary checked=6 passed=5 failed=1" "malformed run entry preserves full summary"
}

assert_malformed_job_entry_fails_per_pair() {
    local fixture_root
    new_fixture_repo fixture_root
    printf '{"total_count":1,"jobs":[{"name":17,"conclusion":"failure"}]}\n' > "$fixture_root/fixtures/staging_nightly.yml.jobs.json"
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "malformed job entry fails only its pair"
    assert_contains "$OUTPUT" "mirror=staging workflow=nightly.yml run_id=103 status=completed conclusion=failure age_seconds=60 failing_job=unknown reason=api_failure" "malformed job entry is api failure"
    assert_contains "$OUTPUT" "mirror=prod workflow=nightly.yml run_id=103 status=completed conclusion=failure age_seconds=60 failing_job=pricing-freshness reason=red_acknowledged" "enumeration continues after malformed job entry"
    assert_contains "$OUTPUT" "summary checked=6 passed=5 failed=1" "malformed job entry preserves full summary"
}

assert_truncated_jobs_fail_closed() {
    local fixture_root jobs_file job_number
    new_fixture_repo fixture_root
    jobs_file="$fixture_root/fixtures/staging_nightly.yml.jobs.json"
    printf '{"total_count":101,"jobs":[{"name":"pricing-freshness","conclusion":"failure"}' > "$jobs_file"
    for job_number in $(seq 2 100); do
        printf ',{"name":"job-%03d","conclusion":"success"}' "$job_number" >> "$jobs_file"
    done
    printf ']}\n' >> "$jobs_file"
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "truncated jobs response fails closed"
    assert_contains "$OUTPUT" "mirror=staging workflow=nightly.yml run_id=103 status=completed conclusion=failure age_seconds=60 failing_job=unknown reason=api_failure" "truncated job response is api failure"
    assert_contains "$OUTPUT" "mirror=prod workflow=nightly.yml run_id=103 status=completed conclusion=failure age_seconds=60 failing_job=pricing-freshness reason=red_acknowledged" "enumeration continues after truncated jobs"
    assert_contains "$OUTPUT" "summary checked=6 passed=5 failed=1" "truncated jobs preserve full summary"
}

assert_null_job_conclusion_fails_closed() {
    local fixture_root
    new_fixture_repo fixture_root
    printf '{"total_count":2,"jobs":[{"name":"pricing-freshness","conclusion":"failure"},{"name":"deploy-smoke","conclusion":null}]}\n' > "$fixture_root/fixtures/staging_nightly.yml.jobs.json"
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "null job conclusion fails closed"
    assert_contains "$OUTPUT" "mirror=staging workflow=nightly.yml run_id=103 status=completed conclusion=failure age_seconds=60 failing_job=unknown reason=api_failure" "null job conclusion is api failure"
    assert_contains "$OUTPUT" "summary checked=6 passed=5 failed=1" "null job conclusion preserves full summary"
}

assert_nonterminal_job_conclusion_fails_closed() {
    local fixture_root
    new_fixture_repo fixture_root
    printf '{"total_count":2,"jobs":[{"name":"pricing-freshness","conclusion":"failure"},{"name":"deploy-smoke","conclusion":"in_progress"}]}\n' > "$fixture_root/fixtures/staging_nightly.yml.jobs.json"
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "nonterminal job conclusion fails closed"
    assert_contains "$OUTPUT" "mirror=staging workflow=nightly.yml run_id=103 status=completed conclusion=failure age_seconds=60 failing_job=unknown reason=api_failure" "nonterminal job conclusion is api failure"
    assert_not_contains "$OUTPUT" "mirror=staging workflow=nightly.yml run_id=103 status=completed conclusion=failure age_seconds=60 failing_job=pricing-freshness reason=red_acknowledged" "acknowledged failure cannot mask indeterminate job"
    assert_contains "$OUTPUT" "summary checked=6 passed=5 failed=1" "nonterminal job conclusion preserves full summary"
}

assert_run_only_conclusion_is_invalid_for_job() {
    local fixture_root
    new_fixture_repo fixture_root
    write_jobs "$fixture_root/fixtures" staging nightly.yml pricing-freshness startup_failure
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "run-only startup_failure conclusion is invalid for a job"
    assert_contains "$OUTPUT" "mirror=staging workflow=nightly.yml run_id=103 status=completed conclusion=failure age_seconds=60 failing_job=unknown reason=api_failure" "run-only job conclusion fails closed as API failure"
    assert_not_contains "$OUTPUT" "mirror=staging workflow=nightly.yml run_id=103 status=completed conclusion=failure age_seconds=60 failing_job=pricing-freshness reason=red_acknowledged" "run-only job conclusion cannot reach acknowledgement"
}

assert_completed_null_run_conclusion_fails_closed() {
    local fixture_root
    new_fixture_repo fixture_root
    write_run_null_conclusion "$fixture_root/fixtures" staging nightly.yml 601 completed 2026-08-06T09:59:00Z
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "completed run with null conclusion fails closed"
    assert_contains "$OUTPUT" "mirror=staging workflow=nightly.yml run_id=none status=none conclusion=none age_seconds=unknown failing_job=none reason=api_failure" "completed null run conclusion is api failure"
    assert_not_contains "$OUTPUT" "mirror=staging workflow=nightly.yml run_id=601 status=completed conclusion=none age_seconds=60 failing_job=pricing-freshness reason=red_acknowledged" "completed null run cannot be acknowledged"
    assert_contains "$OUTPUT" "summary checked=6 passed=5 failed=1" "completed null run preserves full summary"
}

assert_completed_nonterminal_run_conclusion_fails_closed() {
    local fixture_root
    new_fixture_repo fixture_root
    write_run "$fixture_root/fixtures" staging nightly.yml 602 "completed in_progress" 2026-08-06T09:59:00Z
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "completed run with nonterminal conclusion fails closed"
    assert_contains "$OUTPUT" "mirror=staging workflow=nightly.yml run_id=none status=none conclusion=none age_seconds=unknown failing_job=none reason=api_failure" "completed nonterminal run conclusion is api failure"
    assert_not_contains "$OUTPUT" "mirror=staging workflow=nightly.yml run_id=602 status=completed conclusion=in_progress age_seconds=60 failing_job=pricing-freshness reason=red_acknowledged" "completed nonterminal run cannot be acknowledged"
    assert_contains "$OUTPUT" "summary checked=6 passed=5 failed=1" "completed nonterminal run preserves full summary"
}

assert_invalid_run_states_are_api_failures() {
    local fixture_root
    new_fixture_repo fixture_root
    write_run "$fixture_root/fixtures" staging outside_aws_health.yml 603 "mystery success" 2026-08-06T09:59:00Z
    run_fixture_probe "$fixture_root"
    assert_contains "$OUTPUT" "mirror=staging workflow=outside_aws_health.yml run_id=none status=none conclusion=none age_seconds=unknown failing_job=none reason=api_failure" "unknown run status is api failure"
    write_run "$fixture_root/fixtures" staging outside_aws_health.yml 604 "in_progress success" 2026-08-06T09:59:00Z
    run_fixture_probe "$fixture_root"
    assert_contains "$OUTPUT" "mirror=staging workflow=outside_aws_health.yml run_id=none status=none conclusion=none age_seconds=unknown failing_job=none reason=api_failure" "noncompleted run with terminal conclusion is api failure"
}
assert_spaced_job_name_can_be_acknowledged() {
    local fixture_root
    new_fixture_repo fixture_root
    write_jobs "$fixture_root/fixtures" staging nightly.yml "pricing freshness" failure
    printf 'staging nightly.yml pricing freshness # chats/icg/aug05_12pm_2_pricing_registry_verification.md\n' >> "$fixture_root/scripts/tests/scheduled_alarm_acknowledgements.txt"
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 0 "exact job names containing spaces can be acknowledged"
    assert_contains "$OUTPUT" "failing_job=pricing freshness reason=red_acknowledged" "spaced failing job remains visible"
}

assert_future_timestamp_fails_closed() {
    local fixture_root
    new_fixture_repo fixture_root
    write_run "$fixture_root/fixtures" staging outside_aws_health.yml 402 "completed success" 2026-08-06T10:00:01Z
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "future schedule timestamp fails closed"
    assert_contains "$OUTPUT" "mirror=staging workflow=outside_aws_health.yml run_id=402 status=completed conclusion=success age_seconds=unknown failing_job=none reason=timestamp_in_future" "future timestamp is not counted fresh"
}

assert_auth_failure_fails_closed() {
    run_command env GH_TOKEN= FJCLOUD_REPO_ROOT="$REPO_ROOT" bash "$PROBE"
    assert_eq "$RC" 1 "explicit empty GitHub token fails closed"
    assert_contains "$OUTPUT" "mirror=staging workflow=deploy_currency.yml run_id=none status=none conclusion=none age_seconds=unknown failing_job=none reason=auth_missing" "auth failure enumerates declared pair"
    assert_contains "$OUTPUT" "summary checked=6 passed=0 failed=6" "auth failure preserves six-pair denominator"
}

write_workflow_quoted_on() {
    local path="$1"
    {
        printf 'name: Quoted Canary\n\n'
        printf '"on":\n'
        printf '  schedule:\n'
        printf '    - cron: "0 6 * * *"\n'
        printf '  workflow_dispatch:\n\n'
        printf 'jobs:\n  noop:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n'
    } > "$path"
}

assert_quoted_on_key_stays_in_denominator() {
    local fixture_root
    new_fixture_repo fixture_root
    write_workflow_quoted_on "$fixture_root/.github/workflows/quoted_canary.yml"
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "quoted \"on\": scheduled workflow cannot escape the denominator"
    assert_contains "$OUTPUT" "summary checked=6 passed=6 failed=1 reason=registry_mismatch" "quoted-on denominator drift is explicit"

    printf 'staging quoted_canary.yml run 14400\nprod quoted_canary.yml run 14400\n' >> "$fixture_root/scripts/tests/scheduled_alarm_workflows.txt"
    write_run "$fixture_root/fixtures" staging quoted_canary.yml 701 "completed success" 2026-08-06T09:59:00Z
    write_run "$fixture_root/fixtures" prod quoted_canary.yml 702 "completed success" 2026-08-06T09:59:00Z
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 0 "registered quoted-on workflow is probed"
    assert_contains "$OUTPUT" "mirror=staging workflow=quoted_canary.yml run_id=701 status=completed conclusion=success age_seconds=60 failing_job=none reason=green" "quoted-on pair is enumerated"
    assert_contains "$OUTPUT" "summary checked=8 passed=8 failed=0" "registered quoted-on pairs expand denominator"
}

write_workflow_nested_schedule_input() {
    local path="$1"
    {
        printf 'name: Nested Schedule Input\n\n'
        printf 'on:\n'
        printf '  workflow_call:\n'
        printf '    inputs:\n'
        printf '      schedule:\n'
        printf '        required: false\n'
        printf '        type: string\n\n'
        printf 'jobs:\n  noop:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n'
    } > "$path"
}

write_workflow_quoted_schedule() {
    local path="$1"
    {
        printf 'name: Quoted Schedule Canary\n\n'
        printf 'on:\n'
        printf '  "schedule":\n'
        printf '    - cron: "0 6 * * *"\n'
        printf '  workflow_dispatch:\n\n'
        printf 'jobs:\n  noop:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n'
    } > "$path"
}

assert_nested_schedule_key_is_excluded() {
    local fixture_root
    new_fixture_repo fixture_root
    write_workflow_nested_schedule_input "$fixture_root/.github/workflows/reusable_input.yml"
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 0 "nested workflow_call input named schedule is not a scheduled workflow"
    assert_contains "$OUTPUT" "summary checked=6 passed=6 failed=0" "nested schedule key does not expand denominator"
}

assert_quoted_schedule_key_stays_in_denominator() {
    local fixture_root
    new_fixture_repo fixture_root
    write_workflow_quoted_schedule "$fixture_root/.github/workflows/quoted_schedule.yml"
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "quoted direct schedule key cannot escape the denominator"
    assert_contains "$OUTPUT" "summary checked=6 passed=6 failed=1 reason=registry_mismatch" "quoted schedule denominator drift is explicit"

    printf 'staging quoted_schedule.yml run 14400\nprod quoted_schedule.yml run 14400\n' >> "$fixture_root/scripts/tests/scheduled_alarm_workflows.txt"
    write_run "$fixture_root/fixtures" staging quoted_schedule.yml 711 "completed success" 2026-08-06T09:59:00Z
    write_run "$fixture_root/fixtures" prod quoted_schedule.yml 712 "completed success" 2026-08-06T09:59:00Z
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 0 "registered quoted schedule workflow is probed"
    assert_contains "$OUTPUT" "mirror=staging workflow=quoted_schedule.yml run_id=711 status=completed conclusion=success age_seconds=60 failing_job=none reason=green" "quoted schedule pair is enumerated"
    assert_contains "$OUTPUT" "summary checked=8 passed=8 failed=0" "registered quoted schedule pairs expand denominator"
}

assert_zero_count_nonempty_run_fails_per_pair() {
    local fixture_root
    new_fixture_repo fixture_root
    printf '{"total_count":0,"workflow_runs":[{"id":801,"status":"completed","conclusion":"success","created_at":"2026-08-06T09:59:00Z"}]}\n' \
        > "$fixture_root/fixtures/staging_outside_aws_health.yml.runs.json"
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "zero total_count paired with a returned run fails closed"
    assert_contains "$OUTPUT" "mirror=staging workflow=outside_aws_health.yml run_id=none status=none conclusion=none age_seconds=unknown failing_job=none reason=api_failure" "inconsistent run metadata is api failure"
    assert_contains "$OUTPUT" "mirror=prod workflow=outside_aws_health.yml run_id=104 status=completed conclusion=success age_seconds=60 failing_job=none reason=green" "enumeration continues after inconsistent run metadata"
    assert_contains "$OUTPUT" "summary checked=6 passed=5 failed=1" "inconsistent run metadata preserves full summary"
}

assert_stale_red_shows_failing_job() {
    local fixture_root
    new_fixture_repo fixture_root
    write_run "$fixture_root/fixtures" staging nightly.yml 901 "completed failure" 2026-08-05T06:00:00Z
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "stale red run fails"
    assert_contains "$OUTPUT" "mirror=staging workflow=nightly.yml run_id=901 status=completed conclusion=failure age_seconds=100800 failing_job=pricing-freshness reason=stale" "stale red run still prints the exact failing job"
}

assert_stale_red_malformed_jobs_is_api_failure() {
    local fixture_root
    new_fixture_repo fixture_root
    write_run "$fixture_root/fixtures" staging nightly.yml 902 "completed failure" 2026-08-05T06:00:00Z
    printf '{"total_count":1,"jobs":[{"name":"pricing-freshness","conclusion":"queued"}]}\n' > "$fixture_root/fixtures/staging_nightly.yml.jobs.json"
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "stale red run with malformed jobs fails as api failure"
    assert_contains "$OUTPUT" "mirror=staging workflow=nightly.yml run_id=902 status=completed conclusion=failure age_seconds=100800 failing_job=unknown reason=api_failure" "stale red malformed jobs preserves api failure verdict"
    assert_contains "$OUTPUT" "mirror=prod workflow=nightly.yml run_id=103 status=completed conclusion=failure age_seconds=60 failing_job=pricing-freshness reason=red_acknowledged" "enumeration continues after stale red jobs failure"
    assert_contains "$OUTPUT" "summary checked=6 passed=5 failed=1" "stale red jobs failure preserves full summary"
}

assert_registry_denominator() {
    local actual_files declared_files pair_count
    actual_files="$(scheduled_workflow_files "$REPO_ROOT")"
    declared_files="$(awk '!/^#/ && NF {print $2}' "$SCRIPT_DIR/scheduled_alarm_workflows.txt" | LC_ALL=C sort -u)"
    pair_count="$(awk '!/^#/ && NF {count++} END{print count+0}' "$SCRIPT_DIR/scheduled_alarm_workflows.txt")"
    assert_eq "$actual_files" $'deploy_currency.yml\nnightly.yml\noutside_aws_health.yml' "workflow parsing finds the hand-calculated scheduled set"
    assert_eq "$declared_files" "$actual_files" "declared registry matches scheduled workflow files"
    assert_eq "$pair_count" 6 "declared denominator remains six mirror/workflow pairs"
    assert_eq "$(awk '!/^#/ && NF {print $1, $2, $3}' "$SCRIPT_DIR/scheduled_alarm_acknowledgements.txt")" $'staging nightly.yml pricing-freshness\nprod nightly.yml pricing-freshness' "ack registry seeds only exact nightly pricing-freshness keys"

    local fixture_root
    new_fixture_repo fixture_root
    sed -i.bak '/^prod outside_aws_health.yml /d' "$fixture_root/scripts/tests/scheduled_alarm_workflows.txt"
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "deleting one declared pair is caught"
    assert_contains "$OUTPUT" "summary checked=5 passed=5 failed=1 reason=registry_mismatch" "denominator drop is explicit"
}

assert_yaml_scheduled_workflow_requires_registry_row() {
    local fixture_root
    new_fixture_repo fixture_root
    cp "$fixture_root/.github/workflows/outside_aws_health.yml" "$fixture_root/.github/workflows/canary_schedule.yaml"
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 1 "scheduled .yaml workflow missing from registry is caught"
    assert_contains "$OUTPUT" "summary checked=6 passed=6 failed=1 reason=registry_mismatch" ".yaml denominator drift is explicit"

    printf 'staging canary_schedule.yaml run 14400\nprod canary_schedule.yaml run 14400\n' >> "$fixture_root/scripts/tests/scheduled_alarm_workflows.txt"
    write_run "$fixture_root/fixtures" staging canary_schedule.yaml 501 "completed success" 2026-08-06T09:59:00Z
    write_run "$fixture_root/fixtures" prod canary_schedule.yaml 502 "completed success" 2026-08-06T09:59:00Z
    run_fixture_probe "$fixture_root"
    assert_eq "$RC" 0 "registered scheduled .yaml workflow is probed"
    assert_contains "$OUTPUT" "mirror=staging workflow=canary_schedule.yaml run_id=501 status=completed conclusion=success age_seconds=60 failing_job=none reason=green" "staging .yaml pair is enumerated"
    assert_contains "$OUTPUT" "summary checked=8 passed=8 failed=0" "registered .yaml pairs expand denominator"
}

assert_local_ci_shadow_classifier_distinguishes_evidence_failures() {
    local local_ci="$REPO_ROOT/scripts/local-ci.sh"
    local tmp classifier rc
    tmp="$(mktemp -d)"
    TMP_PATHS+=("$tmp")
    classifier="$tmp/scheduled_alarm_classifier.sh"
    sed -n '/^scheduled_alarm_liveness_probe_exit_is_shadowable()/,/^}/p' "$local_ci" > "$classifier"
    if [ ! -s "$classifier" ]; then
        fail "local-ci exposes a scheduled-alarm shadow classifier"
        return
    fi

    run_shadow_classifier() {
        local specimen="$1"
        set +e
        bash -c '. "$1"; scheduled_alarm_liveness_probe_exit_is_shadowable "$2"' _ "$classifier" "$specimen"
        rc=$?
        set -e
        printf '%s' "$rc"
    }

    assert_eq \
        "$(run_shadow_classifier $'mirror=staging workflow=deploy_currency.yml run_id=none status=none conclusion=none age_seconds=unknown failing_job=none reason=schedule_run_missing\nsummary checked=6 passed=5 failed=1')" \
        "0" \
        "local-ci shadows first-batch non-green workflow health verdicts"
    assert_eq \
        "$(run_shadow_classifier $'mirror=staging workflow=outside_aws_health.yml run_id=none status=none conclusion=none age_seconds=unknown failing_job=none reason=api_failure\nsummary checked=6 passed=5 failed=1')" \
        "1" \
        "local-ci keeps API evidence failures fatal"
    assert_eq \
        "$(run_shadow_classifier $'mirror=staging workflow=deploy_currency.yml run_id=none status=none conclusion=none age_seconds=unknown failing_job=none reason=auth_missing\nsummary checked=6 passed=0 failed=6')" \
        "1" \
        "local-ci keeps GitHub auth failures fatal"
    assert_eq \
        "$(run_shadow_classifier $'registry_error reason=scheduled_workflow_denominator_mismatch\nsummary checked=6 passed=6 failed=1 reason=registry_mismatch')" \
        "1" \
        "local-ci keeps workflow registry mismatches fatal"
    assert_eq \
        "$(run_shadow_classifier $'mirror=staging workflow=deploy_currency.yml run_id=none status=none conclusion=none age_seconds=unknown failing_job=none reason=schedule_run_missing\nmirror=prod workflow=nightly.yml run_id=103 status=completed conclusion=failure age_seconds=60 failing_job=pricing-freshness reason=surprise\nsummary checked=6 passed=4 failed=2')" \
        "1" \
        "local-ci keeps unknown live verdict reasons fatal even when another failure is shadowable"
}

assert_local_ci_registration_is_complete() {
    local local_ci="$REPO_ROOT/scripts/local-ci.sh"
    local gate_name="scheduled-alarm-liveness-contract"
    local gate_body

    assert_eq \
        "$(grep -Fxc '#                    scheduled-alarm-liveness-contract,' "$local_ci" || true)" \
        "1" \
        "local-ci usage help names the scheduled-alarm gate exactly once"
    assert_eq \
        "$(grep -Fxc 'gate_scheduled_alarm_liveness_contract() {' "$local_ci" || true)" \
        "1" \
        "local-ci defines the scheduled-alarm gate function exactly once"
    assert_eq \
        "$(grep -Fxc 'schedule scheduled-alarm-liveness-contract' "$local_ci" || true)" \
        "1" \
        "local-ci scheduler names the scheduled-alarm gate exactly once"
    assert_eq \
        "$(grep -Fxc '            scheduled-alarm-liveness-contract) run_gate scheduled-alarm-liveness-contract gate_scheduled_alarm_liveness_contract ;;' "$local_ci" || true)" \
        "1" \
        "local-ci dispatches the scheduled-alarm gate exactly once"
    assert_eq \
        "$(grep -F "    printf 'Known gates:" "$local_ci" | grep -Fc "$gate_name" || true)" \
        "1" \
        "local-ci summary-only inventory names the scheduled-alarm gate exactly once"
    assert_eq \
        "$(grep -F '        echo "Known gates:' "$local_ci" | grep -Fc "$gate_name" || true)" \
        "1" \
        "local-ci unknown-gate help names the scheduled-alarm gate exactly once"
    assert_eq "$(grep -Fo "$gate_name" "$local_ci" | wc -l | tr -d ' ')" "6" \
        "local-ci has exactly the six intended scheduled-alarm gate registrations"

    gate_body="$(sed -n '/^gate_scheduled_alarm_liveness_contract()/,/^}/p' "$local_ci")"
    assert_contains "$gate_body" 'scripts/tests/scheduled_alarm_liveness_probe_test.sh' \
        "scheduled-alarm gate runs the hermetic contract first"
    assert_contains "$gate_body" 'scripts/tests/alerting_scheduled_alarm_runbook_test.sh' \
        "scheduled-alarm gate keeps the matching operator procedure reachable"
    assert_contains "$gate_body" 'scripts/probe_scheduled_alarm_liveness.sh' \
        "scheduled-alarm gate probes the real repository state"
    assert_contains "$gate_body" 'scheduled_alarm_liveness_probe_exit_is_shadowable "$probe_stdout"' \
        "scheduled-alarm gate only shadows classified workflow-health verdicts"
    assert_contains "$gate_body" 'SHADOW_WARN:' \
        "scheduled-alarm gate reports first-batch live failures through the shared shadow channel"
    assert_contains "$gate_body" 'aug05_12pm_3_flapjack_pin_bump_and_drift_guard' \
        "scheduled-alarm gate names its promotion batch"
    assert_contains "$gate_body" 'summary checked=6 passed=6 failed=0' \
        "scheduled-alarm gate names the exact promotion evidence"
}

assert_baseline
assert_no_runs_fails
assert_stale_fails
assert_stale_conclusion_is_red
assert_not_completed_fails
assert_skip_rules
assert_unacknowledged_red_fails
assert_acknowledgement_key_is_exact
assert_deploy_red_cannot_be_acknowledged
assert_indeterminate_fails
assert_malformed_run_entry_fails_per_pair
assert_malformed_job_entry_fails_per_pair
assert_truncated_jobs_fail_closed
assert_null_job_conclusion_fails_closed
assert_nonterminal_job_conclusion_fails_closed
assert_run_only_conclusion_is_invalid_for_job
assert_completed_null_run_conclusion_fails_closed
assert_completed_nonterminal_run_conclusion_fails_closed
assert_invalid_run_states_are_api_failures
assert_spaced_job_name_can_be_acknowledged
assert_future_timestamp_fails_closed
assert_auth_failure_fails_closed
assert_registry_denominator
assert_yaml_scheduled_workflow_requires_registry_row
assert_quoted_on_key_stays_in_denominator
assert_nested_schedule_key_is_excluded
assert_quoted_schedule_key_stays_in_denominator
assert_zero_count_nonempty_run_fails_per_pair
assert_stale_red_shows_failing_job
assert_stale_red_malformed_jobs_is_api_failure
assert_local_ci_shadow_classifier_distinguishes_evidence_failures
assert_local_ci_registration_is_complete

printf '\nSummary: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
