output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (for ALB)"
  value       = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

output "private_subnet_ids" {
  description = "Private subnet IDs (for RDS and internal EC2)"
  value       = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

output "sg_alb_id" {
  description = "ALB security group ID"
  value       = aws_security_group.alb.id
}

output "sg_api_id" {
  description = "API server security group ID"
  value       = aws_security_group.api.id
}

output "sg_rds_id" {
  description = "RDS security group ID"
  value       = aws_security_group.rds.id
}

output "sg_flapjack_vm_id" {
  description = "Flapjack VM security group ID"
  value       = aws_security_group.flapjack_vm.id
}
