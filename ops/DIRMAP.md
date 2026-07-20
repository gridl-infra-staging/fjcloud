<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| build | The build directory contains verify_binaries.sh, which performs Stage 1 verification to confirm that four fjcloud-owned staged release binaries are AL2023-glibc arm64 ELF objects and validates that their build provenance correctly pins the fjcloud source archive used in the local recipe. |
| garage | Garage is an object storage setup and operational tooling suite that provides scripts for provisioning Garage as a systemd service, initializing S3-compatible clusters and credentials, and monitoring API endpoint health. |
| packer | — |
| runbooks | The runbooks directory contains operational procedures, specifically a subdirectory with a restoration script for recovering from a customer-facing site takedown that occurred on May 3, 2026 during the v1.0.0 launch review process. |
| scripts | This directory contains operational scripts for deploying, rolling back, and managing the fjcloud infrastructure, including zero-downtime deployment via SSM, database restore procedures, AWS bootstrap validation, and live-system cleanup tasks. |
| terraform | The terraform directory contains Terraform infrastructure-as-code, deployment and validation scripts for AWS bootstrap and lifecycle operations, and extensive TDD test suites validating operational scripts. |
| user-data | Bootstrap script for fjcloud VM instances that reads metadata and secrets from AWS, configures environment files, and starts services in an idempotent manner suitable for AMI baking and re-execution. |
<!-- [scrai:end] -->
