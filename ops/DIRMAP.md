<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| garage | This directory contains shell scripts for deploying, initializing, and managing Garage, a lightweight S3-compatible object storage system. |
| runbooks | Operational runbooks and procedures for infrastructure and deployment tasks. |
| scripts | The scripts directory contains deployment and infrastructure automation for fjcloud, including zero-downtime deploys via SSM, database migrations and RDS restore operations, AWS bootstrap provisioning and validation, and operational utilities for cleanup and live-environment probes. |
| terraform | This terraform directory contains a comprehensive test and validation suite for infrastructure-as-code deployment, featuring TDD-style static contract tests and runtime smoke tests for bootstrapping, provisioning, deploying, and monitoring AWS resources, along with supporting scripts for publishing Lambda canary images and auditing secret hygiene. |
| user-data | Idempotent EC2 VM bootstrap script that reads instance metadata and environment tags via IMDSv2, retrieves database and API credentials from AWS SSM Parameter Store, writes service configuration files, and starts the Flapjack engine and metering-agent daemons. |
<!-- [scrai:end] -->
