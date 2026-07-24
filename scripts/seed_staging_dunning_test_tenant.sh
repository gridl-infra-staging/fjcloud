#!/usr/bin/env bash
# Link every allowlisted staging dunning tenant to a Stripe test customer.
#
# Reuses the existing /admin/customers/:id/sync-stripe owner so this script
# does not create a parallel Stripe customer-linking path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SECRET_FILE="${FJCLOUD_SECRET_FILE:-${HOME:-}/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret}"
STAGING_ENV_HYDRATOR_DEFAULT="$SCRIPT_DIR/launch/hydrate_seeder_env_from_ssm.sh"
STAGING_DB_QUERY_SCRIPT_DEFAULT="$SCRIPT_DIR/launch/ssm_exec_staging.sh"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"

usage() {
    cat <<'USAGE'
Usage:
  bash scripts/seed_staging_dunning_test_tenant.sh [--secret-file <path>]

Notes:
  - Reads FJCLOUD_TEST_TENANT_IDS and AWS credentials from the secret file.
  - Hydrates canonical staging API/DB/admin credentials via SSM.
  - Reuses PUT /admin/tenants/:id for tenants that are still on the free
    billing plan.
  - Reuses POST /admin/customers/:id/sync-stripe for tenants missing
    stripe_customer_id.
  - Reads staging customer rows through scripts/launch/ssm_exec_staging.sh so
    the operator host does not need direct RDS DNS reachability.
USAGE
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

trim() {
    printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

sql_escape_literal() {
    printf '%s' "$1" | sed "s/'/''/g"
}

allowlisted_tenant_ids() {
    python3 - "$1" <<'PY'
import sys

seen = set()
for raw in sys.argv[1].split(","):
    tenant_id = raw.strip()
    if not tenant_id or tenant_id in seen:
        continue
    seen.add(tenant_id)
    print(tenant_id)
PY
}

load_secret_file() {
    local secret_file="$1"
    [ -r "$secret_file" ] || die "secret file is not readable: $secret_file"
    load_layered_env_files "$secret_file"
    [ -n "${FJCLOUD_TEST_TENANT_IDS:-}" ] || die "FJCLOUD_TEST_TENANT_IDS is required in $secret_file"
}

hydrate_staging_env() {
    local hydrator_script="$1"
    local hydrated_env_file

    [ -x "$hydrator_script" ] || die "missing executable staging env hydrator: $hydrator_script"
    hydrated_env_file="$(mktemp)"
    if ! bash "$hydrator_script" staging >"$hydrated_env_file"; then
        rm -f "$hydrated_env_file"
        die "failed to hydrate canonical staging env via $hydrator_script"
    fi

    # Source the canonical staging values after the secret file so the live API
    # contract wins over any stale file-provided API_URL/ADMIN_KEY values.
    # shellcheck disable=SC1090
    source "$hydrated_env_file"
    rm -f "$hydrated_env_file"

    [ -n "${API_URL:-}" ] || die "hydrated staging API_URL was empty"
    [ -n "${ADMIN_KEY:-}" ] || die "hydrated staging ADMIN_KEY was empty"
}

build_remote_sql_command() {
    local sql_query="$1"
    local escaped_sql

    escaped_sql="$(printf '%s' "$sql_query" | sed "s/'/'\"'\"'/g")"
    cat <<EOF
set -euo pipefail
if [[ -z "\${DATABASE_URL:-}" && -r /etc/fjcloud/env ]]; then
    source /etc/fjcloud/env
fi
if [[ -z "\${DATABASE_URL:-}" ]]; then
    echo "DATABASE_URL is required on staging host for seed queries" >&2
    exit 1
fi
psql -X -t -A -v ON_ERROR_STOP=1 "\$DATABASE_URL" -c '$escaped_sql' | sed -n '1p'
EOF
}

run_staging_sql_row() {
    local sql="$1"
    local staging_db_query_script="${STAGING_DB_QUERY_SCRIPT:-$STAGING_DB_QUERY_SCRIPT_DEFAULT}"
    local remote_command

    [ -x "$staging_db_query_script" ] || die "missing executable staging DB query owner: $staging_db_query_script"
    remote_command="$(build_remote_sql_command "$sql")"
    "$staging_db_query_script" "$remote_command"
}

lookup_customer_row() {
    local tenant_id="$1"
    local escaped_tenant_id sql

    escaped_tenant_id="$(sql_escape_literal "$tenant_id")"
    sql="SELECT id::text || '|' || email || '|' || status || '|' || billing_plan || '|' || COALESCE(stripe_customer_id, '') FROM customers WHERE id = '${escaped_tenant_id}'::uuid;"
    run_staging_sql_row "$sql"
}

parse_customer_row_field() {
    local row="$1"
    local index="$2"
    printf '%s\n' "$row" | cut -d'|' -f"$index"
}

update_customer_plan_via_admin_owner() {
    local tenant_id="$1"
    local response http_code body billing_plan

    response="$(
        curl -sS -w $'\n%{http_code}' \
            -X PUT \
            -H "Content-Type: application/json" \
            -H "x-admin-key: ${ADMIN_KEY}" \
            -d '{"billing_plan":"shared"}' \
            "${API_URL%/}/admin/tenants/${tenant_id}" 2>&1
    )" || die "billing-plan update request failed for tenant ${tenant_id}: $(trim "$response")"

    http_code="$(printf '%s\n' "$response" | tail -n 1)"
    body="$(printf '%s\n' "$response" | sed '$d')"
    [ "$http_code" = "200" ] || die "billing-plan update returned HTTP ${http_code} for tenant ${tenant_id}: $(trim "$body")"

    billing_plan="$(
        python3 - "$body" <<'PY'
import json
import sys

try:
    payload = json.loads(sys.argv[1])
except Exception:
    print("")
    raise SystemExit(0)

value = payload.get("billing_plan")
print("" if value is None else str(value).strip())
PY
    )"
    [ "$billing_plan" = "shared" ] || die "billing-plan update response did not confirm shared plan for tenant ${tenant_id}"
}

sync_customer_via_admin_owner() {
    local tenant_id="$1"
    local response http_code body stripe_customer_id

    response="$(
        curl -sS -w $'\n%{http_code}' \
            -X POST \
            -H "x-admin-key: ${ADMIN_KEY}" \
            "${API_URL%/}/admin/customers/${tenant_id}/sync-stripe" 2>&1
    )" || die "sync-stripe request failed for tenant ${tenant_id}: $(trim "$response")"

    http_code="$(printf '%s\n' "$response" | tail -n 1)"
    body="$(printf '%s\n' "$response" | sed '$d')"
    [ "$http_code" = "200" ] || die "sync-stripe returned HTTP ${http_code} for tenant ${tenant_id}: $(trim "$body")"

    stripe_customer_id="$(
        python3 - "$body" <<'PY'
import json
import sys

try:
    payload = json.loads(sys.argv[1])
except Exception:
    print("")
    raise SystemExit(0)

value = payload.get("stripe_customer_id")
print("" if value is None else str(value).strip())
PY
    )"
    [ -n "$stripe_customer_id" ] || die "sync-stripe response missing stripe_customer_id for tenant ${tenant_id}"

    printf '%s\n' "$stripe_customer_id"
}

main() {
    local secret_file="$DEFAULT_SECRET_FILE"
    local staging_env_hydrator="${STAGING_ENV_HYDRATOR_SCRIPT:-$STAGING_ENV_HYDRATOR_DEFAULT}"
    local tenant_id customer_row customer_email customer_status billing_plan stripe_customer_id
    local synced_customer_id row_count=0 synced_count=0 skipped_count=0 plan_updated_count=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --secret-file)
                [ "$#" -ge 2 ] || die "--secret-file requires a value"
                secret_file="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done

    load_secret_file "$secret_file"
    hydrate_staging_env "$staging_env_hydrator"

    while IFS= read -r tenant_id; do
        [ -n "$tenant_id" ] || continue
        row_count=$((row_count + 1))
        customer_row="$(lookup_customer_row "$tenant_id")"
        [ -n "$customer_row" ] || die "allowlisted tenant ${tenant_id} was not found in staging customers"

        customer_email="$(parse_customer_row_field "$customer_row" 2)"
        customer_status="$(parse_customer_row_field "$customer_row" 3)"
        billing_plan="$(parse_customer_row_field "$customer_row" 4)"
        stripe_customer_id="$(parse_customer_row_field "$customer_row" 5)"

        [ "$customer_status" = "active" ] || die "allowlisted tenant ${tenant_id} must be active for sync-stripe; found status=${customer_status}"

        case "$billing_plan" in
            shared)
                ;;
            free)
                update_customer_plan_via_admin_owner "$tenant_id"
                customer_row="$(lookup_customer_row "$tenant_id")"
                billing_plan="$(parse_customer_row_field "$customer_row" 4)"
                stripe_customer_id="$(parse_customer_row_field "$customer_row" 5)"
                [ "$billing_plan" = "shared" ] || die "post-update verification did not observe shared billing_plan for tenant ${tenant_id}"
                plan_updated_count=$((plan_updated_count + 1))
                printf 'tenant_id=%s email=%s action=billing_plan_updated billing_plan=shared\n' \
                    "$tenant_id" "$customer_email"
                ;;
            *)
                die "allowlisted tenant ${tenant_id} must be free or shared for dunning seed; found billing_plan=${billing_plan:-<empty>}"
                ;;
        esac

        if [ -n "$stripe_customer_id" ]; then
            skipped_count=$((skipped_count + 1))
            printf 'tenant_id=%s email=%s action=already_linked stripe_customer_id=%s\n' \
                "$tenant_id" "$customer_email" "$stripe_customer_id"
            continue
        fi

        synced_customer_id="$(sync_customer_via_admin_owner "$tenant_id")"
        customer_row="$(lookup_customer_row "$tenant_id")"
        stripe_customer_id="$(parse_customer_row_field "$customer_row" 5)"
        [ -n "$stripe_customer_id" ] || die "post-sync verification did not observe stripe_customer_id for tenant ${tenant_id}"
        [ "$stripe_customer_id" = "$synced_customer_id" ] || die "post-sync DB stripe_customer_id (${stripe_customer_id}) did not match API response (${synced_customer_id}) for tenant ${tenant_id}"

        synced_count=$((synced_count + 1))
        printf 'tenant_id=%s email=%s action=linked stripe_customer_id=%s\n' \
            "$tenant_id" "$customer_email" "$stripe_customer_id"
    done < <(allowlisted_tenant_ids "$FJCLOUD_TEST_TENANT_IDS")

    [ "$row_count" -gt 0 ] || die "FJCLOUD_TEST_TENANT_IDS did not contain any tenant IDs"
    printf 'summary total=%s linked=%s already_linked=%s plan_updated=%s\n' "$row_count" "$synced_count" "$skipped_count" "$plan_updated_count"
}

main "$@"
