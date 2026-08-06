#!/usr/bin/env bash
# Red contract test for the Stage 2 evidence-tree secret hygiene guard.
#
# Stage 1 only pins the future guard entrypoint and known-answer behavior.
# It intentionally does not implement scripts/check_evidence_secret_hygiene.sh
# or wire it into scripts/local-ci.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAL_GUARD="$REPO_ROOT/scripts/check_evidence_secret_hygiene.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

fake_secret_value() {
    local prefix="$1" suffix="$2"
    printf '%s%s\n' "$prefix" "$suffix"
}

setup_fixture_repo() {
    local fixture_root="$1"
    mkdir -p "$fixture_root/scripts" "$fixture_root/docs/runbooks/evidence"
    if [ -f "$REAL_GUARD" ]; then
        ln -s "$REAL_GUARD" "$fixture_root/scripts/check_evidence_secret_hygiene.sh"
    fi
}

run_guard() {
    local fixture_root="$1"
    local stdout_file="$fixture_root/guard.stdout"
    local stderr_file="$fixture_root/guard.stderr"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$fixture_root" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin" \
        bash "$fixture_root/scripts/check_evidence_secret_hygiene.sh" \
        >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
    RUN_OUTPUT="$RUN_STDOUT$RUN_STDERR"
}

write_positive_leak_fixtures() {
    local fixture_root="$1"
    local aws_access_key browser_stripe_secret flapjack_secret stripe_secret webhook_secret txt_stripe_secret

    mkdir -p \
        "$fixture_root/docs/runbooks/evidence/browser-evidence/20260711-leaky" \
        "$fixture_root/docs/runbooks/evidence/stripe-rehearsal/20260711-leaky" \
        "$fixture_root/docs/runbooks/evidence/flapjack-live/20260711-leaky" \
        "$fixture_root/docs/runbooks/evidence/aws-canary/20260711-leaky" \
        "$fixture_root/docs/runbooks/evidence/announce-gate/20260711-leaky" \
        "$fixture_root/docs/runbooks/evidence/manual-notes/20260711-leaky"

    browser_stripe_secret="$(fake_secret_value "sk_live_" "HIDDENbyAllowlistButContainerMustFail")"
    stripe_secret="$(fake_secret_value "sk_live_" "STAGE1hygieneFakeSecret123456789")"
    flapjack_secret="$(fake_secret_value "fj_live_" "0123456789abcdef0123456789abcdef")"
    webhook_secret="$(fake_secret_value "whsec_" "STAGE1hygieneFakeWebhook123456789")"
    txt_stripe_secret="$(fake_secret_value "sk_live_" "STAGE1txtLeakFakeSecret123456789")"
    aws_access_key="$(fake_secret_value "AKIA" "1234567890ABCDEF")"

    cat > "$fixture_root/docs/runbooks/evidence/browser-evidence/20260711-leaky/setup.json" <<JSON
{
  "config": {
    "webServer": {
      "command": "npm run dev",
      "env": {
        "ADMIN_KEY": "admin_stage1_hygiene_fixture_secret",
        "STRIPE_SECRET_KEY": "$browser_stripe_secret"
      }
    }
  },
  "status": "failed"
}
JSON

    cat > "$fixture_root/docs/runbooks/evidence/stripe-rehearsal/20260711-leaky/raw_event.json" <<JSON
{
  "source": "stripe",
  "api_key": "$stripe_secret"
}
JSON

    cat > "$fixture_root/docs/runbooks/evidence/flapjack-live/20260711-leaky/node_key.txt" <<TXT
node_api_key=$flapjack_secret
TXT

    cat > "$fixture_root/docs/runbooks/evidence/aws-canary/20260711-leaky/session.txt" <<TXT
aws_access_key_id=$aws_access_key
TXT

    cat > "$fixture_root/docs/runbooks/evidence/announce-gate/20260711-leaky/webhook.json" <<JSON
{
  "webhook_secret": "$webhook_secret"
}
JSON

    cat > "$fixture_root/docs/runbooks/evidence/manual-notes/20260711-leaky/operator_notes.txt" <<TXT
The blanket docs/runbooks/evidence/.*\.(md|txt)$ gitleaks allowlist must not hide $txt_stripe_secret.
TXT
}

write_allowlisted_non_secret_fixtures() {
    local fixture_root="$1"

    mkdir -p \
        "$fixture_root/docs/runbooks/evidence/fingerprint/20260711-allowed" \
        "$fixture_root/docs/runbooks/evidence/announce-gate/20260711-allowed" \
        "$fixture_root/docs/runbooks/evidence/ses-inbox-canary-clean-env/20260711-allowed" \
        "$fixture_root/docs/runbooks/evidence/browser-evidence/20260711-allowed"

    cat > "$fixture_root/docs/runbooks/evidence/fingerprint/20260711-allowed/stripe_key_fingerprint.txt" <<'TXT'
sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
TXT

    cat > "$fixture_root/docs/runbooks/evidence/announce-gate/20260711-allowed/stripe_latest_event.json" <<'JSON'
{
  "id": "evt_stage1_allowed",
  "request": {
    "idempotency_key": "stage1-non-secret-idempotency-token-0123456789abcdef"
  }
}
JSON

    cat > "$fixture_root/docs/runbooks/evidence/ses-inbox-canary-clean-env/20260711-allowed/customer_loop_events_001.json" <<'JSON'
{
  "nextForwardToken": "f/0123456789abcdef0123456789abcdef",
  "events": []
}
JSON

    cat > "$fixture_root/docs/runbooks/evidence/browser-evidence/20260711-allowed/setup.json" <<'JSON'
{
  "config": {
    "webServer": {
      "command": "npm run dev",
      "url": "http://127.0.0.1:4173"
    }
  },
  "status": "passed"
}
JSON
}

write_allowlisted_secret_fixtures() {
    local fixture_root="$1"
    local fingerprint_access_key stripe_secret webhook_secret ses_stripe_secret ses_webhook_secret ses_access_key

    mkdir -p \
        "$fixture_root/docs/runbooks/evidence/fingerprint" \
        "$fixture_root/docs/runbooks/evidence/announce-gate/20260711-allowed" \
        "$fixture_root/docs/runbooks/evidence/ses-inbox-canary-clean-env/20260711-allowed"

    fingerprint_access_key="$(fake_secret_value "AKIA" "ALLOWLISTBUG1234")"
    stripe_secret="$(fake_secret_value "sk_live_" "ALLOWLISTBUG123456789")"
    webhook_secret="$(fake_secret_value "whsec_" "ALLOWLISTBUG123456789")"
    ses_stripe_secret="$(fake_secret_value "sk_live_" "ALLOWLISTBUGses123456789")"
    ses_webhook_secret="$(fake_secret_value "whsec_" "ALLOWLISTBUGses123456789")"
    ses_access_key="$(fake_secret_value "AKIA" "ALLOWLISTSES1234")"

    cat > "$fixture_root/docs/runbooks/evidence/fingerprint/stripe_key_fingerprint.txt" <<TXT
aws_access_key_id=$fingerprint_access_key
TXT

    cat > "$fixture_root/docs/runbooks/evidence/announce-gate/20260711-allowed/stripe_latest_event.json" <<JSON
{
  "api_key": "$stripe_secret",
  "webhook_secret": "$webhook_secret"
}
JSON

    cat > "$fixture_root/docs/runbooks/evidence/ses-inbox-canary-clean-env/20260711-allowed/customer_loop_events_001.json" <<JSON
{
  "message": "$ses_stripe_secret",
  "webhook": "$ses_webhook_secret",
  "aws_access_key_id": "$ses_access_key"
}
JSON
}

test_guard_reports_all_seeded_findings_without_exfiltrating_values() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN
    setup_fixture_repo "$fixture_root"
    write_positive_leak_fixtures "$fixture_root"
    write_allowlisted_non_secret_fixtures "$fixture_root"

    run_guard "$fixture_root"

    assert_ne "$RUN_EXIT_CODE" "0" \
        "guard exits non-zero when evidence leaks are present"

    assert_contains "$RUN_OUTPUT" "docs/runbooks/evidence/browser-evidence/20260711-leaky/setup.json" \
        "guard output names Playwright setup evidence path"
    assert_contains "$RUN_OUTPUT" "playwright_web_server_env" \
        "guard output names Playwright webServer.env pattern class"
    assert_contains "$RUN_OUTPUT" "docs/runbooks/evidence/stripe-rehearsal/20260711-leaky/raw_event.json" \
        "guard output names sk_live evidence path"
    assert_contains "$RUN_OUTPUT" "stripe_live_secret" \
        "guard output names sk_live pattern class"
    assert_contains "$RUN_OUTPUT" "docs/runbooks/evidence/flapjack-live/20260711-leaky/node_key.txt" \
        "guard output names fj_live evidence path"
    assert_contains "$RUN_OUTPUT" "flapjack_live_secret" \
        "guard output names fj_live pattern class"
    assert_contains "$RUN_OUTPUT" "docs/runbooks/evidence/aws-canary/20260711-leaky/session.txt" \
        "guard output names AKIA evidence path despite blanket txt allowlist"
    assert_contains "$RUN_OUTPUT" "aws_access_key_id" \
        "guard output names AKIA pattern class"
    assert_contains "$RUN_OUTPUT" "docs/runbooks/evidence/announce-gate/20260711-leaky/webhook.json" \
        "guard output names whsec evidence path"
    assert_contains "$RUN_OUTPUT" "stripe_webhook_secret" \
        "guard output names whsec pattern class"
    assert_contains "$RUN_OUTPUT" "docs/runbooks/evidence/manual-notes/20260711-leaky/operator_notes.txt" \
        "guard output names txt leak path and does not inherit blanket evidence txt allowlist"

    assert_not_contains "$RUN_OUTPUT" "$(fake_secret_value "sk_live_" "HIDDENbyAllowlistButContainerMustFail")" \
        "guard diagnostic does not print full Playwright fixture secret"
    assert_not_contains "$RUN_OUTPUT" "$(fake_secret_value "sk_live_" "STAGE1hygieneFakeSecret123456789")" \
        "guard diagnostic does not print full sk_live fixture secret"
    assert_not_contains "$RUN_OUTPUT" "$(fake_secret_value "fj_live_" "0123456789abcdef0123456789abcdef")" \
        "guard diagnostic does not print full fj_live fixture secret"
    assert_not_contains "$RUN_OUTPUT" "$(fake_secret_value "AKIA" "1234567890ABCDEF")" \
        "guard diagnostic does not print full AKIA fixture secret"
    assert_not_contains "$RUN_OUTPUT" "$(fake_secret_value "whsec_" "STAGE1hygieneFakeWebhook123456789")" \
        "guard diagnostic does not print full whsec fixture secret"
    assert_not_contains "$RUN_OUTPUT" "$(fake_secret_value "sk_live_" "STAGE1txtLeakFakeSecret123456789")" \
        "guard diagnostic does not print full txt fixture secret"
}

test_guard_preserves_narrow_non_secret_evidence_exceptions() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN
    setup_fixture_repo "$fixture_root"
    write_allowlisted_non_secret_fixtures "$fixture_root"

    run_guard "$fixture_root"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "guard exits 0 for narrow non-secret evidence exceptions"
    assert_not_contains "$RUN_OUTPUT" "docs/runbooks/evidence/fingerprint/20260711-allowed/stripe_key_fingerprint.txt" \
        "guard preserves stripe_key_fingerprint.txt exception"
    assert_not_contains "$RUN_OUTPUT" "docs/runbooks/evidence/announce-gate/20260711-allowed/stripe_latest_event.json" \
        "guard preserves announce-gate stripe_latest_event.json exception"
    assert_not_contains "$RUN_OUTPUT" "docs/runbooks/evidence/ses-inbox-canary-clean-env/20260711-allowed/customer_loop_events_001.json" \
        "guard preserves SES customer_loop_events exception"
    assert_not_contains "$RUN_OUTPUT" "docs/runbooks/evidence/browser-evidence/20260711-allowed/setup.json" \
        "guard preserves harmless browser-evidence setup.json exception"
}

test_guard_reports_real_secret_classes_inside_exception_paths() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN
    setup_fixture_repo "$fixture_root"
    write_allowlisted_secret_fixtures "$fixture_root"

    run_guard "$fixture_root"

    assert_ne "$RUN_EXIT_CODE" "0" \
        "guard exits non-zero when exception paths contain real secret classes"
    assert_contains "$RUN_OUTPUT" "docs/runbooks/evidence/fingerprint/stripe_key_fingerprint.txt" \
        "guard output names allowlisted fingerprint path when it contains AKIA"
    assert_contains "$RUN_OUTPUT" "aws_access_key_id" \
        "guard output names AKIA class inside exception paths"
    assert_contains "$RUN_OUTPUT" "docs/runbooks/evidence/announce-gate/20260711-allowed/stripe_latest_event.json" \
        "guard output names allowlisted announce-gate path when it contains secrets"
    assert_contains "$RUN_OUTPUT" "stripe_live_secret" \
        "guard output names sk_live class inside exception paths"
    assert_contains "$RUN_OUTPUT" "stripe_webhook_secret" \
        "guard output names whsec class inside exception paths"
    assert_contains "$RUN_OUTPUT" "docs/runbooks/evidence/ses-inbox-canary-clean-env/20260711-allowed/customer_loop_events_001.json" \
        "guard output names allowlisted SES path when it contains secrets"

    assert_not_contains "$RUN_OUTPUT" "$(fake_secret_value "AKIA" "ALLOWLISTBUG1234")" \
        "guard diagnostic does not print full allowlisted-path AKIA fixture secret"
    assert_not_contains "$RUN_OUTPUT" "$(fake_secret_value "sk_live_" "ALLOWLISTBUG123456789")" \
        "guard diagnostic does not print full allowlisted-path sk_live fixture secret"
    assert_not_contains "$RUN_OUTPUT" "$(fake_secret_value "whsec_" "ALLOWLISTBUG123456789")" \
        "guard diagnostic does not print full allowlisted-path whsec fixture secret"
    assert_not_contains "$RUN_OUTPUT" "$(fake_secret_value "sk_live_" "ALLOWLISTBUGses123456789")" \
        "guard diagnostic does not print full SES sk_live fixture secret"
    assert_not_contains "$RUN_OUTPUT" "$(fake_secret_value "whsec_" "ALLOWLISTBUGses123456789")" \
        "guard diagnostic does not print full SES whsec fixture secret"
    assert_not_contains "$RUN_OUTPUT" "$(fake_secret_value "AKIA" "ALLOWLISTSES1234")" \
        "guard diagnostic does not print full SES AKIA fixture secret"
}

test_guard_fails_closed_on_malformed_playwright_reporter_json() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN
    setup_fixture_repo "$fixture_root"

    mkdir -p "$fixture_root/docs/runbooks/evidence/browser-evidence/20260711-malformed"
    local malformed_secret
    malformed_secret="$(fake_secret_value "sk_live_" "MalformedFixtureMustNotPrint123456789")"
    cat > "$fixture_root/docs/runbooks/evidence/browser-evidence/20260711-malformed/report.json" <<JSON
{
  "config": {
    "webServer": {
      "env": {
        "STRIPE_SECRET_KEY": "$malformed_secret"
      }
    }
  },
JSON

    run_guard "$fixture_root"

    assert_ne "$RUN_EXIT_CODE" "0" \
        "guard exits non-zero when Playwright reporter JSON cannot be parsed"
    assert_contains "$RUN_OUTPUT" "docs/runbooks/evidence/browser-evidence/20260711-malformed/report.json" \
        "guard output names malformed Playwright reporter path"
    assert_contains "$RUN_OUTPUT" "playwright_json_parse_error" \
        "guard output names malformed Playwright reporter class"
    assert_not_contains "$RUN_OUTPUT" "$malformed_secret" \
        "guard diagnostic does not print malformed reporter secret"
}

test_guard_fails_closed_on_playwright_reporter_truncated_before_env() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN
    setup_fixture_repo "$fixture_root"

    mkdir -p "$fixture_root/docs/runbooks/evidence/browser-evidence/20260711-truncated"
    cat > "$fixture_root/docs/runbooks/evidence/browser-evidence/20260711-truncated/report.json" <<'JSON'
{
  "config": {
    "webServer":
JSON

    run_guard "$fixture_root"

    assert_ne "$RUN_EXIT_CODE" "0" \
        "guard exits non-zero when a Playwright reporter is truncated before env"
    assert_contains "$RUN_OUTPUT" "docs/runbooks/evidence/browser-evidence/20260711-truncated/report.json" \
        "guard output names Playwright reporter truncated before env"
    assert_contains "$RUN_OUTPUT" "playwright_json_parse_error" \
        "guard output names parse-error class for reporter truncated before env"
}

main() {
    echo "=== check_evidence_secret_hygiene_test.sh ==="
    echo ""

    if [ ! -f "$REAL_GUARD" ]; then
        fail "Stage 2 guard exists at scripts/check_evidence_secret_hygiene.sh"
    fi

    test_guard_reports_all_seeded_findings_without_exfiltrating_values
    test_guard_preserves_narrow_non_secret_evidence_exceptions
    test_guard_reports_real_secret_classes_inside_exception_paths
    test_guard_fails_closed_on_malformed_playwright_reporter_json
    test_guard_fails_closed_on_playwright_reporter_truncated_before_env

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
