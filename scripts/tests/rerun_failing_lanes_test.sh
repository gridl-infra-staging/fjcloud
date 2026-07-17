#!/usr/bin/env bash
# Red contract test for scripts/verify/rerun_failing_lanes.sh setup-failure guard
# and credential hydration.
#
# Prevents the 2026-07-06 regression where the driver misclassified harness
# failures (missing E2E_ADMIN_KEY, empty Playwright reporter output) as
# `real_bug` verdicts. The three tests below assert:
#   1. Missing ADMIN_KEY after hydration exits 78 (EX_CONFIG) before any
#      Playwright invocation.
#   2. Successful hydration exports E2E_ADMIN_KEY into the runner env.
#   3. Empty reporter output + non-zero runner exit classifies as
#      setup_failure and exits 78 rather than writing `real_bug`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DRIVER_SCRIPT="$REPO_ROOT/scripts/verify/rerun_failing_lanes.sh"
HYDRATE_LIB="$REPO_ROOT/scripts/lib/hydrate_staging_env.sh"

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
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

setup_fixture_repo() {
    local fixture_root="$1"
    mkdir -p "$fixture_root/scripts/verify" \
             "$fixture_root/scripts/lib" \
             "$fixture_root/scripts/launch" \
             "$fixture_root/web/tests/e2e-ui/full" \
             "$fixture_root/evidence"

    ln -s "$DRIVER_SCRIPT" "$fixture_root/scripts/verify/rerun_failing_lanes.sh"
    ln -s "$HYDRATE_LIB"  "$fixture_root/scripts/lib/hydrate_staging_env.sh"

    # The driver cd's into $REPO_ROOT/web before invoking the runner.
    # The spec file only needs to exist so grep-title tooling doesn't tripwire;
    # our mock runner ignores its argv anyway.
    touch "$fixture_root/web/tests/e2e-ui/full/polished_beta_staging_verify.spec.ts"

    cat > "$fixture_root/evidence/lane_verdicts_first_pass.json" <<'JSON'
{
  "lane_count": 2,
  "non_passed_count": 1,
  "passed_count": 1,
  "lanes": [
    {"lane": "a", "title": "polished_beta_staging_verify.spec.ts › group › lane a passing", "raw_status": "passed"},
    {"lane": "b", "title": "polished_beta_staging_verify.spec.ts › group › lane b failing", "raw_status": "failed"}
  ]
}
JSON
}

write_hydrate_mock() {
    # Mock hydrate_seeder_env_from_ssm.sh. Behavior controlled by
    # MOCK_HYDRATE_ADMIN_KEY: when set, emits a valid export line;
    # when unset/empty, emits nothing (simulating an SSM outage).
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${MOCK_HYDRATE_ADMIN_KEY:-}" ]; then
  printf 'export ADMIN_KEY=%s\n' "$MOCK_HYDRATE_ADMIN_KEY"
fi
MOCK
    chmod +x "$path"
}

write_runner_mock() {
    # Mock Playwright runner. Records the incoming E2E_ADMIN_KEY to
    # $MOCK_RUNNER_ENV_LOG and emits behavior controlled by env vars:
    #   MOCK_RUNNER_EMPTY_OUTPUT=1 → emit nothing
    #   MOCK_RUNNER_STDERR_TEXT  → emit text to stderr
    #   MOCK_RUNNER_FAILING_JSON=1 → emit a structured failing reporter
    #   MOCK_RUNNER_SETUP_TIMEOUT_SKIPPED_JSON=1 → emit setup timeout + skipped target reporter
    #   MOCK_RUNNER_EXECUTED_TIMEOUT_JSON=1 → emit green setup + executed failing target reporter
    #   MOCK_RUNNER_EXIT_CODE      → override exit code (default 0)
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${MOCK_RUNNER_ENV_LOG:-}" ]; then
  printf 'E2E_ADMIN_KEY=%s\n' "${E2E_ADMIN_KEY:-<unset>}" >> "$MOCK_RUNNER_ENV_LOG"
fi
if [ -n "${MOCK_RUNNER_STDERR_TEXT:-}" ]; then
  printf '%s\n' "$MOCK_RUNNER_STDERR_TEXT" >&2
fi
if [ -z "${MOCK_RUNNER_EMPTY_OUTPUT:-}" ]; then
  if [ -n "${MOCK_RUNNER_SETUP_TIMEOUT_SKIPPED_JSON:-}" ]; then
    cat <<'JSON'
{
  "suites": [
    {
      "specs": [
        {
          "title": "authenticate as customer",
          "tests": [
            {
              "projectId": "setup:user",
              "projectName": "setup:user",
              "results": [
                {
                  "status": "timedOut",
                  "error": {
                    "message": "Test timeout of 220000ms exceeded."
                  },
                  "errors": [
                    {
                      "message": "Test timeout of 220000ms exceeded."
                    },
                    {
                      "message": "Error: Customer login setup failed before reaching /console. Current URL: https://cloud.staging.flapjack.foo/login\nAPI URL: https://api.staging.flapjack.foo\nAdmin key fingerprint: (present, len=32)\nVisible alert text: (none)\nLogin response: (none observed)"
                    }
                  ]
                }
              ],
              "status": "unexpected"
            }
          ]
        }
      ]
    },
    {
      "suites": [
        {
          "specs": [
            {
              "title": "lane b failing",
              "tests": [
                {
                  "projectId": "chromium",
                  "projectName": "chromium",
                  "results": [
                    {
                      "status": "skipped"
                    }
                  ],
                  "status": "skipped"
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
  elif [ -n "${MOCK_RUNNER_EXECUTED_TIMEOUT_JSON:-}" ]; then
    cat <<'JSON'
{
  "suites": [
    {
      "specs": [
        {
          "title": "authenticate as customer",
          "tests": [
            {
              "projectId": "setup:user",
              "projectName": "setup:user",
              "results": [
                {
                  "status": "passed"
                }
              ],
              "status": "expected"
            }
          ]
        }
      ]
    },
    {
      "suites": [
        {
          "specs": [
            {
              "title": "lane b failing",
              "tests": [
                {
                  "projectId": "chromium",
                  "projectName": "chromium",
                  "results": [
                    {
                      "status": "failed",
                      "error": {
                        "message": "Timeout 30000ms exceeded while waiting for unrelated account data"
                      }
                    }
                  ],
                  "status": "unexpected"
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
  elif [ -n "${MOCK_RUNNER_FAILING_JSON:-}" ]; then
    cat <<'JSON'
{"suites":[{"suites":[{"specs":[{"tests":[{"results":[{"status":"failed","error":{"message":"fixture setup failed"}}]}]}]}]}],"errors":[]}
JSON
  else
    cat <<'JSON'
{"suites":[{"suites":[{"specs":[{"tests":[{"results":[{"status":"passed"}]}]}]}]}],"errors":[]}
JSON
  fi
fi
exit "${MOCK_RUNNER_EXIT_CODE:-0}"
MOCK
    chmod +x "$path"
}

write_sleep_mock() {
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_SLEEP_LOG:?MOCK_SLEEP_LOG must be set}"
MOCK
    chmod +x "$path"
}

run_driver() {
    # Executes the driver with a controlled env. All caller vars flow via
    # `env -i` so ambient developer creds cannot leak into the harness.
    local fixture_root="$1"; shift
    local stdout_file="$fixture_root/driver.stdout"
    local stderr_file="$fixture_root/driver.stderr"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$fixture_root" \
        PATH="$fixture_root/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin" \
        EVIDENCE_DIR="$fixture_root/evidence" \
        "$@" \
        bash "$fixture_root/scripts/verify/rerun_failing_lanes.sh" \
        >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

test_auth_429_setup_failure_exits_config() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN

    setup_fixture_repo "$fixture_root"
    write_hydrate_mock "$fixture_root/scripts/launch/hydrate_seeder_env_from_ssm.sh"
    write_runner_mock  "$fixture_root/mock_runner"

    local auth_429_message
    auth_429_message=$'Customer login setup failed before reaching /console. Current URL: https://cloud.staging.flapjack.foo/login\nAPI URL: https://api.staging.flapjack.foo\nAdmin key fingerprint: (present, len=23)\nVisible alert text: staging API verify-email failed: exhausted retries after 429 rate limiting\nLogin response: status 429 at https://api.staging.flapjack.foo/auth/login\nRemediation: Run scripts/bootstrap-env-local.sh to bootstrap .env.local'

    run_driver "$fixture_root" \
        "PLAYWRIGHT_RUNNER=$fixture_root/mock_runner" \
        "MOCK_HYDRATE_ADMIN_KEY=synthetic-admin-key-xyz" \
        "MOCK_RUNNER_FAILING_JSON=1" \
        "MOCK_RUNNER_EXIT_CODE=1" \
        "MOCK_RUNNER_STDERR_TEXT=$auth_429_message"

    assert_eq "$RUN_EXIT_CODE" "78" \
        "auth setup 429 exhaustion exits 78 instead of classifying a product bug"
    assert_contains "$RUN_STDERR" "RERUN_INFRA_ERROR" \
        "stderr marks auth setup 429 exhaustion as rerun infrastructure"
    assert_contains "$RUN_STDERR" "setup_failure" \
        "stderr names setup_failure for auth setup 429 exhaustion"
    assert_contains "$RUN_STDERR" "429" \
        "stderr preserves the 429 diagnostic"

    if [ -f "$fixture_root/evidence/rerun_verdicts.json" ]; then
        if grep -q '"classification": "real_bug"' "$fixture_root/evidence/rerun_verdicts.json"; then
            fail "auth setup 429 exhaustion must not be classified as real_bug"
        else
            pass "auth setup 429 exhaustion not written as real_bug verdict"
        fi
    else
        pass "no rerun_verdicts.json written when auth setup 429 exits"
    fi
}

test_register_429_setup_failure_exits_config() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN

    setup_fixture_repo "$fixture_root"
    write_hydrate_mock "$fixture_root/scripts/launch/hydrate_seeder_env_from_ssm.sh"
    write_runner_mock  "$fixture_root/mock_runner"

    local register_429_message
    register_429_message='createUser failed: exhausted retries after 429 rate limiting'

    run_driver "$fixture_root" \
        "PLAYWRIGHT_RUNNER=$fixture_root/mock_runner" \
        "MOCK_HYDRATE_ADMIN_KEY=synthetic-admin-key-xyz" \
        "MOCK_RUNNER_FAILING_JSON=1" \
        "MOCK_RUNNER_EXIT_CODE=1" \
        "MOCK_RUNNER_STDERR_TEXT=$register_429_message"

    assert_eq "$RUN_EXIT_CODE" "78" \
        "register setup 429 exhaustion exits 78 instead of classifying a product bug"
    assert_contains "$RUN_STDERR" "setup_failure" \
        "stderr names setup_failure for register setup 429 exhaustion"
    assert_contains "$RUN_STDERR" "429" \
        "stderr preserves the register 429 diagnostic"

    if [ -f "$fixture_root/evidence/rerun_verdicts.json" ]; then
        if grep -q '"classification": "real_bug"' "$fixture_root/evidence/rerun_verdicts.json"; then
            fail "register setup 429 exhaustion must not be classified as real_bug"
        else
            pass "register setup 429 exhaustion not written as real_bug verdict"
        fi
    else
        pass "no rerun_verdicts.json written when register setup 429 exits"
    fi
}

test_auth_route_too_many_requests_setup_failure_exits_config() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN

    setup_fixture_repo "$fixture_root"
    write_hydrate_mock "$fixture_root/scripts/launch/hydrate_seeder_env_from_ssm.sh"
    write_runner_mock  "$fixture_root/mock_runner"

    local auth_route_message
    auth_route_message=$'Customer login setup failed before reaching /console. Current URL: https://cloud.staging.flapjack.foo/login\nVisible alert text: too many requests\nLogin response: too many requests at https://api.staging.flapjack.foo/auth/verify-email'

    run_driver "$fixture_root" \
        "PLAYWRIGHT_RUNNER=$fixture_root/mock_runner" \
        "MOCK_HYDRATE_ADMIN_KEY=synthetic-admin-key-xyz" \
        "MOCK_RUNNER_FAILING_JSON=1" \
        "MOCK_RUNNER_EXIT_CODE=1" \
        "MOCK_RUNNER_STDERR_TEXT=$auth_route_message"

    assert_eq "$RUN_EXIT_CODE" "78" \
        "auth route too many requests exits 78 instead of classifying a product bug"
    assert_contains "$RUN_STDERR" "setup_failure" \
        "stderr names setup_failure for auth route too many requests"
    assert_contains "$RUN_STDERR" "429" \
        "stderr preserves the shared auth-budget diagnostic"
}

test_non_auth_429_exhaustion_remains_product_failure() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN

    setup_fixture_repo "$fixture_root"
    write_hydrate_mock "$fixture_root/scripts/launch/hydrate_seeder_env_from_ssm.sh"
    write_runner_mock  "$fixture_root/mock_runner"

    local non_auth_429_message
    non_auth_429_message='GET /account failed: exhausted retries after 429 rate limiting'

    run_driver "$fixture_root" \
        "PLAYWRIGHT_RUNNER=$fixture_root/mock_runner" \
        "MOCK_HYDRATE_ADMIN_KEY=synthetic-admin-key-xyz" \
        "MOCK_RUNNER_FAILING_JSON=1" \
        "MOCK_RUNNER_EXIT_CODE=1" \
        "MOCK_RUNNER_STDERR_TEXT=$non_auth_429_message" \
        "RERUN_AUTH_ATTEMPT_COOLDOWN_SECONDS=0"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "non-auth 429 exhaustion completes rerun classification instead of exiting setup_failure"
    assert_file_exists "$fixture_root/evidence/rerun_verdicts.json" \
        "rerun_verdicts.json is written for non-auth product failures"

    local classification
    classification="$(jq -r '.lanes[] | select(.lane == "b") | .classification' "$fixture_root/evidence/rerun_verdicts.json")"
    assert_eq "$classification" "real_bug" \
        "non-auth 429 exhaustion remains classified as real_bug"
    assert_not_contains "$RUN_STDERR" "setup_failure" \
        "non-auth 429 exhaustion is not reported as setup_failure"
}

test_setup_timeout_skipped_spec_exits_config() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN

    setup_fixture_repo "$fixture_root"
    write_hydrate_mock "$fixture_root/scripts/launch/hydrate_seeder_env_from_ssm.sh"
    write_runner_mock  "$fixture_root/mock_runner"

    run_driver "$fixture_root" \
        "PLAYWRIGHT_RUNNER=$fixture_root/mock_runner" \
        "MOCK_HYDRATE_ADMIN_KEY=synthetic-admin-key-xyz" \
        "MOCK_RUNNER_SETUP_TIMEOUT_SKIPPED_JSON=1" \
        "MOCK_RUNNER_EXIT_CODE=1" \
        "RERUN_AUTH_ATTEMPT_COOLDOWN_SECONDS=0"

    assert_eq "$RUN_EXIT_CODE" "78" \
        "setup timeout before skipped chromium spec exits 78 instead of classifying a product bug"
    assert_contains "$RUN_STDERR" "RERUN_INFRA_ERROR" \
        "stderr marks skipped-lane setup timeout as rerun infrastructure"
    assert_contains "$RUN_STDERR" "setup_failure" \
        "stderr names setup_failure for skipped-lane setup timeout"

    if [ -f "$fixture_root/evidence/rerun_verdicts.json" ]; then
        if grep -q '"classification": "real_bug"' "$fixture_root/evidence/rerun_verdicts.json"; then
            fail "skipped-lane setup timeout must not be classified as real_bug"
        else
            pass "skipped-lane setup timeout not written as real_bug verdict"
        fi
    else
        pass "no rerun_verdicts.json written when skipped-lane setup timeout exits"
    fi
}

test_setup_timeout_with_executed_spec_stays_product_failure() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN

    setup_fixture_repo "$fixture_root"
    write_hydrate_mock "$fixture_root/scripts/launch/hydrate_seeder_env_from_ssm.sh"
    write_runner_mock  "$fixture_root/mock_runner"

    run_driver "$fixture_root" \
        "PLAYWRIGHT_RUNNER=$fixture_root/mock_runner" \
        "MOCK_HYDRATE_ADMIN_KEY=synthetic-admin-key-xyz" \
        "MOCK_RUNNER_EXECUTED_TIMEOUT_JSON=1" \
        "MOCK_RUNNER_EXIT_CODE=1" \
        "RERUN_AUTH_ATTEMPT_COOLDOWN_SECONDS=0"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "executed target timeout remains a product-failure classification"
    assert_file_exists "$fixture_root/evidence/rerun_verdicts.json" \
        "rerun_verdicts.json is written for executed target timeouts"

    local classification
    classification="$(jq -r '.lanes[] | select(.lane == "b") | .classification' "$fixture_root/evidence/rerun_verdicts.json")"
    assert_eq "$classification" "real_bug" \
        "executed target timeout remains classified as real_bug"
    assert_not_contains "$RUN_STDERR" "setup_failure" \
        "executed target timeout is not reported as setup_failure"
}

test_rerun_attempts_are_spaced_by_driver_cooldown() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN

    setup_fixture_repo "$fixture_root"
    mkdir -p "$fixture_root/bin"
    write_hydrate_mock "$fixture_root/scripts/launch/hydrate_seeder_env_from_ssm.sh"
    write_runner_mock  "$fixture_root/mock_runner"
    write_sleep_mock "$fixture_root/bin/sleep"

    local sleep_log="$fixture_root/sleep.log"
    : > "$sleep_log"

    run_driver "$fixture_root" \
        "PLAYWRIGHT_RUNNER=$fixture_root/mock_runner" \
        "MOCK_HYDRATE_ADMIN_KEY=synthetic-admin-key-xyz" \
        "MOCK_RUNNER_FAILING_JSON=1" \
        "MOCK_RUNNER_EXIT_CODE=1" \
        "MOCK_SLEEP_LOG=$sleep_log" \
        "RERUN_AUTH_ATTEMPT_COOLDOWN_SECONDS=7"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "driver completes when failing reruns are product failures"

    local captured_sleep
    captured_sleep="$(cat "$sleep_log" 2>/dev/null || true)"
    assert_eq "$captured_sleep" "7" \
        "driver sleeps once between successive rerun attempts using configured cooldown"
}

test_missing_admin_key_exits_setup_failure() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN

    setup_fixture_repo "$fixture_root"
    write_hydrate_mock "$fixture_root/scripts/launch/hydrate_seeder_env_from_ssm.sh"
    write_runner_mock  "$fixture_root/mock_runner"

    # MOCK_HYDRATE_ADMIN_KEY intentionally unset → hydrate emits nothing → ADMIN_KEY remains unset.
    run_driver "$fixture_root" \
        "PLAYWRIGHT_RUNNER=$fixture_root/mock_runner"

    assert_eq "$RUN_EXIT_CODE" "78" \
        "missing ADMIN_KEY after hydration exits 78 (EX_CONFIG)"
    assert_contains "$RUN_STDERR" "ADMIN_KEY" \
        "stderr names ADMIN_KEY when it is missing after hydration"
    # The driver must NOT have written a real_bug verdict because it never
    # got past the pre-loop guard.
    if [ ! -f "$fixture_root/evidence/rerun_verdicts.json" ]; then
        pass "no rerun_verdicts.json written when setup fails pre-loop"
    else
        # A rerun_verdicts.json exists — the guard did not fire.
        fail "no rerun_verdicts.json written when setup fails pre-loop (present: $(cat "$fixture_root/evidence/rerun_verdicts.json"))"
    fi
}

test_hydrated_admin_key_exported_as_e2e_admin_key() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN

    setup_fixture_repo "$fixture_root"
    write_hydrate_mock "$fixture_root/scripts/launch/hydrate_seeder_env_from_ssm.sh"
    write_runner_mock  "$fixture_root/mock_runner"

    local env_log="$fixture_root/runner_env.log"
    : > "$env_log"

    run_driver "$fixture_root" \
        "PLAYWRIGHT_RUNNER=$fixture_root/mock_runner" \
        "MOCK_HYDRATE_ADMIN_KEY=synthetic-admin-key-xyz" \
        "MOCK_RUNNER_ENV_LOG=$env_log"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "driver exits 0 when hydration succeeds and runner passes"

    local captured
    captured="$(cat "$env_log" 2>/dev/null || true)"
    assert_contains "$captured" "E2E_ADMIN_KEY=synthetic-admin-key-xyz" \
        "hydrated ADMIN_KEY reaches runner as E2E_ADMIN_KEY"
}

test_empty_runner_output_classifies_setup_failure() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "'"$fixture_root"'"; trap - RETURN' RETURN

    setup_fixture_repo "$fixture_root"
    write_hydrate_mock "$fixture_root/scripts/launch/hydrate_seeder_env_from_ssm.sh"
    write_runner_mock  "$fixture_root/mock_runner"

    run_driver "$fixture_root" \
        "PLAYWRIGHT_RUNNER=$fixture_root/mock_runner" \
        "MOCK_HYDRATE_ADMIN_KEY=synthetic-admin-key-xyz" \
        "MOCK_RUNNER_EMPTY_OUTPUT=1" \
        "MOCK_RUNNER_EXIT_CODE=1"

    assert_eq "$RUN_EXIT_CODE" "78" \
        "empty reporter output + non-zero runner exit → exit 78"
    assert_contains "$RUN_STDERR" "setup_failure" \
        "stderr names setup_failure when reporter output is empty"
    assert_contains "$RUN_STDERR" "b" \
        "stderr names the failing lane letter (b) in setup_failure message"

    # Must NOT have written the failing lane as real_bug.
    if [ -f "$fixture_root/evidence/rerun_verdicts.json" ]; then
        if grep -q '"classification": "real_bug"' "$fixture_root/evidence/rerun_verdicts.json"; then
            fail "empty reporter output must not be classified as real_bug"
        else
            pass "empty reporter output not written as real_bug verdict"
        fi
    else
        pass "no rerun_verdicts.json written when setup_failure exits"
    fi
}

main() {
    echo "=== rerun_failing_lanes_test.sh ==="
    echo ""

    if [ ! -f "$DRIVER_SCRIPT" ]; then
        fail "driver script exists at scripts/verify/rerun_failing_lanes.sh"
        echo ""
        echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
        exit 1
    fi

    if [ ! -f "$HYDRATE_LIB" ]; then
        fail "shared hydration lib exists at scripts/lib/hydrate_staging_env.sh"
        echo ""
        echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
        exit 1
    fi

    test_missing_admin_key_exits_setup_failure
    test_hydrated_admin_key_exported_as_e2e_admin_key
    test_empty_runner_output_classifies_setup_failure
    test_auth_429_setup_failure_exits_config
    test_register_429_setup_failure_exits_config
    test_auth_route_too_many_requests_setup_failure_exits_config
    test_non_auth_429_exhaustion_remains_product_failure
    test_setup_timeout_skipped_spec_exits_config
    test_setup_timeout_with_executed_spec_stays_product_failure
    test_rerun_attempts_are_spaced_by_driver_cooldown

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
