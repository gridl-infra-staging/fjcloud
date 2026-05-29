<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| build | The build directory contains binary verification utilities, including verify_binaries.sh which validates compiled artifacts. |
| garage | The scripts directory contains operational shell scripts for installing, configuring, and managing Garage, a distributed object storage system. |
| runbooks | The runbooks directory contains operational procedures, including a site_takedown_20260503 subdirectory with a restore script to revert the customer-facing site after a planned maintenance takedown in early May 2026 following the v1.0.0 launch review. |
| scripts | This directory contains operational deployment and infrastructure scripts, including zero-downtime deployments, database migrations, RDS restore procedures, and AWS bootstrap validation, along with shared utilities and test fixtures for production operations. |
| terraform | This directory contains Terraform-related ops scripts for AWS infrastructure provisioning, deployment orchestration (deploy/migrate/rollback), bootstrap resource management, and RDS operations, along with comprehensive static and unit test contracts that validate script behavior before execution. |
| user-data | Bootstrap script for fjcloud VMs baked into AMI that reads instance metadata and secrets from AWS SSM, configures environment files, and starts services idempotently. |
<!-- [scrai:end] -->
