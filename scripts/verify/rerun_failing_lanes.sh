#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EVIDENCE_DIR="${EVIDENCE_DIR:-}"
RERUN_INFRA_ERROR="RERUN_INFRA_ERROR"

emit_rerun_infra_error() {
  echo "${RERUN_INFRA_ERROR}: $*" >&2
}

if [[ -z "$EVIDENCE_DIR" ]]; then
  echo "ERROR: EVIDENCE_DIR must be set" >&2
  exit 1
fi

if [[ ! -d "$EVIDENCE_DIR" ]]; then
  echo "ERROR: EVIDENCE_DIR does not exist: $EVIDENCE_DIR" >&2
  exit 1
fi

EVIDENCE_DIR="$(cd "$EVIDENCE_DIR" && pwd)"

# Hydrate staging credentials from SSM before invoking Playwright. The
# 2026-07-06 run misclassified 7 lanes as `real_bug` because auth setup
# failed on every rerun — the driver had no ADMIN_KEY. Missing credentials
# after hydration are a harness/config failure, not a product regression,
# so exit 78 (EX_CONFIG) rather than fall through to Playwright.
# shellcheck source=../lib/hydrate_staging_env.sh
source "$(cd "$(dirname "$0")/../lib" && pwd)/hydrate_staging_env.sh"
hydrate_staging_env_from_ssm || true
if [[ -z "${ADMIN_KEY:-}" ]]; then
  emit_rerun_infra_error "ERROR: ADMIN_KEY missing after hydrate_staging_env_from_ssm; refusing to run Playwright reruns"
  emit_rerun_infra_error "setup_failure: EX_CONFIG=78, not a real_bug"
  exit 78
fi
export E2E_ADMIN_KEY="$ADMIN_KEY"

FIRST_PASS="$EVIDENCE_DIR/lane_verdicts_first_pass.json"
if [[ ! -f "$FIRST_PASS" ]]; then
  echo "ERROR: lane_verdicts_first_pass.json not found at $FIRST_PASS" >&2
  exit 1
fi

NON_PASSED_COUNT=$(jq '.non_passed_count' "$FIRST_PASS")
LANE_COUNT=$(jq '.lane_count' "$FIRST_PASS")

if [[ "$NON_PASSED_COUNT" -eq 0 ]]; then
  echo "All lanes passed first pass, no reruns needed"
  echo '{"reruns_run": 0, "lanes": []}' > "$EVIDENCE_DIR/rerun_verdicts.json"
  jq '{
    first_pass_pass: [.lanes[] | select(.raw_status == "passed") | .lane],
    reruns_to_flake: [],
    real_bug_after_reruns: [],
    final_pass_including_flakes: .passed_count,
    ready_precondition: {
      real_bug_count: 0,
      final_pass_ge_4: (.passed_count >= 4)
    }
  }' "$FIRST_PASS" > "$EVIDENCE_DIR/classification.json"
  jq empty "$EVIDENCE_DIR/rerun_verdicts.json"
  jq empty "$EVIDENCE_DIR/classification.json"
  exit 0
fi

echo "Found $NON_PASSED_COUNT non-passed lanes out of $LANE_COUNT total"

SPEC_FILE="tests/e2e-ui/full/polished_beta_staging_verify.spec.ts"
RUNNER="${PLAYWRIGHT_RUNNER:-npx playwright}"
MAX_RERUNS=2
# Staging auth routes share a 10-request/60-second budget. Space rerun starts
# at the per-request share so fixture-owned 429 retries in web/tests/fixtures/fixtures.ts
# have room to drain without duplicating their retry/backoff rules here.
DEFAULT_RERUN_AUTH_ATTEMPT_COOLDOWN_SECONDS=6
RERUN_AUTH_ATTEMPT_COOLDOWN_SECONDS="${RERUN_AUTH_ATTEMPT_COOLDOWN_SECONDS:-$DEFAULT_RERUN_AUTH_ATTEMPT_COOLDOWN_SECONDS}"

RERUN_LANES_JSON="[]"
TOTAL_RERUNS=0

text_mentions_shared_auth_route() {
  local text="$1"
  [[ "$text" == *"/auth/register"* ]] && return 0
  [[ "$text" == *"/auth/login"* ]] && return 0
  [[ "$text" == *"/auth/verify-email"* ]] && return 0
  return 1
}

is_auth_budget_setup_failure_text() {
  local text="$1"
  [[ "$text" == *"Login response: status 429"* ]] && return 0
  [[ "$text" == *"/auth/register"* && "$text" == *"status 429"* ]] && return 0
  [[ "$text" == *"/auth/login"* && "$text" == *"status 429"* ]] && return 0
  [[ "$text" == *"/auth/verify-email"* && "$text" == *"status 429"* ]] && return 0
  if text_mentions_shared_auth_route "$text"; then
    [[ "$text" == *"too many requests"* ]] && return 0
    [[ "$text" == *"Too Many Requests"* ]] && return 0
  fi
  [[ "$text" == *"loginAs failed: exhausted retries after 429 rate limiting"* ]] && return 0
  [[ "$text" == *"Auth login failed: exhausted retries after 429 rate limiting"* ]] && return 0
  [[ "$text" == *"createUser failed: exhausted retries after 429 rate limiting"* ]] && return 0
  [[ "$text" == *"staging API verify-email failed: exhausted retries after 429 rate limiting"* ]] && return 0
  [[ "$text" == *"arrangeTrackedCustomerSession email verification failed: exhausted retries after 429 rate limiting"* ]] && return 0
  return 1
}

is_auth_budget_setup_failure() {
  local reporter_path="$1"
  local stderr_path="$2"
  local combined_text=""

  if [[ -s "$stderr_path" ]]; then
    combined_text+="$(cat "$stderr_path")"
  fi
  if [[ -s "$reporter_path" ]]; then
    combined_text+=$'\n'
    combined_text+="$(jq -r '.. | strings' "$reporter_path" 2>/dev/null || true)"
  fi

  is_auth_budget_setup_failure_text "$combined_text"
}

is_auth_setup_failure_before_target_spec() {
  local reporter_path="$1"

  [[ -s "$reporter_path" ]] || return 1

  jq -e '
    def is_project($name): (.projectId? == $name) or (.projectName? == $name);
    def has_result_status($status): any(.results[]?; .status == $status);
    def has_customer_login_setup_failure:
      ([.. | strings] | join("\n") | contains("Customer login setup failed before reaching /console"));
    def setup_user_timed_out:
      any(.. | objects; is_project("setup:user") and has_result_status("timedOut"));
    def chromium_target_skipped:
      any(.. | objects; is_project("chromium") and ((.status? == "skipped") or has_result_status("skipped")));

    setup_user_timed_out and has_customer_login_setup_failure and chromium_target_skipped
  ' "$reporter_path" >/dev/null 2>&1
}

sleep_before_successive_rerun() {
  if [[ "$TOTAL_RERUNS" -eq 0 ]]; then
    return
  fi
  if [[ "$RERUN_AUTH_ATTEMPT_COOLDOWN_SECONDS" == "0" ]]; then
    return
  fi
  echo "  Cooling down ${RERUN_AUTH_ATTEMPT_COOLDOWN_SECONDS}s before next rerun attempt..."
  sleep "$RERUN_AUTH_ATTEMPT_COOLDOWN_SECONDS"
}

while IFS= read -r lane_json; do
  LANE_LETTER=$(echo "$lane_json" | jq -r '.lane')
  LANE_TITLE=$(echo "$lane_json" | jq -r '.title')
  LANE_STATUS=$(echo "$lane_json" | jq -r '.raw_status')

  if [[ ! "$LANE_LETTER" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: invalid lane identifier in first-pass evidence: $LANE_LETTER" >&2
    exit 1
  fi

  if [[ "$LANE_STATUS" == "passed" ]]; then
    continue
  fi

  # Strip file path prefix from title — Playwright --grep matches against
  # describe+test name, not the file path the JSON reporter prepends.
  # "file.spec.ts › Describe › Test Name" → "Test Name" (last segment after ›)
  GREP_TITLE="${LANE_TITLE##*› }"

  echo "--- Rerunning lane $LANE_LETTER: ${LANE_TITLE:0:80}..."
  echo "  grep pattern: ${GREP_TITLE:0:80}"
  ATTEMPTS_JSON="[]"
  CLASSIFICATION="real_bug"

  for attempt in $(seq 1 "$MAX_RERUNS"); do
    RERUN_FILE="$EVIDENCE_DIR/rerun_${LANE_LETTER}_${attempt}.json"
    RERUN_STDERR_FILE="$EVIDENCE_DIR/rerun_${LANE_LETTER}_${attempt}.stderr"
    RAW_RERUN_FILE="$(mktemp "${TMPDIR:-/tmp}/fjcloud_rerun_${LANE_LETTER}_${attempt}.json.XXXXXX")"
    echo "  Attempt $attempt/$MAX_RERUNS..."
    sleep_before_successive_rerun

    START_MS=$(python3 -c "import time; print(int(time.time()*1000))")

    set +e
    cd "$REPO_ROOT/web" && \
      PLAYWRIGHT_TARGET_REMOTE=1 \
      BASE_URL=https://cloud.staging.flapjack.foo \
      PLAYWRIGHT_BASE_URL=https://cloud.staging.flapjack.foo \
      API_URL=https://api.staging.flapjack.foo \
      API_BASE_URL=https://api.staging.flapjack.foo \
      $RUNNER test "$SPEC_FILE" \
        --project=chromium \
        --grep "$GREP_TITLE" \
        --reporter=json \
      > "$RAW_RERUN_FILE" 2>"$RERUN_STDERR_FILE"
    EXIT_CODE=$?
    set -e
    cd "$REPO_ROOT"

    if [[ -s "$RAW_RERUN_FILE" ]]; then
      if ! bash "$REPO_ROOT/scripts/lib/redact_playwright_json.sh" "$RAW_RERUN_FILE" "$RERUN_FILE"; then
        rm -f "$RAW_RERUN_FILE"
        echo "ERROR: failed to redact Playwright JSON reporter output for lane $LANE_LETTER attempt $attempt" >&2
        exit 1
      fi
    else
      rm -f "$RERUN_FILE"
    fi
    rm -f "$RAW_RERUN_FILE"

    END_MS=$(python3 -c "import time; print(int(time.time()*1000))")
    DURATION_MS=$((END_MS - START_MS))

    if [[ $EXIT_CODE -eq 0 ]]; then
      ATTEMPT_STATUS="passed"
    else
      ATTEMPT_STATUS="failed"
    fi

    if [[ ! -s "$RERUN_FILE" ]]; then
      # Empty reporter output with a non-zero runner exit is a harness
      # failure (Playwright never ran a spec — commonly a global-setup
      # crash from a missing dependency). Classifying that as `real_bug`
      # produced 7 false verdicts on 2026-07-06. Exit 78 (EX_CONFIG)
      # instead, naming the lane.
      if [[ $EXIT_CODE -ne 0 ]]; then
        emit_rerun_infra_error "setup_failure: lane $LANE_LETTER produced no spec results (runner exit $EXIT_CODE)"
        echo '{"error": "empty reporter output", "exit_code": '"$EXIT_CODE"'}' > "$RERUN_FILE"
        exit 78
      fi
      echo '{"error": "empty reporter output", "exit_code": '"$EXIT_CODE"'}' > "$RERUN_FILE"
    fi

    if jq -e '.errors[]? | select(.message | test("No tests found"))' "$RERUN_FILE" >/dev/null 2>&1; then
      echo "ERROR: --grep pattern selected zero tests for lane $LANE_LETTER" >&2
      echo "  Pattern: $GREP_TITLE" >&2
      exit 1
    fi

    if ! jq empty "$RERUN_FILE" 2>/dev/null; then
      echo "ERROR: Malformed JSON reporter output for lane $LANE_LETTER attempt $attempt" >&2
      exit 1
    fi

    if [[ $EXIT_CODE -ne 0 ]] && is_auth_budget_setup_failure "$RERUN_FILE" "$RERUN_STDERR_FILE"; then
      emit_rerun_infra_error "setup_failure: lane $LANE_LETTER auth setup hit shared auth-budget 429 (runner exit $EXIT_CODE)"
      exit 78
    fi

    if [[ $EXIT_CODE -ne 0 ]] && is_auth_setup_failure_before_target_spec "$RERUN_FILE"; then
      emit_rerun_infra_error "setup_failure: lane $LANE_LETTER auth setup failed before target spec ran (runner exit $EXIT_CODE)"
      exit 78
    fi

    # A well-formed JSON reporter output that reports zero suites is
    # another harness-failure signal — Playwright produced structured
    # output but selected no work. Same setup_failure treatment.
    SUITE_COUNT=$(jq '[.suites // [] | .. | .specs? // empty] | length' "$RERUN_FILE" 2>/dev/null || echo 0)
    if [[ "$SUITE_COUNT" -eq 0 && $EXIT_CODE -ne 0 ]]; then
      emit_rerun_infra_error "setup_failure: lane $LANE_LETTER produced zero spec results (runner exit $EXIT_CODE)"
      exit 78
    fi

    ATTEMPT_OBJ=$(jq -n \
      --argjson attempt "$attempt" \
      --arg status "$ATTEMPT_STATUS" \
      --argjson duration_ms "$DURATION_MS" \
      --arg reporter_path "rerun_${LANE_LETTER}_${attempt}.json" \
      '{attempt: $attempt, status: $status, duration_ms: $duration_ms, reporter_path: $reporter_path}')

    ATTEMPTS_JSON=$(echo "$ATTEMPTS_JSON" | jq --argjson obj "$ATTEMPT_OBJ" '. + [$obj]')
    TOTAL_RERUNS=$((TOTAL_RERUNS + 1))

    echo "  Attempt $attempt result: $ATTEMPT_STATUS (${DURATION_MS}ms)"

    if [[ "$ATTEMPT_STATUS" == "passed" ]]; then
      CLASSIFICATION="flake"
      break
    fi
  done

  LANE_OBJ=$(jq -n \
    --arg lane "$LANE_LETTER" \
    --arg title "$LANE_TITLE" \
    --argjson attempts "$ATTEMPTS_JSON" \
    --arg classification "$CLASSIFICATION" \
    '{lane: $lane, title: $title, attempts: $attempts, classification: $classification}')

  RERUN_LANES_JSON=$(echo "$RERUN_LANES_JSON" | jq --argjson obj "$LANE_OBJ" '. + [$obj]')

  echo "  Lane $LANE_LETTER classified: $CLASSIFICATION"
done < <(jq -c '.lanes[]' "$FIRST_PASS")

RERUN_VERDICTS=$(jq -n \
  --argjson reruns_run "$TOTAL_RERUNS" \
  --argjson lanes "$RERUN_LANES_JSON" \
  '{reruns_run: $reruns_run, lanes: $lanes}')

echo "$RERUN_VERDICTS" > "$EVIDENCE_DIR/rerun_verdicts.json"

if ! jq empty "$EVIDENCE_DIR/rerun_verdicts.json"; then
  echo "ERROR: rerun_verdicts.json failed JSON validation" >&2
  exit 1
fi

FIRST_PASS_PASS=$(jq '[.lanes[] | select(.raw_status == "passed") | .lane]' "$FIRST_PASS")
RERUNS_TO_FLAKE=$(echo "$RERUN_VERDICTS" | jq '[.lanes[] | select(.classification == "flake") | .lane]')
REAL_BUG=$(echo "$RERUN_VERDICTS" | jq '[.lanes[] | select(.classification == "real_bug") | .lane]')
FLAKE_COUNT=$(echo "$RERUNS_TO_FLAKE" | jq 'length')
FIRST_PASS_COUNT=$(echo "$FIRST_PASS_PASS" | jq 'length')
FINAL_PASS=$((FIRST_PASS_COUNT + FLAKE_COUNT))
REAL_BUG_COUNT=$(echo "$REAL_BUG" | jq 'length')

jq -n \
  --argjson first_pass_pass "$FIRST_PASS_PASS" \
  --argjson reruns_to_flake "$RERUNS_TO_FLAKE" \
  --argjson real_bug_after_reruns "$REAL_BUG" \
  --argjson final_pass_including_flakes "$FINAL_PASS" \
  --argjson real_bug_count "$REAL_BUG_COUNT" \
  --argjson final_pass_ge_4 "$([ "$FINAL_PASS" -ge 4 ] && echo true || echo false)" \
  '{
    first_pass_pass: $first_pass_pass,
    reruns_to_flake: $reruns_to_flake,
    real_bug_after_reruns: $real_bug_after_reruns,
    final_pass_including_flakes: $final_pass_including_flakes,
    ready_precondition: {
      real_bug_count: $real_bug_count,
      final_pass_ge_4: $final_pass_ge_4
    }
  }' > "$EVIDENCE_DIR/classification.json"

if ! jq empty "$EVIDENCE_DIR/classification.json"; then
  echo "ERROR: classification.json failed JSON validation" >&2
  exit 1
fi

echo ""
echo "=== Classification Summary ==="
echo "First pass passed: $(echo "$FIRST_PASS_PASS" | jq -r 'join(", ")')"
echo "Reruns → flake:    $(echo "$RERUNS_TO_FLAKE" | jq -r 'join(", ")')"
echo "Real bugs:         $(echo "$REAL_BUG" | jq -r 'join(", ")')"
echo "Final pass count:  $FINAL_PASS (including flakes)"
echo "Ready precondition: real_bug_count=$REAL_BUG_COUNT, final_pass_ge_4=$([ "$FINAL_PASS" -ge 4 ] && echo true || echo false)"
echo ""
echo "Evidence written to $EVIDENCE_DIR/"
