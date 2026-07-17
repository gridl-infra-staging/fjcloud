#!/usr/bin/env bash
# live_e2e_budget_guardrail_prep.sh -- prepare a non-mutating budget-action proposal.

set -euo pipefail

# Guardrail prep can capture account identifiers and operator-selected IAM ARNs,
# so keep all generated artifacts private even under a permissive caller umask.
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_LIB="$REPO_ROOT/scripts/lib/env.sh"

if [ -f "$ENV_LIB" ]; then
    # shellcheck source=../../scripts/lib/env.sh
    source "$ENV_LIB"
fi

LIVE_E2E_ENV=""
LIVE_E2E_REGION=""
LIVE_E2E_ARTIFACT_ROOT=""
LIVE_E2E_SECRET_ENV_FILE=""
LIVE_E2E_MONTHLY_SPEND_LIMIT_USD=""
LIVE_E2E_BUDGET_ACTION_PRINCIPAL_ARN=""
LIVE_E2E_BUDGET_ACTION_POLICY_ARN=""
LIVE_E2E_BUDGET_ACTION_ROLE_NAME=""
LIVE_E2E_BUDGET_ACTION_EXECUTION_ROLE_ARN=""
LIVE_E2E_API_INSTANCE_ID=""
LIVE_E2E_DB_INSTANCE_IDENTIFIER=""
LIVE_E2E_ALB_ARN_SUFFIX=""
LIVE_E2E_ENABLE_ACTION_PROPOSAL=0
SHOW_HELP=0

RUN_ID=""
RUN_DIR=""
SUMMARY_PATH=""
LOGS_DIR=""
DISCOVERY_LOG_PATH=""
PROPOSAL_PATH=""
PLAN_COMMAND_PATH=""

REDACTION_VALUES=()

print_usage() {
    cat <<'USAGE'
Usage:
  live_e2e_budget_guardrail_prep.sh --env <staging|prod> --region <aws-region> --artifact-dir <dir> [--monthly-spend-limit-usd <amount>] [--budget-action-principal-arn <arn>] [--budget-action-policy-arn <arn>] [--budget-action-role-name <name>] [--budget-action-execution-role-arn <arn>] [--enable-action-proposal] [--secret-env-file <path>] [--api-instance-id <id>] [--db-instance-identifier <id>] [--alb-arn-suffix <suffix>]
  live_e2e_budget_guardrail_prep.sh --help
USAGE
}

parse_args_token() {
    local token="$1"
    local next_value="${2:-}"
    local arg_count="$3"

    PARSE_CONSUMED=1
    case "$token" in
        --help|-h)
            SHOW_HELP=1
            ;;
        --env|--region|--artifact-dir|--secret-env-file|--monthly-spend-limit-usd|--budget-action-principal-arn|--budget-action-policy-arn|--budget-action-role-name|--budget-action-execution-role-arn|--api-instance-id|--db-instance-identifier|--alb-arn-suffix)
            if [ "$arg_count" -lt 2 ] || [ -z "$next_value" ] || [[ "$next_value" == --* ]]; then
                echo "ERROR: $token requires a value" >&2
                print_usage >&2
                return 2
            fi
            case "$token" in
                --env)
                    LIVE_E2E_ENV="$next_value"
                    ;;
                --region)
                    LIVE_E2E_REGION="$next_value"
                    ;;
                --artifact-dir)
                    LIVE_E2E_ARTIFACT_ROOT="$next_value"
                    ;;
                --secret-env-file)
                    LIVE_E2E_SECRET_ENV_FILE="$next_value"
                    ;;
                --monthly-spend-limit-usd)
                    LIVE_E2E_MONTHLY_SPEND_LIMIT_USD="$next_value"
                    ;;
                --budget-action-principal-arn)
                    LIVE_E2E_BUDGET_ACTION_PRINCIPAL_ARN="$next_value"
                    ;;
                --budget-action-policy-arn)
                    LIVE_E2E_BUDGET_ACTION_POLICY_ARN="$next_value"
                    ;;
                --budget-action-role-name)
                    LIVE_E2E_BUDGET_ACTION_ROLE_NAME="$next_value"
                    ;;
                --budget-action-execution-role-arn)
                    LIVE_E2E_BUDGET_ACTION_EXECUTION_ROLE_ARN="$next_value"
                    ;;
                --api-instance-id)
                    LIVE_E2E_API_INSTANCE_ID="$next_value"
                    ;;
                --db-instance-identifier)
                    LIVE_E2E_DB_INSTANCE_IDENTIFIER="$next_value"
                    ;;
                --alb-arn-suffix)
                    LIVE_E2E_ALB_ARN_SUFFIX="$next_value"
                    ;;
            esac
            PARSE_CONSUMED=2
            ;;
        --enable-action-proposal)
            LIVE_E2E_ENABLE_ACTION_PROPOSAL=1
            ;;
        *)
            echo "ERROR: Unknown argument: $token" >&2
            print_usage >&2
            return 2
            ;;
    esac
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        parse_args_token "$1" "${2:-}" "$#" || return 2
        shift "$PARSE_CONSUMED"
    done
}

validate_required_args() {
    if [ "$SHOW_HELP" -eq 1 ]; then
        return 0
    fi

    if [ -z "$LIVE_E2E_ENV" ]; then
        echo "ERROR: --env is required" >&2
        print_usage >&2
        return 2
    fi
    case "$LIVE_E2E_ENV" in
        staging|prod)
            ;;
        *)
            echo "ERROR: --env must be one of: staging|prod" >&2
            print_usage >&2
            return 2
            ;;
    esac

    if [ -z "$LIVE_E2E_REGION" ]; then
        echo "ERROR: --region is required" >&2
        print_usage >&2
        return 2
    fi

    if [ -z "$LIVE_E2E_ARTIFACT_ROOT" ]; then
        echo "ERROR: --artifact-dir is required" >&2
        print_usage >&2
        return 2
    fi

    return 0
}

fail_closed() {
    echo "ERROR: $*" >&2
    exit 1
}

validate_positive_number() {
    local value="$1"
    python3 - "$value" <<'PY'
import decimal
import sys

raw = sys.argv[1]
try:
    value = decimal.Decimal(raw)
except decimal.InvalidOperation:
    raise SystemExit(1)
if value <= 0:
    raise SystemExit(1)
PY
}

validate_arn_value() {
    local flag_name="$1"
    local value="$2"

    if [ -z "$value" ]; then
        return 0
    fi
    if ! [[ "$value" =~ ^arn:[^[:space:]]+$ ]]; then
        fail_closed "$flag_name must be a valid ARN"
    fi
}

validate_role_name_value() {
    local value="$1"

    if [ -z "$value" ]; then
        return 0
    fi
    if ! [[ "$value" =~ ^[A-Za-z0-9+=,.@_-]{1,64}$ ]]; then
        fail_closed "--budget-action-role-name must be a valid IAM role name"
    fi
}

validate_input_values() {
    if [ -n "$LIVE_E2E_MONTHLY_SPEND_LIMIT_USD" ] && ! validate_positive_number "$LIVE_E2E_MONTHLY_SPEND_LIMIT_USD"; then
        fail_closed "--monthly-spend-limit-usd must be greater than 0"
    fi

    validate_arn_value "--budget-action-principal-arn" "$LIVE_E2E_BUDGET_ACTION_PRINCIPAL_ARN"
    validate_arn_value "--budget-action-policy-arn" "$LIVE_E2E_BUDGET_ACTION_POLICY_ARN"
    validate_arn_value "--budget-action-execution-role-arn" "$LIVE_E2E_BUDGET_ACTION_EXECUTION_ROLE_ARN"
    validate_role_name_value "$LIVE_E2E_BUDGET_ACTION_ROLE_NAME"

    if [ -n "${LIVE_E2E_BUDGET_ACTION_ROLE_NAME+x}" ] && [ "$LIVE_E2E_BUDGET_ACTION_ROLE_NAME" = "" ] && [ "$LIVE_E2E_ENABLE_ACTION_PROPOSAL" -eq 1 ]; then
        fail_closed "--budget-action-role-name is required when --enable-action-proposal is set"
    fi

    if [ "$LIVE_E2E_ENABLE_ACTION_PROPOSAL" -eq 1 ]; then
        if [ -z "$LIVE_E2E_MONTHLY_SPEND_LIMIT_USD" ]; then
            fail_closed "--enable-action-proposal requires --monthly-spend-limit-usd"
        fi
        if [ -z "$LIVE_E2E_BUDGET_ACTION_PRINCIPAL_ARN" ]; then
            fail_closed "--budget-action-principal-arn is required when --enable-action-proposal is set"
        fi
        if [ -z "$LIVE_E2E_BUDGET_ACTION_POLICY_ARN" ]; then
            fail_closed "--budget-action-policy-arn is required when --enable-action-proposal is set"
        fi
        if [ -z "$LIVE_E2E_BUDGET_ACTION_ROLE_NAME" ]; then
            fail_closed "--budget-action-role-name is required when --enable-action-proposal is set"
        fi
        if [ -z "$LIVE_E2E_BUDGET_ACTION_EXECUTION_ROLE_ARN" ]; then
            fail_closed "--budget-action-execution-role-arn is required when --enable-action-proposal is set"
        fi
    fi
}

ensure_artifact_root() {
    if [ -e "$LIVE_E2E_ARTIFACT_ROOT" ] && [ ! -d "$LIVE_E2E_ARTIFACT_ROOT" ]; then
        fail_closed "--artifact-dir must be a directory path: $LIVE_E2E_ARTIFACT_ROOT"
    fi
    mkdir -p "$LIVE_E2E_ARTIFACT_ROOT"
}

create_run_id() {
    printf 'fjcloud_budget_guardrail_prep_%s_%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
}

init_run_artifacts() {
    ensure_artifact_root

    RUN_ID="$(create_run_id)"
    RUN_DIR="$LIVE_E2E_ARTIFACT_ROOT/$RUN_ID"
    SUMMARY_PATH="$RUN_DIR/summary.json"
    LOGS_DIR="$RUN_DIR/logs"
    DISCOVERY_LOG_PATH="$LOGS_DIR/aws_discovery.log"
    PROPOSAL_PATH="$RUN_DIR/proposal.auto.tfvars.example"
    PLAN_COMMAND_PATH="$RUN_DIR/terraform_plan_command.txt"

    mkdir -p "$RUN_DIR" "$LOGS_DIR"
    : > "$DISCOVERY_LOG_PATH"
}

add_redaction_value() {
    local value="$1"
    local existing

    [ -n "$value" ] || return 0
    for existing in "${REDACTION_VALUES[@]:-}"; do
        if [ "$existing" = "$value" ]; then
            return 0
        fi
    done
    REDACTION_VALUES+=("$value")
}

collect_redaction_values_from_environment() {
    local key
    for key in AWS_SECRET_ACCESS_KEY CLOUDFLARE_API_TOKEN STRIPE_SECRET_KEY STRIPE_TEST_SECRET_KEY STRIPE_WEBHOOK_SECRET; do
        add_redaction_value "${!key:-}"
    done

    while IFS='=' read -r key _; do
        case "$key" in
            CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_*)
                add_redaction_value "${!key:-}"
                ;;
        esac
    done < <(env)
}

collect_redaction_values_from_env_file() {
    local env_file="$1"
    local line parse_status key value

    [ -n "$env_file" ] || return 0
    [ -f "$env_file" ] || return 0
    if ! declare -F parse_env_assignment_line >/dev/null 2>&1; then
        return 0
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        if [ "$parse_status" -ne 0 ]; then
            continue
        fi
        key="$ENV_ASSIGNMENT_KEY"
        value="$ENV_ASSIGNMENT_VALUE"
        case "$key" in
            AWS_SECRET_ACCESS_KEY|CLOUDFLARE_API_TOKEN|STRIPE_SECRET_KEY|STRIPE_TEST_SECRET_KEY|STRIPE_WEBHOOK_SECRET)
                add_redaction_value "$value"
                ;;
            CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_*)
                add_redaction_value "$value"
                ;;
        esac
    done < "$env_file"
}

redact_text() {
    local text="$1"
    local secret
    local redacted="$text"

    for secret in "${REDACTION_VALUES[@]:-}"; do
        [ -n "$secret" ] || continue
        redacted="${redacted//"$secret"/REDACTED}"
    done
    printf '%s' "$redacted"
}

write_private_file() {
    local path="$1"
    local content="$2"
    printf '%s' "$content" > "$path"
    chmod 600 "$path"
}

canonical_resource_name() {
    local selector="$1"
    case "$selector" in
        budget) printf 'fjcloud-%s-live-e2e-spend\n' "$LIVE_E2E_ENV" ;;
        api_instance) printf 'fjcloud-api-%s\n' "$LIVE_E2E_ENV" ;;
        db_prefix) printf 'fjcloud-%s\n' "$LIVE_E2E_ENV" ;;
        alb_suffix_prefix) printf 'app/fjcloud-%s-alb\n' "$LIVE_E2E_ENV" ;;
        alb_name) printf 'fjcloud-%s-alb\n' "$LIVE_E2E_ENV" ;;
        *) fail_closed "unknown canonical resource selector: $selector" ;;
    esac
}

extract_account_id_from_arn() {
    local arn="$1"
    if [[ "$arn" =~ ^arn:[^:]+:iam::([0-9]{12}): ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    printf '\n'
    return 0
}

aws_cli() {
    AWS_PAGER="" aws --no-cli-pager --region "$LIVE_E2E_REGION" "$@"
}

run_aws_discovery() {
    local label="$1"
    shift

    local stdout_file stderr_file exit_code stdout_payload stderr_payload
    stdout_file="$(mktemp "${TMPDIR:-/tmp}/budget_guardrail_stdout.XXXXXX")"
    stderr_file="$(mktemp "${TMPDIR:-/tmp}/budget_guardrail_stderr.XXXXXX")"
    exit_code=0
    aws_cli "$@" >"$stdout_file" 2>"$stderr_file" || exit_code=$?

    stdout_payload="$(cat "$stdout_file" 2>/dev/null || true)"
    stderr_payload="$(cat "$stderr_file" 2>/dev/null || true)"
    rm -f "$stdout_file" "$stderr_file"

    {
        printf '[%s] aws %s\n' "$label" "$*"
        printf 'exit_code=%s\n' "$exit_code"
        if [ -n "$stdout_payload" ]; then
            printf 'stdout:\n%s\n' "$(redact_text "$stdout_payload")"
        fi
        if [ -n "$stderr_payload" ]; then
            printf 'stderr:\n%s\n' "$(redact_text "$stderr_payload")"
        fi
        printf '\n'
    } >> "$DISCOVERY_LOG_PATH"

    if [ "$exit_code" -ne 0 ]; then
        fail_closed "aws discovery failed for ${label}"
    fi

    printf '%s' "$stdout_payload"
}

extract_account_id_from_caller_identity_payload() {
    local payload="$1"
    python3 - "$payload" <<'PY'
import json
import re
import sys

raw = sys.argv[1] or ""
payload = {}
for candidate in (raw.strip(), raw.splitlines()[-1].strip() if raw.splitlines() else ""):
    if not candidate:
        continue
    try:
        payload = json.loads(candidate)
        break
    except json.JSONDecodeError:
        continue
account = str(payload.get("Account", "")).strip()
if account and re.fullmatch(r"[0-9]{12}", account):
    print(account)
PY
}

derive_budget_account_id() {
    local caller_identity_payload="$1"
    local account_id

    account_id="$(extract_account_id_from_arn "$LIVE_E2E_BUDGET_ACTION_PRINCIPAL_ARN")"
    if [ -z "$account_id" ]; then
        account_id="$(extract_account_id_from_arn "$LIVE_E2E_BUDGET_ACTION_EXECUTION_ROLE_ARN")"
    fi
    if [ -z "$account_id" ]; then
        account_id="$(extract_account_id_from_caller_identity_payload "$caller_identity_payload")"
    fi
    if [ -z "$account_id" ]; then
        fail_closed "unable to derive aws account id for budget discovery"
    fi
    printf '%s\n' "$account_id"
}

extract_unique_api_instance_id() {
    local payload="$1"
    python3 - "$payload" <<'PY'
import json
import sys

raw = sys.argv[1] or ""
payload = {}
for candidate in (raw.strip(), raw.splitlines()[-1].strip() if raw.splitlines() else ""):
    if not candidate:
        continue
    try:
        payload = json.loads(candidate)
        break
    except json.JSONDecodeError:
        continue
matches = []
for reservation in payload.get("Reservations", []):
    for instance in reservation.get("Instances", []):
        instance_id = str(instance.get("InstanceId", "")).strip()
        if instance_id:
            matches.append(instance_id)
matches = sorted(set(matches))
if len(matches) == 1:
    print(matches[0])
PY
}

extract_unique_db_instance_identifier() {
    local payload="$1"
    local identifier_prefix="$2"
    python3 - "$payload" "$identifier_prefix" <<'PY'
import json
import sys

raw = sys.argv[1] or ""
payload = {}
for candidate in (raw.strip(), raw.splitlines()[-1].strip() if raw.splitlines() else ""):
    if not candidate:
        continue
    try:
        payload = json.loads(candidate)
        break
    except json.JSONDecodeError:
        continue
prefix = sys.argv[2]
matches = []
for db_instance in payload.get("DBInstances", []):
    identifier = str(db_instance.get("DBInstanceIdentifier", "")).strip()
    if identifier.startswith(prefix):
        matches.append(identifier)
matches = sorted(set(matches))
if len(matches) == 1:
    print(matches[0])
PY
}

extract_unique_alb_arn_suffix() {
    local payload="$1"
    local suffix_prefix="$2"
    python3 - "$payload" "$suffix_prefix" <<'PY'
import json
import sys

raw = sys.argv[1] or ""
payload = {}
for candidate in (raw.strip(), raw.splitlines()[-1].strip() if raw.splitlines() else ""):
    if not candidate:
        continue
    try:
        payload = json.loads(candidate)
        break
    except json.JSONDecodeError:
        continue
suffix_prefix = sys.argv[2]
matches = []
for lb in payload.get("LoadBalancers", []):
    arn = str(lb.get("LoadBalancerArn", "")).strip()
    if "loadbalancer/" not in arn:
        continue
    suffix = arn.split("loadbalancer/", 1)[1]
    if suffix.startswith(suffix_prefix):
        matches.append(suffix)
matches = sorted(set(matches))
if len(matches) == 1:
    print(matches[0])
PY
}

discover_api_instance_id() {
    local payload
    payload="$(run_aws_discovery \
        "api_instance_discovery" \
        ec2 describe-instances \
        --filters "Name=tag:Name,Values=$(canonical_resource_name api_instance)" "Name=instance-state-name,Values=running")"
    extract_unique_api_instance_id "$payload"
}

discover_db_instance_identifier() {
    local payload
    payload="$(run_aws_discovery "db_instance_discovery" rds describe-db-instances --db-instance-identifier "$(canonical_resource_name db_prefix)")"
    extract_unique_db_instance_identifier "$payload" "$(canonical_resource_name db_prefix)"
}

discover_alb_arn_suffix() {
    local payload
    payload="$(run_aws_discovery "alb_discovery" elbv2 describe-load-balancers --names "$(canonical_resource_name alb_name)")"
    extract_unique_alb_arn_suffix "$payload" "$(canonical_resource_name alb_suffix_prefix)"
}

run_read_only_aws_discovery() {
    local account_id caller_identity_payload
    caller_identity_payload="$(run_aws_discovery "caller_identity" sts get-caller-identity)"
    account_id="$(derive_budget_account_id "$caller_identity_payload")"

    run_aws_discovery "budget_action_role" iam get-role --role-name "$LIVE_E2E_BUDGET_ACTION_ROLE_NAME" >/dev/null
    run_aws_discovery "budget_action_policy" iam get-policy --policy-arn "$LIVE_E2E_BUDGET_ACTION_POLICY_ARN" >/dev/null
    # The budget itself is Terraform-managed and may not exist yet on a first proposal run.
    : "$account_id"

    if [ -z "$LIVE_E2E_API_INSTANCE_ID" ]; then
        LIVE_E2E_API_INSTANCE_ID="$(discover_api_instance_id)"
    fi
    if [ -z "$LIVE_E2E_DB_INSTANCE_IDENTIFIER" ]; then
        LIVE_E2E_DB_INSTANCE_IDENTIFIER="$(discover_db_instance_identifier)"
    fi
    if [ -z "$LIVE_E2E_ALB_ARN_SUFFIX" ]; then
        LIVE_E2E_ALB_ARN_SUFFIX="$(discover_alb_arn_suffix)"
    fi
}

missing_fields_include_non_monitoring_requirements() {
    local missing_field
    for missing_field in "${MISSING_FIELDS[@]:-}"; do
        case "$missing_field" in
            api_instance_id|db_instance_identifier|alb_arn_suffix)
                ;;
            *)
                return 0
                ;;
        esac
    done
    return 1
}

collect_missing_fields() {
    MISSING_FIELDS=()
    MISSING_FLAGS=()
    local requirements=(
        "LIVE_E2E_ENV:env:--env"
        "LIVE_E2E_REGION:region:--region"
        "LIVE_E2E_API_INSTANCE_ID:api_instance_id:--api-instance-id"
        "LIVE_E2E_DB_INSTANCE_IDENTIFIER:db_instance_identifier:--db-instance-identifier"
        "LIVE_E2E_ALB_ARN_SUFFIX:alb_arn_suffix:--alb-arn-suffix"
        "LIVE_E2E_MONTHLY_SPEND_LIMIT_USD:live_e2e_monthly_spend_limit_usd:--monthly-spend-limit-usd"
        "LIVE_E2E_BUDGET_ACTION_PRINCIPAL_ARN:live_e2e_budget_action_principal_arn:--budget-action-principal-arn"
        "LIVE_E2E_BUDGET_ACTION_POLICY_ARN:live_e2e_budget_action_policy_arn:--budget-action-policy-arn"
        "LIVE_E2E_BUDGET_ACTION_ROLE_NAME:live_e2e_budget_action_role_name:--budget-action-role-name"
        "LIVE_E2E_BUDGET_ACTION_EXECUTION_ROLE_ARN:live_e2e_budget_action_execution_role_arn:--budget-action-execution-role-arn"
    )
    local requirement var_name field_name flag_name
    for requirement in "${requirements[@]}"; do
        IFS=':' read -r var_name field_name flag_name <<<"$requirement"
        if [ -z "${!var_name}" ]; then
            MISSING_FIELDS+=("$field_name")
            MISSING_FLAGS+=("$flag_name")
        fi
    done
}

json_array_from_args() {
    python3 - "$@" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1:]))
PY
}

summary_json() {
    local status="$1"
    local reason="$2"
    local missing_fields_json="$3"
    local missing_flags_json="$4"
    local proposed_variables_json="$5"
    local plan_command_json="$6"

    python3 - "$status" "$reason" "$RUN_ID" "$RUN_DIR" "$LIVE_E2E_ENV" "$LIVE_E2E_REGION" "$missing_fields_json" "$missing_flags_json" "$proposed_variables_json" "$plan_command_json" <<'PY'
import json
import sys

status = sys.argv[1]
reason = sys.argv[2]
run_id = sys.argv[3]
run_dir = sys.argv[4]
env_name = sys.argv[5]
region = sys.argv[6]
missing_fields = json.loads(sys.argv[7])
missing_flags = json.loads(sys.argv[8])
proposed_variables = json.loads(sys.argv[9]) if sys.argv[9] else None
plan_command = json.loads(sys.argv[10]) if sys.argv[10] else None

payload = {
    "status": status,
    "result": status,
    "reason": reason,
    "run_id": run_id,
    "run_dir": run_dir,
    "env": env_name,
    "region": region,
    "terraform_module": "ops/terraform/monitoring",
    "missing_fields": missing_fields,
    "missing_flags": missing_flags,
}
if proposed_variables is not None:
    payload["proposed_variables"] = proposed_variables
if plan_command is not None:
    payload["plan_command"] = plan_command

print(json.dumps(payload, sort_keys=True))
PY
}

proposal_variables_json() {
    python3 - "$LIVE_E2E_ENV" "$LIVE_E2E_REGION" "$LIVE_E2E_MONTHLY_SPEND_LIMIT_USD" "$LIVE_E2E_ENABLE_ACTION_PROPOSAL" "$LIVE_E2E_BUDGET_ACTION_PRINCIPAL_ARN" "$LIVE_E2E_BUDGET_ACTION_POLICY_ARN" "$LIVE_E2E_BUDGET_ACTION_ROLE_NAME" "$LIVE_E2E_BUDGET_ACTION_EXECUTION_ROLE_ARN" "$LIVE_E2E_API_INSTANCE_ID" "$LIVE_E2E_DB_INSTANCE_IDENTIFIER" "$LIVE_E2E_ALB_ARN_SUFFIX" <<'PY'
import json
import sys

payload = {
    "env": sys.argv[1],
    "region": sys.argv[2],
    "live_e2e_monthly_spend_limit_usd": float(sys.argv[3]),
    "live_e2e_budget_action_enabled": sys.argv[4] == "1",
    "live_e2e_budget_action_principal_arn": sys.argv[5],
    "live_e2e_budget_action_policy_arn": sys.argv[6],
    "live_e2e_budget_action_role_name": sys.argv[7],
    "live_e2e_budget_action_execution_role_arn": sys.argv[8],
    "api_instance_id": sys.argv[9],
    "db_instance_identifier": sys.argv[10],
    "alb_arn_suffix": sys.argv[11],
}
print(json.dumps(payload, sort_keys=True))
PY
}

write_plan_command_file() {
    local var_file="$1"
    cat > "$PLAN_COMMAND_PATH" <<EOF
cd ops/terraform/monitoring && terraform plan -input=false -var-file="$var_file"
EOF
    chmod 600 "$PLAN_COMMAND_PATH"
}

hcl_string_literal() {
    python3 - "$1" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1]))
PY
}

write_proposal_file() {
    local action_enabled_literal="false"
    local env_literal region_literal api_instance_literal db_identifier_literal alb_suffix_literal
    local principal_arn_literal policy_arn_literal role_name_literal execution_role_arn_literal
    if [ "$LIVE_E2E_ENABLE_ACTION_PROPOSAL" -eq 1 ]; then
        action_enabled_literal="true"
    fi

    env_literal="$(hcl_string_literal "$LIVE_E2E_ENV")"
    region_literal="$(hcl_string_literal "$LIVE_E2E_REGION")"
    api_instance_literal="$(hcl_string_literal "$LIVE_E2E_API_INSTANCE_ID")"
    db_identifier_literal="$(hcl_string_literal "$LIVE_E2E_DB_INSTANCE_IDENTIFIER")"
    alb_suffix_literal="$(hcl_string_literal "$LIVE_E2E_ALB_ARN_SUFFIX")"
    principal_arn_literal="$(hcl_string_literal "$LIVE_E2E_BUDGET_ACTION_PRINCIPAL_ARN")"
    policy_arn_literal="$(hcl_string_literal "$LIVE_E2E_BUDGET_ACTION_POLICY_ARN")"
    role_name_literal="$(hcl_string_literal "$LIVE_E2E_BUDGET_ACTION_ROLE_NAME")"
    execution_role_arn_literal="$(hcl_string_literal "$LIVE_E2E_BUDGET_ACTION_EXECUTION_ROLE_ARN")"

    cat > "$PROPOSAL_PATH" <<EOF
# Generated by ops/scripts/live_e2e_budget_guardrail_prep.sh.
# Budget enforcement remains operator-gated; this file is a proposal artifact,
# not an instruction to auto-enable live enforcement in shared Terraform state.

env = $env_literal
region = $region_literal
api_instance_id = $api_instance_literal
db_instance_identifier = $db_identifier_literal
alb_arn_suffix = $alb_suffix_literal
live_e2e_monthly_spend_limit_usd = $LIVE_E2E_MONTHLY_SPEND_LIMIT_USD
live_e2e_budget_action_enabled = $action_enabled_literal
live_e2e_budget_action_principal_arn = $principal_arn_literal
live_e2e_budget_action_policy_arn = $policy_arn_literal
live_e2e_budget_action_role_name = $role_name_literal
live_e2e_budget_action_execution_role_arn = $execution_role_arn_literal
EOF
    chmod 600 "$PROPOSAL_PATH"
}

emit_blocked_summary() {
    local missing_fields_json missing_flags_json summary_payload
    missing_fields_json="$(json_array_from_args "${MISSING_FIELDS[@]}")"
    missing_flags_json="$(json_array_from_args "${MISSING_FLAGS[@]}")"
    summary_payload="$(summary_json "blocked" "required monitoring and budget guardrail inputs are still missing" "$missing_fields_json" "$missing_flags_json" "" "")"
    write_private_file "$SUMMARY_PATH" "$summary_payload"
    printf '%s\n' "$summary_payload"
}

emit_proposal_summary() {
    local proposed_variables_json plan_command_json summary_payload
    proposed_variables_json="$(proposal_variables_json)"
    plan_command_json="$(json_array_from_args "terraform" "plan" "-input=false" "-var-file=$PROPOSAL_PATH")"
    write_proposal_file
    write_plan_command_file "$PROPOSAL_PATH"
    summary_payload="$(summary_json "proposal_ready" "budget guardrail proposal is ready for operator-reviewed terraform plan" "[]" "[]" "$proposed_variables_json" "$plan_command_json")"
    write_private_file "$SUMMARY_PATH" "$summary_payload"
    printf '%s\n' "$summary_payload"
}

main() {
    parse_args "$@" || exit 2
    validate_required_args || exit $?

    if [ "$SHOW_HELP" -eq 1 ]; then
        print_usage
        exit 0
    fi

    validate_input_values
    init_run_artifacts
    collect_redaction_values_from_environment
    collect_redaction_values_from_env_file "$LIVE_E2E_SECRET_ENV_FILE"

    collect_missing_fields
    if [ "${#MISSING_FIELDS[@]}" -gt 0 ] && missing_fields_include_non_monitoring_requirements; then
        emit_blocked_summary
        exit 0
    fi

    # Read-only discovery confirms the operator-supplied IAM/budget identifiers
    # are shaped for the intended account without invoking Terraform or mutating AWS.
    run_read_only_aws_discovery
    collect_missing_fields
    if [ "${#MISSING_FIELDS[@]}" -gt 0 ]; then
        emit_blocked_summary
        exit 0
    fi

    emit_proposal_summary
}

main "$@"
