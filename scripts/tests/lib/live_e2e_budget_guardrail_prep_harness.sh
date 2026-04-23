#!/usr/bin/env bash
# Shared harness helpers for live_e2e_budget_guardrail_prep contract tests.

shell_quote_for_script() {
    local quoted
    printf -v quoted '%q' "$1"
    printf '%s\n' "$quoted"
}

mock_discovery_value() {
    local env_name="$1"
    local resource="$2"

    case "$resource" in
        api_instance_id)
            case "$env_name" in
                staging) printf 'i-0a11b22c33d44e55f\n' ;;
                prod) printf 'i-0f55e44d33c22b11a\n' ;;
                *) printf '\n' ;;
            esac
            ;;
        db_instance_identifier)
            printf 'fjcloud-%s\n' "$env_name"
            ;;
        alb_arn_suffix)
            printf 'app/fjcloud-%s-alb/abcd1234efgh5678\n' "$env_name"
            ;;
        *)
            printf '\n'
            ;;
    esac
}

write_mock_aws() {
    local quoted_aws_log
    quoted_aws_log="$(shell_quote_for_script "$AWS_LOG")"
    cat > "$TEST_WORKSPACE/bin/aws" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
echo "AWS_PAGER=\${AWS_PAGER-__UNSET__}|\$*" >> "$quoted_aws_log"

service=""
operation=""
known_services_re='^(accessanalyzer|acm|budgets|cloudtrail|cloudwatch|ec2|elbv2|iam|kms|logs|organizations|rds|route53|s3|ses|sns|sqs|ssm|sts)$'
for arg in "\$@"; do
    case "\$arg" in
        --*=*|-*=*)
            continue
            ;;
        -*)
            continue
            ;;
        *)
            if [ -z "\$service" ] && [[ "\$arg" =~ \$known_services_re ]]; then
                service="\$arg"
                continue
            fi
            if [ -n "\$service" ] && [ -z "\$operation" ]; then
                operation="\$arg"
                break
            fi
            ;;
    esac
done

if [ "\${MOCK_AWS_ECHO_SECRETS:-0}" = "1" ]; then
    [ -n "\${AWS_SECRET_ACCESS_KEY:-}" ] && printf '%s\n' "\$AWS_SECRET_ACCESS_KEY"
    [ -n "\${CLOUDFLARE_API_TOKEN:-}" ] && printf '%s\n' "\$CLOUDFLARE_API_TOKEN" >&2
    [ -n "\${STRIPE_SECRET_KEY:-}" ] && printf '%s\n' "\$STRIPE_SECRET_KEY"
    [ -n "\${STRIPE_WEBHOOK_SECRET:-}" ] && printf '%s\n' "\$STRIPE_WEBHOOK_SECRET" >&2
fi

api_mode="\${MOCK_AWS_EC2_MODE:-single}"
rds_mode="\${MOCK_AWS_RDS_MODE:-single}"
alb_mode="\${MOCK_AWS_ALB_MODE:-single}"
budget_mode="\${MOCK_AWS_BUDGET_MODE:-present}"

env_name=""
if [[ "\$*" == *"fjcloud-api-staging"* ]] || [[ "\$*" == *"fjcloud-staging"* ]] || [[ "\$*" == *"fjcloud-staging-alb"* ]]; then
    env_name="staging"
elif [[ "\$*" == *"fjcloud-api-prod"* ]] || [[ "\$*" == *"fjcloud-prod"* ]] || [[ "\$*" == *"fjcloud-prod-alb"* ]]; then
    env_name="prod"
fi

if [ "\$service" = "sts" ] && [ "\$operation" = "get-caller-identity" ]; then
    cat <<'JSON'
{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/mock","UserId":"AIDATEST"}
JSON
    exit 0
fi

if [ "\$service" = "iam" ] && [ "\$operation" = "get-role" ]; then
    cat <<'JSON'
{"Role":{"Arn":"arn:aws:iam::123456789012:role/live-e2e-budget-target-role","RoleName":"live-e2e-budget-target-role"}}
JSON
    exit 0
fi

if [ "\$service" = "iam" ] && [ "\$operation" = "get-policy" ]; then
    cat <<'JSON'
{"Policy":{"Arn":"arn:aws:iam::123456789012:policy/live-e2e-budget-policy","DefaultVersionId":"v1"}}
JSON
    exit 0
fi

if [ "\$service" = "iam" ] && [ "\$operation" = "get-policy-version" ]; then
    cat <<'JSON'
{"PolicyVersion":{"VersionId":"v1","IsDefaultVersion":true}}
JSON
    exit 0
fi

if [ "\$service" = "budgets" ] && [ "\$operation" = "describe-budget" ]; then
    if [ "\$budget_mode" = "missing" ]; then
        printf '%s\n' 'An error occurred (NotFoundException) when calling the DescribeBudget operation: Budget not found' >&2
        exit 254
    fi
    cat <<'JSON'
{"Budget":{"BudgetName":"fjcloud-staging-live-e2e-spend"}}
JSON
    exit 0
fi

if [ "\$service" = "ec2" ] && [ "\$operation" = "describe-instances" ]; then
    if [ -z "\$env_name" ]; then
        cat <<'JSON'
{"Reservations":[]}
JSON
        exit 0
    fi
    if [ "\$api_mode" = "missing" ]; then
        cat <<'JSON'
{"Reservations":[]}
JSON
        exit 0
    fi
    if [ "\$api_mode" = "ambiguous" ]; then
        cat <<'JSON'
{"Reservations":[{"Instances":[{"InstanceId":"i-0a11b22c33d44e55f"}]},{"Instances":[{"InstanceId":"i-09f88e77d66c55b44"}]}]}
JSON
        exit 0
    fi
    case "\$env_name" in
        staging)
            cat <<'JSON'
{"Reservations":[{"Instances":[{"InstanceId":"i-0a11b22c33d44e55f"}]}]}
JSON
            ;;
        prod)
            cat <<'JSON'
{"Reservations":[{"Instances":[{"InstanceId":"i-0f55e44d33c22b11a"}]}]}
JSON
            ;;
    esac
    exit 0
fi

if [ "\$service" = "rds" ] && [ "\$operation" = "describe-db-instances" ]; then
    if [ -z "\$env_name" ]; then
        cat <<'JSON'
{"DBInstances":[]}
JSON
        exit 0
    fi
    if [ "\$rds_mode" = "missing" ]; then
        cat <<'JSON'
{"DBInstances":[]}
JSON
        exit 0
    fi
    if [ "\$rds_mode" = "ambiguous" ]; then
        cat <<JSON
{"DBInstances":[{"DBInstanceIdentifier":"fjcloud-\$env_name"},{"DBInstanceIdentifier":"fjcloud-\$env_name-replica"}]}
JSON
        exit 0
    fi
    cat <<JSON
{"DBInstances":[{"DBInstanceIdentifier":"fjcloud-\$env_name"}]}
JSON
    exit 0
fi

if [ "\$service" = "elbv2" ] && [ "\$operation" = "describe-load-balancers" ]; then
    if [ -z "\$env_name" ]; then
        cat <<'JSON'
{"LoadBalancers":[]}
JSON
        exit 0
    fi
    if [ "\$alb_mode" = "missing" ]; then
        cat <<'JSON'
{"LoadBalancers":[]}
JSON
        exit 0
    fi
    if [ "\$alb_mode" = "ambiguous" ]; then
        cat <<JSON
{"LoadBalancers":[{"LoadBalancerArn":"arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/fjcloud-\$env_name-alb/abcd1234efgh5678"},{"LoadBalancerArn":"arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/fjcloud-\$env_name-alb-secondary/hijk9012lmno3456"}]}
JSON
        exit 0
    fi
    cat <<JSON
{"LoadBalancers":[{"LoadBalancerArn":"arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/fjcloud-\$env_name-alb/abcd1234efgh5678"}]}
JSON
    exit 0
fi

cat <<JSON
{"mock":"aws","service":"\${service:-unknown}","operation":"\${operation:-unknown}"}
JSON
MOCK
    chmod +x "$TEST_WORKSPACE/bin/aws"
}

write_mock_terraform() {
    local quoted_tf_log
    quoted_tf_log="$(shell_quote_for_script "$TERRAFORM_LOG")"
    cat > "$TEST_WORKSPACE/bin/terraform" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
echo "\$*" >> "$quoted_tf_log"
if [ "\${1:-}" = "version" ]; then
    printf '%s\n' "Terraform v1.8.0"
fi
exit 0
MOCK
    chmod +x "$TEST_WORKSPACE/bin/terraform"
}

copy_optional_support_trees() {
    local source_dir dest_dir
    for source_dir in "$REPO_ROOT/ops/scripts/lib" "$REPO_ROOT/scripts/lib"; do
        [ -d "$source_dir" ] || continue
        case "$source_dir" in
            "$REPO_ROOT/ops/scripts/lib")
                dest_dir="$TEST_WORKSPACE/ops/scripts/lib"
                ;;
            "$REPO_ROOT/scripts/lib")
                dest_dir="$TEST_WORKSPACE/scripts/lib"
                ;;
        esac
        mkdir -p "$dest_dir"
        cp "$source_dir"/*.sh "$dest_dir/" 2>/dev/null || true
    done
}

setup_workspace() {
    TEST_WORKSPACE="$(mktemp -d)"
    CLEANUP_DIRS+=("$TEST_WORKSPACE")
    TEST_CALL_LOG="$TEST_WORKSPACE/tmp/calls.log"
    AWS_LOG="$TEST_WORKSPACE/tmp/aws.log"
    TERRAFORM_LOG="$TEST_WORKSPACE/tmp/terraform.log"
    mkdir -p "$TEST_WORKSPACE/ops/scripts" \
             "$TEST_WORKSPACE/ops/scripts/lib" \
             "$TEST_WORKSPACE/ops/terraform/monitoring" \
             "$TEST_WORKSPACE/scripts/lib" \
             "$TEST_WORKSPACE/bin" \
             "$TEST_WORKSPACE/tmp" \
             "$TEST_WORKSPACE/artifacts"
    : > "$TEST_CALL_LOG"
    : > "$AWS_LOG"
    : > "$TERRAFORM_LOG"
    [ -f "$PREP_SCRIPT" ] && cp "$PREP_SCRIPT" "$TEST_WORKSPACE/ops/scripts/" || true
    copy_optional_support_trees
    write_mock_aws
    write_mock_terraform
}

require_budget_guardrail_script_for_contract() {
    local reason="$1"
    if [ ! -x "$PREP_SCRIPT" ]; then
        fail "$reason requires executable ops/scripts/live_e2e_budget_guardrail_prep.sh"
        return 1
    fi
    return 0
}

assert_nonzero_exit() {
    local actual="$1" msg="$2"
    if [ "$actual" -ne 0 ]; then
        pass "$msg"
    else
        fail "$msg (expected nonzero exit code, actual=$actual)"
    fi
}

assert_stdout_not_json() {
    local payload="$1" msg="$2"
    if [ -z "$payload" ]; then
        pass "$msg"
        return
    fi
    if python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$payload" >/dev/null 2>&1; then
        fail "$msg (stdout unexpectedly contained JSON)"
    else
        pass "$msg"
    fi
}

read_file_or_empty() {
    local path="$1"
    if [ -f "$path" ]; then
        cat "$path"
    else
        printf '\n'
    fi
}

run_artifact_dir_count() {
    local artifact_root="$1"
    local d count=0
    for d in "$artifact_root"/fjcloud_budget_guardrail_prep_*; do
        [ -d "$d" ] || continue
        count=$((count + 1))
    done
    printf '%s\n' "$count"
}

find_run_artifact_dir() {
    local artifact_root="$1"
    local d
    for d in "$artifact_root"/fjcloud_budget_guardrail_prep_*; do
        [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
    done
    printf '\n'
    return 0
}

json_field() {
    python3 - "$1" "$2" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
value = payload.get(sys.argv[2], "")
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(str(value))
PY
}

assert_missing_fields_exact() {
    local payload="$1"
    shift
    local expected=("$@")
    local result
    if result="$(python3 - "$payload" "${expected[@]}" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
expected = sorted(sys.argv[2:])
actual = payload.get("missing_fields")
if not isinstance(actual, list):
    print("missing_fields is not a list")
    raise SystemExit(2)
actual_norm = sorted(str(v) for v in actual)
if actual_norm != expected:
    print(f"expected={expected} actual={actual_norm}")
    raise SystemExit(1)
print("ok")
PY
)"; then
        pass "blocked response should expose the exact required missing_fields list"
    else
        fail "blocked response should expose the exact required missing_fields list ($result)"
    fi
}

assert_missing_flags_exact() {
    local payload="$1"
    shift
    local expected=("$@")
    local result
    if result="$(python3 - "$payload" "${expected[@]}" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
expected = sorted(sys.argv[2:])
actual = payload.get("missing_flags")
if not isinstance(actual, list):
    print("missing_flags is not a list")
    raise SystemExit(2)
actual_norm = sorted(str(v) for v in actual)
if actual_norm != expected:
    print(f"expected={expected} actual={actual_norm}")
    raise SystemExit(1)
print("ok")
PY
)"; then
        pass "blocked response should expose the exact required missing_flags list"
    else
        fail "blocked response should expose the exact required missing_flags list ($result)"
    fi
}

assert_status_and_summary_match() {
    local stdout_payload="$1"
    local run_dir="$2"
    local expected_status="$3"

    local summary_path summary_matches_stdout
    summary_path="$run_dir/summary.json"
    summary_matches_stdout="no"
    if python3 - "$stdout_payload" "$summary_path" <<'PY'
import json
import pathlib
import sys
stdout_payload = json.loads(sys.argv[1])
summary_path = pathlib.Path(sys.argv[2])
summary_payload = json.loads(summary_path.read_text(encoding="utf-8"))
if stdout_payload != summary_payload:
    raise SystemExit(1)
PY
    then
        summary_matches_stdout="yes"
    fi

    assert_valid_json "$(read_file_or_empty "$summary_path")" "summary.json should be machine-readable JSON"
    assert_eq "$summary_matches_stdout" "yes" "summary.json should match stdout JSON exactly"
    assert_eq "$(json_field "$stdout_payload" "status")" "$expected_status" "run status should be $expected_status"
}

assert_plan_command_contract() {
    local payload="$1"
    local run_dir="$2"
    if python3 - "$payload" "$run_dir" <<'PY'
import json
import pathlib
import sys
obj = json.loads(sys.argv[1])
run_dir = pathlib.Path(sys.argv[2]).absolute()
proposal_file = (run_dir / "proposal.auto.tfvars.example").absolute()
command_file = run_dir / "terraform_plan_command.txt"

plan = obj.get("plan_command")
if not isinstance(plan, list):
    raise SystemExit(1)
if any(not isinstance(token, str) for token in plan):
    raise SystemExit(2)
expected_plan = [
    "terraform",
    "plan",
    "-input=false",
    f"-var-file={proposal_file}",
]
if plan != expected_plan:
    raise SystemExit(3)
if any("TF_VAR_" in token for token in plan):
    raise SystemExit(4)
if any(token == "-var-file" for token in plan):
    raise SystemExit(5)
if any(token.endswith(".tfvars") for token in plan):
    raise SystemExit(6)
if not command_file.exists():
    raise SystemExit(7)

command_text = command_file.read_text(encoding="utf-8").strip()
expected_command = f'cd ops/terraform/monitoring && terraform plan -input=false -var-file="{proposal_file}"'
if command_text != expected_command:
    raise SystemExit(8)
if "terraform apply" in command_text:
    raise SystemExit(9)
if "TF_VAR_" in command_text:
    raise SystemExit(10)
if " -input=true" in command_text:
    raise SystemExit(11)
PY
    then
        pass "proposal response and terraform_plan_command.txt should expose the same argv-safe terraform plan command"
    else
        fail "proposal response and terraform_plan_command.txt should expose the same argv-safe terraform plan command"
    fi
}

assert_blocked_artifact_contract() {
    local payload="$1"
    local run_dir="$2"
    if python3 - "$payload" "$run_dir" <<'PY'
import json
import pathlib
import sys

payload = json.loads(sys.argv[1])
run_dir = pathlib.Path(sys.argv[2])

if payload.get("status") != "blocked":
    raise SystemExit(1)
missing_fields = payload.get("missing_fields")
missing_flags = payload.get("missing_flags")
if not isinstance(missing_fields, list) or not isinstance(missing_flags, list):
    raise SystemExit(2)
if len(missing_fields) == 0 or len(missing_flags) == 0:
    raise SystemExit(3)
if "plan_command" in payload:
    raise SystemExit(4)
if "proposed_variables" in payload:
    raise SystemExit(5)
if (run_dir / "proposal.auto.tfvars.example").exists():
    raise SystemExit(6)
if (run_dir / "terraform_plan_command.txt").exists():
    raise SystemExit(7)
PY
    then
        pass "blocked response should omit proposal artifacts and plan metadata"
    else
        fail "blocked response should omit proposal artifacts and plan metadata"
    fi
}

assert_proposal_variables_contract() {
    local payload="$1"
    local run_dir="$2"
    local expected_enabled="$3"
    local expected_principal="$4"
    local expected_policy="$5"
    local expected_role_name="$6"
    local expected_execution_role="$7"
    local expected_spend_limit="$8"
    local expected_env="$9"
    local expected_region="${10}"
    local expected_api_id="${11}"
    local expected_db_identifier="${12}"
    local expected_alb_suffix="${13}"

    if python3 - "$payload" "$run_dir" "$expected_enabled" "$expected_principal" "$expected_policy" "$expected_role_name" "$expected_execution_role" "$expected_spend_limit" "$expected_env" "$expected_region" "$expected_api_id" "$expected_db_identifier" "$expected_alb_suffix" <<'PY'
import json
import pathlib
import re
import sys
payload = json.loads(sys.argv[1])
run_dir = pathlib.Path(sys.argv[2])
expected_enabled = sys.argv[3].lower() == "true"
expected_principal = sys.argv[4]
expected_policy = sys.argv[5]
expected_role_name = sys.argv[6]
expected_execution = sys.argv[7]
expected_spend = float(sys.argv[8])
expected_env = sys.argv[9]
expected_region = sys.argv[10]
expected_api = sys.argv[11]
expected_db = sys.argv[12]
expected_alb = sys.argv[13]

canonical_names = {
    "env",
    "region",
    "api_instance_id",
    "db_instance_identifier",
    "alb_arn_suffix",
    "live_e2e_monthly_spend_limit_usd",
    "live_e2e_budget_action_enabled",
    "live_e2e_budget_action_principal_arn",
    "live_e2e_budget_action_policy_arn",
    "live_e2e_budget_action_role_name",
    "live_e2e_budget_action_execution_role_arn",
}

proposed = payload.get("proposed_variables")
proposal_file = run_dir / "proposal.auto.tfvars.example"
if not proposal_file.exists():
    raise SystemExit(10)
text = proposal_file.read_text(encoding="utf-8")
for key in canonical_names:
    if key not in text:
        raise SystemExit(11)
enabled_render = "true" if expected_enabled else "false"
if f"live_e2e_budget_action_enabled = {enabled_render}" not in text:
    raise SystemExit(12)
if expected_principal not in text or expected_policy not in text:
    raise SystemExit(13)
if expected_role_name not in text or expected_execution not in text:
    raise SystemExit(14)
if f'env = "{expected_env}"' not in text:
    raise SystemExit(15)
if f'region = "{expected_region}"' not in text:
    raise SystemExit(16)
if f'api_instance_id = "{expected_api}"' not in text:
    raise SystemExit(17)
if f'db_instance_identifier = "{expected_db}"' not in text:
    raise SystemExit(18)
if f'alb_arn_suffix = "{expected_alb}"' not in text:
    raise SystemExit(19)
match = re.search(r'live_e2e_monthly_spend_limit_usd\s*=\s*"?([0-9]+(?:\.[0-9]+)?)"?', text)
if not match or float(match.group(1)) != expected_spend:
    raise SystemExit(20)

if not isinstance(proposed, dict):
    raise SystemExit(21)
if not canonical_names.issubset(set(proposed.keys())):
    raise SystemExit(22)
if bool(proposed.get("live_e2e_budget_action_enabled")) != expected_enabled:
    raise SystemExit(23)
if str(proposed.get("live_e2e_budget_action_principal_arn")) != expected_principal:
    raise SystemExit(24)
if str(proposed.get("live_e2e_budget_action_policy_arn")) != expected_policy:
    raise SystemExit(25)
if str(proposed.get("live_e2e_budget_action_role_name")) != expected_role_name:
    raise SystemExit(26)
if str(proposed.get("live_e2e_budget_action_execution_role_arn")) != expected_execution:
    raise SystemExit(27)
if float(proposed.get("live_e2e_monthly_spend_limit_usd")) != expected_spend:
    raise SystemExit(28)
if str(proposed.get("env")) != expected_env:
    raise SystemExit(29)
if str(proposed.get("region")) != expected_region:
    raise SystemExit(30)
if str(proposed.get("api_instance_id")) != expected_api:
    raise SystemExit(31)
if str(proposed.get("db_instance_identifier")) != expected_db:
    raise SystemExit(32)
if str(proposed.get("alb_arn_suffix")) != expected_alb:
    raise SystemExit(33)
PY
    then
        pass "proposal variables should use canonical Terraform variable names and preserve supplied values"
    else
        fail "proposal variables should use canonical Terraform variable names and preserve supplied values"
    fi
}

assert_private_artifact_modes() {
    local run_dir="$1"
    local mode_ok
    mode_ok="no"
    if python3 - "$run_dir" <<'PY'
import os
import pathlib
import sys
run_dir = pathlib.Path(sys.argv[1])
paths = [run_dir, run_dir / "summary.json"]
if (run_dir / "proposal.auto.tfvars.example").exists():
    paths.append(run_dir / "proposal.auto.tfvars.example")
if (run_dir / "terraform_plan_command.txt").exists():
    paths.append(run_dir / "terraform_plan_command.txt")
logs_dir = run_dir / "logs"
if logs_dir.exists():
    paths.append(logs_dir)
    for entry in logs_dir.rglob("*"):
        paths.append(entry)
for p in paths:
    if not p.exists():
        continue
    if os.stat(p).st_mode & 0o077:
        raise SystemExit(1)
PY
    then
        mode_ok="yes"
    fi
    assert_eq "$mode_ok" "yes" "run artifacts should be private to the current user even under permissive umask"
}

assert_no_proposal_placeholder_values() {
    local payload="$1"
    local run_dir="$2"
    local combined
    combined="$payload"$'\n'"$(read_file_or_empty "$run_dir/summary.json")"$'\n'"$(read_file_or_empty "$run_dir/proposal.auto.tfvars.example")"
    assert_not_contains "$combined" "TODO" "proposal artifacts should not contain TODO placeholder values"
    assert_not_contains "$combined" "REPLACE_ME" "proposal artifacts should not contain REPLACE_ME placeholder values"
    assert_not_contains "$combined" "live_e2e_budget_action_principal_arn = \"\"" "proposal artifacts should not emit empty principal ARN placeholders"
    assert_not_contains "$combined" "live_e2e_budget_action_policy_arn = \"\"" "proposal artifacts should not emit empty policy ARN placeholders"
    assert_not_contains "$combined" "live_e2e_budget_action_execution_role_arn = \"\"" "proposal artifacts should not emit empty execution-role ARN placeholders"
    assert_not_contains "$combined" "api_instance_id = \"\"" "proposal artifacts should not emit empty API instance placeholders"
    assert_not_contains "$combined" "db_instance_identifier = \"\"" "proposal artifacts should not emit empty DB identifier placeholders"
    assert_not_contains "$combined" "alb_arn_suffix = \"\"" "proposal artifacts should not emit empty ALB suffix placeholders"
}

assert_no_terraform_calls() {
    local tf_calls
    tf_calls="$(read_file_or_empty "$TERRAFORM_LOG")"
    assert_eq "$tf_calls" "" "prep contract should not invoke terraform commands"
}

assert_no_owner_or_delegated_script_calls() {
    local calls
    calls="$(read_file_or_empty "$TEST_CALL_LOG")"
    assert_eq "$calls" "" "blocked prep contract should not invoke owner or delegated scripts"
}

assert_aws_calls_safe_and_read_only() {
    local expected_region="$1"
    if python3 - "$AWS_LOG" "$expected_region" <<'PY'
import re
import sys
from pathlib import Path

aws_log_path = Path(sys.argv[1])
expected_region = sys.argv[2]
lines = [line.strip() for line in aws_log_path.read_text(encoding="utf-8").splitlines() if line.strip()]
if not lines:
    raise SystemExit(10)

required_commands = {
    "sts get-caller-identity",
    "ec2 describe-instances",
    "rds describe-db-instances",
    "elbv2 describe-load-balancers",
}
for required in required_commands:
    if not any(required in line for line in lines):
        raise SystemExit(17)

mutating_re = re.compile(r"\b(create|put|delete|update|modify|terminate|start|stop|attach|detach|apply|execute|run-instances)\b", re.IGNORECASE)
for line in lines:
    if "|" not in line:
        raise SystemExit(11)
    pager, args = line.split("|", 1)
    if not pager.startswith("AWS_PAGER="):
        raise SystemExit(12)
    pager_value = pager.split("=", 1)[1]
    if pager_value != "":
        raise SystemExit(13)
    if " --no-cli-pager" not in f" {args}":
        raise SystemExit(14)
    if f" --region {expected_region}" not in f" {args}":
        raise SystemExit(15)
    if mutating_re.search(args):
        raise SystemExit(16)
PY
    then
        pass "all aws discovery commands should be no-pager, explicit-region, and read-only"
    else
        fail "all aws discovery commands should be no-pager, explicit-region, and read-only"
    fi
}

assert_plan_command_absent() {
    local run_dir="$1"
    local plan_path="$run_dir/terraform_plan_command.txt"
    if [ ! -f "$plan_path" ]; then
        pass "blocked runs should not write terraform_plan_command.txt"
    else
        fail "blocked runs should not write terraform_plan_command.txt"
    fi
}

count_workspace_tfvars_outside_artifact_dir() {
    python3 - "$TEST_WORKSPACE" <<'PY'
from pathlib import Path
import sys
workspace = Path(sys.argv[1])
count = 0
for path in workspace.rglob("*.tfvars*"):
    if "/artifacts/" in str(path):
        continue
    count += 1
print(count)
PY
}

count_workspace_proposal_or_tfvars_files() {
    python3 - "$TEST_WORKSPACE" <<'PY'
from pathlib import Path
import sys

workspace = Path(sys.argv[1])
count = 0
for path in workspace.rglob("*"):
    if not path.is_file():
        continue
    name = path.name.lower()
    if name.endswith(".tfvars") or name.endswith(".tfvars.json") or "proposal" in name:
        count += 1
print(count)
PY
}

_run_budget_guardrail_prep() {
    local cli_args=""
    local env_args=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --args)
                cli_args="$2"
                shift 2
                ;;
            *)
                env_args+=("$1")
                shift
                ;;
        esac
    done

    env_args+=("PATH=$TEST_WORKSPACE/bin:/usr/bin:/bin:/usr/local/bin")
    env_args+=("HOME=$TEST_WORKSPACE")
    env_args+=("TMPDIR=$TEST_WORKSPACE/tmp")
    env_args+=("AWS_PAGER=")
    env_args+=("TEST_CALL_LOG=$TEST_CALL_LOG")
    local wrapper_script="$TEST_WORKSPACE/ops/scripts/live_e2e_budget_guardrail_prep.sh"
    local stdout_file="$TEST_WORKSPACE/tmp/prep_stdout.txt"
    local stderr_file="$TEST_WORKSPACE/tmp/prep_stderr.txt"

    RUN_EXIT_CODE=0
    if [ -n "$cli_args" ]; then
        # shellcheck disable=SC2086
        (cd "$TEST_WORKSPACE" && env -i "${env_args[@]}" /bin/bash "$wrapper_script" $cli_args >"$stdout_file" 2>"$stderr_file") || RUN_EXIT_CODE=$?
    else
        (cd "$TEST_WORKSPACE" && env -i "${env_args[@]}" /bin/bash "$wrapper_script" >"$stdout_file" 2>"$stderr_file") || RUN_EXIT_CODE=$?
    fi

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

_run_budget_guardrail_prep_argv() {
    local -a cli_args=("$@")
    local env_args=()
    env_args+=("PATH=$TEST_WORKSPACE/bin:/usr/bin:/bin:/usr/local/bin")
    env_args+=("HOME=$TEST_WORKSPACE")
    env_args+=("TMPDIR=$TEST_WORKSPACE/tmp")
    env_args+=("AWS_PAGER=")
    env_args+=("TEST_CALL_LOG=$TEST_CALL_LOG")
    local wrapper_script="$TEST_WORKSPACE/ops/scripts/live_e2e_budget_guardrail_prep.sh"
    local stdout_file="$TEST_WORKSPACE/tmp/prep_stdout.txt"
    local stderr_file="$TEST_WORKSPACE/tmp/prep_stderr.txt"

    RUN_EXIT_CODE=0
    (cd "$TEST_WORKSPACE" && env -i "${env_args[@]}" /bin/bash "$wrapper_script" "${cli_args[@]}" >"$stdout_file" 2>"$stderr_file") || RUN_EXIT_CODE=$?
    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

assert_cli_invalid_contract() {
    local label="$1"
    local cli_args="$2"
    local expected_flag="$3"
    setup_workspace
    cli_args="${cli_args//\$TEST_WORKSPACE/$TEST_WORKSPACE}"
    _run_budget_guardrail_prep --args "$cli_args"
    assert_eq "$RUN_EXIT_CODE" "2" "$label should exit 2"
    assert_contains "$RUN_STDERR" "$expected_flag" "$label should name the offending flag"
    assert_contains "$RUN_STDERR" "Usage:" "$label should print usage to stderr"
    assert_eq "$(run_artifact_dir_count "$TEST_WORKSPACE/artifacts")" "0" "$label should not create run artifact directories"
    assert_stdout_not_json "$RUN_STDOUT" "$label should not emit stdout JSON"
    assert_no_terraform_calls
}

assert_invalid_value_fails_closed() {
    local label="$1"
    local expected_snippet="$2"
    shift 2
    local raw_arg
    local -a cli_args=()
    setup_workspace
    for raw_arg in "$@"; do
        cli_args+=("${raw_arg//\$TEST_WORKSPACE/$TEST_WORKSPACE}")
    done
    _run_budget_guardrail_prep_argv "${cli_args[@]}"
    assert_nonzero_exit "$RUN_EXIT_CODE" "$label should fail closed"
    assert_contains "$(printf '%s\n%s' "$RUN_STDOUT" "$RUN_STDERR")" "$expected_snippet" "$label should mention the offending value or flag"
    assert_eq "$(run_artifact_dir_count "$TEST_WORKSPACE/artifacts")" "0" "$label should not create run artifact directories"
    assert_eq "$(count_workspace_proposal_or_tfvars_files)" "0" "$label should not emit proposal or tfvars artifacts anywhere in workspace"
    assert_stdout_not_json "$RUN_STDOUT" "$label should not emit stdout JSON"
    assert_no_terraform_calls
}
