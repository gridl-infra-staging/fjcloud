<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| garage | Garage object storage deployment and operational tooling containing scripts for service installation, cluster initialization, and health monitoring via admin and S3 API endpoints. |
| runbooks | This runbooks directory contains operational procedures, with a notable subdirectory documenting a May 3, 2026 site takedown incident and its restoration script for the customer-facing site. |
| scripts | The scripts directory contains deployment automation, infrastructure validation, and operational testing tools for fjcloud's CI/CD pipeline, including zero-downtime deploys, database migrations, RDS restore operations, AWS bootstrap provisioning, and live end-to-end testing utilities. |
| terraform | This directory contains TDD red-phase test suites that validate ops scripts (deploy, migrate, bootstrap, RDS restore) and Terraform configurations against defined contracts, along with build scripts for publishing AWS Lambda canary container images to ECR. |
| user-data | Bootstrap script for fjcloud EC2 instances that fetches configuration from AWS instance metadata and secrets from SSM Parameter Store, then starts services; idempotent and safe to re-run on initialized instances. |
<!-- [scrai:end] -->
