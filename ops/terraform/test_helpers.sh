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
  local stripped
  stripped="$(strip_comments "$file")"
  if rg -q "$pattern" <<<"$stripped"; then
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
  local stripped
  stripped="$(strip_comments "$file")"
  if rg -q "$pattern" <<<"$stripped"; then
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

# Print the active (comment-stripped) lines of a single resource block,
# `resource "<resource_type>" "<resource_name>" { ... }`. Brace depth is
# tracked so output stops at the block's matching close brace. Prints nothing
# if the resource is not found.
#
# Lives here (shared) rather than in a single test file so any terraform test
# can scope an assertion to one resource block — see assert_resource_block_contains.
extract_active_resource_block() {
  local file="$1"
  local resource_type="$2"
  local resource_name="$3"
  strip_comments "$file" | awk -v resource_type="$resource_type" -v resource_name="$resource_name" '
    BEGIN { in_block = 0; depth = 0 }
    {
      line = $0
      if (!in_block && line ~ "^[[:space:]]*resource[[:space:]]+\"" resource_type "\"[[:space:]]+\"" resource_name "\"[[:space:]]*{") {
        in_block = 1
      }

      if (in_block) {
        print line
        opens = gsub(/{/, "{", line)
        closes = gsub(/}/, "}", line)
        depth += opens - closes
        if (depth == 0) {
          exit
        }
      }
    }
  '
}

# Assert that `pattern` (an rg regex) appears INSIDE a specific resource block,
# not merely somewhere in the file. Prefer this over assert_contains_active for
# attributes that recur across many resources (treat_missing_data, namespace,
# metric_name, ...): a file-scoped grep would let a regression in one block be
# masked by a correct sibling block — a false positive. Block scoping makes the
# assertion fail iff THIS resource is wrong.
assert_resource_block_contains() {
  local file="$1"
  local resource_type="$2"
  local resource_name="$3"
  local pattern="$4"
  local description="$5"
  local block

  block="$(extract_active_resource_block "$file" "$resource_type" "$resource_name")"
  if [[ -z "$block" ]]; then
    fail "$description (resource ${resource_type}.${resource_name} not found)"
    return
  fi

  if rg -q "$pattern" <<<"$block"; then
    pass "$description"
  else
    fail "$description"
  fi
}

# Assert that a multiline rg regex appears INSIDE a specific resource block.
# Use this when the relationship between adjacent attributes matters and a
# line-scoped assertion could pass on unrelated values in the same block.
assert_resource_block_contains_multiline() {
  local file="$1"
  local resource_type="$2"
  local resource_name="$3"
  local pattern="$4"
  local description="$5"
  local block

  block="$(extract_active_resource_block "$file" "$resource_type" "$resource_name")"
  if [[ -z "$block" ]]; then
    fail "$description (resource ${resource_type}.${resource_name} not found)"
    return
  fi

  if rg -Uq "$pattern" <<<"$block"; then
    pass "$description"
  else
    fail "$description"
  fi
}

# Assert that `pattern` appears exactly `expected` times inside a resource block.
assert_resource_block_pattern_count() {
  local file="$1"
  local resource_type="$2"
  local resource_name="$3"
  local pattern="$4"
  local expected="$5"
  local description="$6"
  local block
  local actual

  block="$(extract_active_resource_block "$file" "$resource_type" "$resource_name")"
  if [[ -z "$block" ]]; then
    fail "$description (resource ${resource_type}.${resource_name} not found)"
    return
  fi

  actual=$({ rg -o "$pattern" <<<"$block" || true; } | wc -l | tr -d '[:space:]')

  if [[ "$actual" == "$expected" ]]; then
    pass "$description"
  else
    fail "$description (expected $expected, found $actual)"
  fi
}

# Assert that `pattern` does NOT appear inside a specific resource block.
assert_resource_block_not_contains() {
  local file="$1"
  local resource_type="$2"
  local resource_name="$3"
  local pattern="$4"
  local description="$5"
  local block

  block="$(extract_active_resource_block "$file" "$resource_type" "$resource_name")"
  if [[ -z "$block" ]]; then
    fail "$description (resource ${resource_type}.${resource_name} not found)"
    return
  fi

  if rg -q "$pattern" <<<"$block"; then
    fail "$description"
  else
    pass "$description"
  fi
}

# Assert an active Terraform resource appears exactly `expected` times.
assert_named_resource_count() {
  local file="$1"
  local resource_type="$2"
  local resource_name="$3"
  local expected="$4"
  local description="$5"
  local actual

  actual=$(
    strip_comments "$file" \
      | rg -c "^[[:space:]]*resource[[:space:]]+\"${resource_type}\"[[:space:]]+\"${resource_name}\"[[:space:]]*\\{" \
      || true
  )
  actual="${actual:-0}"

  if [[ "$actual" == "$expected" ]]; then
    pass "$description"
  else
    fail "$description (expected $expected, found $actual)"
  fi
}

# Assert sibling resources of the same type do not contain `pattern`.
assert_sibling_resource_blocks_not_contains() {
  local file="$1"
  local resource_type="$2"
  local allowed_resource_name="$3"
  local pattern="$4"
  local description="$5"
  local resource_names
  local resource_name
  local block
  local offenders=()

  resource_names=$(
    strip_comments "$file" | awk -v resource_type="$resource_type" '
      match($0, "^[[:space:]]*resource[[:space:]]+\"" resource_type "\"[[:space:]]+\"[^\"]+\"[[:space:]]*\\{") {
        line = $0
        sub("^[[:space:]]*resource[[:space:]]+\"" resource_type "\"[[:space:]]+\"", "", line)
        sub("\"[[:space:]]*\\{.*$", "", line)
        print line
      }
    '
  )

  while IFS= read -r resource_name; do
    [[ -z "$resource_name" || "$resource_name" == "$allowed_resource_name" ]] && continue
    block="$(extract_active_resource_block "$file" "$resource_type" "$resource_name")"
    if rg -q "$pattern" <<<"$block"; then
      offenders+=("${resource_type}.${resource_name}")
    fi
  done <<<"$resource_names"

  if (( ${#offenders[@]} == 0 )); then
    pass "$description"
  else
    fail "$description (offenders: ${offenders[*]})"
  fi
}

# Assert locals.public_dns_records.<entry>.content equals expected value.
assert_public_dns_record_content() {
  local file="$1"
  local entry="$2"
  local expected="$3"
  local label="$4"
  local actual

  actual=$(
    strip_comments "$file" | awk -v target="$entry" '
      BEGIN { in_records = 0; in_entry = 0; depth = 0 }
      /public_dns_records[[:space:]]*=[[:space:]]*{/ { in_records = 1; depth = 1; next }
      {
        if (!in_records) next

        opens = gsub(/{/, "{", $0)
        closes = gsub(/}/, "}", $0)
        depth += opens - closes
        if (depth <= 0) { in_records = 0; in_entry = 0; next }

        if ($0 ~ "^[[:space:]]*" target "[[:space:]]*=[[:space:]]*{") {
          in_entry = 1
          entry_depth = depth
          next
        }

        if (in_entry && $0 ~ /^[[:space:]]*content[[:space:]]*=/) {
          line = $0
          sub(/^[[:space:]]*content[[:space:]]*=[[:space:]]*/, "", line)
          gsub(/[[:space:]]+$/, "", line)
          print line
          exit
        }

        if (in_entry && depth < entry_depth) {
          in_entry = 0
        }
      }
    '
  )

  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected $expected, found ${actual:-<missing>})"
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
