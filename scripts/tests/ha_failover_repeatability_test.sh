#!/usr/bin/env bash
# Focused red-phase tests for HA failover repeatability defects.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

setup_proof_test_repo() {
    local tmp_dir="$1"

    mkdir -p "$tmp_dir/scripts/chaos" "$tmp_dir/scripts/lib" "$tmp_dir/bin"
    cp "$REPO_ROOT/scripts/chaos/ha-failover-proof.sh" "$tmp_dir/scripts/chaos/"
    cp "$REPO_ROOT/scripts/lib/env.sh" "$tmp_dir/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/health.sh" "$tmp_dir/scripts/lib/"

    cat > "$tmp_dir/scripts/chaos/restart-region.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$tmp_dir/scripts/chaos/restart-region.sh"

    cat > "$tmp_dir/.env.local" <<'EOF'
API_URL=http://localhost:3001
ADMIN_KEY=test-admin-key
EOF
}

# Convention: payload files live at well-known paths inside $tmp_dir:
#   vms.json, replicas-active.json, replicas-all.json,
#   alerts.json, tenant-before.json, kill.count
write_proof_mock_curl() {
    local tmp_dir="$1"
    local primary_vm_id="$2"
    local kill_count_file="$tmp_dir/kill.count"

    if [ ! -f "$kill_count_file" ]; then
        echo 0 > "$kill_count_file"
    fi

    cat > "$tmp_dir/bin/curl" <<EOF
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

case "\${method} \${url}" in
    "GET http://localhost:3001/health")
        echo '{"status":"ok"}'
        ;;
    "GET http://localhost:3001/admin/vms")
        cat "$tmp_dir/vms.json"
        ;;
    "GET http://localhost:3001/admin/replicas?status=active")
        cat "$tmp_dir/replicas-active.json"
        ;;
    "GET http://localhost:3001/admin/replicas")
        cat "$tmp_dir/replicas-all.json"
        ;;
    "GET http://localhost:3001/admin/alerts")
        cat "$tmp_dir/alerts.json"
        ;;
    "GET http://localhost:3001/admin/vms/$primary_vm_id")
        cat "$tmp_dir/tenant-before.json"
        ;;
    "POST http://localhost:3001/admin/vms/$primary_vm_id/kill")
        kill_count=0
        if [ -f "$kill_count_file" ]; then
            kill_count=\$(cat "$kill_count_file")
        fi
        echo \$((kill_count + 1)) > "$kill_count_file"
        echo '{"status":"killed"}'
        ;;
    *)
        echo "unexpected curl call: \${method} \${url}" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$tmp_dir/bin/curl"
}

test_rejects_stale_alert_state_before_destructive_kill() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_proof_test_repo "$tmp_dir"

    local primary_vm_id="11111111-1111-1111-1111-111111111111"
    local replica_vm_id="22222222-2222-2222-2222-222222222222"

    cat > "$tmp_dir/vms.json" <<JSON
[
  { "id": "$primary_vm_id", "region": "eu-central-1", "hostname": "primary.local" },
  { "id": "$replica_vm_id", "region": "us-east-1", "hostname": "replica.local" }
]
JSON
    cat > "$tmp_dir/replicas-active.json" <<JSON
[
  {
    "tenant_id": "products",
    "primary_vm_id": "$primary_vm_id",
    "primary_vm_region": "eu-central-1",
    "replica_vm_id": "$replica_vm_id",
    "replica_region": "us-east-1",
    "status": "active",
    "lag_ops": 1
  }
]
JSON
    cp "$tmp_dir/replicas-active.json" "$tmp_dir/replicas-all.json"
    cat > "$tmp_dir/alerts.json" <<'JSON'
[
  {
    "title": "Region down — eu-central-1",
    "message": "All 1 VMs in region eu-central-1 are unreachable.",
    "created_at": "2026-03-30T11:00:01Z"
  },
  {
    "title": "Index failed over — products",
    "message": "Index products failed over from eu-central-1 to us-east-1.",
    "created_at": "2026-03-30T11:00:02Z"
  }
]
JSON
    cat > "$tmp_dir/tenant-before.json" <<JSON
{
  "vm": { "id": "$primary_vm_id" },
  "tenants": [ { "tenant_id": "products" } ]
}
JSON
    echo 0 > "$tmp_dir/kill.count"

    write_proof_mock_curl "$tmp_dir" "$primary_vm_id"

    local exit_code=0
    local output
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        REGION_FAILOVER_CYCLE_INTERVAL_SECS=1 \
        bash "$tmp_dir/scripts/chaos/ha-failover-proof.sh" "eu-central-1" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" \
        "proof should exit non-zero when stale failover alerts already exist"
    assert_contains "$output" "Dirty alert state" \
        "proof should fail with explicit stale-alert dirty-state error"
    assert_eq "$(cat "$tmp_dir/kill.count")" "0" \
        "proof should block destructive kill when stale alerts already exist"
}

test_detects_consumed_replicas_from_prior_failover() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_proof_test_repo "$tmp_dir"

    local primary_vm_id="33333333-3333-3333-3333-333333333333"
    local replica_vm_id="44444444-4444-4444-4444-444444444444"

    cat > "$tmp_dir/vms.json" <<JSON
[
  { "id": "$primary_vm_id", "region": "eu-central-1", "hostname": "primary.local" },
  { "id": "$replica_vm_id", "region": "us-east-1", "hostname": "replica.local" }
]
JSON
    cat > "$tmp_dir/replicas-active.json" <<'JSON'
[]
JSON
    cat > "$tmp_dir/replicas-all.json" <<JSON
[
  {
    "tenant_id": "products",
    "primary_vm_id": "$primary_vm_id",
    "primary_vm_region": "eu-central-1",
    "replica_vm_id": "$replica_vm_id",
    "replica_region": "us-east-1",
    "status": "suspended",
    "lag_ops": 0
  }
]
JSON
    cat > "$tmp_dir/alerts.json" <<'JSON'
[]
JSON
    cat > "$tmp_dir/tenant-before.json" <<JSON
{
  "vm": { "id": "$primary_vm_id" },
  "tenants": [ { "tenant_id": "products" } ]
}
JSON
    echo 0 > "$tmp_dir/kill.count"

    write_proof_mock_curl "$tmp_dir" "$primary_vm_id"

    local exit_code=0
    local output
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        REGION_FAILOVER_CYCLE_INTERVAL_SECS=1 \
        bash "$tmp_dir/scripts/chaos/ha-failover-proof.sh" "eu-central-1" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" \
        "proof should exit non-zero when only consumed suspended replicas exist"
    assert_contains "$output" "consumed/suspended replicas from a prior failover run" \
        "proof should identify prior-run consumed replica state explicitly"
    assert_not_contains "$output" "No valid failover candidate found" \
        "proof should not collapse consumed-replica state into generic missing-candidate message"
}

main() {
    echo "=== ha failover repeatability tests ==="
    echo ""

    test_rejects_stale_alert_state_before_destructive_kill
    test_detects_consumed_replicas_from_prior_failover

    run_test_summary
}

main "$@"
