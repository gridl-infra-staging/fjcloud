#!/usr/bin/env bash
set -euo pipefail

EVID_DIR="docs/runbooks/evidence/may16_wave_deploy_verify/20260518T231734Z/stage5_auth_lockout_proof"
mkdir -p "$EVID_DIR"

set -a
source .secret/.env.secret
set +a
source <(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging)
export DATABASE_URL_SSM_PARAM="/fjcloud/staging/database_url"
source scripts/lib/http_json.sh
source scripts/lib/staging_db.sh

json_quote() {
  python3 - "$1" <<'PYQ'
import json
import sys
print(json.dumps(sys.argv[1]))
PYQ
}

capture_http() {
  local label="$1"
  local caller="$2"
  local method="$3"
  local path="$4"
  local payload="$5"
  local req="$EVID_DIR/${label}.request.json"
  local hdr="$EVID_DIR/${label}.response.headers"
  local body="$EVID_DIR/${label}.response.body.json"
  local code_file="$EVID_DIR/${label}.http_code"
  local code

  printf '%s\n' "$payload" > "$req"

  case "$caller" in
    api)
      code="$(api_json_call "$method" "$path" -D "$hdr" -o "$body" -w "%{http_code}" -d "$payload")"
      ;;
    tenant)
      code="$(tenant_call "$method" "$path" "$CANARY_TOKEN" -D "$hdr" -o "$body" -w "%{http_code}" -d "$payload")"
      ;;
    admin)
      code="$(admin_call "$method" "$path" -D "$hdr" -o "$body" -w "%{http_code}")"
      ;;
    *)
      echo "ERROR: unknown caller '$caller'" >&2
      return 1
      ;;
  esac

  printf '%s\n' "$code" > "$code_file"
}

expect_code() {
  local label="$1"
  local expected="$2"
  local got
  got="$(cat "$EVID_DIR/${label}.http_code")"
  if [ "$got" != "$expected" ]; then
    echo "ERROR: ${label} expected HTTP ${expected}, got ${got}" >&2
    return 1
  fi
}

nonce="stage5b$(date -u +%Y%m%d%H%M%S)${RANDOM}"
email="canary+${nonce}@test.flapjack.foo"
password="Stage5b-$(python3 - <<'PYPW'
import secrets
print(secrets.token_hex(16))
PYPW
)"

signup_payload="$(printf '{"name":"Staging Customer Canary","email":%s,"password":%s}' "$(json_quote "$email")" "$(json_quote "$password")")"
capture_http "signup_run2" "api" "POST" "/auth/register" "$signup_payload"
signup_code="$(cat "$EVID_DIR/signup_run2.http_code")"
if [ "$signup_code" != "200" ] && [ "$signup_code" != "201" ]; then
  echo "ERROR: signup expected HTTP 200/201, got ${signup_code}" >&2
  exit 1
fi

read -r CANARY_TOKEN customer_id < <(python3 - "$EVID_DIR/signup_run2.response.body.json" <<'PYTOK'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
print((payload.get("token") or "").strip(), (payload.get("customer_id") or "").strip())
PYTOK
)
if [ -z "${CANARY_TOKEN:-}" ] || [ -z "$customer_id" ]; then
  echo "ERROR: signup response missing token/customer_id" >&2
  exit 1
fi
printf '%s\n' "$customer_id" > "$EVID_DIR/customer_id_run2.txt"
printf '%s\n' "$email" > "$EVID_DIR/customer_email_run2.txt"

ok_payload="$(printf '{"email":%s,"password":%s}' "$(json_quote "$email")" "$(json_quote "$password")")"
bad_payload="$(printf '{"email":%s,"password":%s}' "$(json_quote "$email")" "$(json_quote "${password}-wrong")")"

capture_http "login_prelockout_success_run2" "api" "POST" "/auth/login" "$ok_payload"
expect_code "login_prelockout_success_run2" "200"

for attempt in 1 2 3 4; do
  capture_http "login_wrong_attempt_${attempt}_run2" "api" "POST" "/auth/login" "$bad_payload"
  expect_code "login_wrong_attempt_${attempt}_run2" "400"
done
capture_http "login_wrong_attempt_5_run2" "api" "POST" "/auth/login" "$bad_payload"
expect_code "login_wrong_attempt_5_run2" "429"

capture_http "login_correct_after_five_failures_run2" "api" "POST" "/auth/login" "$ok_payload"
expect_code "login_correct_after_five_failures_run2" "429"

awk 'tolower($1)=="retry-after:" {gsub("\r", "", $2); print $2}' "$EVID_DIR/login_wrong_attempt_5_run2.response.headers" | tail -1 > "$EVID_DIR/retry_after_wrong5_run2.txt"
awk 'tolower($1)=="retry-after:" {gsub("\r", "", $2); print $2}' "$EVID_DIR/login_correct_after_five_failures_run2.response.headers" | tail -1 > "$EVID_DIR/retry_after_correct_after_five_run2.txt"

schema_sql="SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema='public' AND table_name='customers' AND column_name IN ('failed_login_count','failed_login_window_start','login_locked_until') ORDER BY column_name;"
staging_db_run_sql "$DATABASE_URL" "$schema_sql" > "$EVID_DIR/information_schema_lockout_columns_run2.txt"
state_sql="SELECT id, failed_login_count, failed_login_window_start, login_locked_until, (login_locked_until > NOW()) AS lockout_active FROM customers WHERE id='${customer_id}';"
staging_db_run_sql "$DATABASE_URL" "$state_sql" > "$EVID_DIR/customer_lockout_state_row_run2.txt"
verify_sql="SELECT (failed_login_count >= 5) AS failed_count_ge_5, (failed_login_window_start IS NOT NULL) AS has_window_start, (login_locked_until > NOW()) AS lockout_in_future FROM customers WHERE id='${customer_id}';"
staging_db_run_sql "$DATABASE_URL" "$verify_sql" > "$EVID_DIR/customer_lockout_state_assertions_run2.txt"

cleanup_payload="$(printf '{"password":%s}' "$(json_quote "$password")")"
capture_http "cleanup_delete_account_run2" "tenant" "DELETE" "/account" "$cleanup_payload"
cleanup_code="$(cat "$EVID_DIR/cleanup_delete_account_run2.http_code")"
if [ "$cleanup_code" != "204" ] && [ "$cleanup_code" != "404" ]; then
  echo "ERROR: cleanup delete account expected HTTP 204/404, got ${cleanup_code}" >&2
  exit 1
fi

capture_http "cleanup_admin_delete_run2" "admin" "DELETE" "/admin/tenants/${customer_id}" "{}"
admin_code="$(cat "$EVID_DIR/cleanup_admin_delete_run2.http_code")"
if [ "$admin_code" != "204" ] && [ "$admin_code" != "404" ]; then
  echo "ERROR: admin cleanup expected HTTP 204/404, got ${admin_code}" >&2
  exit 1
fi

post_cleanup_sql="SELECT id, status, deleted_at IS NOT NULL AS has_deleted_at FROM customers WHERE id='${customer_id}';"
staging_db_run_sql "$DATABASE_URL" "$post_cleanup_sql" > "$EVID_DIR/cleanup_customer_post_state_run2.txt"
