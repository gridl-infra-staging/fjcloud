#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker_script="$repo_root/ops/terraform/tests_stage2_static.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/ops/terraform/data"

write_runbook_fixture() {
  mkdir -p "$tmpdir/docs/runbooks"
  cat >"$tmpdir/docs/runbooks/infra-terraform-apply.md" <<'EOF'
Use terraform import before apply when the RDS PostgreSQL log group already exists.
Resource address: module.data.aws_cloudwatch_log_group.rds_postgresql
Naming shape: /aws/rds/instance/fjcloud-<env>/postgresql
EOF
}

run_checker_expect_fail() {
  local label="$1"
  local logfile="$tmpdir/${label}.log"
  printf 'Running regression case: %s must fail\n' "$label"
  if (cd "$tmpdir" && bash "$checker_script" >"$logfile" 2>&1); then
    printf 'FAIL: checker accepted invalid configuration for case: %s\n' "$label"
    cat "$logfile"
    exit 1
  fi
  printf 'PASS: checker rejects invalid configuration for case: %s\n' "$label"
}

# Case 1: line comments-only fixture should fail.
write_runbook_fixture
cat >"$tmpdir/ops/terraform/data/main.tf" <<'EOF'
# resource "aws_db_subnet_group" "main" {}
# resource "random_password" "db" { length = 32 special = false }
# resource "aws_db_instance" "main" {}
# engine_version = "17"
# allocated_storage = 20
# max_allocated_storage = 100
# storage_type = "gp3"
# backup_retention_period = 30
# backup_window = "02:00-03:00"
# multi_az = local.is_prod
# deletion_protection = local.is_prod
# skip_final_snapshot = !local.is_prod
# storage_encrypted = true
# performance_insights_enabled = true
# enabled_cloudwatch_logs_exports = ["postgresql"]
# publicly_accessible = false
# resource "aws_ssm_parameter" "db_password" {}
# name = "/fjcloud/${var.env}/db_password"
# type = "SecureString"
# resource "aws_ssm_parameter" "database_url" {}
# name = "/fjcloud/${var.env}/database_url"
# type = "SecureString"
# value = "postgres://${aws_db_instance.main.username}:${random_password.db.result}@${aws_db_instance.main.endpoint}/${aws_db_instance.main.db_name}"
# resource "aws_s3_bucket" "cold" {}
# bucket = "fjcloud-cold-${var.env}"
# resource "aws_s3_bucket_versioning" "cold" {}
# status = "Enabled"
# resource "aws_s3_bucket_server_side_encryption_configuration" "cold" {}
# sse_algorithm = "AES256"
# resource "aws_s3_bucket_public_access_block" "cold" {}
# block_public_acls = true
# block_public_policy = true
# ignore_public_acls = true
# restrict_public_buckets = true
# resource "aws_s3_bucket_lifecycle_configuration" "cold" {}
# filter {}
# days = 90
# storage_class = "GLACIER_IR"
# resource "aws_ssm_parameter" "cold_bucket_name" {}
# name = "/fjcloud/${var.env}/cold_bucket_name"
EOF

cat >"$tmpdir/ops/terraform/data/variables.tf" <<'EOF'
# contains(["staging", "prod"], var.env)
EOF

cat >"$tmpdir/ops/terraform/data/providers.tf" <<'EOF'
# provider stub
EOF

cat >"$tmpdir/ops/terraform/data/outputs.tf" <<'EOF'
# outputs stub
EOF

run_checker_expect_fail "line-comments-only"

# Case 2: block comments-only fixture should fail.
write_runbook_fixture
cat >"$tmpdir/ops/terraform/data/main.tf" <<'EOF'
/*
resource "aws_db_subnet_group" "main" {
  subnet_ids = var.private_subnet_ids
}
resource "random_password" "db" {
  length  = 32
  special = false
}
resource "aws_db_instance" "main" {
  engine_version                  = "17"
  instance_class                  = var.db_instance_class
  allocated_storage               = 20
  max_allocated_storage           = 100
  storage_type                    = "gp3"
  storage_encrypted               = true
  multi_az                        = local.is_prod
  backup_retention_period         = 30
  backup_window                   = "02:00-03:00"
  deletion_protection             = local.is_prod
  skip_final_snapshot             = !local.is_prod
  db_subnet_group_name            = aws_db_subnet_group.main.name
  vpc_security_group_ids          = [var.sg_rds_id]
  publicly_accessible             = false
  performance_insights_enabled    = true
  enabled_cloudwatch_logs_exports = ["postgresql"]
  password                        = random_password.db.result
}
resource "aws_ssm_parameter" "db_password" {
  name = "/fjcloud/${var.env}/db_password"
  type = "SecureString"
}
resource "aws_ssm_parameter" "database_url" {
  name  = "/fjcloud/${var.env}/database_url"
  type  = "SecureString"
  value = "postgres://${aws_db_instance.main.username}:${random_password.db.result}@${aws_db_instance.main.endpoint}/${aws_db_instance.main.db_name}"
}
resource "aws_s3_bucket" "cold" {
  bucket = "fjcloud-cold-${var.env}"
}
resource "aws_s3_bucket_versioning" "cold" {
  versioning_configuration {
    status = "Enabled"
  }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "cold" {
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
resource "aws_s3_bucket_public_access_block" "cold" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_lifecycle_configuration" "cold" {
  rule {
    id     = "glacier-after-90-days"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
  }
}
resource "aws_ssm_parameter" "cold_bucket_name" {
  name = "/fjcloud/${var.env}/cold_bucket_name"
}
*/
EOF

cat >"$tmpdir/ops/terraform/data/variables.tf" <<'EOF'
/*
contains(["staging", "prod"], var.env)
variable "private_subnet_ids" {}
variable "sg_rds_id" {}
variable "db_instance_class" {}
*/
EOF

cat >"$tmpdir/ops/terraform/data/providers.tf" <<'EOF'
/* provider "aws" {} */
EOF

cat >"$tmpdir/ops/terraform/data/outputs.tf" <<'EOF'
/*
output "db_endpoint" {}
output "db_name" {}
output "cold_bucket_name" {}
output "cold_bucket_arn" {}
output "db_password_ssm_arn" {}
output "database_url_ssm_arn" {}
*/
EOF

run_checker_expect_fail "block-comments-only"
