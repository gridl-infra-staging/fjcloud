<!-- [scrai:start] -->
## ops

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| build | The build directory contains verification tooling for fjcloud release binaries, specifically Stage 1 validation that confirms four fjcloud-owned staged release binaries are properly built as AL2023-glibc arm64 ELF objects with correct build provenance tracing back to the local source archive. |
| garage | The garage directory contains shell scripts for deploying and managing a Garage object storage cluster, including installation with binary verification, cluster initialization with credential setup, and health monitoring for admin and S3 endpoints. |
| packer | — |
| runbooks | This runbooks directory contains operational procedures for the fjcloud platform, including a restore script for recovering the customer-facing site after the 2026-05-03 maintenance takedown that followed the v1.0.0 launch review. |
| scripts | The scripts directory contains deployment and operational automation utilities for fjcloud infrastructure, including zero-downtime deploys, database migrations, RDS restore procedures, AWS bootstrap validation, and live system maintenance tasks like TTL cleanup and Algolia migration toggles. |
| terraform | This directory contains infrastructure automation scripts, TDD contract tests, and validation tooling for the platform's deployment pipeline, including AWS bootstrapping, database recovery, secret auditing, and Lambda canary image publishing. |
| user-data | Idempotent VM bootstrap script baked into the fjcloud AMI that reads instance metadata and secrets from AWS Parameter Store to configure environment files and start services. |
<!-- [scrai:end] -->
