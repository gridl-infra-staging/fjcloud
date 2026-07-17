#!/usr/bin/env bash
# Red contract test for the Stage 2 Playwright JSON evidence redactor.
#
# scripts/verify/rerun_failing_lanes.sh currently writes Playwright
# `--reporter=json` output directly to:
#   $EVIDENCE_DIR/rerun_${LANE_LETTER}_${attempt}.json
# Stage 1 only pins the future helper contract. It does not modify the rerun
# driver or implement scripts/lib/redact_playwright_json.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAL_REDACTOR="$REPO_ROOT/scripts/lib/redact_playwright_json.sh"
RERUN_DRIVER="$REPO_ROOT/scripts/verify/rerun_failing_lanes.sh"

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
    mkdir -p "$fixture_root/scripts/lib" "$fixture_root/evidence"
    if [ -f "$REAL_REDACTOR" ]; then
        ln -s "$REAL_REDACTOR" "$fixture_root/scripts/lib/redact_playwright_json.sh"
    fi
}

run_redactor() {
    local fixture_root="$1" input_json="$2" output_json="$3"
    local stdout_file="$fixture_root/redactor.stdout"
    local stderr_file="$fixture_root/redactor.stderr"

    RUN_EXIT_CODE=0
    (
        cd "$fixture_root"
        env -i \
            HOME="$fixture_root" \
            PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin" \
            bash scripts/lib/redact_playwright_json.sh "$input_json" "$output_json"
    ) >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

write_secret_reporter_fixture() {
    local path="$1"
    local aws_access_key stripe_secret webhook_secret github_token bearer_token
    aws_access_key="$(fake_secret_value "AKIA" "1234567890ABCDEF")"
    stripe_secret="$(fake_secret_value "sk_live_" "FAKEstage1redcontract1234567890")"
    webhook_secret="$(fake_secret_value "whsec_" "FAKEstage1redcontract1234567890")"
    github_token="$(fake_secret_value "ghp_" "FAKEstage1redcontract1234567890abcd")"
    bearer_token="Bearer $(fake_secret_value "ghp_" "FAKEbearerredcontract1234567890")"
    cat > "$path" <<JSON
{
  "config": {
    "configFile": "/repo/web/playwright.config.ts",
    "webServer": {
      "command": "npm run dev",
      "url": "http://127.0.0.1:4173",
      "env": {
        "AWS_ACCESS_KEY_ID": "$aws_access_key",
        "STRIPE_SECRET_KEY": "$stripe_secret",
        "STRIPE_WEBHOOK_SECRET": "$webhook_secret",
        "ADMIN_KEY": "admin_stage1_fixture_secret_123456",
        "JWT_SECRET": "jwt_stage1_fixture_secret_abcdef",
        "NPM_AUTH_TOKEN": "$github_token",
        "FLAPJACK_ADMIN_KEY": "$bearer_token"
      }
    },
    "metadata": {
      "lane": "b",
      "attempt": 1
    }
  },
  "suites": [
    {
      "title": "polished beta staging verify",
      "specs": [
        {
          "title": "lane b captures evidence",
          "ok": false,
          "tests": [
            {
              "projectName": "chromium",
              "status": "unexpected",
              "results": [
                {
                  "status": "failed",
                  "duration": 1234,
                  "error": {
                    "message": "fixture failure survived redaction"
                  }
                }
              ]
            }
          ]
        }
      ]
    }
  ],
  "errors": []
}
JSON
}

write_harmless_reporter_fixture() {
    local path="$1"
    cat > "$path" <<'JSON'
{
  "config": {
    "configFile": "/repo/web/playwright.config.ts",
    "webServer": {
      "command": "npm run dev",
      "url": "http://127.0.0.1:4173",
      "reuseExistingServer": false
    },
    "metadata": {
      "lane": "negative-control"
    }
  },
  "suites": [
    {
      "title": "safe suite",
      "specs": [
        {
          "title": "safe spec",
          "ok": true,
          "tests": [
            {
              "projectName": "chromium",
              "status": "expected",
              "results": [
                {
                  "status": "passed",
                  "duration": 17
                }
              ]
            }
          ]
        }
      ]
    }
  ],
  "errors": []
}
JSON
}

assert_jq_filter_true() {
    local json_path="$1" filter="$2" msg="$3"
    if jq -e "$filter" "$json_path" >/dev/null; then
        pass "$msg"
    else
        fail "$msg (jq filter failed: $filter)"
    fi
}

assert_jq_string_eq() {
    local json_path="$1" filter="$2" expected="$3" msg="$4"
    local actual
    actual="$(jq -r "$filter" "$json_path" 2>/dev/null || true)"
    assert_eq "$actual" "$expected" "$msg"
}

test_redacts_web_server_env_container_and_preserves_reporter_fields() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN
    setup_fixture_repo "$fixture_root"

    local input_json="$fixture_root/evidence/rerun_b_1.json"
    local output_json="$fixture_root/evidence/rerun_b_1.redacted.json"
    write_secret_reporter_fixture "$input_json"

    run_redactor "$fixture_root" "$input_json" "$output_json"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "redactor exits 0 for valid Playwright reporter JSON"
    assert_file_exists "$output_json" \
        "redactor writes an output JSON file"

    if [ -f "$output_json" ]; then
        if jq empty "$output_json" >/dev/null 2>&1; then
            pass "redacted output remains valid JSON"
        else
            fail "redacted output remains valid JSON"
        fi

        assert_jq_filter_true "$output_json" '(.config.webServer | has("env") | not)' \
            "redactor deletes .config.webServer.env as a whole container"
        assert_jq_string_eq "$output_json" '.config.webServer.command' "npm run dev" \
            "redactor preserves non-secret webServer command"
        assert_jq_string_eq "$output_json" '.config.metadata.lane' "b" \
            "redactor preserves config metadata"
        assert_jq_string_eq "$output_json" '.suites[0].specs[0].tests[0].results[0].error.message' \
            "fixture failure survived redaction" \
            "redactor preserves reporter failure details"

        local output_content
        local stripe_secret webhook_secret aws_access_key github_token bearer_token
        output_content="$(cat "$output_json")"
        stripe_secret="$(fake_secret_value "sk_live_" "FAKEstage1redcontract1234567890")"
        webhook_secret="$(fake_secret_value "whsec_" "FAKEstage1redcontract1234567890")"
        aws_access_key="$(fake_secret_value "AKIA" "1234567890ABCDEF")"
        github_token="$(fake_secret_value "ghp_" "FAKEstage1redcontract1234567890abcd")"
        bearer_token="Bearer $(fake_secret_value "ghp_" "FAKEbearerredcontract1234567890")"
        assert_not_contains "$output_content" "$stripe_secret" \
            "redacted output omits raw sk_live-shaped value"
        assert_not_contains "$output_content" "$webhook_secret" \
            "redacted output omits raw whsec-shaped value"
        assert_not_contains "$output_content" "$aws_access_key" \
            "redacted output omits raw AKIA-shaped value"
        assert_not_contains "$output_content" "$github_token" \
            "redacted output omits raw GitHub-token-shaped value"
        assert_not_contains "$output_content" "$bearer_token" \
            "redacted output omits raw bearer-token-shaped value"
        assert_not_contains "$output_content" "admin_stage1_fixture_secret_123456" \
            "redacted output omits raw admin secret"
        assert_not_contains "$output_content" "jwt_stage1_fixture_secret_abcdef" \
            "redacted output omits raw JWT secret"
    fi
}

test_malformed_json_fails_without_pass_through_output() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN
    setup_fixture_repo "$fixture_root"

    local input_json="$fixture_root/evidence/malformed.json"
    local output_json="$fixture_root/evidence/malformed.redacted.json"
    printf '{"config": {"webServer": {"env": {"ADMIN_KEY": "admin_stage1_fixture_secret_123456"}}}\n' > "$input_json"

    run_redactor "$fixture_root" "$input_json" "$output_json"

    assert_ne "$RUN_EXIT_CODE" "0" \
        "redactor exits non-zero for malformed JSON"
    if [ ! -e "$output_json" ]; then
        pass "malformed JSON does not produce an output file"
    elif cmp -s "$input_json" "$output_json"; then
        fail "malformed JSON must not be silently passed through to output"
    else
        pass "malformed JSON output is not a silent pass-through copy"
    fi
}

test_harmless_reporter_json_is_preserved_field_for_field() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN
    setup_fixture_repo "$fixture_root"

    local input_json="$fixture_root/evidence/harmless.json"
    local output_json="$fixture_root/evidence/harmless.redacted.json"
    local expected_json="$fixture_root/evidence/harmless.expected.json"
    local actual_json="$fixture_root/evidence/harmless.actual.json"
    write_harmless_reporter_fixture "$input_json"

    run_redactor "$fixture_root" "$input_json" "$output_json"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "redactor exits 0 for harmless reporter JSON without webServer.env"
    assert_file_exists "$output_json" \
        "redactor writes harmless reporter output"

    if [ -f "$output_json" ]; then
        jq -S . "$input_json" > "$expected_json"
        if jq -S . "$output_json" > "$actual_json"; then
            pass "harmless reporter output is valid JSON for normalized compare"
            if cmp -s "$expected_json" "$actual_json"; then
                pass "harmless reporter structure is preserved field-for-field"
            else
                fail "harmless reporter structure is preserved field-for-field"
            fi
        else
            fail "harmless reporter output is valid JSON for normalized compare"
        fi
    fi
}

test_rerun_raw_reporter_temp_file_template_randomizes() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN

    local assignment
    assignment="$(grep 'RAW_RERUN_FILE="$(mktemp ' "$RERUN_DRIVER")"
    assert_contains "$assignment" 'RAW_RERUN_FILE="$(mktemp ' \
        "rerun driver still owns raw reporter mktemp allocation"

    local first_path second_path first_rc second_rc
    local LANE_LETTER="B" attempt="1" TMPDIR="$fixture_root"

    set +e
    RAW_RERUN_FILE=""
    eval "$assignment"
    first_rc=$?
    first_path="$RAW_RERUN_FILE"
    RAW_RERUN_FILE=""
    eval "$assignment"
    second_rc=$?
    second_path="$RAW_RERUN_FILE"
    set -e

    rm -f "$first_path" "$second_path"

    assert_eq "$first_rc" "0" \
        "raw reporter temp allocation succeeds on first call"
    assert_eq "$second_rc" "0" \
        "raw reporter temp allocation succeeds on repeated same-lane call"
    assert_ne "$first_path" "$second_path" \
        "raw reporter temp allocation randomizes repeated same-lane paths"
    assert_not_contains "$first_path$second_path" "XXXXXX" \
        "raw reporter temp allocation does not leave literal template markers"
}

main() {
    echo "=== redact_playwright_json_test.sh ==="
    echo ""

    if ! command -v jq >/dev/null 2>&1; then
        fail "jq is available for JSON contract assertions"
        echo ""
        echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
        exit 1
    fi

    if [ ! -f "$REAL_REDACTOR" ]; then
        fail "Stage 2 redactor exists at scripts/lib/redact_playwright_json.sh"
    fi

    test_redacts_web_server_env_container_and_preserves_reporter_fields
    test_malformed_json_fails_without_pass_through_output
    test_harmless_reporter_json_is_preserved_field_for_field
    test_rerun_raw_reporter_temp_file_template_randomizes

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
