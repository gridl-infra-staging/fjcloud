#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/algolia_migration_safety_probe.sh"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

SHA_A="1111111111111111111111111111111111111111"
SHA_B="2222222222222222222222222222222222222222"
SHA_C="3333333333333333333333333333333333333333"

WORK_DIR=""
RUN_STDOUT=""
RUN_EXIT_CODE=0

cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

setup_workspace() {
  cleanup
  WORK_DIR="$(mktemp -d)"
  mkdir -p "$WORK_DIR/bin"
  : > "$WORK_DIR/curl.log"
  : > "$WORK_DIR/npm.log"

  cat > "$WORK_DIR/bin/aws" <<'AWS_EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "unexpected aws invocation: $*" >&2
exit 1
AWS_EOF

  cat > "$WORK_DIR/bin/curl" <<'CURL_EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$CURL_LOG"

url="${@: -1}"
case "$url" in
  https://api.staging.flapjack.foo/version|https://api.flapjack.foo/version)
    printf '{"dev_sha":"%s","mirror_sha":"%s"}\n200' "$EXPECTED_API_DEV_SHA" "$EXPECTED_API_MIRROR_SHA"
    ;;
  https://api.staging.flapjack.foo/migration/algolia/availability|https://api.flapjack.foo/migration/algolia/availability)
    case "${AVAILABILITY_SCENARIO:-unavailable}" in
      unavailable)
        printf '{"available":false,"reason":"temporarily_unavailable","message":"closed"}\n200'
        ;;
      unknown)
        printf '{"available":false,"reason":"unknown","message":"closed"}\n200'
        ;;
      mixed)
        printf '{"available":true,"reason":"temporarily_unavailable","message":"mixed"}\n200'
        ;;
      not_ready)
        printf '{"available":false,"reason":"not_ready","message":"not ready"}\n200'
        ;;
      *)
        printf '{"error":"bad scenario"}\n500'
        ;;
    esac
    ;;
  https://cloud.staging.flapjack.foo/_app/version.json|https://cloud.flapjack.foo/_app/version.json)
    printf '{"version":"%s"}\n200' "$EXPECTED_PAGES_SHA"
    ;;
  *)
    echo "unexpected curl url: $url" >&2
    exit 1
    ;;
esac
CURL_EOF

  cat > "$WORK_DIR/bin/npm" <<'NPM_EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$NPM_LOG"
printf 'Running 2 tests using 1 worker\n'
printf '  2 passed (1.0s)\n'
NPM_EOF

  chmod +x "$WORK_DIR/bin/aws" "$WORK_DIR/bin/curl" "$WORK_DIR/bin/npm"
}

run_probe() {
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    NPM_LOG="$WORK_DIR/npm.log" \
    EXPECTED_API_DEV_SHA="$SHA_A" \
    EXPECTED_API_MIRROR_SHA="$SHA_B" \
    EXPECTED_PAGES_SHA="$SHA_C" \
    ALGOLIA_MIGRATION_PROBE_TOKEN="${ALGOLIA_MIGRATION_PROBE_TOKEN-test-token}" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/missing.env" \
    bash "$TARGET_SCRIPT" "$@" 2>&1
  )" || RUN_EXIT_CODE=$?
}

run_probe_without_token() {
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    CURL_LOG="$WORK_DIR/curl.log" \
    NPM_LOG="$WORK_DIR/npm.log" \
    EXPECTED_API_DEV_SHA="$SHA_A" \
    EXPECTED_API_MIRROR_SHA="$SHA_B" \
    EXPECTED_PAGES_SHA="$SHA_C" \
    FJCLOUD_SECRET_FILE="$WORK_DIR/missing.env" \
    env -u ALGOLIA_MIGRATION_PROBE_TOKEN -u ALGOLIA_INVALID_CREDENTIALS_TENANT_TOKEN \
      bash "$TARGET_SCRIPT" "$@" 2>&1
  )" || RUN_EXIT_CODE=$?
}

standard_args() {
  printf '%s\n' --env staging --expected-api-dev-sha "$SHA_A" --expected-api-mirror-sha "$SHA_B" --expected-pages-sha "$SHA_C"
}

test_rejects_invalid_env() {
  setup_workspace
  run_probe --env dev --expected-api-dev-sha "$SHA_A" --expected-api-mirror-sha "$SHA_B" --expected-pages-sha "$SHA_C"
  assert_eq "$RUN_EXIT_CODE" "1" "invalid env should fail"
  assert_contains "$RUN_STDOUT" "--env must be staging or prod" "invalid env explains allowed values"
}

test_rejects_bad_api_dev_sha() {
  setup_workspace
  run_probe --env staging --expected-api-dev-sha ABC --expected-api-mirror-sha "$SHA_B" --expected-pages-sha "$SHA_C"
  assert_eq "$RUN_EXIT_CODE" "1" "bad API dev SHA should fail"
  assert_contains "$RUN_STDOUT" "--expected-api-dev-sha must be a 40-character lowercase hexadecimal SHA" "bad API dev SHA explains format"
}

test_rejects_bad_api_mirror_sha() {
  setup_workspace
  run_probe --env staging --expected-api-dev-sha "$SHA_A" --expected-api-mirror-sha ABC --expected-pages-sha "$SHA_C"
  assert_eq "$RUN_EXIT_CODE" "1" "bad API mirror SHA should fail"
  assert_contains "$RUN_STDOUT" "--expected-api-mirror-sha must be a 40-character lowercase hexadecimal SHA" "bad API mirror SHA explains format"
}

test_rejects_bad_pages_sha() {
  setup_workspace
  run_probe --env staging --expected-api-dev-sha "$SHA_A" --expected-api-mirror-sha "$SHA_B" --expected-pages-sha ABC
  assert_eq "$RUN_EXIT_CODE" "1" "bad Pages SHA should fail"
  assert_contains "$RUN_STDOUT" "--expected-pages-sha must be a 40-character lowercase hexadecimal SHA" "bad Pages SHA explains format"
}

test_requires_auth_token() {
  setup_workspace
  run_probe_without_token $(standard_args)
  assert_eq "$RUN_EXIT_CODE" "1" "missing token should fail"
  assert_contains "$RUN_STDOUT" "ALGOLIA_MIGRATION_PROBE_TOKEN or ALGOLIA_INVALID_CREDENTIALS_TENANT_TOKEN is required" "missing token names accepted vars"
}

test_unavailable_state_passes_and_stays_read_only() {
  setup_workspace
  run_probe $(standard_args)
  assert_eq "$RUN_EXIT_CODE" "0" "unavailable state should pass"
  assert_contains "$RUN_STDOUT" "PASS: staging Algolia migration safety probe" "success verdict is printed"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "/version" "probe reads API version"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "/migration/algolia/availability" "probe reads availability"
  assert_contains "$(cat "$WORK_DIR/curl.log")" "/_app/version.json" "probe reads Pages version"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "Authorization: Bearer test-token" "probe must not leak bearer token in curl argv"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "-d " "probe must not send mutating curl payloads"
  assert_not_contains "$(cat "$WORK_DIR/curl.log")" "POST" "probe must not POST"
  assert_contains "$(cat "$WORK_DIR/npm.log")" "test:e2e" "probe drives Playwright scenario"
  assert_contains "$(cat "$WORK_DIR/npm.log")" "--project=chromium" "probe uses chromium project"
  assert_contains "$(cat "$WORK_DIR/npm.log")" "migration-recovery.spec.ts" "probe runs migration recovery scenario"
}

test_fails_closed_on_unknown_availability() {
  setup_workspace
  AVAILABILITY_SCENARIO=unknown run_probe $(standard_args)
  assert_eq "$RUN_EXIT_CODE" "1" "unknown availability should fail closed"
  assert_contains "$RUN_STDOUT" "availability reason must be temporarily_unavailable" "unknown reason is rejected"
}

test_fails_closed_on_mixed_availability() {
  setup_workspace
  AVAILABILITY_SCENARIO=mixed run_probe $(standard_args)
  assert_eq "$RUN_EXIT_CODE" "1" "mixed availability should fail closed"
  assert_contains "$RUN_STDOUT" "availability.available must be false" "available true is rejected"
}

test_fails_closed_on_not_ready_availability() {
  setup_workspace
  AVAILABILITY_SCENARIO=not_ready run_probe $(standard_args)
  assert_eq "$RUN_EXIT_CODE" "1" "not-ready availability should fail closed"
  assert_contains "$RUN_STDOUT" "availability reason must be temporarily_unavailable" "not-ready reason is rejected"
}

test_script_is_executable() {
  if [ -x "$TARGET_SCRIPT" ]; then
    pass "probe script is executable"
  else
    fail "probe script is executable"
  fi
}

test_rejects_invalid_env
test_rejects_bad_api_dev_sha
test_rejects_bad_api_mirror_sha
test_rejects_bad_pages_sha
test_requires_auth_token
test_unavailable_state_passes_and_stays_read_only
test_fails_closed_on_unknown_availability
test_fails_closed_on_mixed_availability
test_fails_closed_on_not_ready_availability
test_script_is_executable

run_test_summary
