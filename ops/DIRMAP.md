<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| build | Verifies that staged release binaries are valid AL2023-glibc ARM64 ELF objects and that their build provenance correctly traces to a commit derived from the PL-13 ack-on-durable feature branch. |
| garage | The garage directory contains deployment and maintenance scripts for a Garage object storage cluster, including tools for service installation with systemd integration, cluster configuration and S3 credential setup, and health monitoring for admin and S3 API endpoints. |
| runbooks | The runbooks directory contains a site-takedown recovery procedure, specifically a restore.sh script that reverses the infrastructure changes applied during the May 3, 2026 site takedown incident following the v1.0.0 launch review. |
| scripts | The scripts directory contains deployment and infrastructure automation for fjcloud, including zero-downtime deploys, SQL migrations, RDS restore drills, AWS bootstrap validation, and operational maintenance tasks like cleanup and TTL janitor work. |
| terraform | This directory contains Terraform-based infrastructure deployment, validation, and testing scripts for the fjcloud platform, including bootstrap provisioning, deploy/migrate/rollback operations, RDS restore handling, Lambda canary image publishing, and comprehensive test suites for each deployment stage. |
| user-data | The user-data directory contains a bootstrap script that initializes fjcloud VMs by reading instance metadata and secrets from AWS SSM, configuring environment files, and starting services in an idempotent manner suitable for inclusion in AMI bakes. |
| build | The build directory contains shell scripts for creating and verifying release binaries, specifically ensuring they are AL2023-glibc arm64 ELF objects with correct build provenance tracking back to the PL-13 ack-on-durable feature. |
| garage | The garage directory contains shell scripts for deploying and managing Garage object storage, including installation with cryptographic verification, cluster initialization with S3 credential configuration, and health monitoring for the admin and S3 API endpoints. |
| runbooks | This directory contains operational runbooks, specifically a May 3, 2026 site takedown reversal procedure with a restore.sh script that undoes changes made during the customer-facing site takedown following the v1.0.0 launch review. |
| scripts | The scripts directory contains deployment and operational automation for fjcloud, including zero-downtime deploy/rollback via SSM, database migration and RDS restore utilities, AWS bootstrap validation, and live environment management scripts. |
| terraform | Terraform infrastructure code and comprehensive test suite for ops automation, covering deployment scripts, AWS bootstrap provisioning, RDS restoration, and synthetic canary monitoring with contract-driven validation and secret auditing. |
| user-data | Bootstrap script for fjcloud VMs that reads instance metadata and secrets from AWS, configures environment files, and starts services in an idempotent manner suitable for AMI baking and re-execution. |
<!-- [scrai:end] -->
