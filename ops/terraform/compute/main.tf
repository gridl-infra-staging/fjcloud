# Compute module — API server EC2 instance.
#
# Single instance (not ASG) for MVP. Placed in a private subnet;
# public traffic arrives via ALB (Stage 4). Emergency SSH via key pair
# below; normal access via SSM Session Manager.

# --------------------------------------------------------------------------
# SSH Key Pair — emergency access only
# --------------------------------------------------------------------------

resource "tls_private_key" "api_ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "api_ssh" {
  key_name   = "fjcloud-api-${var.env}"
  public_key = tls_private_key.api_ssh.public_key_openssh

  tags = {
    Name = "fjcloud-api-${var.env}"
    Env  = var.env
  }
}

# --------------------------------------------------------------------------
# API Server EC2 Instance
# --------------------------------------------------------------------------

resource "aws_instance" "api" {
  ami                         = var.ami_id
  instance_type               = var.api_instance_type
  subnet_id                   = element(var.private_subnet_ids, 0)
  vpc_security_group_ids      = [var.sg_api_id]
  iam_instance_profile        = var.instance_profile_name
  key_name                    = aws_key_pair.api_ssh.key_name
  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    instance_metadata_tags      = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 40
    encrypted             = true
    delete_on_termination = true
  }

  user_data = <<-USERDATA
    #!/bin/bash
    set -euo pipefail

    # Create fjcloud system user and directories
    useradd --system --shell /sbin/nologin --create-home --home-dir /var/lib/fjcloud fjcloud || true
    mkdir -p /etc/fjcloud /var/log/fjcloud
    chown fjcloud:fjcloud /etc/fjcloud /var/log/fjcloud
    chmod 0750 /etc/fjcloud

    # Install dependencies
    dnf install -y aws-cli jq

    # Set hostname
    hostnamectl set-hostname "fjcloud-api-${var.env}"

    # Signal: user data bootstrap complete
    echo "fjcloud user-data bootstrap complete at $(date -u +%FT%TZ)" >> /var/log/fjcloud/bootstrap.log
  USERDATA

  tags = {
    Name = "fjcloud-api-${var.env}"
    Env  = var.env
  }
}
