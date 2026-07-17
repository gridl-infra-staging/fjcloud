#!/usr/bin/env bash
# Read-only safety oracle for the fail-closed Algolia migration state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
# shellcheck source=scripts/canary/contracts/algolia_invalid_credentials_contract.sh
source "$REPO_ROOT/scripts/canary/contracts/algolia_invalid_credentials_contract.sh"

ENVIRONMENT=""
EXPECTED_API_DEV_SHA=""
EXPECTED_API_MIRROR_SHA=""
EXPECTED_PAGES_SHA=""
ALGOLIA_MIGRATION_PROBE_TOKEN_EFFECTIVE=""

usage() {
  cat <<'EOF'
Usage: algolia_migration_safety_probe.sh --env <staging|prod> --expected-api-dev-sha <40hex> --expected-api-mirror-sha <40hex> --expected-pages-sha <40hex>

Required env:
  ALGOLIA_MIGRATION_PROBE_TOKEN or ALGOLIA_INVALID_CREDENTIALS_TENANT_TOKEN
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --env)
        [ "${2:-}" != "" ] || die "--env requires a value"
        ENVIRONMENT="$2"
        shift 2
        ;;
      --expected-api-dev-sha)
        [ "${2:-}" != "" ] || die "--expected-api-dev-sha requires a value"
        EXPECTED_API_DEV_SHA="$2"
        shift 2
        ;;
      --expected-api-mirror-sha)
        [ "${2:-}" != "" ] || die "--expected-api-mirror-sha requires a value"
        EXPECTED_API_MIRROR_SHA="$2"
        shift 2
        ;;
      --expected-pages-sha)
        [ "${2:-}" != "" ] || die "--expected-pages-sha requires a value"
        EXPECTED_PAGES_SHA="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "unknown argument: $1"
        ;;
    esac
  done
}

require_40_hex_sha() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] \
    || die "$name must be a 40-character lowercase hexadecimal SHA"
}

validate_args() {
  [ -n "$ENVIRONMENT" ] || die "--env is required"
  [ -n "$EXPECTED_API_DEV_SHA" ] || die "--expected-api-dev-sha is required"
  [ -n "$EXPECTED_API_MIRROR_SHA" ] || die "--expected-api-mirror-sha is required"
  [ -n "$EXPECTED_PAGES_SHA" ] || die "--expected-pages-sha is required"

  case "$ENVIRONMENT" in
    staging|prod) ;;
    *) die "--env must be staging or prod" ;;
  esac

  require_40_hex_sha "--expected-api-dev-sha" "$EXPECTED_API_DEV_SHA"
  require_40_hex_sha "--expected-api-mirror-sha" "$EXPECTED_API_MIRROR_SHA"
  require_40_hex_sha "--expected-pages-sha" "$EXPECTED_PAGES_SHA"
}

load_secret_env_if_present() {
  local secret_file="${FJCLOUD_SECRET_FILE:-$DEFAULT_SECRET_FILE}"
  if [ -f "$secret_file" ]; then
    load_contract_secret_env "$secret_file"
  fi
}

resolve_probe_token() {
  ALGOLIA_MIGRATION_PROBE_TOKEN_EFFECTIVE="${ALGOLIA_MIGRATION_PROBE_TOKEN:-${ALGOLIA_INVALID_CREDENTIALS_TENANT_TOKEN:-}}"
  [ -n "$ALGOLIA_MIGRATION_PROBE_TOKEN_EFFECTIVE" ] \
    || die "ALGOLIA_MIGRATION_PROBE_TOKEN or ALGOLIA_INVALID_CREDENTIALS_TENANT_TOKEN is required"
}

get_json() {
  local url="$1"
  shift
  local response

  response="$(curl -sS --max-time 30 -w "\n%{http_code}" "$@" "$url" || true)"
  capture_http_response "$response"
  [ "$HTTP_STATUS" = "200" ] || die "GET $url returned HTTP $HTTP_STATUS"
}

get_json_with_bearer() {
  local url="$1"
  local token="$2"
  local header_file response

  header_file="$(mktemp "${TMPDIR:-/tmp}/algolia_probe_auth_header.XXXXXX")"
  chmod 600 "$header_file"
  printf 'Authorization: Bearer %s\n' "$token" > "$header_file"
  response="$(curl -sS --max-time 30 -w "\n%{http_code}" -H @"$header_file" "$url" || true)"
  rm -f "$header_file"

  capture_http_response "$response"
  [ "$HTTP_STATUS" = "200" ] || die "GET $url returned HTTP $HTTP_STATUS"
}

assert_version() {
  local body="$1"
  local dev_sha mirror_sha

  dev_sha="$(json_field "$body" dev_sha)"
  mirror_sha="$(json_field "$body" mirror_sha)"
  [ "$dev_sha" = "$EXPECTED_API_DEV_SHA" ] \
    || die "/version dev_sha mismatch: expected $EXPECTED_API_DEV_SHA"
  [ "$mirror_sha" = "$EXPECTED_API_MIRROR_SHA" ] \
    || die "/version mirror_sha mismatch: expected $EXPECTED_API_MIRROR_SHA"
}

assert_unavailable() {
  local body="$1"
  local available reason

  available="$(json_field "$body" available)"
  reason="$(json_field "$body" reason)"
  [ "$available" = "false" ] || die "availability.available must be false"
  [ "$reason" = "temporarily_unavailable" ] \
    || die "availability reason must be temporarily_unavailable"
}

assert_pages_version() {
  local body="$1"
  local version

  version="$(json_field "$body" version)"
  [ "$version" = "$EXPECTED_PAGES_SHA" ] \
    || die "Pages version mismatch: expected $EXPECTED_PAGES_SHA"
}

run_browser_probe() {
  local api_origin="$1"
  local web_origin="$2"
  local output

  output="$(
    cd "$REPO_ROOT/web" && \
      BASE_URL="$web_origin" \
      API_BASE_URL="$api_origin" \
      API_URL="$api_origin" \
      npm run test:e2e -- --project=chromium --retries=0 tests/e2e-ui/full/migration-recovery.spec.ts
  )" || {
    printf '%s\n' "$output" >&2
    die "Playwright migration recovery scenario failed"
  }

  printf '%s\n' "$output"
  if printf '%s\n' "$output" | grep -qi "skipped"; then
    die "Playwright migration recovery scenario reported skipped assertions"
  fi
  if ! printf '%s\n' "$output" | grep -Eq "[[:space:]][1-9][0-9]* passed"; then
    die "Playwright migration recovery scenario did not report a passing test"
  fi
}

main() {
  local api_origin web_origin

  parse_args "$@"
  validate_args
  load_secret_env_if_present
  resolve_probe_token

  api_origin="$(api_origin_for "$ENVIRONMENT")"
  web_origin="$(web_origin_for "$ENVIRONMENT")"

  get_json "${api_origin}/version"
  assert_version "$HTTP_BODY"

  get_json_with_bearer "${api_origin}/migration/algolia/availability" \
    "$ALGOLIA_MIGRATION_PROBE_TOKEN_EFFECTIVE"
  assert_unavailable "$HTTP_BODY"

  get_json "${web_origin}/_app/version.json"
  assert_pages_version "$HTTP_BODY"

  run_browser_probe "$api_origin" "$web_origin"
  echo "PASS: $ENVIRONMENT Algolia migration safety probe"
}

main "$@"
