#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/probe_live_baseline.sh"

# This is a focused sibling because the aggregate contract spans fleet, HTTP,
# AWS, and DNS evidence; tests_probe_engine_exposure.sh owns per-target exposure.

# shellcheck source=../tests/lib/test_runner.sh disable=SC1091
source "$REPO_ROOT/scripts/tests/lib/test_runner.sh"
# shellcheck source=../tests/lib/assertions.sh disable=SC1091
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

NETWORK_CALLS="$TEST_ROOT/network_calls.log"
STUB_BIN="$TEST_ROOT/bin"
mkdir -p "$STUB_BIN"
: > "$NETWORK_CALLS"

# Stubs record the full argument vector so live-mode tests can assert the exact
# read-only query the collector issues, not merely that a command was invoked.
for command_name in aws curl nc dig host nslookup; do
    stub_path="$STUB_BIN/$command_name"
    cat > "$stub_path" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$command_name \$*" >> '${NETWORK_CALLS}'
exit 99
EOF
    chmod +x "$stub_path"
done

ORIGINAL_PATH="$PATH"
CASE_DIR=""
EVIDENCE_DIR=""
RUN_OUTPUT=""
RUN_EXIT_CODE=0
LIVE_ROW_IDS=(
    fleet_tls_443
    public_tcp_7700_ingress
    engine_admin_surface
    engine_auth_enforcement
    engine_health_disclosure
    spf
    dmarc
)
FLEET_ROW_IDS=(
    fleet_tls_443
    public_tcp_7700_ingress
    engine_admin_surface
    engine_auth_enforcement
    engine_health_disclosure
)
DNS_ROW_IDS=(
    spf
    dmarc
)

create_case() {
    local case_name="$1"

    CASE_DIR="$TEST_ROOT/$case_name"
    EVIDENCE_DIR="$CASE_DIR/evidence"
    mkdir -p "$EVIDENCE_DIR"
    : > "$EVIDENCE_DIR/targets.tsv"
    printf '0\n' > "$EVIDENCE_DIR/targets.exit"
    : > "$EVIDENCE_DIR/targets.error"
}

write_security_group_fixture() {
    local target_key="$1"

    printf '%s\n' \
        '{"SecurityGroups":[{"GroupId":"sg-acde","IpPermissions":[{"IpProtocol":"tcp","FromPort":7700,"ToPort":7700,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]}]}' \
        > "$EVIDENCE_DIR/${target_key}.sg.json"
    printf '0\n' > "$EVIDENCE_DIR/${target_key}.sg.exit"
}

write_http_fixture() {
    local target_key="$1"
    local path_key="$2"
    local status="$3"
    local command_exit="${4:-0}"

    printf '%s\n' "$status" > "$EVIDENCE_DIR/${target_key}.http_${path_key}.status"
    printf '%s\n' "$command_exit" > "$EVIDENCE_DIR/${target_key}.http_${path_key}.exit"
}

add_matching_target() {
    local environment="$1"
    local instance_id="$2"
    local address="$3"
    local target_key="${environment}_${instance_id}"

    printf '%s\t%s\t%s\tsg-acde\n' "$environment" "$instance_id" "$address" \
        >> "$EVIDENCE_DIR/targets.tsv"
    write_security_group_fixture "$target_key"
    printf '000\n' > "$EVIDENCE_DIR/${target_key}.tls.status"
    printf '7\n' > "$EVIDENCE_DIR/${target_key}.tls.exit"
    printf '0\n' > "$EVIDENCE_DIR/${target_key}.tls.verify"
    write_http_fixture "$target_key" dashboard 404
    write_http_fixture "$target_key" swagger_ui 404
    write_http_fixture "$target_key" indexes 403
    write_http_fixture "$target_key" health 200
    printf '%s\n' \
        '{"version":"1.2.3","git_revision":"fixture","workspace_digest":"fixture","loaded_tenant_count":2,"memory_bytes":4096}' \
        > "$EVIDENCE_DIR/${target_key}.http_health.body"
}

write_matching_dns_evidence() {
    printf '0\n' > "$EVIDENCE_DIR/dns_spf.exit"
    printf '%s\n' \
        '"v=spf1 include:amazonses.com include:_spf.google.com ~all"' \
        > "$EVIDENCE_DIR/dns_spf.output"
    printf '%s\n' '"google-site-verification=fixture"' >> "$EVIDENCE_DIR/dns_spf.output"
    printf '0\n' > "$EVIDENCE_DIR/dns_dmarc.exit"
    printf '%s\n' \
        '"v=DMARC1; p=none; rua=mailto:hi@flapjack.foo"' \
        > "$EVIDENCE_DIR/dns_dmarc.output"
}

write_all_match_evidence() {
    add_matching_target staging i-stage vm-stage.example.test
    add_matching_target production i-production vm-production.example.test
    printf '%s\n' '{"SecurityGroups":[{"GroupId":"sg-acde","IpPermissions":[{"IpProtocol":"tcp","FromPort":7700,"ToPort":7700,"IpRanges":[],"Ipv6Ranges":[{"CidrIpv6":"::/0"}]}]}]}' > "$EVIDENCE_DIR/production_i-production.sg.json"
    write_matching_dns_evidence
}

run_case() {
    : > "$NETWORK_CALLS"
    set +e
    RUN_OUTPUT="$(PATH="$STUB_BIN:$ORIGINAL_PATH" bash "$TARGET_SCRIPT" \
        --evidence-dir "$EVIDENCE_DIR" 2>&1)"
    RUN_EXIT_CODE=$?
    set -e
}

run_live_case() {
    local live_root="$1"

    : > "$NETWORK_CALLS"
    set +e
    RUN_OUTPUT="$(cd "$live_root" && PATH="$STUB_BIN:$ORIGINAL_PATH" bash "$TARGET_SCRIPT" 2>&1)"
    RUN_EXIT_CODE=$?
    set -e
}

assert_no_network_calls() {
    local case_name="$1"
    assert_eq "$(cat "$NETWORK_CALLS")" "" \
        "$case_name uses fixture evidence without network, DNS, or AWS commands"
}

assert_row_verdict() {
    local row_id="$1"
    local expected_verdict="$2"
    local message="$3"

    if grep -Eq "^ROW id=$row_id verdict=$expected_verdict([[:space:]]|$)" <<< "$RUN_OUTPUT"; then
        pass "$message"
    else
        fail "$message (expected exact ROW verdict '$expected_verdict' for '$row_id' in '$RUN_OUTPUT')"
    fi
}

assert_no_row_verdict() {
    local row_id="$1"
    local rejected_verdict="$2"
    local message="$3"

    if grep -Eq "^ROW id=$row_id verdict=$rejected_verdict([[:space:]]|$)" <<< "$RUN_OUTPUT"; then
        fail "$message (unexpected exact ROW verdict '$rejected_verdict' for '$row_id')"
    else
        pass "$message"
    fi
}

assert_row_is_not_match() {
    local row_id="$1"
    local message="$2"

    assert_no_row_verdict "$row_id" MATCH "$message"
}

assert_row_is_not_drift() {
    local row_id="$1"
    local message="$2"

    assert_no_row_verdict "$row_id" DRIFT "$message"
}

assert_row_is_not_unmeasurable() {
    local row_id="$1"
    local message="$2"

    assert_no_row_verdict "$row_id" UNMEASURABLE "$message"
}

assert_exact_summary() {
    local expected_summary="$1"
    local message="$2"

    if grep -Fxq "$expected_summary" <<< "$RUN_OUTPUT"; then
        pass "$message"
    else
        fail "$message (expected exact summary '$expected_summary' in '$RUN_OUTPUT')"
    fi
}

count_row_id_lines() {
    local row_id="$1"

    grep -c "^ROW id=$row_id verdict=" <<< "$RUN_OUTPUT" || true
}

assert_exact_live_row_set() {
    local message="$1"
    local row_id row_id_count live_row_count=0

    for row_id in "${LIVE_ROW_IDS[@]}"; do
        row_id_count="$(count_row_id_lines "$row_id")"
        live_row_count=$((live_row_count + row_id_count))
        assert_eq "$row_id_count" "1" \
            "$message renders exactly one ROW line for $row_id"
    done
    assert_eq "$live_row_count" "7" "$message renders exactly seven live ROW lines"
}

assert_single_drift_summary() {
    local row_id="$1"
    local message="$2"

    assert_exact_summary \
        "SUMMARY checked=7 match=6 drift=1 unmeasurable=0 verdict=DRIFT" \
        "$message"
    assert_not_contains "$RUN_OUTPUT" \
        "SUMMARY checked=7 match=7 drift=0 unmeasurable=0 verdict=MATCH" \
        "$row_id scenario rejects a contradictory green summary"
}

assert_single_unmeasurable_summary() {
    local row_id="$1"
    local message="$2"

    assert_exact_summary \
        "SUMMARY checked=7 match=6 drift=0 unmeasurable=1 verdict=UNMEASURABLE" \
        "$message"
    assert_not_contains "$RUN_OUTPUT" \
        "SUMMARY checked=7 match=7 drift=0 unmeasurable=0 verdict=MATCH" \
        "$row_id scenario rejects a contradictory green summary"
}

test_all_match_reports_every_row_and_exact_denominator() {
    local row_id match_count

    create_case all_match
    write_all_match_evidence
    run_case

    assert_eq "$RUN_EXIT_CODE" "0" "all-match evidence exits zero"
    assert_exact_live_row_set "all-match evidence"
    for row_id in "${LIVE_ROW_IDS[@]}"; do
        assert_row_verdict "$row_id" MATCH \
            "all-match evidence renders MATCH for $row_id"
    done
    assert_contains "$RUN_OUTPUT" "actual=v=spf1 include:amazonses.com include:_spf.google.com ~all" "all-match SPF detail reports the SPF TXT record"
    assert_not_contains "$RUN_OUTPUT" "actual=v=spf1 include:amazonses.com include:_spf.google.com ~allgoogle-site" "all-match SPF detail does not concatenate unrelated TXT records"
    assert_not_contains "$RUN_OUTPUT" "actual=baseline" \
        "all-match fleet rows cite measured evidence instead of a placeholder actual"
    assert_contains "$RUN_OUTPUT" \
        "evidence=sg-acde tcp/7700 expected=public_0.0.0.0/0 actual=public_::/0" \
        "all-match ingress detail names the IPv6 public CIDR that was actually measured"
    assert_contains "$RUN_OUTPUT" \
        "evidence=https://vm-production.example.test:443 expected=tls_absent actual=tls_absent" \
        "all-match TLS detail names the measured target rather than a generic fleet label"
    assert_contains "$RUN_OUTPUT" \
        "evidence=/1/indexes expected=403 actual=403" \
        "all-match auth-enforcement detail reports the measured status code"
    match_count=0
    for row_id in "${LIVE_ROW_IDS[@]}"; do
        if grep -Eq "^ROW id=$row_id verdict=MATCH([[:space:]]|$)" <<< "$RUN_OUTPUT"; then
            match_count=$((match_count + 1))
        fi
    done
    assert_eq "$match_count" "7" "all-match evidence renders exactly seven MATCH rows"
    assert_not_contains "$RUN_OUTPUT" "verdict=DRIFT" \
        "all-match evidence rejects contradictory DRIFT row output"
    assert_not_contains "$RUN_OUTPUT" "verdict=UNMEASURABLE" \
        "all-match evidence rejects contradictory UNMEASURABLE row output"
    assert_not_contains "$RUN_OUTPUT" "verdict=VACUOUS" \
        "all-match evidence rejects contradictory VACUOUS row output"
    assert_exact_summary \
        "SUMMARY checked=7 match=7 drift=0 unmeasurable=0 verdict=MATCH" \
        "all-match summary reports the exact non-zero denominator"
    assert_no_network_calls "all-match case"
}

test_measured_drift_names_changed_evidence_and_fails() {
    local row_id case_name evidence_marker
    for row_id in "${LIVE_ROW_IDS[@]}"; do
        case_name="measured_drift_${row_id}"
        create_case "$case_name"
        write_all_match_evidence

        case "$row_id" in
            fleet_tls_443)
                printf '200\n' > "$EVIDENCE_DIR/production_i-production.tls.status"
                printf '0\n' > "$EVIDENCE_DIR/production_i-production.tls.exit"
                printf '0\n' > "$EVIDENCE_DIR/production_i-production.tls.verify"
                evidence_marker="evidence=https://vm-production.example.test:443 expected=tls_absent actual=tls_present_verified"
                ;;
            public_tcp_7700_ingress)
                printf '%s\n' \
                    '{"SecurityGroups":[{"GroupId":"sg-acde","IpPermissions":[{"IpProtocol":"tcp","FromPort":7700,"ToPort":7700,"IpRanges":[{"CidrIp":"10.0.0.0/8"}]}]}]}' \
                    > "$EVIDENCE_DIR/production_i-production.sg.json"
                evidence_marker="evidence=sg-acde tcp/7700 expected=public_0.0.0.0/0 actual=not_public"
                ;;
            engine_admin_surface)
                write_http_fixture production_i-production dashboard 200
                evidence_marker="evidence=/dashboard expected=404 actual=200"
                ;;
            engine_auth_enforcement)
                write_http_fixture production_i-production indexes 200
                evidence_marker="evidence=/1/indexes expected=403 actual=200"
                ;;
            engine_health_disclosure)
                write_http_fixture production_i-production health 404
                evidence_marker="evidence=/health expected=200 actual=404"
                ;;
            spf)
                printf '%s\n' '"v=spf1 -all"' > "$EVIDENCE_DIR/dns_spf.output"
                evidence_marker="evidence=flapjack.foo expected=amazonses_and_google actual=v=spf1 -all"
                ;;
            dmarc)
                printf '%s\n' '"v=DMARC1; p=reject"' > "$EVIDENCE_DIR/dns_dmarc.output"
                evidence_marker="evidence=_dmarc.flapjack.foo expected=p=none actual=p=reject"
                ;;
        esac

        run_case

        assert_ne "$RUN_EXIT_CODE" "0" "measured $row_id drift exits non-zero"
        assert_exact_live_row_set "measured $row_id drift"
        assert_row_verdict "$row_id" DRIFT \
            "measured $row_id drift is a product DRIFT"
        assert_row_is_not_match "$row_id" \
            "measured $row_id drift can never render MATCH"
        assert_row_is_not_unmeasurable "$row_id" \
            "measured $row_id drift is not collapsed into UNMEASURABLE"
        assert_contains "$RUN_OUTPUT" "$evidence_marker" \
            "measured $row_id drift names the changed evidence and values"
        assert_single_drift_summary "$row_id" \
            "measured $row_id drift reports exact non-green summary counts"
        assert_no_network_calls "$case_name case"
    done
}

test_access_denied_is_unmeasurable_not_product_drift() {
    create_case access_denied
    write_all_match_evidence
    printf '254\n' > "$EVIDENCE_DIR/targets.exit"
    printf '%s\n' \
        'An error occurred (AccessDenied) when calling the DescribeInstances operation' \
        > "$EVIDENCE_DIR/targets.error"
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" "AccessDenied evidence exits non-zero"
    assert_row_verdict fleet_inventory UNMEASURABLE \
        "AccessDenied maps to UNMEASURABLE"
    assert_contains "$RUN_OUTPUT" \
        "evidence=aws_ec2_describe_instances reason=AccessDenied" \
        "AccessDenied output names the denied evidence source"
    assert_exact_live_row_set "AccessDenied evidence"
    for row_id in "${FLEET_ROW_IDS[@]}"; do
        assert_row_verdict "$row_id" UNMEASURABLE \
            "AccessDenied maps $row_id to UNMEASURABLE"
        assert_row_is_not_match "$row_id" \
            "AccessDenied can never render $row_id as MATCH from stale fixture evidence"
        assert_row_is_not_drift "$row_id" \
            "AccessDenied is not misreported as product DRIFT for $row_id"
    done
    for row_id in "${DNS_ROW_IDS[@]}"; do
        assert_row_verdict "$row_id" MATCH \
            "AccessDenied preserves independently measured $row_id evidence"
        assert_row_is_not_drift "$row_id" \
            "AccessDenied does not invent product DRIFT for measured $row_id evidence"
        assert_row_is_not_unmeasurable "$row_id" \
            "fleet AccessDenied does not contaminate measured $row_id evidence"
    done
    assert_exact_summary \
        "SUMMARY checked=7 match=2 drift=0 unmeasurable=5 verdict=UNMEASURABLE" \
        "AccessDenied summary preserves two measured DNS rows and fails five fleet rows"
    assert_no_network_calls "AccessDenied case"
}

test_malformed_response_is_unmeasurable_not_product_drift() {
    local row_id case_name evidence_marker

    for row_id in "${LIVE_ROW_IDS[@]}"; do
        case_name="malformed_${row_id}"
        create_case "$case_name"
        write_all_match_evidence

        case "$row_id" in
            fleet_tls_443)
                printf 'not-a-status\n' > "$EVIDENCE_DIR/staging_i-stage.tls.status"
                evidence_marker="evidence=https://vm-stage.example.test:443 reason=unparseable"
                ;;
            public_tcp_7700_ingress)
                printf '%s\n' '{"SecurityGroups":[{"GroupId":"sg-acde","IpPermissions":[]},null]}' > "$EVIDENCE_DIR/staging_i-stage.sg.json"
                evidence_marker="evidence=sg-acde tcp/7700 reason=unparseable"
                ;;
            engine_admin_surface)
                write_http_fixture staging_i-stage dashboard not-a-status
                evidence_marker="evidence=/dashboard reason=unparseable"
                ;;
            engine_auth_enforcement)
                write_http_fixture staging_i-stage indexes not-a-status
                evidence_marker="evidence=/1/indexes reason=unparseable"
                ;;
            engine_health_disclosure)
                printf '%s\n' 'not-json' > "$EVIDENCE_DIR/staging_i-stage.http_health.body"
                evidence_marker="evidence=/health reason=unparseable"
                ;;
            spf)
                printf '%s\n' 'not-an-spf-record' > "$EVIDENCE_DIR/dns_spf.output"
                evidence_marker="evidence=flapjack.foo reason=unparseable"
                ;;
            dmarc)
                printf '%s\n' 'not-a-dmarc-record' > "$EVIDENCE_DIR/dns_dmarc.output"
                evidence_marker="evidence=_dmarc.flapjack.foo reason=unparseable"
                ;;
        esac

        run_case

        assert_ne "$RUN_EXIT_CODE" "0" "malformed $row_id evidence exits non-zero"
        assert_exact_live_row_set "malformed $row_id evidence"
        assert_row_verdict "$row_id" UNMEASURABLE \
            "malformed $row_id evidence maps to UNMEASURABLE"
        assert_contains "$RUN_OUTPUT" "$evidence_marker" \
            "malformed $row_id evidence names the unparseable evidence"
        assert_row_is_not_match "$row_id" \
            "malformed $row_id evidence can never render MATCH"
        assert_row_is_not_drift "$row_id" \
            "malformed $row_id evidence is not misreported as product DRIFT"
        assert_single_unmeasurable_summary "$row_id" \
            "malformed $row_id evidence reports exact non-green summary counts"
        assert_no_network_calls "$case_name case"
    done
}

test_invalid_utf8_evidence_is_unmeasurable_not_a_classifier_crash() {
    local row_id evidence_path evidence_marker

    for row_id in public_tcp_7700_ingress engine_health_disclosure spf; do
        create_case "invalid_utf8_${row_id}"
        write_all_match_evidence
        case "$row_id" in
            public_tcp_7700_ingress)
                evidence_path="$EVIDENCE_DIR/staging_i-stage.sg.json"
                evidence_marker="evidence=sg-acde tcp/7700 reason=unparseable"
                ;;
            engine_health_disclosure)
                evidence_path="$EVIDENCE_DIR/staging_i-stage.http_health.body"
                evidence_marker="evidence=/health reason=unparseable"
                ;;
            spf)
                evidence_path="$EVIDENCE_DIR/dns_spf.output"
                evidence_marker="evidence=flapjack.foo reason=unparseable"
                ;;
        esac
        python3 - "$evidence_path" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(b'\xff')
PY
        run_case

        assert_ne "$RUN_EXIT_CODE" "0" "invalid UTF-8 $row_id evidence exits non-zero"
        assert_exact_live_row_set "invalid UTF-8 $row_id evidence"
        assert_row_verdict "$row_id" UNMEASURABLE \
            "invalid UTF-8 $row_id evidence maps to UNMEASURABLE"
        assert_contains "$RUN_OUTPUT" "$evidence_marker" \
            "invalid UTF-8 $row_id evidence names the unparseable source"
        assert_single_unmeasurable_summary "$row_id" \
            "invalid UTF-8 $row_id evidence reports exact non-green summary counts"
        assert_no_network_calls "invalid UTF-8 $row_id case"
    done
}

test_unreachable_host_is_unmeasurable_not_disabled_posture() {
    local row_id
    local unreachable_row_ids=(
        fleet_tls_443
        engine_admin_surface
        engine_auth_enforcement
        engine_health_disclosure
    )

    create_case unreachable_host
    write_all_match_evidence
    write_http_fixture staging_i-stage dashboard 000 28
    write_http_fixture staging_i-stage swagger_ui 000 28
    write_http_fixture staging_i-stage indexes 000 28
    write_http_fixture staging_i-stage health 000 28
    printf '000\n' > "$EVIDENCE_DIR/staging_i-stage.tls.status"
    printf '28\n' > "$EVIDENCE_DIR/staging_i-stage.tls.exit"
    printf '0\n' > "$EVIDENCE_DIR/staging_i-stage.tls.verify"
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" "unreachable host evidence exits non-zero"
    assert_exact_live_row_set "unreachable host evidence"
    for row_id in "${unreachable_row_ids[@]}"; do
        assert_row_verdict "$row_id" UNMEASURABLE \
            "unreachable host maps $row_id posture to UNMEASURABLE"
        assert_row_is_not_match "$row_id" \
            "unreachable host can never render $row_id as MATCH"
        assert_row_is_not_drift "$row_id" \
            "unreachable host is not misreported as product DRIFT for $row_id"
    done
    # docs/security/README.md rule 6: reachability is not posture.
    assert_contains "$RUN_OUTPUT" \
        "evidence=/dashboard reason=unreachable_is_not_posture" \
        "unreachable host explicitly applies the reachability-is-not-posture rule"
    assert_exact_summary \
        "SUMMARY checked=7 match=3 drift=0 unmeasurable=4 verdict=UNMEASURABLE" \
        "unreachable host reports exact non-green summary counts"
    assert_not_contains "$RUN_OUTPUT" \
        "SUMMARY checked=7 match=7 drift=0 unmeasurable=0 verdict=MATCH" \
        "unreachable host rejects a contradictory green summary"
    assert_no_network_calls "unreachable host case"
}

test_tls_absence_requires_reached_target_evidence() {
    local path_key

    create_case tls_absence_without_reachability
    write_all_match_evidence
    for path_key in dashboard swagger_ui indexes health; do
        write_http_fixture staging_i-stage "$path_key" 000 28
    done
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" "absent TLS without reached target evidence exits non-zero"
    assert_row_verdict fleet_tls_443 UNMEASURABLE "absent TLS requires reached target evidence"
    assert_row_is_not_match fleet_tls_443 "absent TLS cannot render MATCH from unreachable target evidence"
    assert_exact_summary "SUMMARY checked=7 match=3 drift=0 unmeasurable=4 verdict=UNMEASURABLE" "unreachable target keeps absent TLS out of the MATCH count"
    assert_no_network_calls "absent TLS without reached target case"
}

test_missing_required_evidence_is_unmeasurable() {
    local row_id case_name evidence_marker

    for row_id in "${LIVE_ROW_IDS[@]}"; do
        case_name="missing_required_${row_id}"
        create_case "$case_name"
        write_all_match_evidence

        case "$row_id" in
            fleet_tls_443)
                rm "$EVIDENCE_DIR/staging_i-stage.tls.status"
                evidence_marker="evidence=https://vm-stage.example.test:443 reason=missing_evidence"
                ;;
            public_tcp_7700_ingress)
                rm "$EVIDENCE_DIR/staging_i-stage.sg.json"
                evidence_marker="evidence=sg-acde tcp/7700 reason=missing_evidence"
                ;;
            engine_admin_surface)
                rm "$EVIDENCE_DIR/staging_i-stage.http_dashboard.status"
                evidence_marker="evidence=/dashboard reason=missing_evidence"
                ;;
            engine_auth_enforcement)
                rm "$EVIDENCE_DIR/staging_i-stage.http_indexes.status"
                evidence_marker="evidence=/1/indexes reason=missing_evidence"
                ;;
            engine_health_disclosure)
                rm "$EVIDENCE_DIR/staging_i-stage.http_health.status"
                evidence_marker="evidence=/health reason=missing_evidence"
                ;;
            spf)
                rm "$EVIDENCE_DIR/dns_spf.output"
                evidence_marker="evidence=flapjack.foo reason=missing_evidence"
                ;;
            dmarc)
                rm "$EVIDENCE_DIR/dns_dmarc.output"
                evidence_marker="evidence=_dmarc.flapjack.foo reason=missing_evidence"
                ;;
        esac

        run_case

        assert_ne "$RUN_EXIT_CODE" "0" "missing required $row_id evidence exits non-zero"
        assert_exact_live_row_set "missing required $row_id evidence"
        assert_row_verdict "$row_id" UNMEASURABLE \
            "missing required $row_id evidence maps to UNMEASURABLE"
        assert_contains "$RUN_OUTPUT" "$evidence_marker" \
            "missing required $row_id evidence names the absent evidence"
        assert_row_is_not_match "$row_id" \
            "missing required $row_id evidence can never render MATCH"
        assert_row_is_not_drift "$row_id" \
            "missing required $row_id evidence is not misreported as product DRIFT"
        assert_single_unmeasurable_summary "$row_id" \
            "missing required $row_id evidence reports exact non-green summary counts"
        assert_no_network_calls "$case_name case"
    done
}

test_failed_collection_metadata_is_unmeasurable() {
    local row_id case_name evidence_marker

    for row_id in "${LIVE_ROW_IDS[@]}"; do
        case_name="failed_collection_${row_id}"
        create_case "$case_name"
        write_all_match_evidence

        case "$row_id" in
            fleet_tls_443)
                printf '28\n' > "$EVIDENCE_DIR/staging_i-stage.tls.exit"
                evidence_marker="evidence=https://vm-stage.example.test:443 reason=collection_failed exit=28"
                ;;
            public_tcp_7700_ingress)
                printf '254\n' > "$EVIDENCE_DIR/staging_i-stage.sg.exit"
                evidence_marker="evidence=sg-acde tcp/7700 reason=collection_failed exit=254"
                ;;
            engine_admin_surface)
                printf '28\n' > "$EVIDENCE_DIR/staging_i-stage.http_dashboard.exit"
                evidence_marker="evidence=/dashboard reason=collection_failed exit=28"
                ;;
            engine_auth_enforcement)
                printf '28\n' > "$EVIDENCE_DIR/staging_i-stage.http_indexes.exit"
                evidence_marker="evidence=/1/indexes reason=collection_failed exit=28"
                ;;
            engine_health_disclosure)
                printf '28\n' > "$EVIDENCE_DIR/staging_i-stage.http_health.exit"
                evidence_marker="evidence=/health reason=collection_failed exit=28"
                ;;
            spf)
                printf '9\n' > "$EVIDENCE_DIR/dns_spf.exit"
                evidence_marker="evidence=flapjack.foo reason=collection_failed exit=9"
                ;;
            dmarc)
                printf '9\n' > "$EVIDENCE_DIR/dns_dmarc.exit"
                evidence_marker="evidence=_dmarc.flapjack.foo reason=collection_failed exit=9"
                ;;
        esac

        run_case

        assert_ne "$RUN_EXIT_CODE" "0" "failed $row_id collection metadata exits non-zero"
        assert_exact_live_row_set "failed $row_id collection metadata"
        assert_row_verdict "$row_id" UNMEASURABLE \
            "failed $row_id collection metadata maps to UNMEASURABLE"
        assert_contains "$RUN_OUTPUT" "$evidence_marker" \
            "failed $row_id collection metadata names the failing evidence source"
        assert_row_is_not_match "$row_id" \
            "failed $row_id collection metadata can never render MATCH from stale output"
        assert_row_is_not_drift "$row_id" \
            "failed $row_id collection metadata is not misreported as product DRIFT"
        assert_single_unmeasurable_summary "$row_id" \
            "failed $row_id collection metadata reports exact non-green summary counts"
        assert_no_network_calls "$case_name case"
    done
}

test_untrusted_tls_is_measured_drift() {
    local scenario tls_exit tls_verify

    for scenario in cert_untrusted handshake_failed hostname_mismatch; do
        create_case "tls_${scenario}"
        write_all_match_evidence
        case "$scenario" in
            cert_untrusted)
                tls_exit=60
                tls_verify=20
                ;;
            handshake_failed)
                tls_exit=35
                tls_verify=0
                ;;
            hostname_mismatch)
                tls_exit=60
                tls_verify=62
                ;;
        esac
        printf '000\n' > "$EVIDENCE_DIR/staging_i-stage.tls.status"
        printf '%s\n' "$tls_exit" > "$EVIDENCE_DIR/staging_i-stage.tls.exit"
        printf '%s\n' "$tls_verify" > "$EVIDENCE_DIR/staging_i-stage.tls.verify"
        run_case

        assert_ne "$RUN_EXIT_CODE" "0" "$scenario TLS evidence exits non-zero"
        assert_exact_live_row_set "$scenario TLS evidence"
        assert_row_verdict fleet_tls_443 DRIFT \
            "$scenario is measured TLS presence rather than absent baseline posture"
        assert_row_is_not_match fleet_tls_443 \
            "$scenario can never render absent TLS posture as MATCH"
        assert_row_is_not_unmeasurable fleet_tls_443 \
            "$scenario is not collapsed into an unreachable measurement"
        assert_contains "$RUN_OUTPUT" \
            "evidence=https://vm-stage.example.test:443 expected=tls_absent actual=tls_present_untrusted" \
            "$scenario names the measured untrusted TLS evidence"
        assert_single_drift_summary fleet_tls_443 \
            "$scenario reports exact non-green summary counts"
        assert_no_network_calls "$scenario TLS case"
    done
}

test_admin_surface_requires_swagger_evidence() {
    local scenario expected_verdict evidence_marker

    for scenario in drift malformed missing unreachable; do
        create_case "swagger_${scenario}"
        write_all_match_evidence
        [ "$scenario" = drift ] || write_http_fixture staging_i-stage dashboard 200

        case "$scenario" in
            drift)
                write_http_fixture staging_i-stage swagger_ui 200
                expected_verdict=DRIFT
                evidence_marker="evidence=/swagger-ui expected=404 actual=200"
                ;;
            malformed)
                write_http_fixture staging_i-stage swagger_ui not-a-status
                expected_verdict=UNMEASURABLE
                evidence_marker="evidence=/swagger-ui reason=unparseable"
                ;;
            missing)
                rm "$EVIDENCE_DIR/staging_i-stage.http_swagger_ui.status"
                expected_verdict=UNMEASURABLE
                evidence_marker="evidence=/swagger-ui reason=missing_evidence"
                ;;
            unreachable)
                write_http_fixture staging_i-stage swagger_ui 000 28
                expected_verdict=UNMEASURABLE
                evidence_marker="evidence=/swagger-ui reason=unreachable_is_not_posture"
                ;;
        esac

        run_case

        assert_ne "$RUN_EXIT_CODE" "0" "swagger $scenario evidence exits non-zero"
        assert_exact_live_row_set "swagger $scenario evidence"
        assert_row_verdict engine_admin_surface "$expected_verdict" \
            "swagger $scenario evidence controls the admin-surface verdict"
        assert_contains "$RUN_OUTPUT" "$evidence_marker" \
            "swagger $scenario evidence names the affected admin path"
        assert_row_is_not_match engine_admin_surface \
            "swagger $scenario evidence can never render the admin surface as MATCH"
        if [ "$expected_verdict" = "DRIFT" ]; then
            assert_single_drift_summary engine_admin_surface \
                "swagger drift reports exact non-green summary counts"
        else
            assert_row_is_not_drift engine_admin_surface \
                "swagger $scenario evidence is not misreported as product DRIFT"
            assert_single_unmeasurable_summary engine_admin_surface \
                "swagger $scenario evidence reports exact non-green summary counts"
        fi
        assert_no_network_calls "swagger $scenario case"
    done
}

test_health_disclosure_requires_expected_fields() {
    create_case health_disclosure_fields_absent
    write_all_match_evidence
    printf '%s\n' '{}' > "$EVIDENCE_DIR/staging_i-stage.http_health.body"
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" "removed health disclosure fields exit non-zero"
    assert_exact_live_row_set "removed health disclosure fields"
    assert_row_verdict engine_health_disclosure DRIFT \
        "parseable JSON without disclosure fields is a measured product DRIFT"
    assert_row_is_not_match engine_health_disclosure \
        "parseable JSON alone is insufficient for a health-disclosure MATCH"
    assert_row_is_not_unmeasurable engine_health_disclosure \
        "parseable changed health JSON is not collapsed into UNMEASURABLE"
    assert_contains "$RUN_OUTPUT" \
        "evidence=/health expected=disclosure_fields_present actual=disclosure_fields_absent" \
        "health disclosure drift names the changed semantic evidence"
    assert_single_drift_summary engine_health_disclosure \
        "health disclosure field removal reports exact non-green summary counts"
    assert_no_network_calls "health disclosure fields case"
}

test_absent_dns_record_is_measured_drift() {
    local row_id case_name evidence_marker

    # `dig +short TXT` and `host -t TXT` both exit 0 with no matching answer when
    # the record has been removed, so an empty successful answer is measured
    # posture (the record is gone) rather than a failed measurement.
    for row_id in "${DNS_ROW_IDS[@]}"; do
        case_name="absent_dns_${row_id}"
        create_case "$case_name"
        write_all_match_evidence
        printf '0\n' > "$EVIDENCE_DIR/dns_${row_id}.exit"
        : > "$EVIDENCE_DIR/dns_${row_id}.output"

        case "$row_id" in
            spf)
                evidence_marker="evidence=flapjack.foo expected=amazonses_and_google actual=record_absent"
                ;;
            dmarc)
                evidence_marker="evidence=_dmarc.flapjack.foo expected=p=none actual=record_absent"
                ;;
        esac

        run_case

        assert_ne "$RUN_EXIT_CODE" "0" "removed $row_id TXT record exits non-zero"
        assert_exact_live_row_set "removed $row_id TXT record"
        assert_row_verdict "$row_id" DRIFT \
            "successfully collected empty $row_id answer is measured record removal"
        assert_row_is_not_match "$row_id" \
            "removed $row_id TXT record can never render MATCH"
        assert_row_is_not_unmeasurable "$row_id" \
            "removed $row_id TXT record is not misattributed to a failed probe"
        assert_contains "$RUN_OUTPUT" "$evidence_marker" \
            "removed $row_id TXT record names the absent record as the measured value"
        assert_single_drift_summary "$row_id" \
            "removed $row_id TXT record reports exact non-green summary counts"
        assert_no_network_calls "$case_name case"
    done
}

test_live_enumeration_is_constrained_to_running_instances() {
    local live_root live_output live_exit_code recorded_calls

    # Terminated instances keep their tags for about an hour and stopped
    # instances keep them indefinitely, but neither has a public address, so an
    # unconstrained query would blank every fleet row after routine churn.
    live_root="$TEST_ROOT/live_enumeration"
    mkdir -p "$live_root"
    : > "$NETWORK_CALLS"
    set +e
    live_output="$(cd "$live_root" && PATH="$STUB_BIN:$ORIGINAL_PATH" bash "$TARGET_SCRIPT" 2>&1)"
    live_exit_code=$?
    set -e
    recorded_calls="$(cat "$NETWORK_CALLS")"

    assert_contains "$recorded_calls" "ec2 describe-instances" \
        "live mode enumerates the fleet with ec2 describe-instances"
    assert_contains "$recorded_calls" "Name=tag:managed-by,Values=fjcloud" \
        "live enumeration keeps the managed-by tag filter"
    assert_contains "$recorded_calls" "Name=instance-state-name,Values=running" \
        "live enumeration is constrained to running instances"
    assert_ne "$live_exit_code" "0" \
        "failed live enumeration keeps the probe non-zero"
    assert_contains "$live_output" "ROW id=fleet_inventory verdict=UNMEASURABLE" \
        "failed live enumeration reports the fleet inventory diagnostic"
}

test_live_mode_redacts_aws_identifiers_in_generated_evidence() {
    local live_root live_evidence_dir raw_account_id raw_principal raw_profile
    local targets_error instances_json security_group_json

    live_root="$TEST_ROOT/live_redaction"
    mkdir -p "$live_root"
    raw_account_id="213880904778"
    raw_principal="arn:aws:iam::213880904778:user/flapjack-loadtest"
    raw_profile="arn:aws:iam::213880904778:instance-profile/fjcloud-instance-profile"

    cat > "$STUB_BIN/aws" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "ec2" ] && [ "$2" = "describe-instances" ]; then
    cat <<'JSON'
{
  "Reservations": [
    {
      "OwnerId": "213880904778",
      "Instances": [
        {
          "InstanceId": "i-redaction",
          "PublicDnsName": "vm-redaction.example.test",
          "SecurityGroups": [{ "GroupId": "sg-redaction" }],
          "NetworkInterfaces": [{ "OwnerId": "213880904778" }],
          "IamInstanceProfile": {
            "Arn": "arn:aws:iam::213880904778:instance-profile/fjcloud-instance-profile"
          },
          "Tags": [{ "Key": "environment", "Value": "staging" }]
        }
      ]
    }
  ]
}
JSON
    exit 0
fi
if [ "$1" = "ec2" ] && [ "$2" = "describe-security-groups" ]; then
    cat <<'JSON'
{
  "SecurityGroups": [
    {
      "GroupId": "sg-redaction",
      "OwnerId": "213880904778",
      "SecurityGroupArn": "arn:aws:ec2:us-east-1:213880904778:security-group/sg-redaction",
      "IpPermissions": [
        {
          "IpProtocol": "tcp",
          "FromPort": 7700,
          "ToPort": 7700,
          "IpRanges": [{ "CidrIp": "0.0.0.0/0" }],
          "UserIdGroupPairs": [
            { "UserId": "213880904778", "GroupId": "sg-peer" }
          ]
        }
      ]
    }
  ]
}
JSON
    printf '%s\n' \
        "aws: [ERROR]: User: arn:aws:iam::213880904778:user/flapjack-loadtest is not authorized to perform: ssm:GetParameter on resource: arn:aws:ssm:us-east-1:213880904778:parameter/fjcloud/prod/jwt_secret because no identity-based policy allows the ssm:GetParameter action" >&2
    exit 0
fi
printf '%s\n' "unexpected aws invocation: $*" >&2
exit 99
EOF
    chmod +x "$STUB_BIN/aws"

    run_live_case "$live_root"
    live_evidence_dir="$(sed -n 's/^EVIDENCE_DIR path=//p' <<< "$RUN_OUTPUT" | tail -n 1)"
    targets_error="$live_root/$live_evidence_dir/staging_i-redaction.sg.error"
    instances_json="$live_root/$live_evidence_dir/instances.json"
    security_group_json="$live_root/$live_evidence_dir/staging_i-redaction.sg.json"

    assert_ne "$RUN_EXIT_CODE" "0" \
        "redaction live-mode case keeps the probe non-zero when downstream collection fails"
    assert_contains "$RUN_OUTPUT" "EVIDENCE_DIR path=docs/live-state/" \
        "redaction live-mode case reports the generated evidence directory"
    assert_eq "$(test -f "$targets_error"; printf '%s' "$?")" "0" \
        "redaction live-mode case writes the security-group error evidence"
    assert_eq "$(test -f "$instances_json"; printf '%s' "$?")" "0" \
        "redaction live-mode case writes the instance inventory evidence"
    assert_eq "$(test -f "$security_group_json"; printf '%s' "$?")" "0" \
        "redaction live-mode case writes the security-group evidence"
    assert_not_contains "$(cat "$targets_error")" "$raw_principal" \
        "redaction live-mode case strips the raw IAM user ARN from AWS stderr"
    assert_contains "$(cat "$targets_error")" "arn:aws:iam::<account-id>:user/<redacted>" \
        "redaction live-mode case leaves a redacted IAM principal placeholder"
    assert_not_contains "$(cat "$targets_error")" "/fjcloud/prod/jwt_secret" \
        "redaction live-mode case strips the raw secret parameter path from AWS stderr"
    assert_contains "$(cat "$targets_error")" \
        "arn:aws:ssm:<region>:<account-id>:parameter/<redacted>" \
        "redaction live-mode case leaves a redacted parameter ARN placeholder"
    assert_not_contains "$(cat "$instances_json")" "$raw_profile" \
        "redaction live-mode case strips the raw instance-profile ARN from instances.json"
    assert_contains "$(cat "$instances_json")" \
        "arn:aws:iam::<account-id>:instance-profile/<redacted>" \
        "redaction live-mode case leaves a redacted instance-profile placeholder"
    assert_not_contains "$(cat "$instances_json")" "$raw_account_id" \
        "redaction live-mode case strips account IDs from instances.json"
    assert_not_contains "$(cat "$security_group_json")" "$raw_account_id" \
        "redaction live-mode case strips account IDs from security-group JSON"
    assert_contains "$(cat "$security_group_json")" '"OwnerId": "<account-id>"' \
        "redaction live-mode case leaves a placeholder for security-group ownership"
    assert_contains "$(cat "$security_group_json")" \
        "arn:aws:ec2:us-east-1:<account-id>:security-group/sg-redaction" \
        "redaction live-mode case preserves a useful redacted security-group ARN"
}

test_fixture_mode_does_not_load_credentials() {
    create_case fixture_without_credentials
    write_all_match_evidence
    export FJCLOUD_SECRET_FILE="$CASE_DIR/does_not_exist.env"
    run_case
    unset FJCLOUD_SECRET_FILE

    assert_eq "$RUN_EXIT_CODE" "0" \
        "fixture mode does not require or load an ambient secret file"
    assert_exact_live_row_set "credential-free fixture evidence"
    assert_exact_summary \
        "SUMMARY checked=7 match=7 drift=0 unmeasurable=0 verdict=MATCH" \
        "credential-free fixture mode still classifies all baseline evidence"
    assert_no_network_calls "credential-free fixture case"
}

test_empty_target_set_is_vacuous() {
    local row_id live_row_count row_id_count summary_count

    create_case vacuous
    write_matching_dns_evidence
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" "empty in-scope fleet exits non-zero"
    live_row_count=0
    for row_id in "${LIVE_ROW_IDS[@]}"; do
        row_id_count="$(count_row_id_lines "$row_id")"
        live_row_count=$((live_row_count + row_id_count))
    done
    assert_eq "$live_row_count" "2" \
        "empty fleet still renders exactly the two independently measured DNS rows"
    for row_id in "${DNS_ROW_IDS[@]}"; do
        row_id_count="$(count_row_id_lines "$row_id")"
        assert_eq "$row_id_count" "1" \
            "empty fleet renders exactly one ROW line for measured $row_id evidence"
        assert_row_verdict "$row_id" MATCH \
            "empty fleet preserves measured MATCH posture for $row_id"
    done
    for row_id in "${FLEET_ROW_IDS[@]}"; do
        row_id_count="$(count_row_id_lines "$row_id")"
        assert_eq "$row_id_count" "0" \
            "empty fleet does not invent a verdict for uninstantiated $row_id"
    done
    for row_id in "${LIVE_ROW_IDS[@]}"; do
        assert_no_row_verdict "$row_id" DRIFT \
            "vacuous fleet output rejects contradictory DRIFT verdict for live row $row_id"
        assert_no_row_verdict "$row_id" UNMEASURABLE \
            "vacuous fleet output rejects contradictory UNMEASURABLE verdict for live row $row_id"
        assert_no_row_verdict "$row_id" VACUOUS \
            "vacuous fleet output does not invent a VACUOUS verdict for live row $row_id"
    done
    assert_exact_summary \
        "SUMMARY checked=2 match=2 drift=0 unmeasurable=0 verdict=VACUOUS" \
        "empty fleet counts measured DNS rows while keeping the overall verdict VACUOUS"
    summary_count="$(grep -c '^SUMMARY ' <<< "$RUN_OUTPUT" || true)"
    assert_eq "$summary_count" "1" \
        "empty fleet emits exactly one non-contradictory summary"
    assert_no_network_calls "vacuous case"
}

test_all_match_reports_every_row_and_exact_denominator
test_measured_drift_names_changed_evidence_and_fails
test_access_denied_is_unmeasurable_not_product_drift
test_malformed_response_is_unmeasurable_not_product_drift
test_invalid_utf8_evidence_is_unmeasurable_not_a_classifier_crash
test_unreachable_host_is_unmeasurable_not_disabled_posture
test_tls_absence_requires_reached_target_evidence
test_missing_required_evidence_is_unmeasurable
test_failed_collection_metadata_is_unmeasurable
test_untrusted_tls_is_measured_drift
test_admin_surface_requires_swagger_evidence
test_health_disclosure_requires_expected_fields
test_absent_dns_record_is_measured_drift
test_live_enumeration_is_constrained_to_running_instances
test_live_mode_redacts_aws_identifiers_in_generated_evidence
test_fixture_mode_does_not_load_credentials
test_empty_target_set_is_vacuous

run_test_summary
