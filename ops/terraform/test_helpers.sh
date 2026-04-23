#!/usr/bin/env bash
# Shared test helper functions for static Terraform tests.
# Source this file at the top of each test script:
#   source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

_TEST_FAILURES=0
_TEST_PASSES=0
_TEST_ERRORS=()

pass() {
  printf 'PASS: %s\n' "$1"
  _TEST_PASSES=$((_TEST_PASSES + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1"
  _TEST_FAILURES=$((_TEST_FAILURES + 1))
  _TEST_ERRORS+=("$1")
}

# Strip Terraform/HCL comments (line and block) and blank lines.
# Works for .tf files. Do NOT use on non-Terraform files (systemd, shell scripts)
# where # or /* may appear in valid content.
strip_comments() {
  local file="$1"
  awk '
    BEGIN { in_block_comment = 0 }
    {
      line = $0
      if (in_block_comment) {
        if (match(line, /\*\//)) {
          line = substr(line, RSTART + RLENGTH)
          in_block_comment = 0
        } else {
          next
        }
      }
      while (match(line, /(^|[[:space:]])\/\*/)) {
        prefix = substr(line, 1, RSTART - 1)
        remainder = substr(line, RSTART + RLENGTH)
        if (match(remainder, /\*\//)) {
          line = prefix substr(remainder, RSTART + RLENGTH)
        } else {
          line = prefix
          in_block_comment = 1
          break
        }
      }
      if (line ~ /^[[:space:]]*#/) { next }
      if (line ~ /^[[:space:]]*\/\//) { next }
      if (line ~ /^[[:space:]]*$/) { next }
      print line
    }
  ' "$file"
}

assert_file_exists() {
  local file="$1"
  local label="$2"
  if [[ -f "$file" ]]; then
    pass "$label"
  else
    fail "$label (missing: $file)"
  fi
}

# Check that a pattern exists in active (uncommented) Terraform code.
assert_contains_active() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if strip_comments "$file" | rg -q "$pattern"; then
    pass "$label"
  else
    fail "$label"
  fi
}

# Check that a pattern does NOT exist in active (uncommented) Terraform code.
assert_not_contains_active() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if strip_comments "$file" | rg -q "$pattern"; then
    fail "$label"
  else
    pass "$label"
  fi
}

# Raw file search — for non-Terraform files (systemd, shell scripts, markdown)
# where strip_comments would incorrectly treat # or /* as comment syntax.
assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if rg -q "$pattern" "$file"; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_file_not_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if rg -q "$pattern" "$file"; then
    fail "$label"
  else
    pass "$label"
  fi
}

assert_resource_count() {
  local file="$1"
  local expected="$2"
  local label="$3"
  local actual
  actual=$(strip_comments "$file" | rg -c '^[[:space:]]*resource[[:space:]]+"[^"]+"[[:space:]]+"[^"]+"' || true)
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected $expected, found $actual)"
  fi
}

# Print summary and exit with appropriate code.
# Usage: test_summary "Stage N"
test_summary() {
  local label="${1:-Tests}"
  local total=$((_TEST_PASSES + _TEST_FAILURES))
  echo ""
  if [[ "$_TEST_FAILURES" -gt 0 ]]; then
    printf '%s failed: %d/%d issue(s).\n' "$label" "$_TEST_FAILURES" "$total"
    for err in "${_TEST_ERRORS[@]}"; do
      printf '  - %s\n' "$err"
    done
    exit 1
  fi
  printf '%s: %d/%d passed.\n' "$label" "$_TEST_PASSES" "$total"
}
