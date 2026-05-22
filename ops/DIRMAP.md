<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| garage | This directory contains shell scripts for deploying, initializing, and managing Garage, a lightweight S3-compatible object storage system. |
| runbooks | Operational runbooks and procedures for infrastructure and deployment tasks. |
| scripts | The scripts/ directory contains deployment, migration, and infrastructure validation automation for fjcloud, including zero-downtime deploys via SSM, RDS restore procedures, AWS bootstrap provisioning and validation, and live E2E testing utilities. |
| terraform | This terraform directory contains infrastructure-as-code automation and validation scripts for AWS deployment, including ops scripts for bootstrapping, deploying, migrating, and rolling back infrastructure; comprehensive test suites validating deployment correctness and ops runbooks; Lambda canary containers for monitoring customer flows and email deliverability; and RDS restore/evidence collection utilities. |
| user-data | Idempotent EC2 VM bootstrap script that reads instance metadata and environment tags via IMDSv2, retrieves database and API credentials from AWS SSM Parameter Store, writes service configuration files, and starts the Flapjack engine and metering-agent daemons. |
<!-- [scrai:end] -->
