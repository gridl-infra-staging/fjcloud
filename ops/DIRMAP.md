<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| garage | Garage contains deployment and management scripts for a Garage object storage cluster, including installation as a systemd service, cluster initialization, and health monitoring utilities. |
| scripts | The scripts directory contains deployment automation and operational tooling for fjcloud, including zero-downtime deploy and rollback via SSM, SQL migration runners, AWS infrastructure bootstrapping and validation, and utility scripts for pre-deployment checks and environment configuration management. |
| terraform | This directory contains Terraform deployment and validation scripts with TDD-style test suites covering AWS bootstrap resource management, deploy/migrate/rollback operations, RDS recovery procedures, CI/CD pipeline validation, infrastructure runbooks, secret hygiene, and staged production-monitoring contracts. |
| user-data | The user-data directory contains bootstrap.sh, a VM initialization script that runs during instance startup to configure fjcloud instances. |
<!-- [scrai:end] -->
