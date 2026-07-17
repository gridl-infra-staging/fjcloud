#!/usr/bin/env bash
# Web form-login contract probe for deployed fjcloud web actions.
# Required env:
#   FJCLOUD_SECRET_FILE (optional path; defaults to repo-local .secret/.env.secret)
# Usage:
#   web_form_login_contract.sh [--self-test|prod|staging|all]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/contract_secret_env.sh"
DEFAULT_SECRET_FILE="$REPO_ROOT/.secret/.env.secret"

AUTH_SESSION_UNAVAILABLE_MESSAGE="Authentication session could not be established. Please verify JWT_SECRET and try again."
REGISTER_MAX_ATTEMPTS=5
REGISTER_RETRY_SECONDS=2

usage() {
  cat >&2 <<EOF
usage: $0 [--self-test|prod|staging|all]
required env:
  FJCLOUD_SECRET_FILE (optional override; default: $DEFAULT_SECRET_FILE)
EOF
  exit 2
}

json_field() {
  local input="$1" expr="$2"
  printf "%s" "$input" | python3 -c "import json,sys
obj=json.load(sys.stdin)
cur=obj
for part in sys.argv[1].split(\".\"):
    if not isinstance(cur, dict) or part not in cur:
        print(\"\")
        raise SystemExit(0)
    cur=cur[part]
print(cur if isinstance(cur, str) else str(cur))" "$expr" 2>/dev/null || true
}

assert_redirect_json_shape() {
  local body="$1"
  local t location status
  t="$(json_field "$body" type)"
  location="$(json_field "$body" location)"
  status="$(json_field "$body" status)"
  [[ "$t" == "redirect" && "$location" == "/console" && "$status" == "303" ]]
}

assert_auth_unavailable_json_shape() {
  local body="$1"
  local t status message
  t="$(json_field "$body" type)"
  status="$(json_field "$body" status)"
  message="$(json_field "$body" data.errors.form)"
  [[ "$t" == "failure" && "$status" == "503" && "$message" == "$AUTH_SESSION_UNAVAILABLE_MESSAGE" ]]
}

is_rate_limited_body() {
  local body="$1"
  printf "%s" "$body" | grep -qi "too many requests"
}

run_self_test() {
  local good bad_jwt empty malformed
  local usage_output
  good="{\"type\":\"redirect\",\"status\":303,\"location\":\"/console\"}"
  bad_jwt="{\"type\":\"failure\",\"status\":503,\"data\":{\"errors\":{\"form\":\"Authentication session could not be established. Please verify JWT_SECRET and try again.\"},\"email\":\"probe@e2e.griddle.test\"}}"
  empty=""
  malformed="{\"type\":\"redirect\""

  usage_output="$( (usage) 2>&1 || true )"
  if ! printf "%s" "$usage_output" | grep -q "FJCLOUD_SECRET_FILE"; then
    echo "self-test FAIL: usage must document FJCLOUD_SECRET_FILE"
    return 1
  fi
  if ! printf "%s" "$usage_output" | grep -Fq "$DEFAULT_SECRET_FILE"; then
    echo "self-test FAIL: usage must document repo-local default secret path"
    return 1
  fi

  local tmp_single tmp_override tmp_export_crlf
  tmp_single="$(mktemp)"
  tmp_override="$(mktemp)"
  tmp_export_crlf="$(mktemp)"
  printf "CONTRACT_TEST_SINGLE='single-quoted-value'\n" > "$tmp_single"
  printf "CONTRACT_TEST_OVERRIDE=file-should-not-win\n" > "$tmp_override"
  printf "export CONTRACT_TEST_EXPORT=from-export\r\n   CONTRACT_TEST_WS=from-whitespace\r\n" > "$tmp_export_crlf"

  if ! load_contract_secret_env "$tmp_single"; then
    echo "self-test FAIL: single-quoted secret should parse"
    rm -f "$tmp_single" "$tmp_override" "$tmp_export_crlf"
    return 1
  fi
  if [[ "${CONTRACT_TEST_SINGLE:-}" != "single-quoted-value" ]]; then
    echo "self-test FAIL: single-quoted secret should have quotes stripped"
    rm -f "$tmp_single" "$tmp_override" "$tmp_export_crlf"
    return 1
  fi

  CONTRACT_TEST_OVERRIDE="explicit-wins"
  export CONTRACT_TEST_OVERRIDE
  if ! load_contract_secret_env "$tmp_override"; then
    echo "self-test FAIL: explicit env override fixture should parse"
    rm -f "$tmp_single" "$tmp_override" "$tmp_export_crlf"
    return 1
  fi
  if [[ "${CONTRACT_TEST_OVERRIDE:-}" != "explicit-wins" ]]; then
    echo "self-test FAIL: explicit exported env var must not be overwritten by secret file"
    rm -f "$tmp_single" "$tmp_override" "$tmp_export_crlf"
    return 1
  fi

  if ! load_contract_secret_env "$tmp_export_crlf"; then
    echo "self-test FAIL: canonical parser should accept export KEY=, leading whitespace, and CRLF"
    rm -f "$tmp_single" "$tmp_override" "$tmp_export_crlf"
    return 1
  fi
  if [[ "${CONTRACT_TEST_EXPORT:-}" != "from-export" || "${CONTRACT_TEST_WS:-}" != "from-whitespace" ]]; then
    echo "self-test FAIL: export/whitespace CRLF assignments should parse with canonical semantics"
    rm -f "$tmp_single" "$tmp_override" "$tmp_export_crlf"
    return 1
  fi
  rm -f "$tmp_single" "$tmp_override" "$tmp_export_crlf"
  unset CONTRACT_TEST_SINGLE CONTRACT_TEST_OVERRIDE CONTRACT_TEST_EXPORT CONTRACT_TEST_WS

  assert_redirect_json_shape "$good" || { echo "self-test FAIL: known-good redirect shape rejected"; return 1; }
  if assert_redirect_json_shape "$bad_jwt"; then
    echo "self-test FAIL: JWT-mismatch failure shape incorrectly accepted as redirect"
    return 1
  fi
  if assert_redirect_json_shape "$empty"; then
    echo "self-test FAIL: empty payload incorrectly accepted as redirect"
    return 1
  fi
  if assert_redirect_json_shape "$malformed"; then
    echo "self-test FAIL: malformed payload incorrectly accepted as redirect"
    return 1
  fi

  assert_auth_unavailable_json_shape "$bad_jwt" || { echo "self-test FAIL: known 503 failure shape rejected"; return 1; }
  echo "self-test PASS: redirect/failure shape assertions behave as expected"
}

probe_env() {
  local env="$1"
  local api_origin web_origin
  local seed probe_email probe_password register_payload register_body token customer_id
  local register_attempt
  local login_body cleanup_status cleanup_tmp

  case "$env" in
    prod)
      api_origin="https://api.flapjack.foo"
      web_origin="https://cloud.flapjack.foo"
      ;;
    staging)
      api_origin="https://api.staging.flapjack.foo"
      web_origin="https://cloud.staging.flapjack.foo"
      ;;
    *)
      echo "ERROR: unknown env $env" >&2
      return 1
      ;;
  esac

  probe_password="ContractProbe123!"
  register_body=""
  token=""
  customer_id=""
  for register_attempt in $(seq 1 "$REGISTER_MAX_ATTEMPTS"); do
    seed="$(date -u +%s)-$RANDOM"
    probe_email="probe-login-contract-${env}-${seed}@e2e.griddle.test"
    register_payload="$(printf "{\"name\":\"login contract %s\",\"email\":\"%s\",\"password\":\"%s\"}" "$seed" "$probe_email" "$probe_password")"
    register_body="$(curl -sS --max-time 20 -H "Content-Type: application/json" -d "$register_payload" "${api_origin}/auth/register" || true)"
    token="$(json_field "$register_body" token)"
    customer_id="$(json_field "$register_body" customer_id)"
    if [[ -n "$token" && -n "$customer_id" ]]; then
      break
    fi
    if is_rate_limited_body "$register_body" && [[ "$register_attempt" -lt "$REGISTER_MAX_ATTEMPTS" ]]; then
      sleep "$REGISTER_RETRY_SECONDS"
      continue
    fi
    break
  done

  if [[ -z "$token" || -z "$customer_id" ]]; then
    if is_rate_limited_body "$register_body"; then
      echo "SKIP: env=$env /auth/register remained rate-limited after ${REGISTER_MAX_ATTEMPTS} attempts"
      return 0
    fi
    echo "FAIL: env=$env /auth/register did not return AuthResponse {token,customer_id}" >&2
    echo "      body=${register_body:0:280}" >&2
    return 1
  fi

  login_body="$(curl -sS --max-time 20 \
    -H "Origin: ${web_origin}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "email=${probe_email}" \
    --data-urlencode "password=${probe_password}" \
    "${web_origin}/login" || true)"

  cleanup_tmp="/tmp/web_form_login_cleanup_${env}_$$.txt"
  cleanup_status="$(curl -sS --max-time 20 -o "$cleanup_tmp" -w "%{http_code}" \
    -X DELETE \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "{\"password\":\"${probe_password}\"}" \
    "${api_origin}/account" || true)"

  case "$cleanup_status" in
    204) ;;
    400|401|403|404)
      echo "FAIL: env=$env cleanup DELETE /account returned ${cleanup_status}" >&2
      echo "      cleanup body=$(head -c 220 "$cleanup_tmp" 2>/dev/null || true)" >&2
      rm -f "$cleanup_tmp"
      return 1
      ;;
    *)
      echo "FAIL: env=$env cleanup DELETE /account returned unexpected ${cleanup_status}" >&2
      echo "      cleanup body=$(head -c 220 "$cleanup_tmp" 2>/dev/null || true)" >&2
      rm -f "$cleanup_tmp"
      return 1
      ;;
  esac
  rm -f "$cleanup_tmp"

  if assert_redirect_json_shape "$login_body"; then
    echo "PASS: env=$env web form login redirected to /console"
    return 0
  fi
  if assert_auth_unavailable_json_shape "$login_body"; then
    echo "FAIL: env=$env web login returned JWT session-unavailable 503 shape (secret drift)" >&2
    return 1
  fi
  if printf "%s" "$login_body" | grep -q "/login?reason=session_expired"; then
    echo "FAIL: env=$env web login returned session_expired redirect shape" >&2
    return 1
  fi

  echo "FAIL: env=$env web login returned unexpected shape" >&2
  echo "      body=${login_body:0:320}" >&2
  return 1
}

main() {
  local arg="${1:-all}"
  case "$arg" in
    --self-test)
      run_self_test
      exit $?
      ;;
    prod|staging|all) ;;
    *) usage ;;
  esac

  local secret_file="${FJCLOUD_SECRET_FILE:-$DEFAULT_SECRET_FILE}"
  if [[ -f "$secret_file" ]]; then
    load_contract_secret_env "$secret_file"
  fi

  local fail=0
  if [[ "$arg" == "prod" || "$arg" == "all" ]]; then
    probe_env prod || fail=1
  fi
  if [[ "$arg" == "staging" || "$arg" == "all" ]]; then
    probe_env staging || fail=1
  fi
  exit "$fail"
}

main "$@"
