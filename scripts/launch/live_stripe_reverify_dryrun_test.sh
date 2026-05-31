#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/live_stripe_reverify.sh"

assert_equals() {
    local actual="$1"
    local expected="$2"
    local context="$3"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: ${context} expected=${expected} actual=${actual}" >&2
        exit 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local context="$3"
    if ! printf '%s' "$haystack" | grep -Fq "$needle"; then
        echo "FAIL: ${context} missing needle=${needle}" >&2
        exit 1
    fi
}

assert_no_green_bundle() {
    local evidence_root="$1"
    if [ ! -d "$evidence_root" ]; then
        return 0
    fi
    if ls "$evidence_root"/*_GREEN >/dev/null 2>&1; then
        echo "FAIL: unexpected _GREEN bundle under $evidence_root" >&2
        exit 1
    fi
}

assert_not_contains_file() {
    local file_path="$1"
    local needle="$2"
    local context="$3"
    if grep -Fq "$needle" "$file_path"; then
        echo "FAIL: ${context} unexpectedly contained needle=${needle} in $file_path" >&2
        exit 1
    fi
}

assert_file_contains() {
    local file_path="$1"
    local needle="$2"
    local context="$3"
    if ! grep -Fq "$needle" "$file_path"; then
        echo "FAIL: ${context} missing needle=${needle} in $file_path" >&2
        exit 1
    fi
}

make_owner_stub() {
    local owner_stub="$1"
    cat > "$owner_stub" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
printf '{"dry_run":false,"payment_intent_id":"pi_unit_test","charge_id":"ch_unit_test"}\n'
EOS
    chmod +x "$owner_stub"
}

make_curl_stub() {
    local curl_stub="$1"
    cat > "$curl_stub" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

counter_file="${LIVE_STRIPE_REVERIFY_CURL_COUNTER_FILE:?LIVE_STRIPE_REVERIFY_CURL_COUNTER_FILE is required}"
mode="${LIVE_STRIPE_REVERIFY_CURL_MODE:-stable}"
if [ ! -f "$counter_file" ]; then
    printf '0\n' > "$counter_file"
fi
count="$(cat "$counter_file")"
count=$((count + 1))
printf '%s\n' "$count" > "$counter_file"

if [ "$mode" = "transport_fail" ]; then
    printf 'curl: (7) Failed to connect to host\n' >&2
    exit 7
fi

if [ "$mode" = "drift" ] && [ "$count" -ge 2 ]; then
    printf '{"dev_sha":"dev_sha_2","mirror_sha":"mirror_sha_1","synced_at":"2026-05-30T00:00:00Z","build_time":"2026-05-30T00:00:00Z"}\n'
    exit 0
fi

printf '{"dev_sha":"dev_sha_1","mirror_sha":"mirror_sha_1","synced_at":"2026-05-30T00:00:00Z","build_time":"2026-05-30T00:00:00Z"}\n'
EOS
    chmod +x "$curl_stub"
}

make_stripe_shim() {
    local shim_path="$1"
    cat > "$shim_path" <<'EOS'
#!/usr/bin/env bash

stripe_request() {
    local method="$1"
    local path="$2"
    local mode="${LIVE_STRIPE_REVERIFY_STRIPE_MODE:-success}"
    shift 2

    if [ -n "${LIVE_STRIPE_REVERIFY_STRIPE_CALL_LOG:-}" ]; then
        printf '%s %s %s\n' "$method" "$path" "$*" >> "$LIVE_STRIPE_REVERIFY_STRIPE_CALL_LOG"
    fi

    case "$mode" in
        refund_fail)
            if [ "$method" = "POST" ] && [ "$path" = "/v1/refunds" ]; then
                STRIPE_HTTP_CODE="500"
                STRIPE_BODY='{"error":{"message":"refund failed"}}'
                STRIPE_REQUEST_ID="req_fail"
                return 0
            fi
            ;;
    esac

    if [ "$method" = "POST" ] && [ "$path" = "/v1/refunds" ]; then
        STRIPE_HTTP_CODE="200"
        STRIPE_BODY='{"id":"re_unit_test","status":"succeeded","charge":"ch_unit_test"}'
        STRIPE_REQUEST_ID="req_refund"
        return 0
    fi

    if [ "$method" = "GET" ] && [ "$path" = "/v1/payment_intents/pi_unit_test" ]; then
        STRIPE_HTTP_CODE="200"
        STRIPE_BODY='{"id":"pi_unit_test","status":"succeeded","latest_charge":"ch_unit_test"}'
        STRIPE_REQUEST_ID="req_pi"
        return 0
    fi

    if [ "$method" = "GET" ] && [ "$path" = "/v1/refunds/re_unit_test" ]; then
        STRIPE_HTTP_CODE="200"
        STRIPE_BODY='{"id":"re_unit_test","status":"succeeded","charge":"ch_unit_test"}'
        STRIPE_REQUEST_ID="req_refund_get"
        return 0
    fi

    STRIPE_HTTP_CODE="404"
    STRIPE_BODY='{"error":"unexpected request"}'
    STRIPE_REQUEST_ID="req_unexpected"
    return 0
}

sleep() {
    :
}
EOS
    chmod +x "$shim_path"
}

run_happy_path_dry_run_case() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local owner_stub="$tmp_dir/live_card_e2e_test.sh"
    local curl_stub="$tmp_dir/curl"
    local shim_path="$tmp_dir/live_stripe_reverify_shim.sh"
    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"
    local evidence_root="$tmp_dir/evidence"
    local stripe_call_log="$tmp_dir/stripe_calls.log"

    make_owner_stub "$owner_stub"
    make_curl_stub "$curl_stub"
    make_stripe_shim "$shim_path"

    set +e
    PATH="$tmp_dir:$PATH" \
    LIVE_STRIPE_REVERIFY_ALLOW_TEST_SHIM=1 \
    LIVE_STRIPE_REVERIFY_TEST_SHIM="$shim_path" \
    LIVE_STRIPE_REVERIFY_OWNER_SCRIPT="$owner_stub" \
    LIVE_STRIPE_REVERIFY_EVIDENCE_ROOT="$evidence_root" \
    LIVE_STRIPE_REVERIFY_CURL_COUNTER_FILE="$tmp_dir/curl_counter" \
    LIVE_STRIPE_REVERIFY_CURL_MODE=stable \
    LIVE_STRIPE_REVERIFY_STRIPE_CALL_LOG="$stripe_call_log" \
    STRIPE_SECRET_KEY=sk_test_unit_test_key \
    /bin/bash "$RUNNER" --env=prod --dry-run >"$stdout_file" 2>"$stderr_file"
    local rc=$?
    set -e

    assert_equals "$rc" "0" "happy_dry_run_rc"
    assert_contains "$(cat "$stdout_file")" '"dry_run":true' "happy_dry_run_summary_has_dry_run"
    assert_no_green_bundle "$evidence_root"
    if [ -f "$stripe_call_log" ]; then
        assert_equals "$(wc -l < "$stripe_call_log" | tr -d ' ')" "0" "happy_dry_run_no_stripe_calls"
    fi
}

run_refund_failure_case() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local owner_stub="$tmp_dir/live_card_e2e_test.sh"
    local curl_stub="$tmp_dir/curl"
    local shim_path="$tmp_dir/live_stripe_reverify_shim.sh"
    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"
    local evidence_root="$tmp_dir/evidence"

    make_owner_stub "$owner_stub"
    make_curl_stub "$curl_stub"
    make_stripe_shim "$shim_path"

    set +e
    PATH="$tmp_dir:$PATH" \
    LIVE_STRIPE_REVERIFY_ALLOW_TEST_SHIM=1 \
    LIVE_STRIPE_REVERIFY_TEST_SHIM="$shim_path" \
    LIVE_STRIPE_REVERIFY_OWNER_SCRIPT="$owner_stub" \
    LIVE_STRIPE_REVERIFY_EVIDENCE_ROOT="$evidence_root" \
    LIVE_STRIPE_REVERIFY_CURL_COUNTER_FILE="$tmp_dir/curl_counter" \
    LIVE_STRIPE_REVERIFY_CURL_MODE=stable \
    LIVE_STRIPE_REVERIFY_STRIPE_MODE=refund_fail \
    STRIPE_SECRET_KEY=sk_test_unit_test_key \
    /bin/bash "$RUNNER" --env=prod >"$stdout_file" 2>"$stderr_file"
    local rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        echo "FAIL: refund failure case expected non-zero exit" >&2
        exit 1
    fi
    assert_contains "$(cat "$stderr_file")" 'classification=refund_failed_unrefunded_charge' "refund_failure_classification"
    assert_no_green_bundle "$evidence_root"
}

run_version_drift_case() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local owner_stub="$tmp_dir/live_card_e2e_test.sh"
    local curl_stub="$tmp_dir/curl"
    local shim_path="$tmp_dir/live_stripe_reverify_shim.sh"
    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"
    local evidence_root="$tmp_dir/evidence"

    make_owner_stub "$owner_stub"
    make_curl_stub "$curl_stub"
    make_stripe_shim "$shim_path"

    set +e
    PATH="$tmp_dir:$PATH" \
    LIVE_STRIPE_REVERIFY_ALLOW_TEST_SHIM=1 \
    LIVE_STRIPE_REVERIFY_TEST_SHIM="$shim_path" \
    LIVE_STRIPE_REVERIFY_OWNER_SCRIPT="$owner_stub" \
    LIVE_STRIPE_REVERIFY_EVIDENCE_ROOT="$evidence_root" \
    LIVE_STRIPE_REVERIFY_CURL_COUNTER_FILE="$tmp_dir/curl_counter" \
    LIVE_STRIPE_REVERIFY_CURL_MODE=drift \
    LIVE_STRIPE_REVERIFY_STRIPE_MODE=success \
    STRIPE_SECRET_KEY=sk_test_unit_test_key \
    /bin/bash "$RUNNER" --env=prod >"$stdout_file" 2>"$stderr_file"
    local rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        echo "FAIL: version drift case expected non-zero exit" >&2
        exit 1
    fi
    assert_contains "$(cat "$stderr_file")" 'classification=version_drift_detected' "version_drift_classification"
    assert_no_green_bundle "$evidence_root"
}

run_version_probe_curl_failure_case() {
    # Locks in classification fidelity: a curl-transport failure must surface
    # as version_probe_request_failed and NOT be reclassified as
    # version_probe_shape_invalid by a subshell-boundary clobber.
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local owner_stub="$tmp_dir/live_card_e2e_test.sh"
    local curl_stub="$tmp_dir/curl"
    local shim_path="$tmp_dir/live_stripe_reverify_shim.sh"
    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"
    local evidence_root="$tmp_dir/evidence"

    make_owner_stub "$owner_stub"
    make_curl_stub "$curl_stub"
    make_stripe_shim "$shim_path"

    set +e
    PATH="$tmp_dir:$PATH" \
    LIVE_STRIPE_REVERIFY_ALLOW_TEST_SHIM=1 \
    LIVE_STRIPE_REVERIFY_TEST_SHIM="$shim_path" \
    LIVE_STRIPE_REVERIFY_OWNER_SCRIPT="$owner_stub" \
    LIVE_STRIPE_REVERIFY_EVIDENCE_ROOT="$evidence_root" \
    LIVE_STRIPE_REVERIFY_CURL_COUNTER_FILE="$tmp_dir/curl_counter" \
    LIVE_STRIPE_REVERIFY_CURL_MODE=transport_fail \
    STRIPE_SECRET_KEY=sk_test_unit_test_key \
    /bin/bash "$RUNNER" --env=prod >"$stdout_file" 2>"$stderr_file"
    local rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        echo "FAIL: version probe transport failure expected non-zero exit" >&2
        exit 1
    fi
    assert_contains "$(cat "$stderr_file")" 'classification=version_probe_request_failed' "version_probe_transport_classification"
    # Critical: the failure must NOT be reclassified as a shape error.
    if grep -Fq 'classification=version_probe_shape_invalid' "$stderr_file"; then
        echo "FAIL: curl transport failure was misclassified as version_probe_shape_invalid" >&2
        exit 1
    fi
    assert_no_green_bundle "$evidence_root"
}

run_happy_path_live_case() {
    # Exercises the full non-dry-run path: refund -> readback -> postflight
    # -> GREEN bundle mint. Asserts the bundle is created, that raw Stripe
    # IDs from the owner stub do NOT appear in summary.json or SUMMARY.md,
    # and that [REDACTED] does appear in those fields.
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local owner_stub="$tmp_dir/live_card_e2e_test.sh"
    local curl_stub="$tmp_dir/curl"
    local shim_path="$tmp_dir/live_stripe_reverify_shim.sh"
    local stdout_file="$tmp_dir/stdout"
    local stderr_file="$tmp_dir/stderr"
    local evidence_root="$tmp_dir/evidence"
    local stripe_call_log="$tmp_dir/stripe_calls.log"

    make_owner_stub "$owner_stub"
    make_curl_stub "$curl_stub"
    make_stripe_shim "$shim_path"

    set +e
    PATH="$tmp_dir:$PATH" \
    LIVE_STRIPE_REVERIFY_ALLOW_TEST_SHIM=1 \
    LIVE_STRIPE_REVERIFY_TEST_SHIM="$shim_path" \
    LIVE_STRIPE_REVERIFY_OWNER_SCRIPT="$owner_stub" \
    LIVE_STRIPE_REVERIFY_EVIDENCE_ROOT="$evidence_root" \
    LIVE_STRIPE_REVERIFY_CURL_COUNTER_FILE="$tmp_dir/curl_counter" \
    LIVE_STRIPE_REVERIFY_CURL_MODE=stable \
    LIVE_STRIPE_REVERIFY_STRIPE_MODE=success \
    LIVE_STRIPE_REVERIFY_STRIPE_CALL_LOG="$stripe_call_log" \
    STRIPE_SECRET_KEY=sk_test_unit_test_key \
    /bin/bash "$RUNNER" --env=prod >"$stdout_file" 2>"$stderr_file"
    local rc=$?
    set -e

    assert_equals "$rc" "0" "happy_live_rc"

    local bundle_dir
    bundle_dir="$(ls -d "$evidence_root"/*_GREEN 2>/dev/null | head -n 1 || true)"
    if [ -z "$bundle_dir" ]; then
        echo "FAIL: happy live path did not mint a _GREEN bundle under $evidence_root" >&2
        cat "$stderr_file" >&2
        exit 1
    fi

    local summary_file="$bundle_dir/summary.json"
    local summary_md="$bundle_dir/SUMMARY.md"
    if [ ! -f "$summary_file" ] || [ ! -f "$summary_md" ]; then
        echo "FAIL: happy live bundle missing summary.json or SUMMARY.md ($bundle_dir)" >&2
        exit 1
    fi

    # Raw Stripe IDs from stubs (pi_unit_test, ch_unit_test, re_unit_test) must
    # NOT appear in publicly-synced bundle artifacts.
    assert_not_contains_file "$summary_file" "pi_unit_test" "bundle_summary_json_no_raw_pi"
    assert_not_contains_file "$summary_file" "ch_unit_test" "bundle_summary_json_no_raw_charge"
    assert_not_contains_file "$summary_file" "re_unit_test" "bundle_summary_json_no_raw_refund"
    assert_not_contains_file "$summary_md" "pi_unit_test" "bundle_summary_md_no_raw_pi"
    assert_not_contains_file "$summary_md" "ch_unit_test" "bundle_summary_md_no_raw_charge"
    assert_not_contains_file "$summary_md" "re_unit_test" "bundle_summary_md_no_raw_refund"

    # Positive assertion: redacted markers are present where the raw IDs were.
    assert_file_contains "$summary_file" '"payment_intent_id":"[REDACTED]"' "bundle_summary_json_has_redacted_pi"
    assert_file_contains "$summary_file" '"charge_id":"[REDACTED]"' "bundle_summary_json_has_redacted_charge"
    assert_file_contains "$summary_file" '"refund_id":"[REDACTED]"' "bundle_summary_json_has_redacted_refund"
    assert_file_contains "$stripe_call_log" 'POST /v1/refunds -d charge=ch_unit_test' "refund_uses_raw_charge_id"
}

if [ ! -f "$RUNNER" ]; then
    echo "FAIL: runner not found at $RUNNER" >&2
    exit 1
fi

if [ ! -x "$RUNNER" ]; then
    echo "FAIL: runner must be executable for canonical direct invocation: $RUNNER" >&2
    exit 1
fi

run_happy_path_dry_run_case
run_refund_failure_case
run_version_drift_case
run_version_probe_curl_failure_case
run_happy_path_live_case

echo "PASS: live_stripe_reverify dry-run tests succeeded"
