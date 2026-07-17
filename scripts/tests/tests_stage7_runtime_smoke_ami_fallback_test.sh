#!/usr/bin/env bash
# Regression coverage for split AMI fallback resolution in
# ops/terraform/tests_stage7_runtime_smoke.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/ops/terraform/tests_stage7_runtime_smoke.sh"

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

if [ ! -f "$TARGET" ]; then
    fail "target script exists at ops/terraform/tests_stage7_runtime_smoke.sh"
    exit 1
fi

STUB_ROOT="$(mktemp -d)"
trap 'rm -rf "$STUB_ROOT"' EXIT

make_runtime_repo() {
    local repo_dir="$1"
    mkdir -p "$repo_dir/ops/terraform/_shared" "$repo_dir/ops/packer"
    cp "$TARGET" "$repo_dir/ops/terraform/tests_stage7_runtime_smoke.sh"
}

write_stub_env() {
    local env_file="$1"
    cat > "$env_file" <<'ENVSTUB'
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
AWS_DEFAULT_REGION=us-east-1
CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO=cf_token
CLOUDFLARE_ZONE_ID_FLAPJACK_FOO=zone_id
ENVSTUB
}

write_common_stubs() {
    local bin_dir="$1"
    local terraform_log="$2"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/terraform" <<'STUB'
#!/usr/bin/env bash
printf 'terraform|%s\n' "$*" >> "${TERRAFORM_LOG:?}"
case "$1" in
  init|plan)
    exit 0
    ;;
  state)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
    chmod +x "$bin_dir/terraform"

    cat > "$bin_dir/curl" <<'STUB'
#!/usr/bin/env bash
config="$(cat 2>/dev/null || true)"
if printf '%s' "$config" | grep -q '/dns_records'; then
  cat <<'JSON'
{"success":true,"result":[{"name":"staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-123.us-east-1.elb.amazonaws.com","proxied":false},{"name":"api.staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-123.us-east-1.elb.amazonaws.com","proxied":false},{"name":"www.staging.flapjack.foo","type":"CNAME","content":"fjcloud-staging-alb-123.us-east-1.elb.amazonaws.com","proxied":false},{"name":"cloud.staging.flapjack.foo","type":"CNAME","content":"staging.flapjack-cloud.pages.dev","proxied":true}]}
JSON
  exit 0
fi
if printf '%s' "$config" | grep -q '/zones/'; then
  cat <<'JSON'
{"success":true,"result":{"name":"flapjack.foo"}}
JSON
  exit 0
fi
exit 0
STUB
    chmod +x "$bin_dir/curl"

    TERRAFORM_LOG="$terraform_log"
    export TERRAFORM_LOG
}

write_aws_stub() {
    local bin_dir="$1"
    local mode="$2"
    cat > "$bin_dir/aws" <<STUB
#!/usr/bin/env bash
mode="$mode"
service="\${1:-}"
operation="\${2:-}"
case "\$service \$operation" in
  "sts get-caller-identity")
    echo "123456789012"
    exit 0
    ;;
  "ec2 describe-instances")
    if [ "\$mode" = "all_fail" ]; then
      echo "stubbed ec2 describe-instances failure" >&2
      exit 255
    fi
    echo "ami-aaaaaaaaaaaaaaaaa"
    exit 0
    ;;
  "ec2 describe-images")
    echo "1"
    exit 0
    ;;
  "ssm get-parameter")
    if [ "\$mode" = "manifest" ]; then
      echo "ssm should not be called when manifest contains the Flapjack AMI" >&2
      exit 98
    fi
    if [ "\$mode" = "all_fail" ]; then
      echo "stubbed ssm failure" >&2
      exit 255
    fi
    echo "ami-ccccccccccccccccc"
    exit 0
    ;;
  "acm list-certificates")
    echo "arn:aws:acm:us-east-1:123456789012:certificate/test"
    exit 0
    ;;
  "acm describe-certificate")
    echo "ISSUED"
    exit 0
    ;;
  "elbv2 describe-load-balancers")
    echo "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/test"
    exit 0
    ;;
  "elbv2 describe-listeners")
    echo "1"
    exit 0
    ;;
  "elbv2 describe-target-groups")
    echo "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/test"
    exit 0
    ;;
  "elbv2 describe-target-health")
    echo "1"
    exit 0
    ;;
  "sesv2 get-email-identity")
    echo "SUCCESS SUCCESS"
    exit 0
    ;;
  *)
    echo "unexpected aws call: \$*" >&2
    exit 99
    ;;
esac
STUB
    chmod +x "$bin_dir/aws"
}

run_runtime_smoke() {
    local repo_dir="$1"
    local bin_dir="$2"
    local env_file="$3"
    set +e
    RUNTIME_OUTPUT="$(PATH="$bin_dir:$PATH" FJCLOUD_RUNTIME_SMOKE_ARTIFACT_DIR="$repo_dir/artifacts" \
        bash "$repo_dir/ops/terraform/tests_stage7_runtime_smoke.sh" \
        --env staging \
        --env-file "$env_file" 2>&1)"
    RUNTIME_RC=$?
    set -e
}

scenario_a_all_sources_fail() {
    local repo_dir="$STUB_ROOT/scenario_a/repo"
    local bin_dir="$STUB_ROOT/scenario_a/bin"
    local env_file="$STUB_ROOT/scenario_a/env.secret"
    local terraform_log="$STUB_ROOT/scenario_a/terraform.log"
    make_runtime_repo "$repo_dir"
    write_stub_env "$env_file"
    write_common_stubs "$bin_dir" "$terraform_log"
    write_aws_stub "$bin_dir" "all_fail"

    run_runtime_smoke "$repo_dir" "$bin_dir" "$env_file"

    if [ "$RUNTIME_RC" -eq 0 ]; then
        fail "scenario A: script should exit non-zero when API and Flapjack AMI sources fail"
    else
        pass "scenario A: non-zero exit when API and Flapjack AMI sources fail"
    fi
    assert_contains "$RUNTIME_OUTPUT" "ERROR: --api-ami-id and --flapjack-ami-id are required unless resolvable from live state" \
        "scenario A: split fallback error names both AMI contracts"
}

scenario_b_manifest_resolves_flapjack_and_instance_resolves_api() {
    local repo_dir="$STUB_ROOT/scenario_b/repo"
    local bin_dir="$STUB_ROOT/scenario_b/bin"
    local env_file="$STUB_ROOT/scenario_b/env.secret"
    local terraform_log="$STUB_ROOT/scenario_b/terraform.log"
    make_runtime_repo "$repo_dir"
    write_stub_env "$env_file"
    write_common_stubs "$bin_dir" "$terraform_log"
    write_aws_stub "$bin_dir" "manifest"
    cat > "$repo_dir/ops/packer/flapjack-ami-manifest.json" <<'JSON'
{"staging":{"ami_id":"ami-bbbbbbbbbbbbbbbbb"}}
JSON

    run_runtime_smoke "$repo_dir" "$bin_dir" "$env_file"

    if [ "$RUNTIME_RC" -ne 0 ]; then
        echo "$RUNTIME_OUTPUT" >&2
    fi
    assert_eq "$RUNTIME_RC" "0" "scenario B: manifest-backed split resolution should clear preflight and runtime stubs"
    assert_contains "$RUNTIME_OUTPUT" "resolved API AMI ami-aaaaaaaaaaaaaaaaa from running fjcloud-api-staging instance" \
        "scenario B: API AMI resolves from the running control-plane instance"
    assert_contains "$RUNTIME_OUTPUT" "resolved Flapjack AMI ami-bbbbbbbbbbbbbbbbb from manifest" \
        "scenario B: Flapjack AMI resolves from the manifest when present"
    assert_contains "$(cat "$terraform_log")" "-var=api_ami_id=ami-aaaaaaaaaaaaaaaaa" \
        "scenario B: terraform receives the resolved API AMI"
    assert_contains "$(cat "$terraform_log")" "-var=flapjack_ami_id=ami-bbbbbbbbbbbbbbbbb" \
        "scenario B: terraform receives the resolved Flapjack AMI"
}

scenario_c_ssm_resolves_flapjack_without_manifest() {
    local repo_dir="$STUB_ROOT/scenario_c/repo"
    local bin_dir="$STUB_ROOT/scenario_c/bin"
    local env_file="$STUB_ROOT/scenario_c/env.secret"
    local terraform_log="$STUB_ROOT/scenario_c/terraform.log"
    make_runtime_repo "$repo_dir"
    write_stub_env "$env_file"
    write_common_stubs "$bin_dir" "$terraform_log"
    write_aws_stub "$bin_dir" "ssm"

    run_runtime_smoke "$repo_dir" "$bin_dir" "$env_file"

    if [ "$RUNTIME_RC" -ne 0 ]; then
        echo "$RUNTIME_OUTPUT" >&2
    fi
    assert_eq "$RUNTIME_RC" "0" "scenario C: SSM-backed split resolution should clear preflight and runtime stubs"
    assert_contains "$RUNTIME_OUTPUT" "resolved API AMI ami-aaaaaaaaaaaaaaaaa from running fjcloud-api-staging instance" \
        "scenario C: API AMI resolves from the running control-plane instance"
    assert_contains "$RUNTIME_OUTPUT" "resolved Flapjack AMI ami-ccccccccccccccccc from ssm" \
        "scenario C: Flapjack AMI resolves from SSM when manifest is absent"
    assert_contains "$(cat "$terraform_log")" "-var=api_ami_id=ami-aaaaaaaaaaaaaaaaa" \
        "scenario C: terraform receives the resolved API AMI"
    assert_contains "$(cat "$terraform_log")" "-var=flapjack_ami_id=ami-ccccccccccccccccc" \
        "scenario C: terraform receives the resolved Flapjack AMI"
}

scenario_a_all_sources_fail
scenario_b_manifest_resolves_flapjack_and_instance_resolves_api
scenario_c_ssm_resolves_flapjack_without_manifest

echo
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
