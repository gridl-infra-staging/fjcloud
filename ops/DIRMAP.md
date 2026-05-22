<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| garage | The garage directory contains Bash scripts for managing Garage object storage deployments, covering systemd service installation, cluster initialization with S3 credentials, and API health probing. |
| runbooks | The runbooks directory contains operational procedures for site maintenance and recovery, including a restore script for reversing the site takedown that occurred on 2026-05-03 following the v1.0.0 launch review. |
| scripts | Deployment and ops automation for fjcloud, including zero-downtime deploy via SSM, database migrations and recovery, AWS bootstrap validation and provisioning, and live-environment testing utilities. |
| terraform | This directory contains Terraform-adjacent ops infrastructure automation and comprehensive test coverage, including scripts for AWS bootstrap provisioning, deployment/migration/rollback operations, RDS disaster recovery, and Lambda canary publications, along with extensive static contract tests and behavioral unit tests that validate infrastructure correctness before live execution. |
| user-data | The user-data directory contains bootstrap.sh, an idempotent VM initialization script that runs on fjcloud instances, fetching configuration from AWS instance metadata and SSM Parameter Store to write environment files and start services. |
<!-- [scrai:end] -->
