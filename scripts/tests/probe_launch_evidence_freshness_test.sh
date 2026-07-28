#!/usr/bin/env bash
# Hermetic known-answer tests for scripts/probe_launch_evidence_freshness.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/assertions.sh"

PROBE="$REPO_ROOT/scripts/probe_launch_evidence_freshness.sh"
TMP_PATHS=()

SECTION_DIRS=(
    "ses-coverage-a1"
    "billing_coverage_a2"
    "security-coverage-a3"
    "database-recovery"
    "ha_coverage_a5"
    "launch-rc-runs"
)

cleanup() {
    if [ "${#TMP_PATHS[@]}" -gt 0 ]; then
        rm -rf "${TMP_PATHS[@]}"
    fi
}
trap cleanup EXIT

register_tmp_path() {
    TMP_PATHS+=("$1")
}

timestamp_for_age_days() {
    local age_days="$1"
    python3 - "$age_days" <<'PY'
from datetime import datetime, timedelta, timezone
import sys

age_days = int(sys.argv[1])
timestamp = datetime.now(timezone.utc) - timedelta(days=age_days)
print(timestamp.strftime("%Y%m%dT%H%M%SZ"))
PY
}

create_valid_bundle() {
    local evidence_root="$1" section_dir="$2" age_days="$3" name="$4"
    local bundle_name
    bundle_name="$(timestamp_for_age_days "$age_days")_${name}"
    mkdir -p "$evidence_root/$section_dir/$bundle_name"
    if [ "$section_dir" = "ha_coverage_a5" ]; then
        create_complete_ha_measurements "$evidence_root/$section_dir/$bundle_name"
    fi
    printf '%s\n' "$bundle_name"
}

create_complete_ha_measurements() {
    local bundle_path="$1" artifact
    for artifact in \
        soak_exit_code.txt \
        writes_attempted.count \
        visible_in_search_after.count \
        cross_tenant_leaks.count \
        noisy_neighbor_violations.count \
        fail_fast_during_restart_window.count; do
        printf '0\n' >"$bundle_path/$artifact"
    done
}

create_incomplete_ha_bundle() {
    local evidence_root="$1" age_days="$2"
    local bundle_name bundle_path artifact
    bundle_name="$(timestamp_for_age_days "$age_days")_NONGREEN"
    bundle_path="$evidence_root/ha_coverage_a5/$bundle_name"
    mkdir -p "$bundle_path"
    printf '1\n' >"$bundle_path/soak_exit_code.txt"
    for artifact in \
        writes_attempted.count \
        visible_in_search_after.count \
        cross_tenant_leaks.count \
        noisy_neighbor_violations.count \
        fail_fast_during_restart_window.count; do
        : >"$bundle_path/$artifact"
    done
    printf '%s\n' "$bundle_name"
}

create_empty_section() {
    local evidence_root="$1" section_dir="$2"
    mkdir -p "$evidence_root/$section_dir"
}

create_unparseable_bundle() {
    local evidence_root="$1" section_dir="$2"
    local bundle_name="not_a_timestamp_bundle"
    mkdir -p "$evidence_root/$section_dir/$bundle_name"
    printf '%s\n' "$bundle_name"
}

create_named_bundle() {
    local evidence_root="$1" section_dir="$2" bundle_name="$3"
    mkdir -p "$evidence_root/$section_dir/$bundle_name"
}

seed_fresh_sections_except() {
    local evidence_root="$1" excluded_section="${2:-}" section_dir
    for section_dir in "${SECTION_DIRS[@]}"; do
        if [ "$section_dir" != "$excluded_section" ]; then
            create_valid_bundle "$evidence_root" "$section_dir" 1 "fresh_fixture" >/dev/null
        fi
    done
}

run_probe_path() {
    local probe_path="$1" evidence_root="$2" out_path="$3" err_path="$4" rc_path="$5"
    set +e
    LAUNCH_EVIDENCE_MAX_AGE_DAYS=14 \
        bash "$probe_path" --evidence-root "$evidence_root" >"$out_path" 2>"$err_path"
    printf '%s\n' "$?" >"$rc_path"
    set -e
}

assert_probe_case() {
    local evidence_root="$1" expected_rc="$2" expected_line="$3" message="$4"
    local out err rc
    out="$evidence_root/out.txt"
    err="$evidence_root/err.txt"
    rc="$evidence_root/rc.txt"

    run_probe_path "$PROBE" "$evidence_root" "$out" "$err" "$rc"

    assert_eq "$(cat "$rc")" "$expected_rc" "$message exits with the expected status"
    assert_contains "$(cat "$out")" "$expected_line" "$message names the exact freshness verdict"
    assert_eq "$(grep -Fxc "$expected_line" "$out" || true)" "1" \
        "$message emits the freshness verdict as one complete line"
}

test_one_day_old_newest_bundle_is_fresh() {
    local tmp newest_bundle
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    seed_fresh_sections_except "$tmp" "ses-coverage-a1"
    create_valid_bundle "$tmp" "ses-coverage-a1" 63 "older_fixture" >/dev/null
    newest_bundle="$(create_valid_bundle "$tmp" "ses-coverage-a1" 1 "newest_fixture")"

    assert_probe_case "$tmp" 0 \
        "1. Email/SES delivery $newest_bundle age=1d FRESH" \
        "a one-day-old newest bundle"
}

test_sixty_three_day_old_newest_bundle_is_stale() {
    local tmp newest_bundle
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    seed_fresh_sections_except "$tmp" "billing_coverage_a2"
    create_valid_bundle "$tmp" "billing_coverage_a2" 90 "older_fixture" >/dev/null
    newest_bundle="$(create_valid_bundle "$tmp" "billing_coverage_a2" 63 "newest_fixture")"

    assert_probe_case "$tmp" 1 \
        "2. Billing / Stripe / webhook $newest_bundle age=63d STALE" \
        "a sixty-three-day-old newest bundle"
}

test_fourteen_day_boundary_is_stale() {
    local tmp bundle_name
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    seed_fresh_sections_except "$tmp" "security-coverage-a3"
    bundle_name="$(create_valid_bundle "$tmp" "security-coverage-a3" 14 "boundary_fixture")"

    assert_probe_case "$tmp" 1 \
        "3. Security boundaries $bundle_name age=14d STALE" \
        "a bundle exactly at the fourteen-day bound"
}

test_section_without_bundles_is_missing() {
    local tmp
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    seed_fresh_sections_except "$tmp" "database-recovery"
    create_empty_section "$tmp" "database-recovery"

    assert_probe_case "$tmp" 1 \
        "4. Backup / restore + DB integrity - age=unknown MISSING" \
        "a section with no evidence bundles"
}

test_missing_required_section_directory_is_explicit() {
    local tmp section_state
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    seed_fresh_sections_except "$tmp" "launch-rc-runs"

    if [ -d "$tmp/launch-rc-runs" ]; then
        section_state="present"
    else
        section_state="missing"
    fi
    assert_eq "$section_state" "missing" \
        "the fixture omits the required evidence section directory"

    assert_probe_case "$tmp" 1 \
        "6. Cross-cutting full-stack - age=unknown MISSING_SECTION" \
        "an absent required evidence section"
}

test_unparseable_bundle_name_is_explicit() {
    local tmp bundle_name
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    seed_fresh_sections_except "$tmp" "ha_coverage_a5"
    bundle_name="$(create_unparseable_bundle "$tmp" "ha_coverage_a5")"

    assert_probe_case "$tmp" 1 \
        "5. HA / multi-tenant isolation $bundle_name age=unknown UNPARSEABLE" \
        "an unparseable evidence bundle"
}

test_valid_bundle_with_malformed_sibling_is_classified_and_fails_loudly() {
    local tmp valid_bundle malformed_bundle out err rc
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    seed_fresh_sections_except "$tmp" "launch-rc-runs"
    valid_bundle="$(create_valid_bundle "$tmp" "launch-rc-runs" 1 "valid_fixture")"
    malformed_bundle="fjcloud_post_deploy_evidence_20260502T033932Z_76792"
    create_named_bundle "$tmp" "launch-rc-runs" "$malformed_bundle"
    out="$tmp/out.txt"
    err="$tmp/err.txt"
    rc="$tmp/rc.txt"

    run_probe_path "$PROBE" "$tmp" "$out" "$err" "$rc"

    assert_eq "$(cat "$rc")" "1" \
        "a valid bundle with a malformed sibling exits non-zero"
    assert_eq "$(awk -v expected="6. Cross-cutting full-stack $valid_bundle age=1d FRESH" \
        '$0 == expected { count++ } END { print count + 0 }' "$out")" "1" \
        "a malformed sibling does not replace the newest valid bundle verdict"
    assert_contains "$(cat "$err")" \
        "6. Cross-cutting full-stack/$malformed_bundle" \
        "a malformed sibling emits a section-qualified diagnostic"
    assert_contains "$(cat "$out")" "malformed_names=1" \
        "the summary counts malformed sibling names"
}

test_newer_incomplete_ha_refresh_does_not_replace_completed_bundle() {
    local tmp completed_bundle incomplete_bundle out err rc
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    seed_fresh_sections_except "$tmp" "ha_coverage_a5"
    completed_bundle="$(create_valid_bundle "$tmp" "ha_coverage_a5" 2 "GREEN")"
    incomplete_bundle="$(create_incomplete_ha_bundle "$tmp" 1)"
    out="$tmp/out.txt"
    err="$tmp/err.txt"
    rc="$tmp/rc.txt"

    run_probe_path "$PROBE" "$tmp" "$out" "$err" "$rc"

    assert_eq "$(cat "$rc")" "1" \
        "a newer incomplete HA refresh exits non-zero"
    assert_eq "$(awk -v expected="5. HA / multi-tenant isolation $completed_bundle age=2d FRESH" \
        '$0 == expected { count++ } END { print count + 0 }' "$out")" "1" \
        "a newer incomplete HA refresh does not replace completed evidence"
    assert_contains "$(cat "$err")" \
        "5. HA / multi-tenant isolation/$incomplete_bundle reason=empty_required_files" \
        "a newer incomplete HA refresh emits a section-qualified diagnostic"
    assert_contains "$(cat "$out")" "rejected_bundles=1" \
        "the summary counts rejected incomplete bundles"
}

test_all_fresh_summary_has_exact_denominator() {
    local tmp out err rc
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    seed_fresh_sections_except "$tmp"
    out="$tmp/out.txt"
    err="$tmp/err.txt"
    rc="$tmp/rc.txt"

    run_probe_path "$PROBE" "$tmp" "$out" "$err" "$rc"

    assert_eq "$(cat "$rc")" "0" "an all-fresh corpus exits successfully"
    assert_contains "$(cat "$out")" \
        "sections=6 fresh=6 stale=0 missing=0 missing_section=0 unparseable=0 malformed_names=0" \
        "the summary reports the exact all-fresh denominator"
    assert_eq "$(cat "$err")" "" "an all-fresh corpus emits no diagnostics"
}

test_stale_only_summary_keeps_integrity_counts_zero() {
    local tmp out err rc
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    seed_fresh_sections_except "$tmp" "billing_coverage_a2"
    create_valid_bundle "$tmp" "billing_coverage_a2" 63 "stale_fixture" >/dev/null
    out="$tmp/out.txt"
    err="$tmp/err.txt"
    rc="$tmp/rc.txt"

    run_probe_path "$PROBE" "$tmp" "$out" "$err" "$rc"

    assert_eq "$(cat "$rc")" "1" "a stale-only corpus exits non-zero"
    assert_contains "$(cat "$out")" \
        "sections=6 fresh=5 stale=1 missing=0 missing_section=0 unparseable=0 malformed_names=0 rejected_bundles=0" \
        "a stale-only corpus keeps integrity counters at zero"
    assert_eq "$(cat "$err")" "" "a stale-only corpus emits no diagnostics"
}

test_calendar_invalid_timestamp_is_unparseable() {
    local tmp bundle_name
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    seed_fresh_sections_except "$tmp" "database-recovery"
    bundle_name="20260230T120000Z_invalid_calendar"
    create_named_bundle "$tmp" "database-recovery" "$bundle_name"

    assert_probe_case "$tmp" 1 \
        "4. Backup / restore + DB integrity $bundle_name age=unknown UNPARSEABLE" \
        "a calendar-invalid timestamp"
}

test_future_timestamp_is_unparseable() {
    local tmp bundle_name
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    seed_fresh_sections_except "$tmp" "ses-coverage-a1"
    bundle_name="$(create_valid_bundle "$tmp" "ses-coverage-a1" -1 "future_fixture")"

    assert_probe_case "$tmp" 1 \
        "1. Email/SES delivery $bundle_name age=unknown UNPARSEABLE" \
        "a future timestamp"
}

test_invalid_max_age_configuration_fails_as_usage_error() {
    local tmp out err rc
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    seed_fresh_sections_except "$tmp"
    out="$tmp/out.txt"
    err="$tmp/err.txt"

    set +e
    LAUNCH_EVIDENCE_MAX_AGE_DAYS=invalid \
        bash "$PROBE" --evidence-root "$tmp" >"$out" 2>"$err"
    rc=$?
    set -e

    assert_eq "$rc" "2" "an invalid max-age configuration exits with usage status"
    assert_eq "$(cat "$out")" "" \
        "an invalid max-age configuration emits no freshness verdict"
    assert_contains "$(cat "$err")" "LAUNCH_EVIDENCE_MAX_AGE_DAYS" \
        "an invalid max-age configuration names the rejected input"
}

test_cli_failure_contract() {
    local tmp out err rc
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/out.txt"
    err="$tmp/err.txt"

    set +e
    bash "$PROBE" --unknown >"$out" 2>"$err"
    rc=$?
    set -e

    assert_eq "$rc" "2" "an invalid CLI shape exits with usage status"
    assert_eq "$(cat "$out")" "" "an invalid CLI shape emits no freshness verdict"
    assert_contains "$(cat "$err")" "usage:" "an invalid CLI shape emits a usage diagnostic"
}

# The gate compares the probe's live rejected/malformed diagnostics against a
# closed baseline registry instead of requiring those counts to be zero, because
# they can never reach zero without deleting preserved NONGREEN soak evidence.
# These tests pin that the comparison is exact in BOTH directions, so the
# registry can never decay into an unconditional pass. They exercise the real
# gate function against the real registry — not a fixture — because the thing
# worth protecting is that this specific baseline stays closed.
gate_baseline_check() {
    set +e
    printf '%s\n' "$1" \
        | bash "$REPO_ROOT/scripts/check_launch_evidence_corpus_baseline.sh" 2>&1
    printf 'RC=%s\n' "${PIPESTATUS[1]}"
    set -e
}

live_probe_diagnostics() {
    bash "$PROBE" 2>&1 >/dev/null || true
}

test_gate_baseline_accepts_exactly_the_live_legacy_corpus() {
    local output
    output="$(gate_baseline_check "$(live_probe_diagnostics)")"

    assert_contains "$output" "RC=0" \
        "the closed baseline registry matches the live legacy corpus exactly"
}

test_gate_baseline_rejects_a_new_non_conforming_bundle() {
    local output injected
    injected="$(live_probe_diagnostics)
probe_launch_evidence_freshness: malformed bundle 6. Cross-cutting full-stack/brand_new_rot reason=malformed_name"
    output="$(gate_baseline_check "$injected")"

    assert_contains "$output" "NEW non-conforming evidence bundle" \
        "a bundle outside the baseline is named as new corpus rot"
    assert_contains "$output" "brand_new_rot" \
        "the new-rot failure names the offending bundle"
    assert_not_contains "$output" "RC=0" \
        "a bundle outside the baseline fails the gate"
}

test_gate_baseline_rejects_a_registry_entry_the_probe_no_longer_reports() {
    local output thinned
    # Drop one real diagnostic: the registry still lists it, the probe no longer
    # reports it, so the registry has gone stale and must fail rather than pass.
    thinned="$(live_probe_diagnostics | grep -v '20260528T092151Z_NONGREEN' || true)"
    output="$(gate_baseline_check "$thinned")"

    assert_contains "$output" "no longer reports" \
        "a stale baseline line is named"
    assert_contains "$output" "20260528T092151Z_NONGREEN" \
        "the stale-baseline failure names the stale entry"
    assert_not_contains "$output" "RC=0" \
        "a stale baseline entry fails the gate"
}

test_gate_baseline_accepts_exactly_the_live_legacy_corpus
test_gate_baseline_rejects_a_new_non_conforming_bundle
test_gate_baseline_rejects_a_registry_entry_the_probe_no_longer_reports
test_one_day_old_newest_bundle_is_fresh
test_sixty_three_day_old_newest_bundle_is_stale
test_fourteen_day_boundary_is_stale
test_section_without_bundles_is_missing
test_missing_required_section_directory_is_explicit
test_unparseable_bundle_name_is_explicit
test_valid_bundle_with_malformed_sibling_is_classified_and_fails_loudly
test_newer_incomplete_ha_refresh_does_not_replace_completed_bundle
test_all_fresh_summary_has_exact_denominator
test_stale_only_summary_keeps_integrity_counts_zero
test_calendar_invalid_timestamp_is_unparseable
test_future_timestamp_is_unparseable
test_invalid_max_age_configuration_fails_as_usage_error
test_cli_failure_contract

run_test_summary
