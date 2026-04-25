<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| garage | Garage contains deployment and management scripts for a Garage object storage cluster, including installation as a systemd service, cluster initialization, and health monitoring utilities. |
| scripts | Deployment and operational automation scripts for fjcloud, including zero-downtime deploys via SSM, database migrations, AWS bootstrap setup and validation, and RDS restore tools. |
| terraform | This ops/terraform directory contains TDD contract tests and validation scripts organized around deployment lifecycle stages, validating bootstrap provisioning, RDS restore procedures, deploy/migrate/rollback scripts, CI/CD pipelines, and secret hygiene through both static structural assertions and behavioral unit tests. |
| user-data | The user-data directory contains bootstrap.sh, a VM initialization script that runs during instance startup to configure fjcloud instances. |
<!-- [scrai:end] -->
