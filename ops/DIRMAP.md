<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| garage | This directory contains bash scripts for deploying and managing Garage object storage, including installation as a systemd service, cluster initialization with credential generation, and health monitoring for the admin and S3 API endpoints. |
| runbooks | This directory contains operational runbooks for fjcloud, including incident recovery procedures. |
| scripts | The scripts directory contains deployment and infrastructure operations tooling for fjcloud, including zero-downtime deployment via SSM, database migrations, AWS bootstrap validation and provisioning, RDS restore/backup workflows, and resource cleanup. |
| terraform | This directory contains Terraform automation scripts and comprehensive test suites for infrastructure deployment, covering bootstrap provisioning, deploy/migrate/rollback operations, RDS restoration, canary publishing, and secret hygiene auditing. |
| user-data | The user-data directory contains bootstrap.sh, an idempotent VM bootstrap script that reads AWS instance metadata and secrets from SSM Parameter Store to configure and start services on fjcloud instances. |
<!-- [scrai:end] -->
