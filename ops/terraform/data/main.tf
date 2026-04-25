# Data stores: RDS PostgreSQL, SSM parameters, S3 cold tier bucket.

locals {
  is_prod                           = var.env == "prod"
  db_name                           = "fjcloud"
  rds_postgresql_log_retention_days = 30
}

# -----------------------------------------------------------------------------
# RDS PostgreSQL
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name       = "fjcloud-${var.env}"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "fjcloud-${var.env}-db-subnet-group"
  }
}

resource "random_password" "db" {
  length  = 32
  special = false # avoid shell-escaping headaches in connection strings
}

resource "random_password" "internal_auth_token" {
  length  = 48
  special = false # token is passed via HTTP headers and env files
}

resource "aws_db_instance" "main" {
  identifier     = "fjcloud-${var.env}"
  engine         = "postgres"
  engine_version = "17"

  instance_class        = var.db_instance_class
  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"

  db_name  = local.db_name
  username = "fjcloud"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.sg_rds_id]

  multi_az            = local.is_prod
  publicly_accessible = false

  backup_retention_period = 30
  backup_window           = "02:00-03:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  deletion_protection       = local.is_prod
  skip_final_snapshot       = !local.is_prod
  final_snapshot_identifier = local.is_prod ? "fjcloud-${var.env}-final" : null

  storage_encrypted = true

  performance_insights_enabled = true

  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = {
    Name = "fjcloud-${var.env}-db"
  }
}

resource "aws_cloudwatch_log_group" "rds_postgresql" {
  name              = "/aws/rds/instance/${aws_db_instance.main.identifier}/postgresql"
  retention_in_days = local.rds_postgresql_log_retention_days
}

# -----------------------------------------------------------------------------
# SSM parameters (secrets stored in Parameter Store, not in .tf files)
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "db_password" {
  name  = "/fjcloud/${var.env}/db_password"
  type  = "SecureString"
  value = random_password.db.result

  tags = {
    Name = "fjcloud-${var.env}-db-password"
  }
}

resource "aws_ssm_parameter" "database_url" {
  name  = "/fjcloud/${var.env}/database_url"
  type  = "SecureString"
  value = "postgres://${aws_db_instance.main.username}:${random_password.db.result}@${aws_db_instance.main.endpoint}/${aws_db_instance.main.db_name}"

  tags = {
    Name = "fjcloud-${var.env}-database-url"
  }
}

resource "aws_ssm_parameter" "internal_auth_token" {
  name  = "/fjcloud/${var.env}/internal_auth_token"
  type  = "SecureString"
  value = random_password.internal_auth_token.result

  tags = {
    Name = "fjcloud-${var.env}-internal-auth-token"
  }
}

# -----------------------------------------------------------------------------
# S3 cold tier bucket
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "cold" {
  bucket = "fjcloud-cold-${var.env}"

  tags = {
    Name = "fjcloud-${var.env}-cold"
  }
}

resource "aws_s3_bucket_versioning" "cold" {
  bucket = aws_s3_bucket.cold.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cold" {
  bucket = aws_s3_bucket.cold.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cold" {
  bucket = aws_s3_bucket.cold.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "cold" {
  bucket = aws_s3_bucket.cold.id

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
  name  = "/fjcloud/${var.env}/cold_bucket_name"
  type  = "String"
  value = aws_s3_bucket.cold.id

  tags = {
    Name = "fjcloud-${var.env}-cold-bucket-name"
  }
}
