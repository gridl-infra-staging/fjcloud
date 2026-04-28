<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| garage | This directory contains shell scripts for deploying, initializing, and managing Garage, a lightweight S3-compatible object storage system. |
| scripts | Scripts directory contains deployment automation (zero-downtime deploys, rollbacks, migrations), AWS infrastructure validation and provisioning, RDS restore drills with evidence capture, and live E2E testing utilities, with shared helpers in lib/ for common operations like service configuration and validation. |
| terraform | This directory contains infrastructure automation and a comprehensive TDD-style contract test suite that validates deployment, bootstrap, RDS restore, and AWS infrastructure provisioning scripts, plus a support-email canary Lambda handler for monitoring email deliverability. |
| user-data | Idempotent EC2 VM bootstrap script that reads instance metadata and environment tags via IMDSv2, retrieves database and API credentials from AWS SSM Parameter Store, writes service configuration files, and starts the Flapjack engine and metering-agent daemons. |
<!-- [scrai:end] -->
