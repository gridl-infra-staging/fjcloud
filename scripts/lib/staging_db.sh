#!/usr/bin/env bash
# staging_db.sh — Run SQL against staging/prod RDS via AWS SSM RunShellScript.
#
# RDS is VPC-private and unreachable directly from a developer machine.
# This helper discovers the fjcloud-api EC2 instance via Name tag and
# executes psql on it using SSM so SQL can reach the database.
#
# Usage (source this file, then call staging_db_run_sql):
#
#   source scripts/lib/staging_db.sh
#   staging_db_run_sql "$DATABASE_URL" "SELECT COUNT(*) FROM customers"
#
# Environment:
#   DATABASE_URL_SSM_PARAM  — used to auto-detect staging vs prod
#                             (e.g. /fjcloud/staging/database_url → staging)
#   SSM_INSTANCE_ID         — override EC2 instance auto-detection
#   AWS_DEFAULT_REGION      — defaults to us-east-1
#
# Prints stdout from the remote psql invocation. Exits non-zero on failure.

STAGING_DB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STAGING_DB_SCRIPT_DIR/db_url.sh"

_STAGING_DB_INSTANCE_ID="${SSM_INSTANCE_ID:-}"
_STAGING_DB_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# Derive "staging" or "prod" from DATABASE_URL_SSM_PARAM path.
# Callers that set DATABASE_URL directly must also set SSM_INSTANCE_ID.
staging_db_env_tag() {
    if [[ "${DATABASE_URL_SSM_PARAM:-}" == */prod/* ]]; then
        echo "prod"
    elif [[ "${DATABASE_URL_SSM_PARAM:-}" == */staging/* ]]; then
        echo "staging"
    elif [ -n "${SSM_INSTANCE_ID:-}" ]; then
        echo "staging"  # SSM_INSTANCE_ID set explicitly; env tag not needed for lookup
    else
        echo "[staging_db] ERROR: cannot auto-detect env. Set DATABASE_URL_SSM_PARAM or SSM_INSTANCE_ID." >&2
        return 1
    fi
}

# Resolve the EC2 instance ID for the given env tag, caching in _STAGING_DB_INSTANCE_ID.
staging_db_resolve_instance() {
    local env_tag="${1:-staging}"
    if [ -n "$_STAGING_DB_INSTANCE_ID" ]; then
        return 0
    fi
    echo "[staging_db] detecting fjcloud-api-${env_tag} instance for SSM DB access..." >&2
    _STAGING_DB_INSTANCE_ID="$(
        aws ec2 describe-instances \
            --region "$_STAGING_DB_REGION" \
            --filters "Name=tag:Name,Values=fjcloud-api-${env_tag}" \
                      "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].InstanceId' \
            --output text 2>/dev/null || true
    )"
    if [ -z "$_STAGING_DB_INSTANCE_ID" ] || [ "$_STAGING_DB_INSTANCE_ID" = "None" ]; then
        echo "[staging_db] ERROR: no running fjcloud-api-${env_tag} instance found. Set SSM_INSTANCE_ID manually." >&2
        return 1
    fi
    echo "[staging_db] using instance: $_STAGING_DB_INSTANCE_ID" >&2
}

# Run a SQL statement against the RDS database via SSM.
# Args: DATABASE_URL SQL
staging_db_run_sql() {
    local database_url="$1" sql="$2"
    local env_tag
    env_tag="$(staging_db_env_tag)" || return 1
    staging_db_resolve_instance "$env_tag" || return 1

    local db_user db_password db_host db_port db_name
    db_user="$(db_url_user "$database_url")"
    db_password="$(db_url_password "$database_url")"
    db_host="$(db_url_host "$database_url")"
    db_port="$(db_url_port "$database_url" 2>/dev/null || echo "5432")"
    db_name="$(db_url_database "$database_url")"

    # Build the JSON parameters file via Python. Use shell-safe quoting so SQL
    # and credentials are passed verbatim even when they contain shell metacharacters.
    local tmpjson
    tmpjson="$(mktemp /tmp/ssm_sql_XXXXXX.json)"
    if ! python3 -c "
import json, shlex, sys
h, port, user, pw, db, sql = sys.argv[1:]
script = '\n'.join([
    'set -e',
    f'export PGPASSWORD={shlex.quote(pw)}',
    (
        'psql '
        f'-h {shlex.quote(h)} '
        f'-p {shlex.quote(port)} '
        f'-U {shlex.quote(user)} '
        f'-d {shlex.quote(db)} '
        f'-c {shlex.quote(sql)}'
    ),
])
print(json.dumps({'commands': [script]}))
" "$db_host" "$db_port" "$db_user" "$db_password" "$db_name" "$sql" > "$tmpjson"
    then
        rm -f "$tmpjson"
        return 1
    fi

    local cmd_id
    if ! cmd_id="$(aws ssm send-command \
        --region "$_STAGING_DB_REGION" \
        --instance-ids "$_STAGING_DB_INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters "file://$tmpjson" \
        --query 'Command.CommandId' --output text)"
    then
        rm -f "$tmpjson"
        return 1
    fi
    rm -f "$tmpjson"

    local result status stdout stderr
    local max_attempts=20
    local attempt
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        result="$(aws ssm get-command-invocation \
            --command-id "$cmd_id" \
            --instance-id "$_STAGING_DB_INSTANCE_ID" \
            --query '{status:Status,stdout:StandardOutputContent,stderr:StandardErrorContent}' \
            --output json)"

        status="$(printf '%s' "$result" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("status", ""), end="")')"
        stdout="$(printf '%s' "$result" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("stdout", ""), end="")')"
        stderr="$(printf '%s' "$result" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("stderr", ""), end="")')"

        if [ "$status" = "Success" ]; then
            printf '%s\n' "$stdout"
            return 0
        fi

        if [ "$status" != "Pending" ] && [ "$status" != "InProgress" ] && [ "$status" != "Delayed" ]; then
            echo "[staging_db] ERROR: SSM Run Command failed (status=$status): ${stderr:-$stdout}" >&2
            return 1
        fi

        if [ "$attempt" -lt "$max_attempts" ]; then
            sleep 3
        fi
    done

    echo "[staging_db] ERROR: SSM Run Command did not reach Success after ${max_attempts} polls (last_status=${status:-unknown}): ${stderr:-$stdout}" >&2
    return 1
}
