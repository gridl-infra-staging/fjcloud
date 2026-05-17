<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| garage | This directory contains shell scripts for deploying, initializing, and managing Garage, a lightweight S3-compatible object storage system. |
| runbooks | Operational runbooks and procedures for infrastructure and deployment tasks. |
| scripts | The scripts directory contains bash utilities for fjcloud operations, including zero-downtime deployment, database migrations, RDS restore drills, infrastructure validation, and AWS bootstrap provisioning, supported by shared deployment libraries and tests. |
| terraform | This Terraform directory contains infrastructure-as-code and automated testing for AWS deployment orchestration across multiple stages, including bootstrap provisioning, deployment/migration scripts, RDS restore operations, and Lambda canary publishing. |
| user-data | Idempotent EC2 VM bootstrap script that reads instance metadata and environment tags via IMDSv2, retrieves database and API credentials from AWS SSM Parameter Store, writes service configuration files, and starts the Flapjack engine and metering-agent daemons. |
<!-- [scrai:end] -->
