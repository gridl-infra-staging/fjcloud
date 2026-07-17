#!/usr/bin/env bash
# Chaos-specific test helpers for chaos_test.sh.
#
# Callers must define REPO_ROOT before sourcing.
# Shared mock writer helper (write_mock_script) is sourced from test_helpers.sh.

SCRIPT_DIR_CHAOS_HELPERS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR_CHAOS_HELPERS/test_helpers.sh"

copy_chaos_script_into_test_root() {
    local script_name="$1"
    local root_dir="$2"
    cp "$REPO_ROOT/scripts/chaos/$script_name" "$root_dir/scripts/chaos/"
}

copy_chaos_support_libs_into_test_root() {
    local root_dir="$1"
    cp "$REPO_ROOT/scripts/lib/env.sh" "$root_dir/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/health.sh" "$root_dir/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/flapjack_binary.sh" "$root_dir/scripts/lib/"
}

setup_kill_region_test_root() {
    local root_dir="$1"
    mkdir -p "$root_dir/.local" "$root_dir/scripts/chaos"
    copy_chaos_script_into_test_root "kill-region.sh" "$root_dir"
}

setup_restart_region_test_root() {
    local root_dir="$1"
    mkdir -p "$root_dir/.local" "$root_dir/scripts/chaos" "$root_dir/scripts/lib"
    copy_chaos_script_into_test_root "restart-region.sh" "$root_dir"
    copy_chaos_support_libs_into_test_root "$root_dir"
}

setup_ha_failover_test_root() {
    local root_dir="$1"
    mkdir -p "$root_dir/scripts/chaos" "$root_dir/scripts/lib"
    copy_chaos_script_into_test_root "ha-failover-proof.sh" "$root_dir"
    copy_chaos_support_libs_into_test_root "$root_dir"
}

write_test_database_env_file() {
    local root_dir="$1"
    cat > "$root_dir/.env.local" <<'EOF'
DATABASE_URL=postgres://test:test@localhost:5432/test
EOF
}

write_successful_restart_region_stub() {
    local path="$1"
    cat > "$path" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$path"
}

kill_process_from_pid_file_if_present() {
    local pid_file="$1"
    if [ -f "$pid_file" ]; then
        kill "$(cat "$pid_file")" 2>/dev/null || true
    fi
}

write_mock_lsof_for_pid_file() {
    local path="$1" pid_file="$2"
    cat > "$path" << MOCK
#!/usr/bin/env bash
cat "$pid_file" 2>/dev/null || true
MOCK
    chmod +x "$path"
}

write_mock_lsof_static_pid() {
    local path="$1" pid="$2"
    cat > "$path" << MOCK
#!/usr/bin/env bash
echo "$pid"
MOCK
    chmod +x "$path"
}

write_ha_curl_mock_header() {
    local path="$1"
    local call_log="$2"
    cat > "$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

method="GET"
url=""
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        -X)
            method="\$2"
            shift 2
            ;;
        http://*|https://*)
            url="\$1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

echo "\${method} \${url}" >> "$call_log"

case "\${method} \${url}" in
EOF
}

append_ha_curl_mock_footer() {
    local path="$1"
    cat >> "$path" <<'EOF'
    *)
        echo "unexpected curl call: ${method} ${url}" >&2
        exit 1
        ;;
esac
EOF
}

append_minimal_ha_inventory_routes() {
    local path="$1"
    cat >> "$path" <<EOF
    "GET http://localhost:3001/health")
        echo '{"status":"ok"}'
        ;;
    "GET http://localhost:3001/admin/vms")
        cat <<'JSON'
[
  {"id":"11111111-1111-1111-1111-111111111111","region":"us-east-1","hostname":"primary.local"},
  {"id":"ffffffff-ffff-ffff-ffff-ffffffffffff","region":"eu-central-1","hostname":"replica.local"}
]
JSON
        ;;
    "GET http://localhost:3001/admin/replicas?status=active")
        cat <<'JSON'
[
  {
    "customer_id":"22222222-2222-2222-2222-222222222222",
    "tenant_id":"products",
    "primary_vm_id":"11111111-1111-1111-1111-111111111111",
    "primary_vm_region":"us-east-1",
    "replica_vm_id":"ffffffff-ffff-ffff-ffff-ffffffffffff",
    "replica_region":"eu-central-1",
    "status":"active",
    "lag_ops":1
  }
]
JSON
        ;;
EOF
}

append_minimal_ha_alert_routes() {
    local path="$1"
    local alert_state_dir="$2"
    cat >> "$path" <<EOF
    "GET http://localhost:3001/admin/alerts")
        alert_count_file="$alert_state_dir/alerts.count"
        if [ ! -f "\$alert_count_file" ]; then
            echo 0 > "\$alert_count_file"
        fi
        alert_count=\$(cat "\$alert_count_file")
        case "\$alert_count" in
            0)
                cat <<'JSON'
[
  {"title":"Region down — us-east-1","message":"old","created_at":"2026-03-29T12:00:01Z"}
]
JSON
                ;;
            1)
                cat <<'JSON'
[
  {"title":"Region down — us-east-1","message":"old","created_at":"2026-03-29T12:00:01Z"},
  {"title":"Region down — us-east-1","message":"new","created_at":"2026-03-30T12:00:01Z"},
  {"title":"Index failed over — products","message":"new","created_at":"2026-03-30T12:00:02Z"}
]
JSON
                ;;
            *)
                cat <<'JSON'
[
  {"title":"Region down — us-east-1","message":"old","created_at":"2026-03-29T12:00:01Z"},
  {"title":"Region down — us-east-1","message":"new","created_at":"2026-03-30T12:00:01Z"},
  {"title":"Index failed over — products","message":"new","created_at":"2026-03-30T12:00:02Z"},
  {"title":"Region recovered — us-east-1","message":"new","created_at":"2026-03-30T12:00:03Z"}
]
JSON
                ;;
        esac
        echo \$((alert_count + 1)) > "\$alert_count_file"
        ;;
EOF
}

append_minimal_ha_vm_detail_routes() {
    local path="$1"
    cat >> "$path" <<'EOF'
    "GET http://localhost:3001/admin/vms/11111111-1111-1111-1111-111111111111")
        cat <<'JSON'
{"vm":{"id":"11111111-1111-1111-1111-111111111111"},"tenants":[{"customer_id":"22222222-2222-2222-2222-222222222222","tenant_id":"products"}]}
JSON
        ;;
    "GET http://localhost:3001/admin/vms/ffffffff-ffff-ffff-ffff-ffffffffffff")
        cat <<'JSON'
{"vm":{"id":"ffffffff-ffff-ffff-ffff-ffffffffffff"},"tenants":[{"customer_id":"22222222-2222-2222-2222-222222222222","tenant_id":"products"}]}
JSON
        ;;
    "POST http://localhost:3001/admin/vms/11111111-1111-1111-1111-111111111111/kill")
        echo '{"status":"killed"}'
        ;;
EOF
}

append_lowest_lag_ha_inventory_routes() {
    local path="$1"
    cat >> "$path" <<'EOF'
    "GET http://localhost:3001/health")
        echo '{"status":"ok"}'
        ;;
    "GET http://localhost:3001/admin/vms")
        cat <<'JSON'
[
  {"id":"11111111-1111-1111-1111-111111111111","region":"us-east-1","hostname":"primary.local"},
  {"id":"00000000-0000-0000-0000-000000000001","region":"eu-west-1","hostname":"replica-high-lag.local"},
  {"id":"ffffffff-ffff-ffff-ffff-ffffffffffff","region":"eu-central-1","hostname":"replica-low-lag.local"}
]
JSON
        ;;
    "GET http://localhost:3001/admin/replicas?status=active")
        cat <<'JSON'
[
  {"customer_id":"22222222-2222-2222-2222-222222222222","tenant_id":"products","primary_vm_id":"11111111-1111-1111-1111-111111111111","primary_vm_region":"us-east-1","replica_vm_id":"00000000-0000-0000-0000-000000000001","replica_region":"eu-west-1","status":"active","lag_ops":50},
  {"customer_id":"22222222-2222-2222-2222-222222222222","tenant_id":"products","primary_vm_id":"11111111-1111-1111-1111-111111111111","primary_vm_region":"us-east-1","replica_vm_id":"ffffffff-ffff-ffff-ffff-ffffffffffff","replica_region":"eu-central-1","status":"active","lag_ops":1}
]
JSON
        ;;
EOF
}

append_lowest_lag_ha_alert_routes() {
    local path="$1"
    local alert_state_dir="$2"
    cat >> "$path" <<EOF
    "GET http://localhost:3001/admin/alerts")
        alert_count_file="$alert_state_dir/alerts.count"
        if [ ! -f "\$alert_count_file" ]; then
            echo 0 > "\$alert_count_file"
        fi
        alert_count=\$(cat "\$alert_count_file")
        case "\$alert_count" in
            0)
                cat <<'JSON'
[
  {"title":"Region down — us-east-1","message":"Old proof alert for region us-east-1.","created_at":"2026-03-29T12:00:01Z"},
  {"title":"Index failed over — products","message":"Old proof alert for tenant products.","created_at":"2026-03-29T12:00:02Z"}
]
JSON
                ;;
            1)
                cat <<'JSON'
[
  {"title":"Region down — us-east-1","message":"Old proof alert for region us-east-1.","created_at":"2026-03-29T12:00:01Z"},
  {"title":"Index failed over — products","message":"Old proof alert for tenant products.","created_at":"2026-03-29T12:00:02Z"},
  {"title":"Region down — us-east-1","message":"All 1 VMs in region us-east-1 are unreachable.","created_at":"2026-03-30T12:00:01Z"},
  {"title":"Index failed over — products","message":"Index products failed over from us-east-1 to eu-central-1.","created_at":"2026-03-30T12:00:02Z"}
]
JSON
                ;;
            *)
                cat <<'JSON'
[
  {"title":"Region down — us-east-1","message":"Old proof alert for region us-east-1.","created_at":"2026-03-29T12:00:01Z"},
  {"title":"Index failed over — products","message":"Old proof alert for tenant products.","created_at":"2026-03-29T12:00:02Z"},
  {"title":"Region down — us-east-1","message":"All 1 VMs in region us-east-1 are unreachable.","created_at":"2026-03-30T12:00:01Z"},
  {"title":"Index failed over — products","message":"Index products failed over from us-east-1 to eu-central-1.","created_at":"2026-03-30T12:00:02Z"},
  {"title":"Region recovered — us-east-1","message":"All 1 VMs in region us-east-1 are healthy again.","created_at":"2026-03-30T12:00:03Z"}
]
JSON
                ;;
        esac
        echo \$((alert_count + 1)) > "\$alert_count_file"
        ;;
EOF
}

append_lowest_lag_ha_vm_detail_routes() {
    local path="$1"
    cat >> "$path" <<'EOF'
    "GET http://localhost:3001/admin/vms/11111111-1111-1111-1111-111111111111")
        cat <<'JSON'
{"vm":{"id":"11111111-1111-1111-1111-111111111111"},"tenants":[{"customer_id":"22222222-2222-2222-2222-222222222222","tenant_id":"products"}]}
JSON
        ;;
    "GET http://localhost:3001/admin/vms/00000000-0000-0000-0000-000000000001")
        echo '{"vm":{"id":"00000000-0000-0000-0000-000000000001"},"tenants":[]}'
        ;;
    "GET http://localhost:3001/admin/vms/ffffffff-ffff-ffff-ffff-ffffffffffff")
        cat <<'JSON'
{"vm":{"id":"ffffffff-ffff-ffff-ffff-ffffffffffff"},"tenants":[{"customer_id":"22222222-2222-2222-2222-222222222222","tenant_id":"products"}]}
JSON
        ;;
    "POST http://localhost:3001/admin/vms/11111111-1111-1111-1111-111111111111/kill")
        echo '{"status":"killed"}'
        ;;
EOF
}

write_minimal_ha_failover_curl_mock() {
    local path="$1"
    local alert_state_dir="$2"
    local call_log="$3"
    write_ha_curl_mock_header "$path" "$call_log"
    append_minimal_ha_inventory_routes "$path"
    append_minimal_ha_alert_routes "$path" "$alert_state_dir"
    append_minimal_ha_vm_detail_routes "$path"
    append_ha_curl_mock_footer "$path"
    chmod +x "$path"
}

write_lowest_lag_ha_failover_curl_mock() {
    local path="$1"
    local alert_state_dir="$2"
    local call_log="$3"
    write_ha_curl_mock_header "$path" "$call_log"
    append_lowest_lag_ha_inventory_routes "$path"
    append_lowest_lag_ha_alert_routes "$path" "$alert_state_dir"
    append_lowest_lag_ha_vm_detail_routes "$path"
    append_ha_curl_mock_footer "$path"
    chmod +x "$path"
}
