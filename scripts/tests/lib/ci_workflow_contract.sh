#!/usr/bin/env bash
# Shared workflow-contract parsing seams for static assertions against
# .github/workflows/ci.yml. Extracted from ci_deploy_web_contract_test.sh so
# multiple contract tests (web-deploy, Lane 24 deploy) reuse ONE workflow
# parser instead of forking a second.
#
# Contract for callers:
#   - Define pass "<msg>" and fail "<msg>" before sourcing (or source
#     lib/test_runner.sh, which provides them).
#   - Set WORKFLOW_FILE to the ci.yml path before calling any job/step helper.

# Portable grep wrapper: converts \s to [[:space:]] so patterns work with
# POSIX grep -E on both macOS (BSD grep) and Linux (GNU grep).
_grep() {
  local flags=()
  while [[ $# -gt 1 && "$1" == -* ]]; do
    flags+=("$1"); shift
  done
  local pattern="$1"; shift
  pattern="${pattern//\\s/[[:space:]]}"
  if [[ ${#flags[@]} -gt 0 ]]; then
    grep -E "${flags[@]}" -- "$pattern" "$@"
  else
    grep -E -- "$pattern" "$@"
  fi
}

# Extract a top-level job block (`  <job>:` up to the next `  <job>:`).
job_block() {
  local job_name="$1"
  awk -v job="$job_name" '
    $0 ~ "^  " job ":$" { in_job=1; print; next }
    in_job && $0 ~ "^  [a-zA-Z0-9_-]+:$" { exit }
    in_job { print }
  ' "$WORKFLOW_FILE"
}

# Extract a single named step out of a job block (`- name: <step>` up to the
# next `- name:`).
step_block() {
  local job_name="$1"
  local step_name="$2"
  job_block "$job_name" | awk -v step="$step_name" '
    $0 ~ "^[[:space:]]+- name: " step "$" { in_step=1; print; next }
    in_step && $0 ~ "^[[:space:]]+- name: " { exit }
    in_step { print }
  '
}

assert_job_contains_regex() {
  local job_name="$1" pattern="$2" msg="$3" block
  block="$(job_block "$job_name")"
  block="$(printf '%s\n' "$block" | grep -Ev '^[[:space:]]*#')"
  if [[ -z "$block" ]]; then fail "$msg (job block missing: $job_name)"; return; fi
  if _grep -n "$pattern" <<<"$block" >/dev/null 2>&1; then pass "$msg"
  else fail "$msg (pattern not found in $job_name: $pattern)"; fi
}

assert_job_not_contains_regex() {
  local job_name="$1" pattern="$2" msg="$3" block
  block="$(job_block "$job_name")"
  if [[ -z "$block" ]]; then fail "$msg (job block missing: $job_name)"; return; fi
  if _grep -n "$pattern" <<<"$block" >/dev/null 2>&1; then
    fail "$msg (unexpected pattern found in $job_name: $pattern)"
  else pass "$msg"; fi
}

assert_step_contains_regex() {
  local job_name="$1" step_name="$2" pattern="$3" msg="$4" block
  block="$(step_block "$job_name" "$step_name")"
  block="$(printf '%s\n' "$block" | grep -Ev '^[[:space:]]*#')"
  if [[ -z "$block" ]]; then fail "$msg (step missing in $job_name: $step_name)"; return; fi
  if _grep -n "$pattern" <<<"$block" >/dev/null 2>&1; then pass "$msg"
  else fail "$msg (pattern not found in $job_name/$step_name: $pattern)"; fi
}

assert_step_not_contains_regex() {
  local job_name="$1" step_name="$2" pattern="$3" msg="$4" block
  block="$(step_block "$job_name" "$step_name")"
  if [[ -z "$block" ]]; then fail "$msg (step missing in $job_name: $step_name)"; return; fi
  if _grep -n "$pattern" <<<"$block" >/dev/null 2>&1; then
    fail "$msg (unexpected pattern found in $job_name/$step_name: $pattern)"
  else pass "$msg"; fi
}

assert_file_contains_regex() {
  local path="$1" pattern="$2" msg="$3"
  if _grep -n "$pattern" "$path" >/dev/null 2>&1; then pass "$msg"
  else fail "$msg (pattern not found in $path: $pattern)"; fi
}

assert_file_not_contains_regex() {
  local path="$1" pattern="$2" msg="$3"
  if _grep -n "$pattern" "$path" >/dev/null 2>&1; then
    fail "$msg (unexpected pattern found in $path: $pattern)"
  else pass "$msg"; fi
}

step_line_number() {
  local job_name="$1"
  local step_name="$2"
  local block
  block="$(job_block "$job_name")"
  printf '%s\n' "$block" | awk -v step="$step_name" '
    $0 ~ "^[[:space:]]+- name: " step "$" { print NR; exit }
  '
}

assert_step_order() {
  local job_name="$1"
  local first_step="$2"
  local second_step="$3"
  local msg="$4"
  local first_line second_line

  first_line="$(step_line_number "$job_name" "$first_step")"
  second_line="$(step_line_number "$job_name" "$second_step")"

  if [[ -z "$first_line" || -z "$second_line" ]]; then
    fail "$msg (missing step in $job_name: $first_step -> $second_step)"
    return
  fi

  if (( first_line < second_line )); then
    pass "$msg"
  else
    fail "$msg (order wrong in $job_name: $first_step line $first_line, $second_step line $second_line)"
  fi
}

step_block_normalized() {
  local job_name="$1"
  local step_name="$2"
  step_block "$job_name" "$step_name" \
    | awk '!/^[[:space:]]*#/' \
    | sed -E 's/[[:space:]]*\\$//' \
    | tr '\n' ' ' \
    | sed -E 's/[[:space:]]+/ /g'
}

assert_step_contains_normalized_regex() {
  local job_name="$1" step_name="$2" pattern="$3" msg="$4" block
  block="$(step_block_normalized "$job_name" "$step_name")"
  if [[ -z "$block" ]]; then fail "$msg (step missing in $job_name: $step_name)"; return; fi
  if _grep -n "$pattern" <<<"$block" >/dev/null 2>&1; then pass "$msg"
  else fail "$msg (normalized pattern not found in $job_name/$step_name: $pattern)"; fi
}

# Parse the job-level `timeout-minutes:` integer (4-space indent isolates it
# from any step-level timeout) and assert it falls inside a concrete closed
# range.
assert_job_timeout_in_range() {
  local job_name="$1" min="$2" max="$3" msg="$4" value
  # No early `exit` here: under `set -o pipefail` an awk exit mid-stream
  # SIGPIPEs job_block's writer and kills the whole script with 141 on the
  # CI runner. Consume all input and keep first-match semantics with a flag.
  value="$(job_block "$job_name" | awk '
    !found && /^[[:space:]]{4}timeout-minutes:[[:space:]]*[0-9]+[[:space:]]*$/ {
      print $2
      found = 1
    }
  ')"
  if [[ -z "$value" ]]; then
    fail "$msg (no job-level timeout-minutes parsed in $job_name)"
    return
  fi
  if (( value >= min && value <= max )); then
    pass "$msg (timeout-minutes=$value)"
  else
    fail "$msg (timeout-minutes=$value outside [$min,$max] in $job_name)"
  fi
}

# List the top-level job names in the workflow (`  <job>:` at 2-space indent).
workflow_job_names() {
  awk '/^  [a-zA-Z0-9_-]+:$/ { name=$1; sub(/:$/, "", name); print name }' "$WORKFLOW_FILE"
}
