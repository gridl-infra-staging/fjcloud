<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| garage | This directory contains shell scripts for deploying, initializing, and managing Garage, a lightweight S3-compatible object storage system. |
| runbooks | Operational runbooks and procedures for infrastructure and deployment tasks. |
| scripts | The scripts directory contains operational automation for fjcloud deployment, AWS infrastructure setup, RDS restoration and recovery procedures, and live E2E testing utilities. |
| terraform | This directory contains Terraform operations scripts and test suites for validating AWS infrastructure provisioning, deployment, and monitoring, organized by stages with an emphasis on contract-driven TDD. |
| user-data | Idempotent EC2 VM bootstrap script that reads instance metadata and environment tags via IMDSv2, retrieves database and API credentials from AWS SSM Parameter Store, writes service configuration files, and starts the Flapjack engine and metering-agent daemons. |
<!-- [scrai:end] -->
