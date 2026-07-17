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

  # user_data only runs on first boot, so editing it should not force EC2
  # replacement. The AMI bakes the same package list; existing hosts are
  # reconciled out-of-band (SSM / runbook) rather than by replacement.
  user_data_replace_on_change = false

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

    # The PostgreSQL client owns live probes; the server package owns the
    # isolated temporary instance used by rollback compatibility proofs.
    # The AMI bakes the same packages so new hosts do not depend on user_data.
    dnf install -y aws-cli jq postgresql16 postgresql16-server amazon-cloudwatch-agent

    # Set hostname
    hostnamectl set-hostname "fjcloud-api-${var.env}"

    # Open fjcloud-api ports in firewalld. Without this, fresh EC2 launches
    # have 3001/3002 blocked by the firewalld default zone (firewalld is
    # baked into the AMI but its port-list isn't). Customers see 502 from
    # the ALB until firewalld is reconfigured. Adding here lets every
    # subsequent AMI bake include the right config. NOTE: per
    # user_data_replace_on_change=false, editing this does NOT remediate
    # existing instances — only the next fresh launch picks it up.
    firewall-cmd --permanent --add-port=3001/tcp --add-port=3002/tcp
    firewall-cmd --reload

    # Configure CloudWatch Agent so prod/staging API instances publish
    # disk_used_percent under the standard CWAgent namespace.
    mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
    cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CWAGENTCONF'
    {
      "agent": {
        "metrics_collection_interval": 60,
        "run_as_user": "root"
      },
      "metrics": {
        "namespace": "CWAgent",
        "append_dimensions": {
          "InstanceId": "$${aws:InstanceId}"
        },
        "metrics_collected": {
          "disk": {
            "measurement": [
              {
                "name": "used_percent",
                "rename": "disk_used_percent",
                "unit": "Percent"
              }
            ],
            "resources": [
              "/"
            ],
            "ignore_file_system_types": [
              "sysfs",
              "devtmpfs",
              "tmpfs",
              "overlay",
              "squashfs"
            ]
          }
        }
      },
      "logs": {
        "logs_collected": {
          "files": {
            "collect_list": [
              {
                "file_path": "/var/log/messages",
                "log_group_name": "/fjcloud/${var.env}/api/system",
                "log_stream_name": "{instance_id}/messages"
              },
              {
                "file_path": "/var/log/fjcloud/bootstrap.log",
                "log_group_name": "/fjcloud/${var.env}/api/bootstrap",
                "log_stream_name": "{instance_id}/bootstrap"
              }
            ]
          }
        }
      }
    }
    CWAGENTCONF

    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config \
      -m ec2 \
      -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
      -s

    # Signal: user data bootstrap complete
    echo "fjcloud user-data bootstrap complete at $(date -u +%FT%TZ)" >> /var/log/fjcloud/bootstrap.log
  USERDATA

  tags = {
    Name = "fjcloud-api-${var.env}"
    Env  = var.env
  }
}
