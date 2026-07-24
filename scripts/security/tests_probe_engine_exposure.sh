#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/probe_engine_exposure.sh"

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

for command_name in aws curl nc; do
    stub_path="$STUB_BIN/$command_name"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf 'printf %s\\n %s >> %s\n' "'%s'" "'$command_name'" "'${NETWORK_CALLS}'"
        printf '%s\n' 'exit 99'
    } > "$stub_path"
    chmod +x "$stub_path"
done

ORIGINAL_PATH="$PATH"
CASE_DIR=""
TARGETS_FILE=""
EVIDENCE_DIR=""
RUN_OUTPUT=""
RUN_EXIT_CODE=0
TARGET_ADDRESS="198.51.100.10"

create_case() {
    local case_name="$1"

    CASE_DIR="$TEST_ROOT/$case_name"
    TARGETS_FILE="$CASE_DIR/targets.tsv"
    EVIDENCE_DIR="$CASE_DIR/evidence"
    mkdir -p "$EVIDENCE_DIR"
    : > "$TARGETS_FILE"
    TARGET_ADDRESS="198.51.100.10"
}

write_security_group_fixture() {
    local target_key="$1"
    local fixture_kind="$2"
    local fixture_path="$EVIDENCE_DIR/${target_key}.sg.json"

    case "$fixture_kind" in
        public)
            printf '%s\n' '{"SecurityGroups":[{"GroupId":"sg-acde","IpPermissions":[{"IpProtocol":"tcp","FromPort":7700,"ToPort":7700,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]}]}' > "$fixture_path"
            ;;
        restricted)
            printf '%s\n' '{"SecurityGroups":[{"GroupId":"sg-acde","IpPermissions":[{"IpProtocol":"tcp","FromPort":7700,"ToPort":7700,"IpRanges":[{"CidrIp":"10.0.0.0/16"}],"UserIdGroupPairs":[{"GroupId":"sg-api"}]}]}]}' > "$fixture_path"
            ;;
        public_other_port)
            printf '%s\n' '{"SecurityGroups":[{"GroupId":"sg-acde","IpPermissions":[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]}]}' > "$fixture_path"
            ;;
        malformed)
            printf '%s\n' '{not-json' > "$fixture_path"
            ;;
        *)
            fail "test setup accepts security-group fixture kind '$fixture_kind'"
            ;;
    esac
}

write_nc_fixture() {
    local target_key="$1"
    local fixture_kind="$2"

    case "$fixture_kind" in
        open)
            printf '0\n' > "$EVIDENCE_DIR/${target_key}.nc.exit"
            printf 'Connection to 198.51.100.10 port 7700 [tcp/*] succeeded!\n' > "$EVIDENCE_DIR/${target_key}.nc.output"
            ;;
        closed)
            printf '1\n' > "$EVIDENCE_DIR/${target_key}.nc.exit"
            printf 'nc: connectx failed: Connection refused\n' > "$EVIDENCE_DIR/${target_key}.nc.output"
            ;;
        timeout)
            printf '1\n' > "$EVIDENCE_DIR/${target_key}.nc.exit"
            printf 'nc: connectx failed: Operation timed out\n' > "$EVIDENCE_DIR/${target_key}.nc.output"
            ;;
        command_missing)
            printf '127\n' > "$EVIDENCE_DIR/${target_key}.nc.exit"
            printf 'nc: command not found\n' > "$EVIDENCE_DIR/${target_key}.nc.output"
            ;;
        malformed)
            printf 'not-an-exit-code\n' > "$EVIDENCE_DIR/${target_key}.nc.exit"
            printf 'unclassifiable\n' > "$EVIDENCE_DIR/${target_key}.nc.output"
            ;;
        *)
            fail "test setup accepts nc fixture kind '$fixture_kind'"
            ;;
    esac
}

write_http_fixture() {
    local target_key="$1"
    local path_key="$2"
    local fixture_value="$3"
    local status_file="$EVIDENCE_DIR/${target_key}.http_${path_key}.status"
    local exit_file="$EVIDENCE_DIR/${target_key}.http_${path_key}.exit"
    local fixture_status fixture_exit fixture_verify

    if [ "$path_key" = "tls" ]; then
        status_file="$EVIDENCE_DIR/${target_key}.tls.status"
        exit_file="$EVIDENCE_DIR/${target_key}.tls.exit"
        case "$fixture_value" in
            ok) fixture_status=403; fixture_exit=0; fixture_verify=0 ;;
            absent) fixture_status=000; fixture_exit=7; fixture_verify=0 ;;
            cert_untrusted) fixture_status=000; fixture_exit=60; fixture_verify=20 ;;
            handshake_failed) fixture_status=000; fixture_exit=35; fixture_verify=0 ;;
            hostname_mismatch) fixture_status=000; fixture_exit=60; fixture_verify=62 ;;
            unreachable) fixture_status=000; fixture_exit=28; fixture_verify=0 ;;
            *)
                fail "test setup accepts TLS fixture kind '$fixture_value'"
                ;;
        esac
        printf '%s\n' "$fixture_status" > "$status_file"
        printf '%s\n' "$fixture_exit" > "$exit_file"
        printf '%s\n' "$fixture_verify" > "$EVIDENCE_DIR/${target_key}.tls.verify"
        return
    fi

    case "$fixture_value" in
        timeout)
            printf '000\n' > "$status_file"
            printf '28\n' > "$exit_file"
            ;;
        malformed)
            printf 'not-a-status\n' > "$status_file"
            printf '0\n' > "$exit_file"
            ;;
        *)
            printf '%s\n' "$fixture_value" > "$status_file"
            printf '0\n' > "$exit_file"
            ;;
    esac
}

add_target() {
    local target_suffix="$1"
    local sg_fixture="$2"
    local nc_fixture="$3"
    local http_fixtures="$4"
    local tls_fixture="${5:-ok}"
    local target_key="test_i-${target_suffix}"
    local dashboard_status swagger_status indexes_status

    read -r dashboard_status swagger_status indexes_status <<< "$http_fixtures"
    printf 'test\ti-%s\t%s\tsg-acde\n' "$target_suffix" "$TARGET_ADDRESS" >> "$TARGETS_FILE"
    printf '0\n' > "$EVIDENCE_DIR/${target_key}.sg.exit"
    write_security_group_fixture "$target_key" "$sg_fixture"
    write_nc_fixture "$target_key" "$nc_fixture"
    write_http_fixture "$target_key" dashboard "$dashboard_status"
    write_http_fixture "$target_key" swagger_ui "$swagger_status"
    write_http_fixture "$target_key" indexes "$indexes_status"
    write_http_fixture "$target_key" tls "$tls_fixture"
}

run_case() {
    : > "$NETWORK_CALLS"
    set +e
    RUN_OUTPUT="$(PATH="$STUB_BIN:$ORIGINAL_PATH" bash "$TARGET_SCRIPT" \
        --targets-file "$TARGETS_FILE" \
        --evidence-dir "$EVIDENCE_DIR" 2>&1)"
    RUN_EXIT_CODE=$?
    set -e
}

assert_no_network_calls() {
    local case_name="$1"
    assert_eq "$(cat "$NETWORK_CALLS")" "" "$case_name uses fixture evidence without network commands"
}

target_tls_token() {
    awk '
        $1 == "TARGET" {
            for (field = 1; field <= NF; field++) {
                if ($field ~ /^tls=/) {
                    sub(/^tls=/, "", $field)
                    print $field
                }
            }
        }
    ' <<< "$RUN_OUTPUT"
}

assert_target_tls() {
    local expected_token="$1"
    local case_name="$2"

    assert_eq "$(target_tls_token)" "$expected_token" \
        "$case_name renders the exact per-target TLS token"
}

test_reachable_plaintext_without_tls_is_tls_absent() {
    create_case plaintext_without_tls
    add_target plaintext public open "401 401 403" absent
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" "reachable plaintext engine without trusted TLS is fail-loud"
    assert_target_tls "TLS_ABSENT" "reachable plaintext engine"
    assert_contains "$RUN_OUTPUT" "VERDICT: EXPOSED" \
        "transport classification preserves the existing exposure verdict"
    assert_no_network_calls "reachable plaintext engine case"
}

test_verified_tls_is_tls_ok() {
    create_case verified_tls
    TARGET_ADDRESS="vm-shared-abc.staging.flapjack.foo"
    add_target verified restricted closed "401 403 404" ok
    run_case

    assert_eq "$RUN_EXIT_CODE" "0" "verified TLS on a DNS target permits a green result"
    assert_target_tls "TLS_OK" "verified TLS case"
    assert_contains "$RUN_OUTPUT" "target_address=$TARGET_ADDRESS" \
        "DNS target address is accepted and rendered"
}

test_tls_failures_are_never_tls_ok() {
    local fixture_kind target_suffix

    for fixture_kind in cert_untrusted handshake_failed hostname_mismatch; do
        create_case "tls_${fixture_kind}"
        target_suffix="${fixture_kind//_/-}"
        add_target "$target_suffix" restricted closed "401 403 404" "$fixture_kind"
        run_case

        assert_ne "$RUN_EXIT_CODE" "0" "$fixture_kind is fail-loud"
        assert_target_tls "TLS_UNTRUSTED" "$fixture_kind case"
        assert_not_contains "$RUN_OUTPUT" "tls=TLS_OK" \
            "$fixture_kind can never be classified as TLS_OK"
    done
}

test_unreachable_transport_probe_is_explicit() {
    create_case unreachable_transport
    add_target unreachable restricted timeout "timeout timeout timeout" unreachable
    run_case

    assert_ne "$RUN_EXIT_CODE" "0" "unreachable transport probe is fail-loud"
    assert_target_tls "PROBE_UNREACHABLE" "unreachable transport case"
    assert_contains "$RUN_OUTPUT" "VERDICT: TRANSPORT_FAILURE" "transport failure is non-green"
    assert_not_contains "$RUN_OUTPUT" "tls=TLS_OK" \
        "unreachable transport probe can never be classified as TLS_OK"
}

test_public_dashboard_is_exposed() {
    create_case public_dashboard
    add_target public public open "200 401 401"
    run_case
    assert_ne "$RUN_EXIT_CODE" "0" "public tcp/7700 plus unauthenticated dashboard is fail-loud"
    assert_contains "$RUN_OUTPUT" "VERDICT: EXPOSED" "public dashboard verdict is EXPOSED"
    assert_no_network_calls "public dashboard case"
}

test_public_timeout_is_latent_exposure() {
    create_case public_timeout
    add_target latent public timeout "timeout timeout timeout"
    run_case
    assert_ne "$RUN_EXIT_CODE" "0" "public tcp/7700 timeout is fail-loud"
    assert_contains "$RUN_OUTPUT" "VERDICT: EXPOSED (latent" "public timeout retains latent exposure verdict"
    assert_no_network_calls "public timeout case"
}

test_restricted_timeout_is_not_exposed() {
    create_case restricted_timeout
    add_target restricted restricted timeout "timeout timeout timeout"
    run_case
    assert_eq "$RUN_EXIT_CODE" "0" "restricted SG with engine timeout is green"
    assert_contains "$RUN_OUTPUT" "VERDICT: NOT_EXPOSED" "restricted timeout verdict is NOT_EXPOSED"
    assert_no_network_calls "restricted timeout case"
}

test_restricted_non_200_is_not_exposed() {
    create_case restricted_non_200
    add_target restrictedauth restricted closed "401 403 404"
    run_case
    assert_eq "$RUN_EXIT_CODE" "0" "restricted SG with no unauthenticated 200 is green"
    assert_contains "$RUN_OUTPUT" "port=closed" "connection refusal is confirmed closed-port evidence"
    assert_contains "$RUN_OUTPUT" "VERDICT: NOT_EXPOSED" "restricted non-200 verdict is NOT_EXPOSED"
}

test_missing_nc_is_indeterminate() {
    create_case missing_nc
    add_target missingnc restricted command_missing "401 403 404"
    run_case
    assert_ne "$RUN_EXIT_CODE" "0" "missing nc evidence collection is fail-loud"
    assert_contains "$RUN_OUTPUT" "port=indeterminate" "exit 127 is not closed-port evidence"
    assert_contains "$RUN_OUTPUT" "VERDICT: INDETERMINATE" "missing nc verdict is INDETERMINATE"
    assert_no_network_calls "missing nc case"
}

test_restricted_open_port_is_indeterminate() {
    create_case restricted_open_port
    add_target restrictedopen restricted open "401 403 404"
    run_case
    assert_ne "$RUN_EXIT_CODE" "0" "restricted SG with open external tcp/7700 is fail-loud"
    assert_contains "$RUN_OUTPUT" "port=open" "successful nc evidence is rendered as open"
    assert_contains "$RUN_OUTPUT" "VERDICT: INDETERMINATE" "restricted open port verdict is INDETERMINATE"
    assert_no_network_calls "restricted open port case"
}

test_public_rule_on_other_port_is_not_exposed() {
    create_case public_other_port
    add_target otherport public_other_port closed "401 403 404"
    run_case
    assert_eq "$RUN_EXIT_CODE" "0" "public ingress outside tcp/7700 does not trigger exposure"
    assert_contains "$RUN_OUTPUT" "VERDICT: NOT_EXPOSED" "public ingress on another port stays NOT_EXPOSED"
}

test_each_additional_http_path_can_expose() {
    create_case swagger_exposed
    add_target swagger restricted open "401 200 401"
    run_case
    assert_ne "$RUN_EXIT_CODE" "0" "unauthenticated swagger-ui 200 is fail-loud"
    assert_contains "$RUN_OUTPUT" "VERDICT: EXPOSED" "swagger-ui 200 verdict is EXPOSED"

    create_case indexes_exposed
    add_target indexes restricted open "401 401 200"
    run_case
    assert_ne "$RUN_EXIT_CODE" "0" "unauthenticated read-only data-path 200 is fail-loud"
    assert_contains "$RUN_OUTPUT" "VERDICT: EXPOSED" "read-only data-path 200 verdict is EXPOSED"
}

test_empty_targets_are_vacuous() {
    create_case no_targets
    run_case
    assert_ne "$RUN_EXIT_CODE" "0" "empty target set is fail-loud"
    assert_contains "$RUN_OUTPUT" "VERDICT: VACUOUS" "empty target set verdict is VACUOUS"
    assert_no_network_calls "empty target case"
}

test_malformed_security_group_is_indeterminate() {
    create_case malformed_sg
    add_target badsg malformed open "401 401 401"
    run_case
    assert_ne "$RUN_EXIT_CODE" "0" "malformed security-group evidence is fail-loud"
    assert_contains "$RUN_OUTPUT" "VERDICT: INDETERMINATE" "malformed security-group verdict is INDETERMINATE"
}

test_malformed_http_is_indeterminate() {
    create_case malformed_http
    add_target badhttp restricted open "401 malformed 401"
    run_case
    assert_ne "$RUN_EXIT_CODE" "0" "malformed HTTP evidence is fail-loud"
    assert_contains "$RUN_OUTPUT" "VERDICT: INDETERMINATE" "malformed HTTP verdict is INDETERMINATE"
}

test_exposed_outranks_indeterminate() {
    create_case exposed_precedence
    add_target exposed restricted open "200 401 401"
    add_target unknown malformed malformed "malformed malformed malformed"
    run_case
    assert_ne "$RUN_EXIT_CODE" "0" "mixed exposed and indeterminate targets are fail-loud"
    assert_contains "$RUN_OUTPUT" "VERDICT: EXPOSED" "EXPOSED outranks INDETERMINATE"
    assert_not_contains "$RUN_OUTPUT" "VERDICT: VACUOUS" "non-empty mixed targets are never VACUOUS"
}

test_latent_exposure_outranks_indeterminate() {
    create_case latent_precedence
    add_target latentmixed public timeout "timeout timeout timeout"
    add_target unknownmixed malformed malformed "malformed malformed malformed"
    run_case
    assert_ne "$RUN_EXIT_CODE" "0" "mixed latent exposure and indeterminate targets are fail-loud"
    assert_contains "$RUN_OUTPUT" "VERDICT: EXPOSED (latent" "latent EXPOSED outranks INDETERMINATE"
}

test_indeterminate_outranks_not_exposed() {
    create_case indeterminate_precedence
    add_target green restricted closed "401 403 404"
    add_target unknownlast restricted open "401 malformed 401"
    run_case
    assert_ne "$RUN_EXIT_CODE" "0" "mixed green and indeterminate targets are fail-loud"
    assert_contains "$RUN_OUTPUT" "VERDICT: INDETERMINATE" "INDETERMINATE outranks NOT_EXPOSED"
    assert_not_contains "$RUN_OUTPUT" "VERDICT: VACUOUS" "mixed targets with evidence failures are not VACUOUS"
}

test_invalid_target_row_is_indeterminate() {
    create_case invalid_target
    printf 'test\ti-invalid\tnot-an-ip\tsg-acde\n' > "$TARGETS_FILE"
    run_case
    assert_ne "$RUN_EXIT_CODE" "0" "invalid target input is fail-loud"
    assert_contains "$RUN_OUTPUT" "VERDICT: INDETERMINATE" "invalid target input is INDETERMINATE"
    assert_no_network_calls "invalid target case"
}

test_fixture_mode_does_not_load_credentials() {
    create_case fixture_without_credentials
    add_target fixturecreds restricted closed "401 403 404"
    export FJCLOUD_SECRET_FILE="$CASE_DIR/does_not_exist.env"
    run_case
    unset FJCLOUD_SECRET_FILE

    assert_eq "$RUN_EXIT_CODE" "0" "fixture mode does not require an ambient secret file"
    assert_contains "$RUN_OUTPUT" "VERDICT: NOT_EXPOSED" "fixture mode still classifies without credentials"
    assert_no_network_calls "credential-free fixture case"
}

test_live_mode_honors_explicit_secret_file() {
    create_case live_missing_secret
    set +e
    RUN_OUTPUT="$(FJCLOUD_SECRET_FILE="$CASE_DIR/does_not_exist.env" \
        PATH="$STUB_BIN:$ORIGINAL_PATH" bash "$TARGET_SCRIPT" \
        --targets-file "$TARGETS_FILE" 2>&1)"
    RUN_EXIT_CODE=$?
    set -e

    assert_eq "$RUN_EXIT_CODE" "2" "live mode fails loudly when explicit secret file is missing"
    assert_contains "$RUN_OUTPUT" "FJCLOUD_SECRET_FILE not found" "live mode reports the missing secret-file override"
    assert_no_network_calls "missing live secret case"
}

test_probe_script_is_executable() {
    if [ -x "$TARGET_SCRIPT" ]; then
        pass "probe script is executable for direct Stage 2 invocation"
    else
        fail "probe script is executable for direct Stage 2 invocation"
    fi
}

test_local_ci_registration_is_complete() {
    local local_ci_content
    local_ci_content="$(cat "$REPO_ROOT/scripts/local-ci.sh")"

    assert_contains "$local_ci_content" "engine-exposure-probe-contract" "local-ci help names the exposure gate"
    assert_contains "$local_ci_content" "gate_engine_exposure_probe_contract()" "local-ci defines the exposure gate"
    assert_contains "$local_ci_content" "schedule engine-exposure-probe-contract" "local-ci schedules the exposure gate"
    assert_contains "$local_ci_content" "engine-exposure-probe-contract) run_gate engine-exposure-probe-contract gate_engine_exposure_probe_contract" "local-ci dispatches the exposure gate"
}

test_probe_does_not_render_raw_security_group_payloads() {
    local probe_content
    probe_content="$(cat "$TARGET_SCRIPT")"

    assert_not_contains "$probe_content" "cat \"\$EVIDENCE_DIR/\${TARGET_KEY}.sg.json\"" \
        "live collection keeps raw security-group metadata out of public output"
}

test_tls_collection_is_status_only_and_trust_enforcing() {
    local probe_content
    probe_content="$(cat "$TARGET_SCRIPT")"

    assert_contains "$probe_content" "%{ssl_verify_result}" "TLS probe captures verification status"
    assert_contains "$probe_content" "-o /dev/null" "TLS probe discards response bodies"
    assert_contains "$probe_content" "\"https://\${TARGET_ADDRESS}/1/indexes\"" \
        "TLS probe validates the supplied target name"
    assert_not_contains "$probe_content" "--insecure" "TLS probe never disables certificate validation"
    assert_not_contains "$probe_content" "curl -k" "TLS probe never uses curl's insecure shorthand"
}

test_reachable_plaintext_without_tls_is_tls_absent
test_verified_tls_is_tls_ok
test_tls_failures_are_never_tls_ok
test_unreachable_transport_probe_is_explicit
test_public_dashboard_is_exposed
test_public_timeout_is_latent_exposure
test_restricted_timeout_is_not_exposed
test_restricted_non_200_is_not_exposed
test_missing_nc_is_indeterminate
test_restricted_open_port_is_indeterminate
test_public_rule_on_other_port_is_not_exposed
test_each_additional_http_path_can_expose
test_empty_targets_are_vacuous
test_malformed_security_group_is_indeterminate
test_malformed_http_is_indeterminate
test_exposed_outranks_indeterminate
test_latent_exposure_outranks_indeterminate
test_indeterminate_outranks_not_exposed
test_invalid_target_row_is_indeterminate
test_fixture_mode_does_not_load_credentials
test_live_mode_honors_explicit_secret_file
test_probe_script_is_executable
test_local_ci_registration_is_complete
test_probe_does_not_render_raw_security_group_payloads
test_tls_collection_is_status_only_and_trust_enforcing

run_test_summary
