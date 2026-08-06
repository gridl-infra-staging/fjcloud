#!/usr/bin/env bash
# Focused red-phase tests for HA failover repeatability defects.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/chaos_test_helpers.sh
source "$SCRIPT_DIR/lib/chaos_test_helpers.sh"

latest_region_artifact_dir_after() {
    local marker_file="$1"
    local region="$2"
    local candidate newest=""

    for candidate in /tmp/fjcloud-ha-proof/*-"$region"-*; do
        [ -d "$candidate" ] || continue
        if [ "$candidate" -nt "$marker_file" ]; then
            newest="$candidate"
        fi
    done

    printf '%s\n' "$newest"
}

setup_proof_test_repo() {
    local tmp_dir="$1"

    mkdir -p "$tmp_dir/scripts/chaos" "$tmp_dir/scripts/lib" "$tmp_dir/bin"
    cp "$REPO_ROOT/scripts/chaos/ha-failover-proof.sh" "$tmp_dir/scripts/chaos/"
    cp "$REPO_ROOT/scripts/lib/env.sh" "$tmp_dir/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/health.sh" "$tmp_dir/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/flapjack_binary.sh" "$tmp_dir/scripts/lib/"

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

    local alert_state_dir="$tmp_dir/state"
    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin" "$alert_state_dir"
    setup_ha_failover_test_root "$tmp_dir"
    write_successful_restart_region_stub "$tmp_dir/scripts/chaos/restart-region.sh"
    write_pre_satisfied_ha_failover_curl_mock \
        "$tmp_dir/bin/curl" "$alert_state_dir" "$call_log"
    write_mock_script "$tmp_dir/bin/flapjack" 'sleep 60'

    local exit_code=0
    local output
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        REGION_FAILOVER_CYCLE_INTERVAL_SECS=1 \
        bash "$tmp_dir/scripts/chaos/ha-failover-proof.sh" "us-east-1" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" \
        "proof should exit non-zero when stale failover alerts already exist"
    assert_contains "$output" "Dirty alert state" \
        "proof should fail with explicit stale-alert dirty-state error"
    local calls
    calls="$(cat "$call_log" 2>/dev/null || true)"
    assert_not_contains "$calls" \
        "POST http://localhost:3001/admin/vms/11111111-1111-1111-1111-111111111111/kill" \
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

test_artifact_dir_is_private_even_under_permissive_parent_umask() {
    local tmp_dir marker_file artifact_dir artifact_mode
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_proof_test_repo "$tmp_dir"

    local primary_vm_id="55555555-5555-5555-5555-555555555555"
    local replica_vm_id="66666666-6666-6666-6666-666666666666"

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

    write_proof_mock_curl "$tmp_dir" "$primary_vm_id"
    marker_file="$tmp_dir/artifact.marker"
    : > "$marker_file"

    env PATH="$tmp_dir/bin:$PATH" \
        REGION_FAILOVER_CYCLE_INTERVAL_SECS=1 \
        bash -c 'umask 022; exec bash "$1" "eu-central-1"' _ \
        "$tmp_dir/scripts/chaos/ha-failover-proof.sh" >/dev/null 2>&1 || true

    artifact_dir="$(latest_region_artifact_dir_after "$marker_file" "eu-central-1")"
    if [ -n "$artifact_dir" ]; then
        pass "proof wrote an artifact directory for permission inspection"
    else
        fail "proof should create an artifact directory before failing dirty-alert preflight"
        return
    fi

    artifact_mode="$(stat -c '%a' "$artifact_dir" 2>/dev/null || stat -f '%OLp' "$artifact_dir")"
    assert_eq "$artifact_mode" "700" \
        "proof artifact directory should stay private even if parent shell umask is 022"
    rm -rf "$artifact_dir"
}

main() {
    echo "=== ha failover repeatability tests ==="
    echo ""

    test_rejects_stale_alert_state_before_destructive_kill
    test_detects_consumed_replicas_from_prior_failover
    test_artifact_dir_is_private_even_under_permissive_parent_umask

    run_test_summary
}

main "$@"
