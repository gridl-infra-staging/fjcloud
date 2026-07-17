#!/usr/bin/env bash
set -euo pipefail
EVID_DIR="docs/runbooks/evidence/may16_wave_deploy_verify/20260518T231734Z/stage5_auth_lockout_proof"
mkdir -p "$EVID_DIR"
set -a
source .secret/.env.secret
set +a
source <(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging)
source scripts/lib/http_json.sh
source scripts/lib/staging_db.sh

json_quote() {
  python3 - "$1" <<'PYQ'
import json, sys
print(json.dumps(sys.argv[1]))
PYQ
}

capture_http() {
  local label="$1" method="$2" path="$3" payload="$4"
  local req="$EVID_DIR/${label}.request.json"
  local hdr="$EVID_DIR/${label}.response.headers"
  local body="$EVID_DIR/${label}.response.body.json"
  local codefile="$EVID_DIR/${label}.http_code"
  printf '%s\n' "$payload" > "$req"
  local code
  code="$(curl -sS -X "$method" "${API_URL}${path}" -H "Content-Type: application/json" -D "$hdr" -o "$body" -w "%{http_code}" -d "$payload")"
  printf '%s\n' "$code" > "$codefile"
}

expect_code() {
  local label="$1" expected="$2"
  local got
  got="$(cat "$EVID_DIR/${label}.http_code")"
  if [ "$got" != "$expected" ]; then
    echo "ERROR: ${label} expected HTTP ${expected}, got ${got}" >&2
    return 1
  fi
}

nonce="stage5$(date -u +%Y%m%d%H%M%S)${RANDOM}"
email="canary+${nonce}@test.flapjack.foo"
password="Stage5-$(python3 - <<'PYPW'
import secrets
print(secrets.token_hex(16))
PYPW
)"

signup_payload="$(printf '{"name":"Staging Customer Canary","email":%s,"password":%s}' "$(json_quote "$email")" "$(json_quote "$password")")"
capture_http "signup" "POST" "/auth/register" "$signup_payload"
signup_code="$(cat "$EVID_DIR/signup.http_code")"
if [ "$signup_code" != "200" ] && [ "$signup_code" != "201" ]; then
  echo "ERROR: signup expected HTTP 200/201, got ${signup_code}" >&2
  exit 1
fi

read -r token customer_id < <(python3 - "$EVID_DIR/signup.response.body.json" <<'PYTOK'
import json, sys
p = json.load(open(sys.argv[1]))
print((p.get("token") or "").strip(), (p.get("customer_id") or "").strip())
PYTOK
)
if [ -z "$token" ] || [ -z "$customer_id" ]; then
  echo "ERROR: signup response missing token/customer_id" >&2
  exit 1
fi
printf '%s\n' "$customer_id" > "$EVID_DIR/customer_id.txt"
printf '%s\n' "$email" > "$EVID_DIR/customer_email.txt"

login_ok_payload="$(printf '{"email":%s,"password":%s}' "$(json_quote "$email")" "$(json_quote "$password")")"
capture_http "login_prelockout_success" "POST" "/auth/login" "$login_ok_payload"
expect_code "login_prelockout_success" "200"

wrong_password="${password}-wrong"
login_bad_payload="$(printf '{"email":%s,"password":%s}' "$(json_quote "$email")" "$(json_quote "$wrong_password")")"
for attempt in 1 2 3 4; do
  capture_http "login_wrong_attempt_${attempt}" "POST" "/auth/login" "$login_bad_payload"
  expect_code "login_wrong_attempt_${attempt}" "400"
done

capture_http "login_wrong_attempt_5" "POST" "/auth/login" "$login_bad_payload"
expect_code "login_wrong_attempt_5" "429"

capture_http "login_correct_during_lockout" "POST" "/auth/login" "$login_ok_payload"
expect_code "login_correct_during_lockout" "429"

retry_after_wrong5="$(awk 'tolower($1)=="retry-after:" {gsub("\r", "", $2); print $2}' "$EVID_DIR/login_wrong_attempt_5.response.headers" | tail -1)"
retry_after_correct_lockout="$(awk 'tolower($1)=="retry-after:" {gsub("\r", "", $2); print $2}' "$EVID_DIR/login_correct_during_lockout.response.headers" | tail -1)"
if [[ ! "$retry_after_wrong5" =~ ^[0-9]+$ ]]; then
  echo "ERROR: non-numeric Retry-After for wrong attempt 5: ${retry_after_wrong5:-<empty>}" >&2
  exit 1
fi
if [[ ! "$retry_after_correct_lockout" =~ ^[0-9]+$ ]]; then
  echo "ERROR: non-numeric Retry-After for correct-password lockout: ${retry_after_correct_lockout:-<empty>}" >&2
  exit 1
fi
cat > "$EVID_DIR/retry_after_parsed.txt" <<EOF
login_wrong_attempt_5_retry_after_seconds=${retry_after_wrong5}
login_correct_during_lockout_retry_after_seconds=${retry_after_correct_lockout}
EOF

schema_sql="SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema='public' AND table_name='customers' AND column_name IN ('failed_login_count','failed_login_window_start','login_locked_until') ORDER BY column_name;"
staging_db_run_sql "$DATABASE_URL" "$schema_sql" > "$EVID_DIR/information_schema_lockout_columns.txt"

state_sql="SELECT id, failed_login_count, failed_login_window_start, login_locked_until, (login_locked_until > NOW()) AS lockout_active FROM customers WHERE id='${customer_id}';"
staging_db_run_sql "$DATABASE_URL" "$state_sql" > "$EVID_DIR/customer_lockout_state_row.txt"

verify_sql="SELECT (failed_login_count >= 5) AS failed_count_ge_5, (failed_login_window_start IS NOT NULL) AS has_window_start, (login_locked_until > NOW()) AS lockout_in_future FROM customers WHERE id='${customer_id}';"
staging_db_run_sql "$DATABASE_URL" "$verify_sql" > "$EVID_DIR/customer_lockout_state_assertions.txt"

capture_http "cleanup_delete_account" "DELETE" "/account" "$(printf '{"password":%s}' "$(json_quote "$password")")"
cleanup_account_code="$(cat "$EVID_DIR/cleanup_delete_account.http_code")"
if [ "$cleanup_account_code" != "204" ] && [ "$cleanup_account_code" != "404" ]; then
  echo "ERROR: cleanup delete account expected 204/404, got ${cleanup_account_code}" >&2
  exit 1
fi

admin_hdr="$EVID_DIR/cleanup_admin_delete.response.headers"
admin_body="$EVID_DIR/cleanup_admin_delete.response.body.json"
admin_code_file="$EVID_DIR/cleanup_admin_delete.http_code"
admin_code="$(
  curl -sS --config - -X DELETE "${API_URL}/admin/tenants/${customer_id}" \
    -D "$admin_hdr" \
    -o "$admin_body" \
    -w "%{http_code}" <<EOF
header = "x-admin-key: ${ADMIN_KEY}"
EOF
)"
printf '%s\n' "$admin_code" > "$admin_code_file"
if [ "$admin_code" != "204" ] && [ "$admin_code" != "404" ]; then
  echo "ERROR: cleanup admin delete expected 204/404, got ${admin_code}" >&2
  exit 1
fi

echo "STAGE5_PROBE_SUCCESS customer_id=${customer_id}" > "$EVID_DIR/probe_status.txt"
