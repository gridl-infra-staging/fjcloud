<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| build | The build directory contains a Stage 1 verification script that validates four staged release binaries are AL2023-glibc arm64 ELF objects and confirms build provenance traces to a commit descended from the PL-13 ack-on-durable feature. |
| garage | Garage is an object storage system deployment and management framework written in shell scripts that handles systemd service installation, cluster initialization with S3 credentials, and health monitoring of admin and S3 API endpoints. |
| runbooks | The runbooks directory contains operational procedures, with site_takedown_20260503 housing a restore.sh script that reverses the site takedown performed after the v1.0.0 launch review on 2026-05-03. |
| scripts | The scripts directory contains production deployment and infrastructure management utilities, including zero-downtime deployment, SQL migrations, AWS bootstrap provisioning and validation, RDS restore operations, and rollback procedures for the fjcloud platform. |
| terraform | This directory contains AWS infrastructure automation scripts (deployment, migrations, bootstrap provisioning, RDS restore utilities) paired with extensive static contract tests that validate script structure and correctness before runtime execution. |
| user-data | The user-data directory contains a bootstrap script that initializes fjcloud VMs by reading instance metadata and secrets from AWS SSM Parameter Store, then configuring environment files and starting services. |
<!-- [scrai:end] -->
