#!/usr/bin/env bash
# seed_local.sh — Idempotent local development seed script.
#
# Creates a test user, index, and optionally seeds search data.
# Safe to run multiple times — skips resources that already exist.
#
# Usage:
#   ./scripts/seed_local.sh              # uses defaults from .env.local
#   API_URL=http://localhost:3001 ADMIN_KEY=my-key ./scripts/seed_local.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via env vars or .env.local)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SEED_ENV_OVERRIDE_VARS=(API_URL ADMIN_KEY DATABASE_URL FLAPJACK_PORT FLAPJACK_URL LOCAL_DEV_FLAPJACK_URL)

# shellcheck source=lib/db_url.sh
source "$SCRIPT_DIR/lib/db_url.sh"
# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/flapjack_regions.sh
source "$SCRIPT_DIR/lib/flapjack_regions.sh"

log() { echo "[seed] $*"; }
die() { echo "[seed] ERROR: $*" >&2; exit 1; }

json_string() {
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

urlencode_path_component() {
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

parse_json_field() {
    local field_name="$1"
    python3 -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$field_name"
}

http_response_status() {
    printf '%s\n' "$1" | tail -1
}

http_response_body() {
    printf '%s\n' "$1" | sed '$d'
}

normalize_local_dev_flapjack_url() {
    local raw_url="$1"

    python3 - "$raw_url" <<'PY'
import ipaddress
import sys
from urllib.parse import urlparse

trimmed = sys.argv[1].strip()
if not trimmed:
    raise SystemExit(1)

suffix_start = None
for marker in ("?", "#"):
    index = trimmed.find(marker)
    if index != -1 and (suffix_start is None or index < suffix_start):
        suffix_start = index

if suffix_start is None:
    base = trimmed
    suffix = ""
else:
    base = trimmed[:suffix_start]
    suffix = trimmed[suffix_start:]

normalized_base = base.rstrip("/")
if not normalized_base:
    raise SystemExit(1)

parsed = urlparse(normalized_base)
if parsed.scheme not in ("http", "https"):
    raise SystemExit(1)
if parsed.username is not None or parsed.password is not None:
    raise SystemExit(1)

host = parsed.hostname
if host is None:
    raise SystemExit(1)

if host != "localhost":
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        raise SystemExit(1)
    if not ip.is_loopback:
        raise SystemExit(1)

print(f"{normalized_base}{suffix}")
PY
}

resolve_seed_flapjack_url() {
    local normalized_local_dev_url

    if [ "${LOCAL_DEV_FLAPJACK_URL+x}" = "x" ]; then
        normalized_local_dev_url="$(normalize_local_dev_flapjack_url "${LOCAL_DEV_FLAPJACK_URL}" 2>/dev/null || true)"
        if [ -n "$normalized_local_dev_url" ]; then
            printf '%s\n' "$normalized_local_dev_url"
            return 0
        fi
    fi

    if [ -n "${FLAPJACK_URL:-}" ]; then
        printf '%s\n' "$FLAPJACK_URL"
    else
        printf 'http://localhost:%s\n' "${FLAPJACK_PORT:-7700}"
    fi
}

remember_explicit_env() {
    local var_name="$1"
    local flag_name="SEED_${var_name}_WAS_SET"
    local value_name="SEED_${var_name}_VALUE"

    if [ "${!var_name+x}" = "x" ]; then
        printf -v "$flag_name" '%s' "1"
        printf -v "$value_name" '%s' "${!var_name}"
    else
        printf -v "$flag_name" '%s' "0"
        printf -v "$value_name" '%s' ""
    fi
}

restore_explicit_env() {
    local var_name="$1"
    local flag_name="SEED_${var_name}_WAS_SET"
    local value_name="SEED_${var_name}_VALUE"

    if [ "${!flag_name}" = "1" ]; then
        printf -v "$var_name" '%s' "${!value_name}"
        export "$var_name"
    fi
}

remember_explicit_env_vars() {
    local var_name
    for var_name in "${SEED_ENV_OVERRIDE_VARS[@]}"; do
        remember_explicit_env "$var_name"
    done
}

restore_explicit_env_vars() {
    local var_name
    for var_name in "${SEED_ENV_OVERRIDE_VARS[@]}"; do
        restore_explicit_env "$var_name"
    done
}

require_local_database_access() {
    local skip_context="$1"

    if [ -z "${DATABASE_URL:-}" ]; then
        log "WARNING: DATABASE_URL is not set — skipping ${skip_context}"
        return 1
    fi

    if command -v psql >/dev/null 2>&1; then
        DB_ACCESS_MODE="host-psql"
        return 0
    fi

    if command -v docker >/dev/null 2>&1 \
        && (cd "$REPO_ROOT" && docker compose ps --status running postgres >/dev/null 2>&1); then
        DB_ACCESS_MODE="docker-compose-psql"
        return 0
    fi

    log "WARNING: psql not found and Docker Postgres is unavailable — skipping ${skip_context}"
    return 1
}

run_local_psql() {
    local db_user db_password db_name

    case "${DB_ACCESS_MODE:-}" in
        host-psql)
            PSQLRC=/dev/null psql "$DATABASE_URL" "$@"
            ;;
        docker-compose-psql)
            db_user="$(db_url_user "$DATABASE_URL")" \
                || die "DATABASE_URL must include a username for docker compose psql access"
            db_password="$(db_url_password "$DATABASE_URL")" \
                || die "DATABASE_URL must include a password for docker compose psql access"
            db_name="$(db_url_database "$DATABASE_URL")" \
                || die "DATABASE_URL must include a database name for docker compose psql access"

            (
                cd "$REPO_ROOT" || exit 1
                PSQLRC=/dev/null docker compose exec -T postgres \
                    env "PGPASSWORD=$db_password" \
                    psql -h 127.0.0.1 -U "$db_user" -d "$db_name" "$@"
            )
            ;;
        *)
            die "Database access requested before require_local_database_access initialized DB_ACCESS_MODE"
            ;;
    esac
}

remember_explicit_env_vars

load_env_file "$REPO_ROOT/.env.local"

restore_explicit_env_vars

# Derive from API_BASE_URL (set by .env.local) when API_URL isn't explicit,
# matching the same fallback chain used by e2e-preflight.sh.
API_URL="${API_URL:-${API_BASE_URL:-http://localhost:3001}}"
[ -n "${ADMIN_KEY:-}" ] \
    || die "ADMIN_KEY is required; set a random local value in .env.local or export it before running seed_local.sh"

DEFAULT_SEED_REGIONS=()
# Capture first so invalid FLAPJACK_REGIONS entries fail the seed immediately.
# Bash does not propagate process-substitution failures through a while loop,
# which would otherwise allow a partially parsed topology to seed silently.
DEFAULT_SEED_REGION_LINES="$(resolve_seed_vm_regions)" \
    || die "Failed to resolve local seed VM regions"
while IFS= read -r seed_region; do
    [ -n "$seed_region" ] || continue
    DEFAULT_SEED_REGIONS+=("$seed_region")
done <<< "$DEFAULT_SEED_REGION_LINES"
[ "${#DEFAULT_SEED_REGIONS[@]}" -gt 0 ] \
    || die "No local seed VM regions resolved from FLAPJACK_REGIONS"
# Keep this aligned with infra/api/src/services/provisioning/auto_provision.rs::default_shared_vm_capacity
# so pre-seeded local-dev rows match the runtime shared-VM contract.
LOCAL_VM_CAPACITY_JSON='{"cpu_weight":4.0,"mem_rss_bytes":8589934592,"disk_bytes":107374182400,"query_rps":500.0,"indexing_rps":200.0}'
LOCAL_VM_CURRENT_LOAD_JSON='{"cpu_weight":0.0,"mem_rss_bytes":0,"disk_bytes":0,"query_rps":0.0,"indexing_rps":0.0}'

SEED_USER_NAME="${SEED_USER_NAME:-Test Developer}"
SEED_USER_EMAIL="${SEED_USER_EMAIL:-dev@example.com}"
SEED_USER_PASSWORD="${SEED_USER_PASSWORD:-localdev-password-1234}"
SEED_FREE_USER_NAME="${SEED_FREE_USER_NAME:-Free Plan User}"
SEED_FREE_USER_EMAIL="${SEED_FREE_USER_EMAIL:-free@example.com}"
SEED_FREE_USER_PASSWORD="${SEED_FREE_USER_PASSWORD:-localdev-password-1234}"

SEED_INDEX_NAME="${SEED_INDEX_NAME:-test-index}"
SEED_INDEX_REGION="${SEED_INDEX_REGION:-us-east-1}"
SEED_INDEX_TARGETS=(
    "shared|${SEED_INDEX_NAME}|${SEED_INDEX_REGION}"
    "shared|test-index-eu|eu-west-1"
    "shared|test-index-eu2|eu-central-1"
    "free|free-test-index|us-east-1"
)
FLAPJACK_URL="$(resolve_seed_flapjack_url)"

api_json_call() {
    local method="$1" path="$2"
    shift 2
    curl -sf -X "$method" "${API_URL}${path}" \
        -H "Content-Type: application/json" \
        "$@"
}

api_call() {
    local method="$1" path="$2"
    shift 2
    api_json_call "$method" "$path" "$@"
}

api_call_with_token() {
    local method="$1" path="$2" token="$3"
    shift 3
    api_json_call "$method" "$path" \
        -H "Authorization: Bearer ${token}" \
        "$@"
}

admin_call() {
    local method="$1" path="$2"
    shift 2
    api_json_call "$method" "$path" \
        -H "x-admin-key: ${ADMIN_KEY}" \
        "$@"
}

verify_seed_user_email() {
    local seed_email="$1"

    if ! require_local_database_access "local email verification for ${seed_email}"; then
        return 0
    fi

    local verified_count
    verified_count="$(
        run_local_psql -v ON_ERROR_STOP=1 -v seed_email="$seed_email" -tA <<'SQL'
WITH updated AS (
    UPDATE customers
    SET email_verified_at = COALESCE(email_verified_at, NOW()),
        email_verify_token = NULL,
        email_verify_expires_at = NULL,
        updated_at = NOW()
    WHERE email = :'seed_email'
      AND status != 'deleted'
    RETURNING 1
)
SELECT COUNT(*) FROM updated;
SQL
    )"
    verified_count="$(printf '%s' "$verified_count" | tr -d '[:space:]')"

    if [ "$verified_count" = "1" ]; then
        log "Verified user email: ${seed_email}"
        return 0
    fi

    log "WARNING: no active customer matched ${seed_email} for local email verification"
}

sql_escape_literal() {
    local raw_value="$1"
    printf '%s' "${raw_value//\'/\'\'}"
}

parse_flapjack_region_port() {
    local raw_port="$1"

    [[ "$raw_port" =~ ^[0-9]+$ ]] || return 1
    [ "$raw_port" -ge 1 ] && [ "$raw_port" -le 65535 ]
}

# Resolve the flapjack_url for a given region. Uses per-region URL when
# FLAPJACK_REGIONS is configured, otherwise keeps the single shared FLAPJACK_URL
# contract. FLAPJACK_SINGLE_INSTANCE=1 also forces the shared endpoint even when
# region mappings are present. Iterates the region list on each call — avoids
# Bash 4+
# associative arrays so the script works on macOS system bash (3.2).
resolve_region_flapjack_url() {
    local region="$1"

    if [ "${FLAPJACK_SINGLE_INSTANCE:-}" = "1" ]; then
        printf '%s\n' "$FLAPJACK_URL"
        return 0
    fi

    local region_mappings="${FLAPJACK_REGIONS:-}"

    if [ -n "$region_mappings" ]; then
        local region_port mr_region mr_port
        for region_port in $region_mappings; do
            mr_region="${region_port%%:*}"
            mr_port="${region_port##*:}"
            if [ "$mr_region" = "$region" ]; then
                if ! parse_flapjack_region_port "$mr_port"; then
                    die "FLAPJACK_REGIONS entry for ${region} must use a numeric TCP port between 1 and 65535"
                fi
                printf 'http://127.0.0.1:%s\n' "$mr_port"
                return 0
            fi
        done
    fi
    printf '%s\n' "$FLAPJACK_URL"
}

seed_vm_inventory() {
    if ! require_local_database_access "VM inventory seed for default regions"; then
        return 0
    fi

    local region hostname escaped_region escaped_hostname escaped_flapjack_url escaped_capacity
    local escaped_current_load region_url
    local insert_rows="" expected_hostnames=""
    escaped_capacity="$(sql_escape_literal "$LOCAL_VM_CAPACITY_JSON")"
    escaped_current_load="$(sql_escape_literal "$LOCAL_VM_CURRENT_LOAD_JSON")"

    for region in "${DEFAULT_SEED_REGIONS[@]}"; do
        hostname="local-dev-${region}"
        escaped_region="$(sql_escape_literal "$region")"
        escaped_hostname="$(sql_escape_literal "$hostname")"
        # Per-region Flapjack URL when multi-region is active, else the single default.
        region_url="$(resolve_region_flapjack_url "$region")"
        escaped_flapjack_url="$(sql_escape_literal "$region_url")"

        if [ -n "$insert_rows" ]; then
            insert_rows+=$',\n'
            expected_hostnames+=$',\n'
        fi

        insert_rows+="('local','${escaped_hostname}','${escaped_flapjack_url}','${escaped_region}','${escaped_capacity}'::jsonb,'${escaped_current_load}'::jsonb,NOW(),NOW(),NOW())"
        expected_hostnames+="('${escaped_hostname}')"
    done

    run_local_psql -v ON_ERROR_STOP=1 <<SQL
INSERT INTO vm_inventory (
    provider,
    hostname,
    flapjack_url,
    region,
    capacity,
    current_load,
    load_scraped_at,
    created_at,
    updated_at
)
VALUES
${insert_rows}
ON CONFLICT (hostname) DO UPDATE
SET provider = EXCLUDED.provider,
    region = EXCLUDED.region,
    flapjack_url = EXCLUDED.flapjack_url,
    capacity = EXCLUDED.capacity,
    current_load = EXCLUDED.current_load,
    -- Reset status to 'active' on every seed run. Background monitors may
    -- have moved VMs to 'draining' if their Flapjack was offline between
    -- runs; re-seeding means "I want these VMs usable again."
    status = 'active',
    load_scraped_at = NOW(),
    updated_at = NOW();

WITH expected_seed_hostnames(hostname) AS (
    VALUES
${expected_hostnames}
)
UPDATE vm_inventory
SET status = 'decommissioned',
    updated_at = NOW()
WHERE provider = 'local'
  AND hostname LIKE 'local-dev-%'
  AND NOT EXISTS (
      SELECT 1
      FROM expected_seed_hostnames
      WHERE expected_seed_hostnames.hostname = vm_inventory.hostname
  );
SQL

    local missing_hostnames
    missing_hostnames="$(
        run_local_psql -v ON_ERROR_STOP=1 -tA <<SQL
WITH expected(hostname) AS (
    VALUES
${expected_hostnames}
)
SELECT expected.hostname
FROM expected
LEFT JOIN vm_inventory inventory ON inventory.hostname = expected.hostname
WHERE inventory.hostname IS NULL;
SQL
    )"
    missing_hostnames="$(printf '%s' "$missing_hostnames" | sed '/^[[:space:]]*$/d')"

    if [ -n "$missing_hostnames" ]; then
        die "VM inventory verification failed; missing seeded hostnames: ${missing_hostnames//$'\n'/, }"
    fi

    log "Verified VM inventory hostnames for ${#DEFAULT_SEED_REGIONS[@]} default regions"
}

seed_user() {
    local user_name="$1"
    local user_email="$2"
    local user_password="$3"
    local desired_plan="$4"
    local token_output_var="$5"
    local customer_id_output_var="$6"

    local register_payload register_response register_code register_body login_response login_code
    local user_token="" account_response customer_id current_plan upgrade_response upgrade_code

    login_response=$(api_call POST /auth/login \
        -d "$(printf '{"email":%s,"password":%s}' \
            "$(json_string "$user_email")" \
            "$(json_string "$user_password")")" \
        -w "\n%{http_code}" 2>/dev/null || true)
    login_code="$(http_response_status "$login_response")"

    if [ "$login_code" = "200" ]; then
        user_token="$(http_response_body "$login_response" | parse_json_field token 2>/dev/null || true)"
        log "User already exists: ${user_email} (logging in)"
    else
        register_payload=$(printf '{"name":%s,"email":%s,"password":%s}' \
            "$(json_string "$user_name")" \
            "$(json_string "$user_email")" \
            "$(json_string "$user_password")")

        register_response=$(api_call POST /auth/register \
            -d "$register_payload" \
            -w "\n%{http_code}" 2>/dev/null) || true

        register_code="$(http_response_status "$register_response")"
        register_body="$(http_response_body "$register_response")"

        if [ "$register_code" = "201" ]; then
            user_token=$(echo "$register_body" | parse_json_field token 2>/dev/null || true)
            log "Created user: ${user_email}"
        elif [ "$register_code" = "409" ]; then
            log "User already exists: ${user_email} (logging in)"
            login_response=$(api_call POST /auth/login \
                -d "$(printf '{"email":%s,"password":%s}' \
                    "$(json_string "$user_email")" \
                    "$(json_string "$user_password")")")
            user_token="$(printf '%s' "$login_response" | parse_json_field token)"
        else
            die "Registration failed for ${user_email} with HTTP ${register_code}: ${register_body}"
        fi
    fi

    if [ -z "$user_token" ]; then
        die "Failed to obtain auth token for ${user_email}"
    fi

    verify_seed_user_email "$user_email"

    account_response=$(api_call_with_token GET /account "$user_token")
    customer_id=$(echo "$account_response" | parse_json_field id)
    log "Customer ID for ${user_email}: ${customer_id}"

    if [ "$desired_plan" != "free" ]; then
        upgrade_response=$(admin_call PUT "/admin/tenants/${customer_id}" \
            -d "$(printf '{"billing_plan":%s}' "$(json_string "$desired_plan")")" \
            -w "\n%{http_code}" 2>/dev/null) || true
        upgrade_code="$(http_response_status "$upgrade_response")"
        if [ "$upgrade_code" = "200" ]; then
            log "Set billing plan to ${desired_plan} for ${user_email}"
        else
            log "WARNING: billing plan upgrade for ${user_email} returned HTTP ${upgrade_code}"
        fi
    fi

    account_response=$(api_call_with_token GET /account "$user_token")
    current_plan=$(echo "$account_response" | parse_json_field billing_plan 2>/dev/null || true)
    if [ "$current_plan" != "$desired_plan" ]; then
        die "Seeded user ${user_email} has billing_plan=${current_plan:-<missing>} (expected ${desired_plan})"
    fi
    log "Verified seeded account for ${user_email} (plan: ${current_plan})"

    printf -v "$token_output_var" '%s' "$user_token"
    printf -v "$customer_id_output_var" '%s' "$customer_id"
}

resolve_seed_user_context() {
    local user_key="$1"
    local token_var_name="$2"
    local customer_var_name="$3"
    local email_var_name="$4"

    case "$user_key" in
        shared)
            printf -v "$token_var_name" '%s' "$SHARED_USER_TOKEN"
            printf -v "$customer_var_name" '%s' "$SHARED_USER_CUSTOMER_ID"
            printf -v "$email_var_name" '%s' "$SEED_USER_EMAIL"
            ;;
        free)
            printf -v "$token_var_name" '%s' "$FREE_USER_TOKEN"
            printf -v "$customer_var_name" '%s' "$FREE_USER_CUSTOMER_ID"
            printf -v "$email_var_name" '%s' "$SEED_FREE_USER_EMAIL"
            ;;
        *)
            die "Unknown seeded user key: ${user_key}"
            ;;
    esac
}

seed_shared_usage_daily_current_month() {
    local shared_customer_id="$1"

    if ! require_local_database_access "usage_daily seed for ${SEED_USER_EMAIL}"; then
        return 1
    fi

    local seed_target target_user_key target_index_name target_region escaped_region
    local region_values="" region_count=0 seen_regions=","

    for seed_target in "${SEED_INDEX_TARGETS[@]}"; do
        IFS='|' read -r target_user_key target_index_name target_region <<<"$seed_target"
        if [ "$target_user_key" != "shared" ]; then
            continue
        fi

        case "$seen_regions" in
            *,"$target_region",*)
                continue
                ;;
        esac
        seen_regions+="${target_region},"

        escaped_region="$(sql_escape_literal "$target_region")"
        if [ -n "$region_values" ]; then
            region_values+=$',\n'
        fi
        region_values+="('${escaped_region}')"
        region_count=$((region_count + 1))
    done

    [ "$region_count" -gt 0 ] \
        || die "No shared-plan regions were found in SEED_INDEX_TARGETS for usage_daily seeding"

    if ! run_local_psql -v ON_ERROR_STOP=1 -v shared_customer_id="$shared_customer_id" <<SQL
-- usage_daily is the source for estimate computation via
-- pg_usage_repo::get_daily_usage -> usage::aggregate_monthly -> invoicing::compute_invoice_for_customer.
WITH month_days(day) AS (
    SELECT generate_series(
        date_trunc('month', timezone('UTC', now()))::date,
        (date_trunc('month', timezone('UTC', now())) + interval '1 month - 1 day')::date,
        interval '1 day'
    )::date
),
shared_regions(region) AS (
    VALUES
${region_values}
)
INSERT INTO usage_daily (
    customer_id,
    date,
    region,
    search_requests,
    write_operations,
    storage_bytes_avg,
    documents_count_avg,
    aggregated_at
)
SELECT
    :'shared_customer_id'::uuid,
    month_days.day,
    shared_regions.region,
    250000::bigint,
    25000::bigint,
    2147483648::bigint,
    50000::bigint,
    NOW()
FROM month_days
CROSS JOIN shared_regions
ON CONFLICT (customer_id, date, region) DO UPDATE
SET search_requests = EXCLUDED.search_requests,
    write_operations = EXCLUDED.write_operations,
    storage_bytes_avg = EXCLUDED.storage_bytes_avg,
    documents_count_avg = EXCLUDED.documents_count_avg,
    aggregated_at = NOW();
SQL
    then
        die "usage_daily seed failed for ${SEED_USER_EMAIL}"
    fi

    log "Seeded current UTC month usage_daily rows for ${SEED_USER_EMAIL} across ${region_count} regions"
}

verify_shared_estimate_after_usage_seed() {
    local estimate_month="$1"
    local estimate_response estimate_code estimate_body estimate_month_value subtotal_cents

    estimate_response="$(api_call_with_token GET "/billing/estimate?month=${estimate_month}" "$SHARED_USER_TOKEN" \
        -w "\n%{http_code}" 2>/dev/null || true)"
    estimate_code="$(http_response_status "$estimate_response")"
    estimate_body="$(http_response_body "$estimate_response")"

    if [ "$estimate_code" != "200" ]; then
        die "Estimate smoke check failed with HTTP ${estimate_code}: ${estimate_body}"
    fi

    estimate_month_value="$(echo "$estimate_body" | parse_json_field month 2>/dev/null || true)"
    if [ "$estimate_month_value" != "$estimate_month" ]; then
        die "Estimate smoke check returned month=${estimate_month_value:-<missing>} (expected ${estimate_month})"
    fi

    subtotal_cents="$(echo "$estimate_body" | parse_json_field subtotal_cents 2>/dev/null || true)"
    if ! [[ "$subtotal_cents" =~ ^-?[0-9]+$ ]]; then
        die "Estimate smoke check returned a non-numeric subtotal_cents: ${subtotal_cents:-<missing>}"
    fi
    if [ "$subtotal_cents" -le 0 ]; then
        die "Estimate smoke check subtotal_cents=${subtotal_cents} after usage_daily seed"
    fi

    log "Verified /billing/estimate for ${SEED_USER_EMAIL} (${estimate_month})"
}

build_index_payload() {
    local index_name="$1"
    local index_region="$2"
    local index_flapjack_url

    if [ "$flapjack_reachable" -eq 1 ]; then
        # Keep index creation on the same per-region/shared URL contract as the
        # VM inventory seed so local multi-region failover exercises the
        # correct flapjack endpoint for each region.
        index_flapjack_url="$(resolve_region_flapjack_url "$index_region")"
        printf '{"name":%s,"region":%s,"flapjack_url":%s}' \
            "$(json_string "$index_name")" \
            "$(json_string "$index_region")" \
            "$(json_string "$index_flapjack_url")"
        return 0
    fi

    printf '{"name":%s,"region":%s}' \
        "$(json_string "$index_name")" \
        "$(json_string "$index_region")"
}

verify_seeded_indexes_for_user() {
    local user_key="$1"
    local user_email="$2"
    local user_token="$3"
    local indexes_response index_names
    local seed_target target_user_key target_index_name target_region

    indexes_response=$(api_call_with_token GET /indexes "$user_token")
    index_names="$(printf '%s' "$indexes_response" | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
if isinstance(payload, dict):
    items = payload.get("indexes", [])
elif isinstance(payload, list):
    items = payload
else:
    items = []

for item in items:
    if isinstance(item, dict):
        name = item.get("name")
        if isinstance(name, str):
            print(name)
')"

    for seed_target in "${SEED_INDEX_TARGETS[@]}"; do
        IFS='|' read -r target_user_key target_index_name target_region <<<"$seed_target"
        if [ "$target_user_key" != "$user_key" ]; then
            continue
        fi

        if ! printf '%s\n' "$index_names" | grep -Fxq "$target_index_name"; then
            die "Seeded index ${target_index_name} is missing from GET /indexes for ${user_email}"
        fi
    done

    log "Verified seeded index names for ${user_email}"
}

# In STRIPE_LOCAL_MODE, seed_local guarantees each seeded customer has a
# stripe_customer_id by calling the admin sync endpoint. That backend operation
# is idempotent, so rerunning the seed script safely preserves the linkage.
sync_stripe_if_local_mode() {
    local customer_id="$1" user_email="$2"
    [ "${STRIPE_LOCAL_MODE:-}" = "1" ] || return 0

    local response response_code response_body stripe_customer_id
    response=$(admin_call POST "/admin/customers/${customer_id}/sync-stripe" \
        -w "\n%{http_code}" 2>/dev/null) || true
    response_code=$(echo "$response" | tail -1)
    response_body=$(echo "$response" | sed '$d')

    if [ "$response_code" != "200" ]; then
        die "Stripe sync failed for ${user_email} (customer ${customer_id}) with HTTP ${response_code}"
    fi

    stripe_customer_id=$(echo "$response_body" | parse_json_field stripe_customer_id 2>/dev/null || true)
    if [ -z "$stripe_customer_id" ]; then
        die "Stripe sync for ${user_email} returned no stripe_customer_id"
    fi

    log "Stripe-synced ${user_email}: ${stripe_customer_id}"
}

wait_for_api() {
    local max_wait=15 elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        if curl -sf "${API_URL}/health" >/dev/null 2>&1; then
            log "API is healthy at ${API_URL}"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    die "API not reachable at ${API_URL}/health after ${max_wait}s"
}

wait_for_api

seed_vm_inventory

flapjack_reachable=0
if curl -sf "${FLAPJACK_URL}/health" >/dev/null 2>&1; then
    flapjack_reachable=1
    log "Flapjack reachable at ${FLAPJACK_URL} — seeding indexes and sample documents"
else
    log "Flapjack not reachable at ${FLAPJACK_URL} — index creation will omit flapjack_url and document seed will be skipped"
fi

SHARED_USER_TOKEN=""
SHARED_USER_CUSTOMER_ID=""
FREE_USER_TOKEN=""
FREE_USER_CUSTOMER_ID=""

seed_user \
    "$SEED_USER_NAME" \
    "$SEED_USER_EMAIL" \
    "$SEED_USER_PASSWORD" \
    "shared" \
    "SHARED_USER_TOKEN" \
    "SHARED_USER_CUSTOMER_ID"

sync_stripe_if_local_mode "$SHARED_USER_CUSTOMER_ID" "$SEED_USER_EMAIL"

seed_user \
    "$SEED_FREE_USER_NAME" \
    "$SEED_FREE_USER_EMAIL" \
    "$SEED_FREE_USER_PASSWORD" \
    "free" \
    "FREE_USER_TOKEN" \
    "FREE_USER_CUSTOMER_ID"

sync_stripe_if_local_mode "$FREE_USER_CUSTOMER_ID" "$SEED_FREE_USER_EMAIL"

usage_rows_seeded=0
if seed_shared_usage_daily_current_month "$SHARED_USER_CUSTOMER_ID"; then
    usage_rows_seeded=1
fi
current_utc_month="$(date -u +%Y-%m)"

seed_target_count=0
seed_target=""
for seed_target in "${SEED_INDEX_TARGETS[@]}"; do
    IFS='|' read -r target_user_key target_index_name target_region <<<"$seed_target"
    seed_target_count=$((seed_target_count + 1))

    user_token=""
    customer_id=""
    user_email=""
    resolve_seed_user_context "$target_user_key" "user_token" "customer_id" "user_email"

    index_payload="$(build_index_payload "$target_index_name" "$target_region")"
    index_response=$(admin_call POST "/admin/tenants/${customer_id}/indexes" \
        -d "$index_payload" \
        -w "\n%{http_code}" 2>/dev/null) || true

    index_code="$(http_response_status "$index_response")"
    index_body="$(http_response_body "$index_response")"
    if [ "$index_code" = "201" ] || [ "$index_code" = "200" ]; then
        log "Created index ${target_index_name} (${target_region}) for ${user_email}"
    elif [ "$index_code" = "409" ]; then
        log "Index already exists: ${target_index_name} (${target_region}) for ${user_email}"
    else
        log "WARNING: index seed returned HTTP ${index_code} for ${target_index_name} (${target_region}): ${index_body}"
    fi
done

if [ "$flapjack_reachable" -eq 1 ]; then
    seeded_document_batches=0
    for seed_target in "${SEED_INDEX_TARGETS[@]}"; do
        IFS='|' read -r target_user_key target_index_name target_region <<<"$seed_target"
        user_token=""
        customer_id=""
        user_email=""
        resolve_seed_user_context "$target_user_key" "user_token" "customer_id" "user_email"
        index_path_component="$(urlencode_path_component "$target_index_name")"

        for i in $(seq 1 5); do
            api_call_with_token POST "/indexes/${index_path_component}/documents" "$user_token" \
                -d "[{\"id\":\"doc-${i}\",\"title\":\"Sample Document ${i}\",\"body\":\"This is sample document number ${i} for local development testing.\"}]" \
                >/dev/null 2>&1 || true
        done
        seeded_document_batches=$((seeded_document_batches + 1))
        log "Seeded 5 sample documents into ${target_index_name} for ${user_email}"
    done
else
    log "Skipped document seed because flapjack is unreachable"
fi

verify_seeded_indexes_for_user "shared" "$SEED_USER_EMAIL" "$SHARED_USER_TOKEN"
verify_seeded_indexes_for_user "free" "$SEED_FREE_USER_EMAIL" "$FREE_USER_TOKEN"
if [ "$usage_rows_seeded" -eq 1 ]; then
    verify_shared_estimate_after_usage_seed "$current_utc_month"
else
    log "WARNING: skipped /billing/estimate smoke check because usage_daily seed was skipped"
fi

seed_replicas() {
    if ! require_local_database_access "replica seed"; then
        log "Skipping replica seed — no database access"
        return 0
    fi

    # Map each index to a target replica region (must differ from primary).
    # Format: "user_key|index_name|primary_region|replica_target_region"
    local REPLICA_TARGETS=(
        "shared|${SEED_INDEX_NAME}|${SEED_INDEX_REGION}|eu-west-1"
        "shared|test-index-eu|eu-west-1|us-east-1"
        "shared|test-index-eu2|eu-central-1|us-east-1"
    )

    local replicas_created=0
    local replica_reset_values=""
    for replica_target in "${REPLICA_TARGETS[@]}"; do
        IFS='|' read -r ruser_key rindex_name rprimary_region rtarget_region <<<"$replica_target"

        local ruser_token=""
        local rcustomer_id=""
        local ruser_email=""
        resolve_seed_user_context "$ruser_key" "ruser_token" "rcustomer_id" "ruser_email"

        local index_path
        index_path="$(urlencode_path_component "$rindex_name")"

        # Create the replica via API. 409 = already exists, which is fine.
        local replica_response replica_code
        replica_response=$(api_call_with_token POST "/indexes/${index_path}/replicas" "$ruser_token" \
            -d "{\"region\":\"${rtarget_region}\"}" \
            -w "\n%{http_code}" 2>/dev/null) || true

        replica_code="$(http_response_status "$replica_response")"
        if [ "$replica_code" = "201" ] || [ "$replica_code" = "200" ]; then
            log "Created replica: ${rindex_name} → ${rtarget_region}"
            replicas_created=$((replicas_created + 1))
        elif [ "$replica_code" = "409" ]; then
            log "Replica already exists: ${rindex_name} → ${rtarget_region}"
        else
            log "WARNING: replica creation returned HTTP ${replica_code} for ${rindex_name} → ${rtarget_region}"
        fi

        local escaped_customer_id escaped_index_name escaped_primary_region escaped_replica_region
        escaped_customer_id="$(sql_escape_literal "$rcustomer_id")"
        escaped_index_name="$(sql_escape_literal "$rindex_name")"
        escaped_primary_region="$(sql_escape_literal "$rprimary_region")"
        escaped_replica_region="$(sql_escape_literal "$rtarget_region")"
        if [ -n "$replica_reset_values" ]; then
            replica_reset_values+=$',\n'
        fi
        replica_reset_values+="('${escaped_customer_id}'::uuid, '${escaped_index_name}', '${escaped_primary_region}', '${escaped_replica_region}')"
    done

    # Restore the canonical local HA topology via SQL.
    # In production, the replication orchestrator would do this after data sync.
    # In local dev, we skip actual replication and just mark them ready so the
    # region failover monitor can promote them.
    # Scope this reset to the canonical seed triples so rerunning seed_local.sh
    # repairs failed/suspended replicas and tenant placements from prior local
    # HA proof attempts without touching unrelated operator-created indexes.
    [ -n "$replica_reset_values" ] || die "No seed replicas resolved for reset"
    run_local_psql -v ON_ERROR_STOP=1 <<SQL
WITH seed_replicas(customer_id, tenant_id, primary_region, replica_region) AS (
    VALUES
${replica_reset_values}
),
canonical_seed_vms AS (
    SELECT
        seed_replicas.customer_id,
        seed_replicas.tenant_id,
        seed_replicas.primary_region,
        seed_replicas.replica_region,
        primary_vm.id AS primary_vm_id,
        replica_vm.id AS replica_vm_id
    FROM seed_replicas
    JOIN vm_inventory primary_vm
      ON primary_vm.hostname = 'local-dev-' || seed_replicas.primary_region
     AND primary_vm.provider = 'local'
     AND primary_vm.region = seed_replicas.primary_region
    JOIN vm_inventory replica_vm
      ON replica_vm.hostname = 'local-dev-' || seed_replicas.replica_region
     AND replica_vm.provider = 'local'
     AND replica_vm.region = seed_replicas.replica_region
),
reset_seed_tenants AS (
    UPDATE customer_tenants
    SET vm_id = canonical_seed_vms.primary_vm_id,
        tier = 'active',
        cold_snapshot_id = NULL
    FROM canonical_seed_vms
    WHERE customer_tenants.customer_id = canonical_seed_vms.customer_id
      AND customer_tenants.tenant_id = canonical_seed_vms.tenant_id
    RETURNING customer_tenants.customer_id, customer_tenants.tenant_id
)
UPDATE index_replicas
SET primary_vm_id = canonical_seed_vms.primary_vm_id,
    replica_vm_id = canonical_seed_vms.replica_vm_id,
    status = 'active',
    lag_ops = 0,
    updated_at = NOW()
FROM canonical_seed_vms
WHERE index_replicas.customer_id = canonical_seed_vms.customer_id
  AND index_replicas.tenant_id = canonical_seed_vms.tenant_id
  AND index_replicas.replica_region = canonical_seed_vms.replica_region
  AND index_replicas.status IN ('provisioning', 'syncing', 'failed', 'suspended');
SQL

    log "Marked seed replicas as active (${replicas_created} new)"
}

seed_replicas

log ""
log "Local dev environment seeded successfully!"
log "  API:      ${API_URL}"
log "  Shared:   ${SEED_USER_EMAIL}"
log "  Free:     ${SEED_FREE_USER_EMAIL}"
log "  Indexes:  ${seed_target_count} targets"
