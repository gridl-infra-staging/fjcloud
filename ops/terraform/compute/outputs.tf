output "api_instance_id" {
  description = "API server EC2 instance ID"
  value       = aws_instance.api.id
}

output "api_private_ip" {
  description = "API server private IP address"
  value       = aws_instance.api.private_ip
}

output "ssh_key_pair_name" {
  description = "SSH key pair name for emergency access"
  value       = aws_key_pair.api_ssh.key_name
}
