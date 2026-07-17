# Packer template for building fjcloud AMIs (Amazon Linux 2023, ARM64)
#
# Produces a single AMI used for both the staging API host and customer VMs.
# Staging API host: runs fjcloud-api, fjcloud-aggregation-job, fjcloud-retention-job, fj-metering-agent
# Customer VMs: run flapjack engine via bootstrap.sh (reads IMDS tags at boot)
#
# Binary contract for the dual-use AMI:
#   flapjack, fjcloud-api, fjcloud-aggregation-job, fjcloud-retention-job, fj-metering-agent
#
# Prerequisites:
#   - Packer >= 1.9 with amazon plugin
#   - AWS credentials with EC2/AMI permissions
#   - Upstream Flapjack E3 manifest and named aarch64-unknown-linux-musl archive
#   - Staging fjcloud binaries in ../build/ (fjcloud-api, fjcloud-aggregation-job, fjcloud-retention-job, fj-metering-agent)
#   - systemd unit files in ../systemd/
#   - bootstrap script in ../user-data/
#
# Build:
#   cd ops/packer
#   packer init .
#   packer build -var 'flapjack_manifest_path=/path/to/flapjack-e3-manifest.json' -var 'flapjack_archive_path=/path/to/flapjack-e3-aarch64-unknown-linux-musl.tar.gz' -var 'env=staging' flapjack-ami.pkr.hcl

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

variable "flapjack_manifest_path" {
  type        = string
  description = "Local path to the upstream Flapjack E3 release manifest JSON"
}

variable "flapjack_archive_path" {
  type        = string
  description = "Local path to the upstream Flapjack E3 aarch64-unknown-linux-musl archive named by the manifest"
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
  description = "Directory containing fjcloud-api, fjcloud-aggregation-job, fjcloud-retention-job, and fj-metering-agent binaries"
}

variable "env" {
  type        = string
  description = "Deployment environment (staging or prod)"

  validation {
    condition     = contains(["staging", "prod"], var.env)
    error_message = "The env variable must be 'staging' or 'prod'."
  }
}

locals {
  flapjack_release_manifest         = jsondecode(file(var.flapjack_manifest_path))
  flapjack_release_identifier       = local.flapjack_release_manifest.build.version
  flapjack_release_archive_file     = basename(var.flapjack_archive_path)
  flapjack_upstream_manifest_sha256 = filesha256(var.flapjack_manifest_path)
  flapjack_upstream_archive_sha256  = filesha256(var.flapjack_archive_path)
}

# --------------------------------------------------------------------------
# Source: Amazon Linux 2023 ARM64
# --------------------------------------------------------------------------

source "amazon-ebs" "flapjack" {
  ami_name      = "flapjack-${local.flapjack_release_identifier}-${formatdate("YYYYMMDD-hhmm", timestamp())}"
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
    Name       = "flapjack-${local.flapjack_release_identifier}"
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

  # --- Copy upstream Flapjack E3 inputs and fjcloud AMI binaries ---
  provisioner "file" {
    source      = var.flapjack_manifest_path
    destination = "/tmp/flapjack-e3-manifest.json"
  }

  provisioner "file" {
    source      = var.flapjack_archive_path
    destination = "/tmp/${local.flapjack_release_archive_file}"
  }

  provisioner "file" {
    source      = "validate_flapjack_ami_input.sh"
    destination = "/tmp/validate_flapjack_ami_input.sh"
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
    source      = "${var.binary_dir}/fjcloud-retention-job"
    destination = "/tmp/fjcloud-retention-job"
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

  provisioner "file" {
    source      = "../systemd/fjcloud-retention-job.service"
    destination = "/tmp/fjcloud-retention-job.service"
  }

  provisioner "file" {
    source      = "../systemd/fjcloud-retention-job.timer"
    destination = "/tmp/fjcloud-retention-job.timer"
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
      # The client owns live DB probes; the server package owns the isolated
      # temporary PostgreSQL used by rollback compatibility proofs.
      "sudo dnf install -y aws-cli jq gcc cargo postgresql16 postgresql16-server",
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
      "chmod +x /tmp/validate_flapjack_ami_input.sh",
      "/tmp/validate_flapjack_ami_input.sh --manifest /tmp/flapjack-e3-manifest.json --archive /tmp/${local.flapjack_release_archive_file} --out /tmp/validated-flapjack",
      "sudo install -m 0755 /tmp/validated-flapjack /usr/local/bin/flapjack",
      "sudo install -m 0755 /tmp/fjcloud-api /usr/local/bin/fjcloud-api",
      "sudo install -m 0755 /tmp/fjcloud-aggregation-job /usr/local/bin/fjcloud-aggregation-job",
      "sudo install -m 0755 /tmp/fjcloud-retention-job /usr/local/bin/fjcloud-retention-job",
      "sudo install -m 0755 /tmp/fj-metering-agent /usr/local/bin/fj-metering-agent",

      # Install systemd units
      "sudo install -m 0644 /tmp/flapjack.service /etc/systemd/system/flapjack.service",
      "sudo install -m 0644 /tmp/fj-metering-agent.service /etc/systemd/system/fj-metering-agent.service",
      "sudo install -m 0644 /tmp/fjcloud-api.service /etc/systemd/system/fjcloud-api.service",
      "sudo install -m 0644 /tmp/fjcloud-aggregation-job.service /etc/systemd/system/fjcloud-aggregation-job.service",
      "sudo install -m 0644 /tmp/fjcloud-aggregation-job.timer /etc/systemd/system/fjcloud-aggregation-job.timer",
      "sudo install -m 0644 /tmp/fjcloud-retention-job.service /etc/systemd/system/fjcloud-retention-job.service",
      "sudo install -m 0644 /tmp/fjcloud-retention-job.timer /etc/systemd/system/fjcloud-retention-job.timer",

      # Install bootstrap script
      "sudo install -m 0755 /tmp/bootstrap.sh /usr/local/bin/fjcloud-bootstrap",

      # Reload systemd and enable services
      "sudo systemctl daemon-reload",
      "sudo systemctl enable fjcloud-api fjcloud-aggregation-job.timer fjcloud-retention-job.timer",

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
      "rm -f /tmp/flapjack-e3-manifest.json /tmp/${local.flapjack_release_archive_file} /tmp/validate_flapjack_ami_input.sh /tmp/validated-flapjack /tmp/fjcloud-api /tmp/fjcloud-aggregation-job /tmp/fjcloud-retention-job /tmp/fj-metering-agent /tmp/flapjack.service /tmp/fj-metering-agent.service /tmp/fjcloud-api.service /tmp/fjcloud-aggregation-job.service /tmp/fjcloud-aggregation-job.timer /tmp/fjcloud-retention-job.service /tmp/fjcloud-retention-job.timer /tmp/bootstrap.sh /tmp/logrotate-flapjack",
    ]
  }

  post-processor "manifest" {
    output = "flapjack-ami-manifest.json"
    custom_data = {
      flapjack_upstream_manifest_sha256 = local.flapjack_upstream_manifest_sha256
      flapjack_upstream_archive_sha256  = local.flapjack_upstream_archive_sha256
      flapjack_release_identifier       = local.flapjack_release_identifier
    }
  }
}
