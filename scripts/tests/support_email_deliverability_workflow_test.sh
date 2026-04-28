#!/usr/bin/env bash
# Focused workflow contract test for SES script seams in .github/workflows/ci.yml
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/ci.yml"

PASS_COUNT=0
FAIL_COUNT=0

# Portable grep wrapper for BSD/GNU compatibility.
_grep() {
  local flags=()
  while [[ $# -gt 1 && "$1" == -* ]]; do
    flags+=("$1")
    shift
  done
  local pattern="$1"
  shift
  pattern="${pattern//\\s/[[:space:]]}"
  if [[ ${#flags[@]} -gt 0 ]]; then
    grep -E "${flags[@]}" -- "$pattern" "$@"
  else
    grep -E -- "$pattern" "$@"
  fi
}

pass() {
  echo "PASS: $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "FAIL: $1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

job_block() {
  local job_name="$1"
  awk -v job="$job_name" '
    $0 ~ "^  " job ":$" { in_job=1; print; next }
    in_job && $0 ~ "^  [a-zA-Z0-9_-]+:$" { exit }
    in_job { print }
  ' "$WORKFLOW_FILE"
}

assert_file_exists() {
  local path="$1"
  local msg="$2"
  if [[ -f "$path" ]]; then
    pass "$msg"
  else
    fail "$msg (missing file: $path)"
  fi
}

assert_job_contains_regex() {
  local job_name="$1"
  local pattern="$2"
  local msg="$3"
  local block
  block="$(job_block "$job_name")"
  if [[ -z "$block" ]]; then
    fail "$msg (job block missing: $job_name)"
    return
  fi

  if _grep -n "$pattern" <<<"$block" >/dev/null 2>&1; then
    pass "$msg"
  else
    fail "$msg (pattern not found in $job_name: $pattern)"
  fi
}

find_step_index_for_command() {
  local block="$1"
  local command="$2"

  awk -v cmd="$command" '
    BEGIN { step_index=0 }
    $0 ~ /^[[:space:]]*-[[:space:]]name:/ { step_index++ }
    $0 ~ "^[[:space:]]*bash " cmd "[[:space:]]*$" { print step_index; exit }
  ' <<<"$block"
}

step_block_by_index() {
  local block="$1"
  local wanted_index="$2"

  awk -v wanted="$wanted_index" '
    BEGIN { step_index=0; in_step=0 }
    $0 ~ /^[[:space:]]*-[[:space:]]name:/ {
      if (in_step && step_index == wanted) { exit }
      step_index++
      in_step=1
    }
    in_step && step_index == wanted { print }
  ' <<<"$block"
}

assert_commands_share_single_run_block_in_job() {
  local job_name="$1"
  local command_a="$2"
  local command_b="$3"
  local msg="$4"
  local block step_a step_b step_block

  block="$(job_block "$job_name")"
  if [[ -z "$block" ]]; then
    fail "$msg (job block missing: $job_name)"
    return
  fi

  step_a="$(find_step_index_for_command "$block" "$command_a")"
  step_b="$(find_step_index_for_command "$block" "$command_b")"

  if [[ -z "$step_a" || -z "$step_b" ]]; then
    fail "$msg (expected both commands inside $job_name)"
    return
  fi

  if [[ "$step_a" != "$step_b" ]]; then
    fail "$msg (commands are split across different steps: $step_a vs $step_b)"
    return
  fi

  step_block="$(step_block_by_index "$block" "$step_a")"
  if [[ -z "$step_block" ]]; then
    fail "$msg (unable to read step block index: $step_a)"
    return
  fi

  if ! _grep -n '^[[:space:]]*run:[[:space:]]*\|[[:space:]]*$' <<<"$step_block" >/dev/null 2>&1; then
    fail "$msg (expected a single multiline run: | block)"
    return
  fi

  if ! _grep -n "^[[:space:]]*bash ${command_a}[[:space:]]*$" <<<"$step_block" >/dev/null 2>&1; then
    fail "$msg (first command missing from multiline run block)"
    return
  fi

  if ! _grep -n "^[[:space:]]*bash ${command_b}[[:space:]]*$" <<<"$step_block" >/dev/null 2>&1; then
    fail "$msg (second command missing from multiline run block)"
    return
  fi

  pass "$msg"
}

assert_command_absent_from_other_jobs() {
  local expected_job="$1"
  local command="$2"
  local msg="$3"
  local job_name block

  while IFS= read -r job_name; do
    [[ "$job_name" == "$expected_job" ]] && continue
    block="$(job_block "$job_name")"
    [[ -z "$block" ]] && continue
    if _grep -n "^[[:space:]]*bash ${command}[[:space:]]*$" <<<"$block" >/dev/null 2>&1; then
      fail "$msg (command appears under unexpected job: $job_name)"
      return
    fi
  done < <(awk '/^  [a-zA-Z0-9_-]+:$/ { sub(/^  /, "", $1); sub(/:$/, "", $1); print $1 }' "$WORKFLOW_FILE")

  pass "$msg"
}

echo ""
echo "=== Support Email Workflow Contract Tests ==="
echo ""

assert_file_exists "$WORKFLOW_FILE" "ci workflow file exists"
assert_job_contains_regex "rust-lint" '^[[:space:]]*-[[:space:]]name:[[:space:]]+Run CI workflow contract tests[[:space:]]*$' "rust-lint keeps baseline CI workflow contract test step"
assert_job_contains_regex "rust-lint" '^[[:space:]]*-[[:space:]]name:[[:space:]]+Run SES support email unit seams[[:space:]]*$' "rust-lint defines dedicated SES support email unit seams step"

assert_commands_share_single_run_block_in_job \
  "rust-lint" \
  "scripts/tests/validate_inbound_email_roundtrip_test\\.sh" \
  "scripts/tests/support_email_deliverability_test\\.sh" \
  "rust-lint SES step runs both support-email unit seams in one multiline run block"

assert_command_absent_from_other_jobs \
  "rust-lint" \
  "scripts/tests/validate_inbound_email_roundtrip_test\\.sh" \
  "validate_inbound_email_roundtrip_test.sh is not wired under unrelated jobs"

assert_command_absent_from_other_jobs \
  "rust-lint" \
  "scripts/tests/support_email_deliverability_test\\.sh" \
  "support_email_deliverability_test.sh is not wired under unrelated jobs"

echo ""
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

[[ "$FAIL_COUNT" -eq 0 ]]
