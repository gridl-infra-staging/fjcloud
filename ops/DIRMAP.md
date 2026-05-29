<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| build | This build directory contains a single verification script that validates four staged release binaries are properly formatted AL2023-glibc arm64 ELF objects and confirms their build provenance traces back to the PL-13 ack-on-durable feature commit. |
| garage | Garage contains operational scripts for deploying and managing an object storage cluster as a systemd service, including binary installation, cluster initialization with S3 credentials and bucket creation, and health monitoring endpoints. |
| runbooks | The runbooks directory contains operational procedures for the fjcloud platform, specifically including a site restoration script (restore.sh) for recovering from the May 3, 2026 takedown incident that occurred following the v1.0.0 launch review. |
| scripts | The scripts directory contains operational and deployment automation for fjcloud, including zero-downtime deployment, database migrations, AWS infrastructure provisioning and validation, RDS restore procedures, and cleanup utilities, along with supporting libraries for configuration management and cloud interactions. |
| terraform | Ops orchestration and infrastructure validation for Terraform-managed fjcloud resources, including deployment, migration, rollback, and bootstrap management scripts. |
| user-data | Bootstrap script that initializes fjcloud VMs by reading instance metadata from AWS IMDS, fetching secrets from SSM Parameter Store, configuring environment files, and starting services in an idempotent manner suitable for AMI baking and re-execution. |
| build | This directory contains a verification script that validates the four staged release binaries are properly built as AL2023-glibc ARM64 ELF objects and confirms their build provenance traces back to the PL-13 ack-on-durable feature commit. |
| garage | Garage is a deployment and operations suite providing Bash scripts to install and configure Garage object storage as a systemd service, initialize clusters with S3 credentials, and monitor API health endpoints. |
| runbooks | The runbooks directory contains operational procedures and restoration scripts, including a site recovery script for the customer-facing site that was taken down on 2026-05-03 following the v1.0.0 launch review. |
| scripts | The scripts directory contains deployment, infrastructure, and operational automation for fjcloud, including deploy/rollback/migrate operations, RDS restore drills, AWS bootstrap validation, and live E2E testing utilities, with supporting libraries for SSM parameter mapping and Cloudflare DNS operations. |
| terraform | This directory contains TDD contract tests and validation harnesses for Terraform infrastructure code, covering bootstrap provisioning, deployment scripts, RDS restore operations, and monitoring—plus tooling for building and publishing Lambda canary container images to ECR for customer-loop and support-email monitoring probes. |
| user-data | Bootstrap script for fjcloud VM initialization that reads instance metadata and secrets from AWS SSM Parameter Store, configures environment files, and starts services in an idempotent manner suitable for AMI baking and re-runs. |
<!-- [scrai:end] -->
