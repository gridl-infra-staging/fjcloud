# Packer template for building fjcloud AMIs (Amazon Linux 2023, ARM64)
#
# Produces a single AMI used for both the staging API host and customer VMs.
# Staging API host: runs fjcloud-api, fjcloud-aggregation-job, fj-metering-agent
# Customer VMs: run flapjack engine via bootstrap.sh (reads IMDS tags at boot)
#
# Binary contract for the dual-use AMI:
#   flapjack, fjcloud-api, fjcloud-aggregation-job, fj-metering-agent
#
# Prerequisites:
#   - Packer >= 1.9 with amazon plugin
#   - AWS credentials with EC2/AMI permissions
#   - Staging binaries in ../build/ (flapjack, fjcloud-api, fjcloud-aggregation-job, fj-metering-agent)
#   - systemd unit files in ../systemd/
#   - bootstrap script in ../user-data/
#
# Build:
#   cd ops/packer
#   packer init .
#   packer build -var 'flapjack_version=0.1.0' -var 'env=staging' flapjack-ami.pkr.hcl

packer {
  required_version = ">= 1.9.0"
  required_plugins {
    amazon = {
      version = ">= 1.2.8"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

# --------------------------------------------------------------------------
# Variables
# --------------------------------------------------------------------------

variable "flapjack_version" {
  type        = string
  description = "Version tag for the AMI name (e.g. 0.1.0)"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t4g.small"
}

variable "binary_dir" {
  type        = string
  default     = "../build"
  description = "Directory containing flapjack, fjcloud-api, fjcloud-aggregation-job, and fj-metering-agent binaries"
}

variable "env" {
  type        = string
  description = "Deployment environment (staging or prod)"

  validation {
    condition     = contains(["staging", "prod"], var.env)
    error_message = "The env variable must be 'staging' or 'prod'."
  }
}

# --------------------------------------------------------------------------
# Source: Amazon Linux 2023 ARM64
# --------------------------------------------------------------------------

source "amazon-ebs" "flapjack" {
  ami_name      = "flapjack-${var.flapjack_version}-${formatdate("YYYYMMDD-hhmm", timestamp())}"
  instance_type = var.instance_type
  region        = var.region

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-arm64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["amazon"]
  }

  ssh_username = "ec2-user"

  tags = {
    Name       = "flapjack-${var.flapjack_version}"
    Env        = var.env
    managed-by = "packer"
    service    = "fjcloud"
  }
}

# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------

build {
  sources = ["source.amazon-ebs.flapjack"]

  # --- Copy AMI binaries ---
  provisioner "file" {
    source      = "${var.binary_dir}/flapjack"
    destination = "/tmp/flapjack"
  }

  provisioner "file" {
    source      = "${var.binary_dir}/fjcloud-api"
    destination = "/tmp/fjcloud-api"
  }

  provisioner "file" {
    source      = "${var.binary_dir}/fjcloud-aggregation-job"
    destination = "/tmp/fjcloud-aggregation-job"
  }

  provisioner "file" {
    source      = "${var.binary_dir}/fj-metering-agent"
    destination = "/tmp/fj-metering-agent"
  }

  # --- Copy systemd unit files ---
  provisioner "file" {
    source      = "../systemd/flapjack.service"
    destination = "/tmp/flapjack.service"
  }

  provisioner "file" {
    source      = "../systemd/fj-metering-agent.service"
    destination = "/tmp/fj-metering-agent.service"
  }

  provisioner "file" {
    source      = "../systemd/fjcloud-api.service"
    destination = "/tmp/fjcloud-api.service"
  }

  provisioner "file" {
    source      = "../systemd/fjcloud-aggregation-job.service"
    destination = "/tmp/fjcloud-aggregation-job.service"
  }

  provisioner "file" {
    source      = "../systemd/fjcloud-aggregation-job.timer"
    destination = "/tmp/fjcloud-aggregation-job.timer"
  }

  # --- Copy bootstrap script ---
  provisioner "file" {
    source      = "../user-data/bootstrap.sh"
    destination = "/tmp/bootstrap.sh"
  }

  # --- Copy logrotate config ---
  provisioner "file" {
    source      = "files/logrotate-flapjack"
    destination = "/tmp/logrotate-flapjack"
  }

  # --- Install everything ---
  provisioner "shell" {
    inline = [
      # System packages (aws-cli is the AL2023 package name for AWS CLI v2)
      "sudo dnf update -y",
      # postgresql16 bakes in `psql` so the staging metering rehearsal and
      # RDS restore-drill verification owners can run DB evidence checks
      # from the API host without operator-side tooling installs.
      "sudo dnf install -y aws-cli jq gcc cargo postgresql16",
      "cargo install sqlx-cli --version 0.8.3 --no-default-features --features postgres,rustls",
      "sudo install -m 0755 /home/ec2-user/.cargo/bin/sqlx /usr/local/bin/sqlx",
      "sudo chmod +x /usr/local/bin/sqlx",

      # Create fjcloud system user and directories (staging API host services)
      "sudo useradd --system --shell /sbin/nologin --create-home --home-dir /var/lib/fjcloud fjcloud",
      "sudo mkdir -p /var/log/fjcloud /etc/fjcloud",
      "sudo chown fjcloud:fjcloud /var/lib/fjcloud /var/log/fjcloud /etc/fjcloud",

      # Create flapjack system user and directories (customer VM engine)
      "sudo useradd --system --shell /sbin/nologin --create-home --home-dir /var/lib/flapjack flapjack",
      "sudo mkdir -p /var/log/flapjack /etc/flapjack",
      "sudo chown flapjack:flapjack /var/lib/flapjack /var/log/flapjack /etc/flapjack",

      # Install binaries needed by the dual-use AMI. Shared VMs start the
      # flapjack engine directly from the baked image, while the staging API
      # host later refreshes the fjcloud binaries via deploy.sh.
      "sudo install -m 0755 /tmp/flapjack /usr/local/bin/flapjack",
      "sudo install -m 0755 /tmp/fjcloud-api /usr/local/bin/fjcloud-api",
      "sudo install -m 0755 /tmp/fjcloud-aggregation-job /usr/local/bin/fjcloud-aggregation-job",
      "sudo install -m 0755 /tmp/fj-metering-agent /usr/local/bin/fj-metering-agent",

      # Install systemd units
      "sudo install -m 0644 /tmp/flapjack.service /etc/systemd/system/flapjack.service",
      "sudo install -m 0644 /tmp/fj-metering-agent.service /etc/systemd/system/fj-metering-agent.service",
      "sudo install -m 0644 /tmp/fjcloud-api.service /etc/systemd/system/fjcloud-api.service",
      "sudo install -m 0644 /tmp/fjcloud-aggregation-job.service /etc/systemd/system/fjcloud-aggregation-job.service",
      "sudo install -m 0644 /tmp/fjcloud-aggregation-job.timer /etc/systemd/system/fjcloud-aggregation-job.timer",

      # Install bootstrap script
      "sudo install -m 0755 /tmp/bootstrap.sh /usr/local/bin/fjcloud-bootstrap",

      # Reload systemd and enable services
      "sudo systemctl daemon-reload",
      "sudo systemctl enable fjcloud-api fjcloud-aggregation-job.timer",

      # Configure host firewall (defense-in-depth; primary access control is via security groups)
      "sudo dnf install -y firewalld",
      "sudo systemctl enable --now firewalld",
      "sudo firewall-cmd --permanent --add-port=443/tcp",
      "sudo firewall-cmd --permanent --add-port=3001/tcp",
      "sudo firewall-cmd --permanent --add-port=7700/tcp",
      "sudo firewall-cmd --permanent --add-port=9091/tcp",
      "sudo firewall-cmd --permanent --add-service=ssh",
      "sudo firewall-cmd --reload",

      # Log rotation for flapjack
      "sudo install -m 0644 /tmp/logrotate-flapjack /etc/logrotate.d/flapjack",

      # Clean up temp files
      "rm -f /tmp/flapjack /tmp/fjcloud-api /tmp/fjcloud-aggregation-job /tmp/fj-metering-agent /tmp/flapjack.service /tmp/fj-metering-agent.service /tmp/fjcloud-api.service /tmp/fjcloud-aggregation-job.service /tmp/fjcloud-aggregation-job.timer /tmp/bootstrap.sh /tmp/logrotate-flapjack",
    ]
  }

  post-processor "manifest" {
    output = "flapjack-ami-manifest.json"
  }
}
