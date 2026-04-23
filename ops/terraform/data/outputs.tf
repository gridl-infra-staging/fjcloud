output "db_endpoint" {
  description = "RDS PostgreSQL endpoint (host:port)"
  value       = aws_db_instance.main.endpoint
}

output "db_instance_identifier" {
  description = "RDS DB instance identifier"
  value       = aws_db_instance.main.identifier
}

output "db_name" {
  description = "RDS database name"
  value       = aws_db_instance.main.db_name
}

output "db_password_ssm_arn" {
  description = "ARN of the SSM parameter storing the DB password"
  value       = aws_ssm_parameter.db_password.arn
}

output "database_url_ssm_arn" {
  description = "ARN of the SSM parameter storing the full DATABASE_URL"
  value       = aws_ssm_parameter.database_url.arn
}

output "cold_bucket_name" {
  description = "S3 cold tier bucket name"
  value       = aws_s3_bucket.cold.id
}

output "cold_bucket_arn" {
  description = "S3 cold tier bucket ARN"
  value       = aws_s3_bucket.cold.arn
}
