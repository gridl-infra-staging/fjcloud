#!/usr/bin/env bash
# Static contract test for docs/screen_specs/coverage.md.
#
# This keeps the route/spec/test map useful without requiring a live browser or
# local stack. It verifies that promoted coverage rows point to real files and
# that individual specs keep the sections needed for criterion-level mapping.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COVERAGE_FILE="$REPO_ROOT/docs/screen_specs/coverage.md"
SPECS_DIR="$REPO_ROOT/docs/screen_specs"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  echo "PASS: $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "FAIL: $1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

normalize_path() {
  local value
  value="$(trim "$1")"
  value="${value#\`}"
  value="${value%\`}"
  printf '%s' "$value"
}

assert_file_exists() {
  local rel_path
  rel_path="$(normalize_path "$1")"
  local msg="$2"
  case "$rel_path" in
    "" | /* | .. | ../* | */.. | */../*)
      fail "$msg (unsafe repo-relative path: $rel_path)"
      return
      ;;
  esac
  if [[ -f "$REPO_ROOT/$rel_path" ]]; then
    pass "$msg"
  else
    fail "$msg (missing file: $rel_path)"
  fi
}

assert_not_contains() {
  local pattern="$1"
  local file="$2"
  local msg="$3"
  if grep -E -n -- "$pattern" "$file" >/dev/null 2>&1; then
    fail "$msg"
  else
    pass "$msg"
  fi
}

assert_contains() {
  local pattern="$1"
  local file="$2"
  local msg="$3"
  if grep -E -n -- "$pattern" "$file" >/dev/null 2>&1; then
    pass "$msg"
  else
    fail "$msg"
  fi
}

assert_semicolon_paths_exist() {
  local value="$1"
  local row_label="$2"
  local column_label="$3"

  if [[ "$value" == Missing* ]]; then
    fail "$row_label ${column_label} is still marked missing"
    return
  fi

  local old_ifs="$IFS"
  IFS=';'
  read -r -a paths <<< "$value"
  IFS="$old_ifs"

  local path
  for path in "${paths[@]}"; do
    path="$(normalize_path "$path")"
    [[ -z "$path" ]] && continue
    assert_file_exists "$path" "$row_label ${column_label} exists: $path"
  done
}

assert_file_exists "docs/screen_specs/coverage.md" "coverage map exists"
assert_not_contains 'Missing spec|Missing browser-unmocked mapping|Browser-unmocked tests: missing mapping' "$COVERAGE_FILE" "coverage map has no stale missing markers"

while IFS= read -r line; do
  [[ "$line" == \|* ]] || continue
  [[ "$line" == *'---'* ]] && continue
  [[ "$line" == *'Priority'*'Route'* ]] && continue

  IFS='|' read -r _ priority route spec_path browser_paths component_paths status gaps _ <<< "$line"
  priority="$(trim "$priority")"
  route="$(trim "$route")"
  spec_path="$(trim "$spec_path")"
  browser_paths="$(trim "$browser_paths")"
  component_paths="$(trim "$component_paths")"
  status="$(trim "$status")"
  gaps="$(trim "$gaps")"
  row_label="${priority} ${route}"

  [[ -n "$priority" && -n "$route" && -n "$spec_path" && -n "$status" && -n "$gaps" ]] || {
    fail "coverage row has all required columns: $line"
    continue
  }

  assert_file_exists "$spec_path" "$row_label spec exists"
  assert_semicolon_paths_exist "$browser_paths" "$row_label" "browser test path"
  assert_semicolon_paths_exist "$component_paths" "$row_label" "component test path"
done < "$COVERAGE_FILE"

ERROR_BOUNDARIES_SPEC="$SPECS_DIR/error_boundaries.md"

assert_contains '^- \[x\] Public and dashboard boundaries each render exactly one `Support reference` label\.$' "$ERROR_BOUNDARIES_SPEC" "error boundaries spec marks support-reference label criterion satisfied"
assert_contains '^- \[x\] Each boundary renders one customer-visible support reference matching `web-\[a-f0-9\]\{12\}`\.$' "$ERROR_BOUNDARIES_SPEC" "error boundaries spec marks support-reference format criterion satisfied"
assert_contains '^- \[x\] Existing privacy guardrails remain intact: unsafe infrastructure details stay hidden and raw 5xx internals stay suppressed\.$' "$ERROR_BOUNDARIES_SPEC" "error boundaries spec marks privacy guardrails criterion satisfied"
assert_contains '^- \[x\] Support-contact copy for both boundaries is sourced from `SUPPORT_EMAIL`\.$' "$ERROR_BOUNDARIES_SPEC" "error boundaries spec marks support-contact source criterion satisfied"
assert_contains '^- \[x\] Backend `x-request-id` values are preserved by `ApiRequestError` metadata \(`web/src/lib/api/client.ts:80-126`\) and paired with the web support reference in route-error logs \(`web/src/hooks.server.ts:86-114`\)\.$' "$ERROR_BOUNDARIES_SPEC" "error boundaries spec marks backend request-id correlation satisfied"
assert_contains '^- Component tests: `web/src/lib/error-boundary/recovery-copy.test.ts`; `web/src/lib/error-boundary/SupportReferenceBlock.test.ts`; `web/src/lib/error-boundary/client-runtime.test.ts`; `web/src/routes/layout.test.ts`; `web/src/routes/error.test.ts`; `web/src/routes/dashboard/error.test.ts`$' "$ERROR_BOUNDARIES_SPEC" "error boundaries spec component coverage lists shared helper/component and route owners"
assert_contains '^- Server/contract tests: `web/src/lib/api/client.test.ts`; `web/src/hooks.server.test.ts`$' "$ERROR_BOUNDARIES_SPEC" "error boundaries spec server coverage lists API client and route error hook tests"
assert_contains 'Public route error boundary .*web/src/lib/error-boundary/recovery-copy.test.ts.*web/src/lib/error-boundary/SupportReferenceBlock.test.ts.*web/src/lib/error-boundary/client-runtime.test.ts.*web/src/routes/layout.test.ts.*web/src/routes/error.test.ts.*web/src/routes/dashboard/error.test.ts' "$COVERAGE_FILE" "public error boundary coverage row includes shared helper/component and route tests"
assert_contains 'Dashboard route error boundary .*web/src/lib/error-boundary/recovery-copy.test.ts.*web/src/lib/error-boundary/SupportReferenceBlock.test.ts.*web/src/lib/error-boundary/client-runtime.test.ts.*web/src/routes/layout.test.ts.*web/src/routes/error.test.ts.*web/src/routes/dashboard/error.test.ts' "$COVERAGE_FILE" "dashboard error boundary coverage row includes shared helper/component and route tests"
assert_contains 'Public route error boundary .*Customer-visible reference remains `web-` prefixed; backend `x-request-id` appears only in server route-error logs when available; browser-only runtime failures are captured locally but not sent to a centralized or third-party sink\.' "$COVERAGE_FILE" "public error boundary gap documents server-log-only backend request-id correlation and centralized-reporting residual risk"
assert_contains 'Dashboard route error boundary .*Customer-visible reference remains `web-` prefixed; backend `x-request-id` appears only in server route-error logs when available; browser-only runtime failures are captured locally but not sent to a centralized or third-party sink\.' "$COVERAGE_FILE" "dashboard error boundary gap documents server-log-only backend request-id correlation and centralized-reporting residual risk"

for spec_file in "$SPECS_DIR"/*.md; do
  case "$(basename "$spec_file")" in
    _template.md | README.md | coverage.md) continue ;;
  esac

  assert_contains '^## Acceptance Criteria$' "$spec_file" "${spec_file#$REPO_ROOT/} has acceptance criteria"
  assert_contains '^## Current Implementation Gaps$' "$spec_file" "${spec_file#$REPO_ROOT/} has implementation gaps"
  assert_contains '^## Automated Coverage$' "$spec_file" "${spec_file#$REPO_ROOT/} has automated coverage"
  assert_not_contains 'Browser-unmocked tests: missing mapping' "$spec_file" "${spec_file#$REPO_ROOT/} has no missing browser mapping marker"
done

echo ""
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

[[ "$FAIL_COUNT" -eq 0 ]]
