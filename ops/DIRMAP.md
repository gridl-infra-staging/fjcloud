<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| build | The build directory contains verification scripts for fjcloud release binaries, specifically verifying that staged release artifacts are AL2023-glibc arm64 ELF objects with correct build provenance tied to the source archive. |
| garage | The garage directory contains scripts for deploying and managing Garage object storage, including systemd service installation, cluster initialization with S3 credentials and bucket creation. |
| packer | — |
| runbooks | The runbooks directory contains operational procedures, including a restore script for recovering the customer-facing site after the May 3, 2026 takedown incident that occurred following the v1.0.0 launch review. |
| scripts | The scripts directory contains operational and deployment utilities for fjcloud, including zero-downtime deployment via SSM, SQL migration execution, RDS restore procedures, AWS infrastructure validation and provisioning, and maintenance scripts for resource cleanup and operational configuration management. |
| terraform | This terraform directory contains production deployment infrastructure-as-code with extensive TDD-style test suites covering AWS bootstrap validation, provisioning, RDS recovery, deployment scripts, CI/CD pipelines, and secret hygiene, plus Lambda canary implementations for monitoring system health. |
| user-data | The user-data directory contains a bootstrap script that initializes fjcloud VMs by reading instance metadata, fetching secrets from AWS SSM Parameter Store, configuring environment files, and starting services. |
<!-- [scrai:end] -->
