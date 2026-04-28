#!/usr/bin/env bash
# Static validation tests for Stage 7 secret hygiene.
# TDD contract for audit_no_secrets.sh behavior.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

audit_script="ops/terraform/audit_no_secrets.sh"
shared_parser_script="scripts/lib/secret_audit_parsing.sh"
consumer_audit_script="scripts/audit_secrets.sh"

echo ""
echo "=== Stage 7 Static Tests: Secret Hygiene ==="
echo ""

assert_file_exists "$audit_script" "audit_no_secrets.sh exists"
assert_file_exists "$shared_parser_script" "shared Terraform/workflow parser exists"
assert_file_exists "$consumer_audit_script" "scripts/audit_secrets.sh exists"
assert_file_contains "$audit_script" "scripts/lib/secret_audit_parsing.sh" "audit_no_secrets.sh sources shared parser"
assert_file_contains "$consumer_audit_script" "scripts/lib/secret_audit_parsing.sh" "audit_secrets.sh sources shared parser"
assert_file_not_contains "$audit_script" "^strip_tf_comments\\(\\)" "audit_no_secrets.sh no longer defines strip_tf_comments inline"
assert_file_not_contains "$audit_script" "^extract_workflow_secret_refs\\(\\)" "audit_no_secrets.sh no longer defines extract_workflow_secret_refs inline"

run_missing_root_case() {
    local tmpdir
    local output_file
    local rc
    tmpdir="$(mktemp -d)"
    output_file="$tmpdir/output.log"

    set +e
    bash "$audit_script" --root >"$output_file" 2>&1
    rc=$?
    set -e

    if [[ "$rc" == "2" ]]; then
        pass "--root without a value exits with usage error"
    else
        fail "--root without a value exits with usage error (got $rc)"
    fi
    assert_file_contains "$output_file" "Missing value for --root" "--root without a value reports the missing operand"
    assert_file_not_contains "$output_file" "unbound variable" "--root without a value does not crash via set -u"

    rm -rf "$tmpdir"
}

run_case() {
  local case_name="$1"
  local expected_exit="$2"
  local expected_output="$3"
  local tmpdir
  local output_file
  tmpdir="$(mktemp -d)"
  output_file="$tmpdir/output.log"

  mkdir -p "$tmpdir/ops/terraform" "$tmpdir/.github/workflows"

  case "$case_name" in
    clean)
      cat > "$tmpdir/ops/terraform/main.tf" <<'CLEAN_TF'
resource "aws_ssm_parameter" "jwt_secret" {
  name  = "/fjcloud/staging/jwt_secret"
  type  = "SecureString"
  value = var.jwt_secret
}
CLEAN_TF
      cat > "$tmpdir/.github/workflows/ci.yml" <<'CLEAN_WF'
name: CI
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.DEPLOY_IAM_ROLE_ARN }}
CLEAN_WF
      ;;
    hardcoded_tf_secret)
      cat > "$tmpdir/ops/terraform/main.tf" <<'BAD_TF'
locals {
  db_password = "super-secret-password"
}
BAD_TF
      cat > "$tmpdir/.github/workflows/ci.yml" <<'BAD_WF_1'
name: CI
jobs: {}
BAD_WF_1
      ;;
    hardcoded_tf_secret_with_hash)
      cat > "$tmpdir/ops/terraform/main.tf" <<'BAD_TF_HASH'
locals {
  db_password = "super#secret"
}
BAD_TF_HASH
      cat > "$tmpdir/.github/workflows/ci.yml" <<'BAD_WF_1_HASH'
name: CI
jobs: {}
BAD_WF_1_HASH
      ;;
    disallowed_workflow_secret)
      cat > "$tmpdir/ops/terraform/main.tf" <<'OK_TF'
variable "db_password" {
  type = string
}
OK_TF
      cat > "$tmpdir/.github/workflows/ci.yml" <<'BAD_WF_2'
name: CI
jobs:
  deploy:
    runs-on: ubuntu-latest
        steps:
          - run: echo "${{ secrets.AWS_SECRET_ACCESS_KEY }}"
BAD_WF_2
      ;;
    disallowed_workflow_secret_bracket)
      cat > "$tmpdir/ops/terraform/main.tf" <<'OK_TF_2'
variable "db_password" {
  type = string
}
OK_TF_2
      cat > "$tmpdir/.github/workflows/ci.yml" <<'BAD_WF_3'
name: CI
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: echo "${{ secrets['AWS_SECRET_ACCESS_KEY'] }}"
BAD_WF_3
      ;;
    allowed_workflow_secret_bracket)
      cat > "$tmpdir/ops/terraform/main.tf" <<'OK_TF_3'
variable "db_password" {
  type = string
}
OK_TF_3
      cat > "$tmpdir/.github/workflows/ci.yml" <<'GOOD_WF_3'
name: CI
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: echo "${{ secrets['DEPLOY_IAM_ROLE_ARN'] }}"
GOOD_WF_3
      ;;
    disallowed_workflow_secret_bracket_spaced)
      cat > "$tmpdir/ops/terraform/main.tf" <<'OK_TF_4'
variable "db_password" {
  type = string
}
OK_TF_4
      cat > "$tmpdir/.github/workflows/ci.yml" <<'BAD_WF_4'
name: CI
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: echo "${{ secrets[ 'AWS_SECRET_ACCESS_KEY' ] }}"
BAD_WF_4
      ;;
    commented_workflow_secret_ignored)
      cat > "$tmpdir/ops/terraform/main.tf" <<'OK_TF_5'
variable "db_password" {
  type = string
}
OK_TF_5
      cat > "$tmpdir/.github/workflows/ci.yml" <<'GOOD_WF_5'
name: CI
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      # - run: echo "${{ secrets.AWS_SECRET_ACCESS_KEY }}"
      - run: echo "safe"
GOOD_WF_5
      ;;
    benign_http_tokens_setting)
      cat > "$tmpdir/ops/terraform/main.tf" <<'TOKEN_TF'
resource "aws_instance" "example" {
  metadata_options {
    http_tokens = "required"
  }
}
TOKEN_TF
      cat > "$tmpdir/.github/workflows/ci.yml" <<'TOKEN_WF'
name: CI
jobs: {}
TOKEN_WF
      ;;
    *)
      fail "Unknown test case: $case_name"
      rm -rf "$tmpdir"
      return
      ;;
  esac

  set +e
  bash "$audit_script" --root "$tmpdir" >"$output_file" 2>&1
  local status=$?
  set -e

  if [[ "$status" -eq "$expected_exit" ]]; then
    pass "$case_name exits with code $expected_exit"
  else
    fail "$case_name exits with code $expected_exit (got $status)"
  fi

  if [[ -n "$expected_output" ]]; then
    if rg -q "$expected_output" "$output_file"; then
      pass "$case_name output contains expected marker"
    else
      fail "$case_name output contains expected marker"
    fi
  fi

  rm -rf "$tmpdir"
}

run_missing_root_case
run_case clean 0 "Secret audit passed"
run_case hardcoded_tf_secret 1 "Hardcoded secret-like Terraform assignments found"
run_case hardcoded_tf_secret_with_hash 1 "Hardcoded secret-like Terraform assignments found"
run_case disallowed_workflow_secret 1 "Disallowed GitHub Actions secrets found"
run_case disallowed_workflow_secret_bracket 1 "Disallowed GitHub Actions secrets found"
run_case disallowed_workflow_secret_bracket_spaced 1 "Disallowed GitHub Actions secrets found"
run_case commented_workflow_secret_ignored 0 "Secret audit passed"
run_case allowed_workflow_secret_bracket 0 "Secret audit passed"
run_case benign_http_tokens_setting 0 "Secret audit passed"

test_summary "Stage 7 secret hygiene static checks"
