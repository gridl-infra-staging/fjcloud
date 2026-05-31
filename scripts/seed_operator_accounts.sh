#!/usr/bin/env bash
# seed_operator_accounts.sh — Seed the six operator test accounts on staging or prod.
#
# Idempotent: accounts that already exist are treated as success.
# Requires a direct DATABASE_URL for force-verifying email (SKIP_EMAIL_VERIFICATION
# is production-gated and cannot be used here).
#
# Usage (staging):
#   API_URL=https://api.flapjack.foo \
#   DATABASE_URL_SSM_PARAM=/fjcloud/staging/database_url \
#   AWS_DEFAULT_REGION=us-east-1 \
#     bash scripts/seed_operator_accounts.sh
#
# If DATABASE_URL is set directly instead of via DATABASE_URL_SSM_PARAM,
# SSM_INSTANCE_ID must also be set (auto-detection requires the SSM param path).
# See docs/runbooks/staging-access.md for full context.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/db_url.sh"
source "$SCRIPT_DIR/lib/staging_db.sh"

log()  { echo "[seed-operator] $*"; }
die()  { echo "[seed-operator] ERROR: $*" >&2; exit 1; }
ok()   { echo "[seed-operator] OK  $*"; }

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

ACCOUNTS=(
    "q@q.q:qqqqqqqq"
    "a@a.a:aaaaaaaa"
    "w@w.w:wwwwwwww"
    "m@m.m:mmmmmmmm"
    "n@n.n:nnnnnnnn"
    "l@l.l:llllllll"
)

# ---------------------------------------------------------------------------
# Env resolution
# ---------------------------------------------------------------------------

if [ -z "${API_URL:-}" ]; then
    die "API_URL is required (e.g. https://api.flapjack.foo)"
fi
API_URL="${API_URL%/}"  # strip trailing slash

# Fetch DATABASE_URL from SSM if not set directly
if [ -z "${DATABASE_URL:-}" ]; then
    SSM_PARAM="${DATABASE_URL_SSM_PARAM:-}"
    if [ -z "$SSM_PARAM" ]; then
        die "DATABASE_URL or DATABASE_URL_SSM_PARAM must be set"
    fi
    log "Fetching DATABASE_URL from SSM: $SSM_PARAM"
    DATABASE_URL="$(aws ssm get-parameter \
        --name "$SSM_PARAM" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text \
        --region "${AWS_DEFAULT_REGION:-us-east-1}")"
    [ -n "$DATABASE_URL" ] || die "SSM parameter $SSM_PARAM returned empty value"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

api_post() {
    local path="$1" payload="$2"
    curl -s -X POST "${API_URL}${path}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        -w "\n%{http_code}" \
        --max-time 15
}

http_body()   { printf '%s\n' "$1" | sed '$d'; }
http_status() { printf '%s\n' "$1" | tail -1; }

force_verify_email() {
    local email="$1"
    local sql="UPDATE customers SET email_verified_at = COALESCE(email_verified_at, NOW()), email_verify_token = NULL, email_verify_expires_at = NULL, updated_at = NOW() WHERE email = '$email' AND status != 'deleted'"

    # Try local psql first (works when DATABASE_URL is locally reachable)
    local db_user db_password db_host db_port db_name
    db_user="$(db_url_user "$DATABASE_URL")"
    db_password="$(db_url_password "$DATABASE_URL")"
    db_host="$(db_url_host "$DATABASE_URL")"
    db_port="$(db_url_port "$DATABASE_URL" 2>/dev/null || echo "5432")"
    db_name="$(db_url_database "$DATABASE_URL")"

    if command -v psql >/dev/null 2>&1 \
        && PGPASSWORD="$db_password" psql -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" \
               -c "SELECT 1" >/dev/null 2>&1; then
        local count
        count="$(PGPASSWORD="$db_password" psql -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" \
            -v ON_ERROR_STOP=1 -tA -c "$sql" | tr -d '[:space:]')"
        # psql returns rowcount only with RETURNING; use a follow-up SELECT
        count="$(PGPASSWORD="$db_password" psql -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" \
            -v ON_ERROR_STOP=1 -tA -c "SELECT COUNT(*) FROM customers WHERE email='$email' AND email_verified_at IS NOT NULL AND status != 'deleted'" | tr -d '[:space:]')"
        [ "$count" = "1" ] || die "Email verify failed for $email (local psql, count=$count)"
    else
        # RDS is VPC-private; run via SSM on the API EC2 instance
        log "Local psql unavailable or DB unreachable — using SSM Run Command"
        staging_db_run_sql "$DATABASE_URL" "$sql" >/dev/null
    fi
    log "Email verified: $email"
}

# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

log "Checking API health at ${API_URL}/health …"
health_code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${API_URL}/health" || true)"
[ "$health_code" = "200" ] || die "API health check returned HTTP $health_code — is the API reachable?"
log "API is up."

# ---------------------------------------------------------------------------
# Seed loop
# ---------------------------------------------------------------------------

log "Seeding ${#ACCOUNTS[@]} operator accounts …"
echo

for pair in "${ACCOUNTS[@]}"; do
    email="${pair%%:*}"
    password="${pair##*:}"

    payload="$(python3 -c 'import json,sys; e,p=sys.argv[1],sys.argv[2]; print(json.dumps({"name":e,"email":e,"password":p}))' "$email" "$password")"

    # Try login first (idempotent — skip register if account already exists)
    login_resp="$(api_post /auth/login "$(python3 -c 'import json,sys; e,p=sys.argv[1],sys.argv[2]; print(json.dumps({"email":e,"password":p}))' "$email" "$password")")"
    login_code="$(http_status "$login_resp")"

    if [ "$login_code" = "200" ]; then
        token="$(http_body "$login_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null || true)"
        ok "$email — already exists, login confirmed (token=${token:0:12}…)"
        continue
    fi

    # Register
    reg_resp="$(api_post /auth/register "$payload")"
    reg_code="$(http_status "$reg_resp")"
    reg_body="$(http_body "$reg_resp")"

    if [ "$reg_code" = "201" ]; then
        log "Registered: $email"
    elif [ "$reg_code" = "409" ]; then
        log "Already registered (409): $email"
    else
        die "Registration failed for $email — HTTP $reg_code: $reg_body"
    fi

    # Force-verify email (required in non-local environments)
    force_verify_email "$email"

    # Confirm login works
    login_resp="$(api_post /auth/login "$(python3 -c 'import json,sys; e,p=sys.argv[1],sys.argv[2]; print(json.dumps({"email":e,"password":p}))' "$email" "$password")")"
    login_code="$(http_status "$login_resp")"
    if [ "$login_code" = "200" ]; then
        token="$(http_body "$login_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null || true)"
        ok "$email — login confirmed (token=${token:0:12}…)"
    else
        die "Login failed for $email after registration — HTTP $login_code: $(http_body "$login_resp")"
    fi
done

echo
log "Done. All operator accounts are live."
