#!/usr/bin/env bash
# purge_dev_state.sh - remove retroactive dev@example.com fixture tenant rows.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/db_url.sh
source "$SCRIPT_DIR/lib/db_url.sh"
# shellcheck source=lib/psql_path.sh
source "$SCRIPT_DIR/lib/psql_path.sh"
# shellcheck source=lib/local_db_access.sh
source "$SCRIPT_DIR/lib/local_db_access.sh"
# shellcheck source=lib/local_seed_contract.sh
source "$SCRIPT_DIR/lib/local_seed_contract.sh"
# shellcheck source=lib/stale_fixture_contract.sh
source "$SCRIPT_DIR/lib/stale_fixture_contract.sh"

log() { echo "[purge-dev-state] $*"; }
die() { echo "[purge-dev-state] ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: scripts/purge_dev_state.sh [--dry-run|--execute] [--database-url <url>]

Dry-run is the default. Use --execute to delete only the retroactive
dev@example.com fixture tenant rows named by scripts/lib/stale_fixture_contract.sh.
USAGE
}

reject_conflicting_mode_flag() {
    local selected_mode="$1" requested_mode="$2"

    if [ -n "$selected_mode" ] && [ "$selected_mode" != "$requested_mode" ]; then
        echo "[purge-dev-state] ERROR: Conflicting mode flags: --dry-run and --execute" >&2
        usage >&2
        exit 2
    fi
}

purge_dev_target_values_csv() {
    purge_dev_tenant_target_sql_values | paste -sd, -
}

purge_dev_state_target_sql() {
    local target_values
    target_values="$(purge_dev_target_values_csv)"

    cat <<SQL
-- source scripts/lib/stale_fixture_contract.sh
-- source scripts/lib/local_seed_contract.sh
CREATE TEMP TABLE purge_dev_tenant_targets(tenant_id text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO purge_dev_tenant_targets(tenant_id)
VALUES ${target_values};

CREATE TEMP TABLE purge_dev_target_tenants ON COMMIT DROP AS
SELECT
    ct.customer_id,
    ct.tenant_id,
    c.email
FROM customer_tenants ct
JOIN customers c ON c.id = ct.customer_id
JOIN purge_dev_tenant_targets target_owner
  ON target_owner.tenant_id = ct.tenant_id
WHERE c.email = :'dev_customer_email';
SQL
}

purge_dev_state_plan_sql() {
    cat <<'SQL'
\if :execute_purge
WITH deleted AS (
    DELETE FROM index_replicas ir
    USING purge_dev_target_tenants tt
    WHERE ir.customer_id = tt.customer_id
      AND ir.tenant_id = tt.tenant_id
    RETURNING 1
)
SELECT 'removed-dependent', 'index_replicas', COUNT(*)::text FROM deleted;

WITH deleted AS (
    DELETE FROM customer_tenants ct
    USING purge_dev_target_tenants tt
    WHERE ct.customer_id = tt.customer_id
      AND ct.tenant_id = tt.tenant_id
    RETURNING ct.customer_id, ct.tenant_id
)
SELECT 'pruned', deleted.tenant_id, customers.email
FROM deleted
JOIN customers ON customers.id = deleted.customer_id
ORDER BY deleted.tenant_id;
\else
SELECT 'would-prune', tenant_id, email
FROM purge_dev_target_tenants
ORDER BY tenant_id;
\endif
SQL
}

purge_dev_state_sql() {
    echo "BEGIN;"
    purge_dev_state_target_sql
    purge_dev_state_plan_sql
    echo "COMMIT;"
}

run_purge_plan() {
    local execute_purge="$1"

    purge_dev_state_sql | run_local_psql -v ON_ERROR_STOP=1 -tA -F '|' \
        -v execute_purge="$execute_purge" \
        -v dev_customer_email="$LOCAL_SEED_SHARED_USER_EMAIL"
}

main() {
    local execute_purge=0 mode_label="dry-run" selected_mode=""

    load_env_file "$REPO_ROOT/.env.local"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run)
                reject_conflicting_mode_flag "$selected_mode" "dry-run"
                selected_mode="dry-run"
                execute_purge=0
                mode_label="dry-run"
                ;;
            --execute)
                reject_conflicting_mode_flag "$selected_mode" "execute"
                selected_mode="execute"
                execute_purge=1
                mode_label="execute"
                ;;
            --database-url)
                if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
                    echo "[purge-dev-state] ERROR: Missing value for --database-url" >&2
                    usage >&2
                    exit 2
                fi
                DATABASE_URL="$2"
                export DATABASE_URL
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "[purge-dev-state] ERROR: Unknown argument: $1" >&2
                usage >&2
                exit 2
                ;;
        esac
        shift
    done

    ensure_psql_on_path || true

    if ! require_local_database_access "dev state purge"; then
        die "Local database access unavailable; set DATABASE_URL or start Docker Postgres"
    fi

    log "Mode: ${mode_label}"
    run_purge_plan "$execute_purge"
    if [ "$execute_purge" -eq 0 ]; then
        log "Dry-run only; rerun with --execute to delete these rows"
    else
        log "Execute complete"
    fi
}

main "$@"
