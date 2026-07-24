#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2030,SC2031
# Prove the disabled VM-autorepair detection path against one lane-owned EC2 VM.
#
# The script deliberately does not classify liveness. It observes the Rust
# reconciler's structured EngineDown log and durable lifecycle-event API.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/http_json.sh
source "$SCRIPT_DIR/lib/http_json.sh"
# shellcheck source=scripts/lib/health.sh
source "$SCRIPT_DIR/lib/health.sh"

CANONICAL_SECRET_FILE="/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret"
DEFAULT_EVIDENCE_ROOT="$REPO_ROOT/docs/runbooks/evidence/vm-autorepair"
DEFAULT_LOCAL_DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:5432/fjcloud_dev"
SSM_ENVIRONMENT="staging"

API_PID=""
TEMP_DATABASE_URL=""
TEMP_DATABASE_NAME=""
BASE_DATABASE_URL=""
RUNTIME_DIR=""
EVIDENCE_DIR=""
ALLOWLIST_FILE=""
CLEANUP_STARTED=0
CLEANUP_RESULT=0
DATABASE_CREATED=0
CREATED_INSTANCE_IDS=()
LANE_INSTANCE_ID=""

log() {
    printf '%s\n' "$*"
}

fail() {
    log "ERROR: $*" >&2
    return 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

require_nonempty() {
    local name="$1"
    local value="${!name:-}"
    if [ -z "$value" ] || [ "$value" = "None" ]; then
        fail "required AWS config is absent: $name"
    fi
}

is_loopback_database_url() {
    local database_url="$1"
    local authority host

    case "$database_url" in
        postgres://* | postgresql://*) ;;
        *) return 1 ;;
    esac
    authority="${database_url#*://}"
    authority="${authority%%/*}"
    authority="${authority##*@}"
    if [[ "$authority" == \[*\]* ]]; then
        host="${authority#\[}"
        host="${host%%\]*}"
    else
        host="${authority%%:*}"
    fi
    case "$host" in
        localhost | 127.* | ::1) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_secret_file() {
    if [ "${FJCLOUD_VM_AUTOREPAIR_TEST_MODE:-0}" = "1" ]; then
        printf '%s\n' "${FJCLOUD_VM_AUTOREPAIR_SECRET_FILE:-$CANONICAL_SECRET_FILE}"
        return
    fi
    if [ -n "${FJCLOUD_VM_AUTOREPAIR_SECRET_FILE:-}" ] &&
        [ "$FJCLOUD_VM_AUTOREPAIR_SECRET_FILE" != "$CANONICAL_SECRET_FILE" ]; then
        fail "secret-file override is permitted only in hermetic test mode"
        return 1
    fi
    printf '%s\n' "$CANONICAL_SECRET_FILE"
}

resolve_evidence_root() {
    if [ "${FJCLOUD_VM_AUTOREPAIR_TEST_MODE:-0}" = "1" ]; then
        printf '%s\n' "${FJCLOUD_VM_AUTOREPAIR_EVIDENCE_ROOT:-$DEFAULT_EVIDENCE_ROOT}"
        return
    fi
    if [ -n "${FJCLOUD_VM_AUTOREPAIR_EVIDENCE_ROOT:-}" ] &&
        [ "$FJCLOUD_VM_AUTOREPAIR_EVIDENCE_ROOT" != "$DEFAULT_EVIDENCE_ROOT" ]; then
        fail "evidence-root override is permitted only in hermetic test mode"
        return 1
    fi
    printf '%s\n' "$DEFAULT_EVIDENCE_ROOT"
}

allowlist_contains() {
    local instance_id="$1"
    [ -f "$ALLOWLIST_FILE" ] &&
        grep -Fxq "$instance_id" "$ALLOWLIST_FILE"
}

process_created_instance() {
    local candidate="$1"
    local created_id
    for created_id in "${CREATED_INSTANCE_IDS[@]}"; do
        if [ "$created_id" = "$candidate" ]; then
            return 0
        fi
    done
    return 1
}

assert_termination_authorized() {
    local instance_id="$1"
    process_created_instance "$instance_id" ||
        {
            fail "instance was not created by this proof process: $instance_id"
            return 1
        }
    allowlist_contains "$instance_id" ||
        {
            fail "target instance ID is not present in the stage allowlist: $instance_id"
            return 1
        }
}

assert_customer_tag_absent() {
    local instance_id="$1"
    local customer_tag_count
    customer_tag_count="$(
        aws ec2 describe-tags \
            --filters \
                "Name=resource-id,Values=$instance_id" \
                "Name=key,Values=customer_id" \
            --query 'length(Tags)' \
            --output text
    )"
    [ "$customer_tag_count" = "0" ] ||
        {
            fail "refusing to terminate instance carrying customer_id tag: $instance_id"
            return 1
        }
}

instance_state() {
    aws ec2 describe-instances \
        --instance-ids "$1" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text
}

terminate_owned_instance() {
    local instance_id="$1"
    local state

    assert_termination_authorized "$instance_id" || return $?
    state="$(instance_state "$instance_id")"
    case "$state" in
        shutting-down | terminated) ;;
        *)
            # This tag interlock is intentionally the final preflight.
            assert_customer_tag_absent "$instance_id" || return $?
            aws ec2 terminate-instances \
                --instance-ids "$instance_id" \
                --output json >/dev/null
            ;;
    esac
    aws ec2 wait instance-terminated --instance-ids "$instance_id"
}

cleanup() {
    local cleanup_status=0
    local instance_id

    if [ "$CLEANUP_STARTED" -eq 1 ]; then
        return "$CLEANUP_RESULT"
    fi
    CLEANUP_STARTED=1
    set +e

    if [ -n "$API_PID" ] && kill -0 "$API_PID" 2>/dev/null; then
        kill "$API_PID" 2>/dev/null
        wait "$API_PID" 2>/dev/null
        if kill -0 "$API_PID" 2>/dev/null; then
            cleanup_status=1
        fi
    fi

    for instance_id in "${CREATED_INSTANCE_IDS[@]}"; do
        if allowlist_contains "$instance_id"; then
            terminate_owned_instance "$instance_id" >/dev/null 2>&1 || cleanup_status=1
        fi
    done

    if [ "$DATABASE_CREATED" -eq 1 ] && [ -n "$TEMP_DATABASE_URL" ]; then
        sqlx database drop --database-url "$TEMP_DATABASE_URL" -y >/dev/null 2>&1 ||
            cleanup_status=1
    fi
    if [ -n "$RUNTIME_DIR" ] && [ -d "$RUNTIME_DIR" ]; then
        rm -rf "$RUNTIME_DIR"
    fi

    CLEANUP_RESULT=$cleanup_status
    set -e
    return "$CLEANUP_RESULT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

hydrate_aws_provisioner_config() {
    AWS_AMI_ID="$(
        aws ssm get-parameter \
            --name "/fjcloud/$SSM_ENVIRONMENT/aws_ami_id" \
            --query 'Parameter.Value' \
            --output text
    )"
    AWS_SUBNET_ID="$(
        aws ssm get-parameter \
            --name "/fjcloud/$SSM_ENVIRONMENT/aws_subnet_id" \
            --query 'Parameter.Value' \
            --output text
    )"
    AWS_SECURITY_GROUP_IDS="$(
        aws ssm get-parameter \
            --name "/fjcloud/$SSM_ENVIRONMENT/aws_security_group_ids" \
            --query 'Parameter.Value' \
            --output text
    )"
    AWS_KEY_PAIR_NAME="$(
        aws ssm get-parameter \
            --name "/fjcloud/$SSM_ENVIRONMENT/aws_key_pair_name" \
            --query 'Parameter.Value' \
            --output text
    )"
    AWS_INSTANCE_PROFILE_NAME="$(
        aws ssm get-parameter \
            --name "/fjcloud/$SSM_ENVIRONMENT/aws_instance_profile_name" \
            --query 'Parameter.Value' \
            --output text 2>/dev/null || true
    )"
    export AWS_AMI_ID AWS_SUBNET_ID AWS_SECURITY_GROUP_IDS AWS_KEY_PAIR_NAME
    if [ "$AWS_INSTANCE_PROFILE_NAME" = "None" ]; then
        AWS_INSTANCE_PROFILE_NAME=""
    fi
    export AWS_INSTANCE_PROFILE_NAME

    require_nonempty AWS_AMI_ID
    require_nonempty AWS_SUBNET_ID
    require_nonempty AWS_SECURITY_GROUP_IDS
    require_nonempty AWS_KEY_PAIR_NAME
}

create_temporary_database() {
    local database_url_without_query database_url_query database_url_prefix

    database_url_without_query="${BASE_DATABASE_URL%%\?*}"
    database_url_query=""
    if [[ "$BASE_DATABASE_URL" == *\?* ]]; then
        database_url_query="?${BASE_DATABASE_URL#*\?}"
    fi
    database_url_prefix="${database_url_without_query%/*}"
    [ "$database_url_prefix" != "$database_url_without_query" ] ||
        fail "could not derive a temporary database URL"

    TEMP_DATABASE_NAME="fjcloud_vm_autorepair_$(date -u +%Y%m%d%H%M%S)_$$"
    TEMP_DATABASE_URL="${database_url_prefix}/${TEMP_DATABASE_NAME}${database_url_query}"
    sqlx database create --database-url "$TEMP_DATABASE_URL"
    DATABASE_CREATED=1
    sqlx migrate run \
        --source "$REPO_ROOT/infra/migrations" \
        --database-url "$TEMP_DATABASE_URL"

    local inventory_count
    inventory_count="$(
        psql "$TEMP_DATABASE_URL" -v ON_ERROR_STOP=1 -Atqc \
            'SELECT count(*) FROM vm_inventory'
    )"
    [ "$inventory_count" = "0" ] ||
        fail "temporary database vm_inventory must initially be empty"
}

managed_nonterminated_instance_ids() {
    aws ec2 describe-instances \
        --filters \
            "Name=tag:managed-by,Values=fjcloud" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text |
        tr '\t' '\n' |
        sed '/^$/d' |
        sort
}

seed_vm_inventory() {
    local hostname="$1"
    local engine_port="$2"
    psql "$TEMP_DATABASE_URL" \
        -v ON_ERROR_STOP=1 \
        -Atq \
        -v region="$AWS_DEFAULT_REGION" \
        -v hostname="$hostname" \
        -v flapjack_url="http://127.0.0.1:$engine_port" <<'SQL'
INSERT INTO vm_inventory (
    region, provider, hostname, flapjack_url, capacity, current_load
) VALUES (
    :'region', 'aws', :'hostname', :'flapjack_url',
    '{"cpu_cores":2,"memory_mb":4096}'::jsonb, '{}'::jsonb
) RETURNING id;
SQL
}

create_lane_instance() {
    local hostname="$1"
    local security_group_ids=()
    local run_arguments=()

    IFS=',' read -r -a security_group_ids <<< "$AWS_SECURITY_GROUP_IDS"
    run_arguments=(
        ec2 run-instances
        --image-id "$AWS_AMI_ID"
        --instance-type "t4g.small"
        --subnet-id "$AWS_SUBNET_ID"
        --security-group-ids "${security_group_ids[@]}"
        --key-name "$AWS_KEY_PAIR_NAME"
        --metadata-options "HttpTokens=required,InstanceMetadataTags=enabled"
        --tag-specifications
        "ResourceType=instance,Tags=[{Key=Name,Value=fj-$hostname},{Key=managed-by,Value=fjcloud},{Key=stage,Value=vm-autorepair-detection}]"
    )
    if [ -n "$AWS_INSTANCE_PROFILE_NAME" ]; then
        run_arguments+=(
            --iam-instance-profile "Name=$AWS_INSTANCE_PROFILE_NAME"
        )
    fi
    run_arguments+=(
        --query 'Instances[0].InstanceId'
        --output text
    )

    LANE_INSTANCE_ID="$(aws "${run_arguments[@]}")"
    require_nonempty LANE_INSTANCE_ID
    CREATED_INSTANCE_IDS+=("$LANE_INSTANCE_ID")
    printf '%s\n' "$LANE_INSTANCE_ID" >> "$ALLOWLIST_FILE"
    chmod 600 "$ALLOWLIST_FILE"
}

start_local_api() {
    local api_port="$1"
    local s3_port="$2"
    local api_log="$3"

    log "pre-building API binary"
    cargo build --manifest-path "$REPO_ROOT/infra/Cargo.toml" -p api ||
        fail "API binary compilation failed"

    API_URL="http://127.0.0.1:$api_port"
    export API_URL
    (
        unset LOCAL_DEV_FLAPJACK_URL
        unset DNS_HOSTED_ZONE_ID DNS_DOMAIN
        unset CLOUDFLARE_API_TOKEN CLOUDFLARE_ZONE_ID
        unset SES_FROM_ADDRESS SES_REGION SES_CONFIGURATION_SET
        export DATABASE_URL="$TEMP_DATABASE_URL"
        export LISTEN_ADDR="127.0.0.1:$api_port"
        export S3_LISTEN_ADDR="127.0.0.1:$s3_port"
        export ENVIRONMENT="local"
        export NODE_SECRET_BACKEND="memory"
        export FJCLOUD_VM_AUTOREPAIR_ENABLED="false"
        export FJCLOUD_VM_AUTOREPAIR_CHECK_INTERVAL_SECONDS="1"
        export FJCLOUD_VM_AUTOREPAIR_HOST_DEAD_AFTER_SECONDS="3"
        export FJCLOUD_VM_AUTOREPAIR_REPLACEMENT_COOLDOWN_SECONDS="60"
        export JWT_SECRET="vm-autorepair-local-proof-jwt-secret"
        export DUNNING_EMAILS_DISABLED="true"
        export RUST_LOG="info,api=debug"
        exec cargo run --manifest-path "$REPO_ROOT/infra/Cargo.toml" -p api
    ) > "$api_log" 2>&1 &
    API_PID=$!
    if ! wait_for_health "$API_URL/health" "local API" 60; then
        local failure_log="$EVIDENCE_DIR/api_startup_failure.log"
        if [ -f "$api_log" ]; then
            local redacted
            redacted="$(cat "$api_log")"
            local secret_val
            for secret_val in \
                "${AWS_SECRET_ACCESS_KEY:-}" \
                "${AWS_ACCESS_KEY_ID:-}" \
                "${ADMIN_KEY:-}"; do
                [ -n "$secret_val" ] || continue
                redacted="${redacted//"$secret_val"/[REDACTED]}"
            done
            printf '%s\n' "$redacted" > "$failure_log"
        fi
        fail "local API failed to start"
    fi
}

poll_for_engine_down() {
    local api_log="$1"
    local max_polls="${FJCLOUD_VM_AUTOREPAIR_MAX_POLLS:-60}"
    local poll_seconds="${FJCLOUD_VM_AUTOREPAIR_POLL_SECONDS:-1}"
    local attempt
    for ((attempt = 0; attempt < max_polls; attempt++)); do
        if grep -F '"liveness":"EngineDown"' "$api_log" >/dev/null 2>&1; then
            grep -F '"liveness":"EngineDown"' "$api_log" |
                tail -1 > "$EVIDENCE_DIR/engine_down_observation.json"
            return 0
        fi
        sleep "$poll_seconds"
    done
    fail "Rust reconciler did not emit EngineDown observation"
}

poll_for_disabled_replacement_events() {
    local vm_id="$1"
    local lifecycle_file="$EVIDENCE_DIR/lifecycle_events.json"
    local max_polls="${FJCLOUD_VM_AUTOREPAIR_MAX_POLLS:-60}"
    local poll_seconds="${FJCLOUD_VM_AUTOREPAIR_POLL_SECONDS:-1}"
    local attempt

    for ((attempt = 0; attempt < max_polls; attempt++)); do
        admin_call GET "/admin/vms/$vm_id/lifecycle-events" > "$lifecycle_file"
        if jq -e '
            ([.[].event_type] | index("detected_dead")) as $dead
            | ([.[].event_type] | index("replacement_refused")) as $refused
            | $dead != null
              and $refused != null
              and $dead < $refused
              and any(.[];
                .event_type == "replacement_refused"
                and .detail.guardrail == "kill_switch_disabled")
        ' "$lifecycle_file" >/dev/null; then
            return 0
        fi
        sleep "$poll_seconds"
    done
    fail "ordered disabled-replacement lifecycle trail was not observed"
}

assert_no_autonomous_replacement() {
    local initial_fleet="$1"
    local vm_id="$2"
    local lifecycle_file="$EVIDENCE_DIR/lifecycle_events.json"
    local final_fleet inventory_count placement_count

    jq -e '
        all(.[].event_type;
            . != "replacement_provisioning"
            and . != "replacement_booted"
            and . != "tenants_replaced"
            and . != "replacement_completed")
    ' "$lifecycle_file" >/dev/null ||
        fail "autonomous replacement lifecycle evidence was produced"

    final_fleet="$(managed_nonterminated_instance_ids)"
    [ "$final_fleet" = "$initial_fleet" ] ||
        fail "non-terminated managed EC2 fleet changed outside the allowlist"

    inventory_count="$(
        psql "$TEMP_DATABASE_URL" -v ON_ERROR_STOP=1 -Atqc \
            'SELECT count(*) FROM vm_inventory'
    )"
    [ "$inventory_count" = "1" ] ||
        fail "local inventory changed beyond the seeded VM"
    placement_count="$(
        psql "$TEMP_DATABASE_URL" -v ON_ERROR_STOP=1 -Atq -v vm_id="$vm_id" <<'SQL'
SELECT count(*) FROM customer_tenants WHERE vm_id = :'vm_id';
SQL
    )"
    [ "$placement_count" = "0" ] ||
        fail "tenant placement mutation was observed"
}

write_success_evidence() {
    local hostname="$1"
    local instance_id="$2"
    local instance_final_state="$3"
    cat > "$EVIDENCE_DIR/summary.json" <<JSON
{
  "verdict": "passed",
  "hostname": "$hostname",
  "instance_id": "$instance_id",
  "instance_final_state": "$instance_final_state",
  "autorepair_enabled": false,
  "inventory_rows": 1,
  "tenant_placement_mutations": 0,
  "autonomous_replacement_events": 0
}
JSON
    cat > "$EVIDENCE_DIR/command_evidence.txt" <<'EOF'
PASS: isolated migrations applied
PASS: initial vm_inventory count = 0
PASS: running EC2 plus unreachable engine observed as EngineDown by Rust owner
PASS: terminated EC2 observed as detected_dead
PASS: replacement_refused guardrail = kill_switch_disabled
PASS: no autonomous replacement or tenant placement mutation
PASS: lane-created instance terminated
EOF
}

main() {
    local secret_file evidence_root timestamp
    local api_port s3_port engine_port api_log
    local hostname timestamp_slug vm_id instance_id initial_fleet final_state database_exists

    require_command aws
    require_command cargo
    require_command curl
    require_command jq
    require_command psql
    require_command sqlx

    BASE_DATABASE_URL="${DATABASE_URL:-$DEFAULT_LOCAL_DATABASE_URL}"
    is_loopback_database_url "$BASE_DATABASE_URL" ||
        fail "DATABASE_URL must target loopback"

    secret_file="$(resolve_secret_file)"
    [ -f "$secret_file" ] || fail "authorized secret file is missing: $secret_file"

    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    unset AWS_SECURITY_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE
    unset AWS_REGION AWS_DEFAULT_REGION
    unset AWS_AMI_ID AWS_SUBNET_ID AWS_SECURITY_GROUP_IDS
    unset AWS_KEY_PAIR_NAME AWS_INSTANCE_PROFILE_NAME
    load_env_file "$secret_file"
    require_nonempty AWS_ACCESS_KEY_ID
    require_nonempty AWS_SECRET_ACCESS_KEY
    require_nonempty AWS_DEFAULT_REGION
    require_nonempty ADMIN_KEY
    aws sts get-caller-identity --query Account --output text >/dev/null
    hydrate_aws_provisioner_config

    evidence_root="$(resolve_evidence_root)"
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    EVIDENCE_DIR="$evidence_root/${timestamp}_l3_detection_proof"
    mkdir -p "$EVIDENCE_DIR"
    ALLOWLIST_FILE="$EVIDENCE_DIR/instance_allowlist.txt"
    : > "$ALLOWLIST_FILE"
    chmod 600 "$ALLOWLIST_FILE"
    RUNTIME_DIR="$(mktemp -d)"
    api_log="$RUNTIME_DIR/api.log"

    api_port="${FJCLOUD_VM_AUTOREPAIR_API_PORT:-$((18000 + RANDOM % 1000))}"
    s3_port="${FJCLOUD_VM_AUTOREPAIR_S3_PORT:-$((19000 + RANDOM % 1000))}"
    engine_port="${FJCLOUD_VM_AUTOREPAIR_ENGINE_PORT:-$((20000 + RANDOM % 1000))}"
    check_port_available "$api_port" "VM autorepair proof API"
    check_port_available "$s3_port" "VM autorepair proof S3 listener"
    check_port_available "$engine_port" "intentionally unreachable engine"

    create_temporary_database
    timestamp_slug="$(printf '%s' "$timestamp" | tr '[:upper:]' '[:lower:]')"
    hostname="autorepair-l3-${timestamp_slug}-$$"
    vm_id="$(seed_vm_inventory "$hostname" "$engine_port")"
    [ -n "$vm_id" ] || fail "failed to seed exactly one vm_inventory row"

    initial_fleet="$(managed_nonterminated_instance_ids)"
    create_lane_instance "$hostname"
    instance_id="$LANE_INSTANCE_ID"
    aws ec2 wait instance-running --instance-ids "$instance_id"

    start_local_api "$api_port" "$s3_port" "$api_log"
    poll_for_engine_down "$api_log"

    terminate_owned_instance "$instance_id"
    final_state="$(instance_state "$instance_id")"
    case "$final_state" in
        shutting-down | terminated) ;;
        *) fail "lane-created instance did not reach AWS death state" ;;
    esac
    poll_for_disabled_replacement_events "$vm_id"
    assert_no_autonomous_replacement "$initial_fleet" "$vm_id"

    cleanup || fail "deterministic cleanup failed"
    if [ -n "$API_PID" ] && kill -0 "$API_PID" 2>/dev/null; then
        fail "local API process survived cleanup"
    fi
    database_exists="$(
        psql "$BASE_DATABASE_URL" -v ON_ERROR_STOP=1 -Atq \
            -v database_name="$TEMP_DATABASE_NAME" <<'SQL'
SELECT count(*) FROM pg_database WHERE datname = :'database_name';
SQL
    )"
    [ "$database_exists" = "0" ] ||
        fail "temporary local database survived cleanup"
    for instance_id in "${CREATED_INSTANCE_IDS[@]}"; do
        [ "$(instance_state "$instance_id")" = "terminated" ] ||
            fail "lane-created instance survived cleanup: $instance_id"
    done
    write_success_evidence "$hostname" "$LANE_INSTANCE_ID" "$final_state"
    {
        printf '%s\n' "PASS: local API stopped"
        printf '%s\n' "PASS: temporary local database dropped"
        printf '%s\n' "PASS: every lane-created EC2 instance terminated"
    } >> "$EVIDENCE_DIR/command_evidence.txt"

    log "VM autorepair disabled-detection proof passed"
    log "Sanitized evidence: $EVIDENCE_DIR"
}

main "$@"
