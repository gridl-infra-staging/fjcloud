<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| build | The build directory contains a verification script that validates fjcloud's staged release binaries, confirming they are AL2023-glibc arm64 ELF objects and verifying the build provenance traces back to the correct fjcloud source archive. |
| garage | The garage directory contains scripts for deploying and managing Garage object storage, including systemd service installation with binary verification, cluster initialization, S3 credential setup, and health endpoint monitoring. |
| packer | Validates a Flapjack E3 release manifest and archive pair by checking schema versions, SHA256 checksums, archive integrity, and build metadata, then extracts the flapjack executable to a specified output path. |
| runbooks | The runbooks directory contains operational procedures and scripts, including a site_takedown_20260503 subdirectory with a restore.sh script to recover from a May 3, 2026 customer-facing site takedown that followed the v1.0.0 launch review. |
| scripts | This directory contains operational automation scripts for deploying, migrating, and managing the fjcloud infrastructure on AWS, including zero-downtime deployments, database restore procedures, and infrastructure validation. |
| terraform | This directory contains infrastructure deployment and validation scripts for the Terraform-managed AWS environment, including secret-audit tooling, Lambda canary image publishers, and an extensive suite of TDD-style test scripts that validate bootstrap processes, deployment/migration procedures, RDS operations, CI/CD pipelines, and security compliance without requiring live infrastructure. |
| user-data | bootstrap.sh is an idempotent fjcloud VM initialization script baked into the AMI that runs at instance startup. |
| build | Verifies that fjcloud's staged release binaries are AL2023-glibc arm64 ELF objects and validates the build provenance against the source archive used in the local build recipe. |
| garage | Garage contains installation and operational scripts for Garage object storage, including cluster setup and initialization utilities as well as health monitoring probes for the admin and S3 API endpoints. |
| packer | The packer directory contains infrastructure-as-code tooling for building and validating AMI (Amazon Machine Image) artifacts, including a validation script for Flapjack AMI inputs as part of the deployment pipeline. |
| runbooks | This runbooks directory contains operational procedures for managing fjcloud infrastructure, including a site takedown recovery script from May 3, 2026 that restores customer-facing services after the v1.0.0 launch review incident. |
| scripts | The scripts directory contains operational deployment and infrastructure management tools for fjcloud, including zero-downtime deployment, database migrations and restore procedures, AWS bootstrap validation, and cleanup utilities. |
| terraform | The ops/terraform directory contains deployment validation and testing infrastructure for the cloud platform, including TDD-style contract tests for bootstrap, deploy, migrate, and rollback scripts, plus canary Lambda image publishing and monitoring utilities. |
| user-data | This directory contains bootstrap.sh, an idempotent VM initialization script that reads AWS instance metadata and secrets from SSM Parameter Store to configure environment files and start services on fjcloud instances. |
<!-- [scrai:end] -->
