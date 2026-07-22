<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| build | The build directory contains verification scripts for fjcloud's staged release binaries, specifically checking that they are properly formatted AL2023-glibc arm64 ELF objects with correct build provenance. |
| garage | The garage directory contains operational utilities for managing Garage object storage, including installation scripts with integrity verification and systemd integration, cluster initialization tooling, and health monitoring probes for admin and S3 API endpoints. |
| packer | — |
| runbooks | This runbooks directory contains operational procedures for the fjcloud project, including a site_takedown_20260503 subdirectory with a restore.sh script to reverse customer-facing changes made during a May 3, 2026 takedown that followed the v1.0.0 launch review. |
| scripts | The scripts directory contains deployment and operational automation for fjcloud, including zero-downtime deploy/rollback via SSM, database migration runners, AWS bootstrap validation and provisioning, RDS restore rehearsal, and various cleanup and maintenance operations. |
| terraform | This directory contains Terraform deployment automation and ops scripts for infrastructure provisioning, validation, and management, along with an extensive suite of TDD-style static contract and unit tests that validate bootstrap operations, deployment/migration/rollback procedures, AWS resource management, secret hygiene, and monitoring prerequisites without requiring live infrastructure. |
| user-data | A VM bootstrap script that reads instance metadata and secrets from AWS, configures environment, and starts services—baked into the AMI and idempotent for safe re-runs. |
<!-- [scrai:end] -->
