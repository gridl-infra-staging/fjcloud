<!-- [scrai:start] -->
## evidence

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| alert_emails | — |
| database-recovery | — |
| fleet-recovery | — |
| ha_coverage_a5 | — |
| launch-rc-runs | The launch-rc-runs directory contains a production launch monitoring suite from May 5, 2026 that validates metering and usage rollup freshness over a 4-hour window with probes executed every 30 minutes across an 8-tick monitoring cycle. |
| may16_wave_deploy_verify | — |
| monitoring-coverage | — |
| privacy_com_contract | — |
| prod_db_leak_cleanup | This directory contains two consecutive cleanup stages: Stage 4 terminates customer deployments via the admin API with reproducibility verification, while Stage 5 performs soft-delete operations on eligible customers and aggregates results for downstream handoff. |
| security-coverage-a3 | — |
| ses-coverage-a1 | This directory contains test evidence and results from an SES email delivery coverage validation run performed on 2026-06-03, with probes validating email verification, password reset, dunning emails, bounce handling, complaint handling, and staging delivery functionality. |
| launch-rc-runs | A monitoring suite for the production launch's first 4-hour critical window, consisting of scripts that probe rollup freshness, execute 30-minute interval queries, and run 8 consecutive monitoring cycles to ensure metering data aggregation health. |
| may16_wave_deploy_verify | — |
| monitoring-coverage | — |
| privacy_com_contract | — |
| prod_db_leak_cleanup | This directory contains operational stages for a database leak cleanup pipeline, with Stage 4 terminating customer deployments via the admin API with reproducibility validation, and Stage 5 performing idempotent tenant soft-deletion of eligible customers while producing summary artifacts for downstream stages. |
| security-coverage-a3 | — |
| ses-coverage-a1 | This directory contains SES coverage test evidence with a timestamped subdirectory (20260603T033009Z_in_vpc_rerun) holding a stage4_integrity.py validation script that verifies email delivery and system consistency following an in-VPC rerun of the SES coverage testing. |
| launch-rc-runs | This directory contains production launch monitoring tools, specifically a timestamped subdirectory with probes for metering data freshness and a detached monitor wrapper that runs eight 30-minute monitoring iterations during a 4-hour production launch window. |
| may16_wave_deploy_verify | — |
| monitoring-coverage | — |
| privacy_com_contract | — |
| prod_db_leak_cleanup | This directory orchestrates the cleanup of a production database leak through two stages: Stage 4 terminates affected customer deployments via the admin API with reproducibility verification, and Stage 5 performs idempotent soft-deletion of eligible tenants using customer cohort and disposition data from prior stages. |
| security-coverage-a3 | — |
| ses-coverage-a1 | The ses-coverage-a1 directory is an evidence collection point for SES (Simple Email Service) testing and coverage validation, likely containing timestamped run results from inbound email roundtrip tests and readiness probes. |
| launch-rc-runs | A production launch monitoring bundle that runs 8 ticks of monitoring queries over a 4-hour window on 30-minute intervals, probing the freshness and correctness of the usage_daily rollup after a release candidate deployment. |
| may16_wave_deploy_verify | — |
| monitoring-coverage | — |
| privacy_com_contract | — |
| prod_db_leak_cleanup | This directory contains stages 4 and 5 of a production database leak cleanup workflow: Stage 4 terminates deployments for affected customers identified in earlier stages and validates consistency, while Stage 5 performs soft-deletes of tenant records via admin APIs with reproducibility guarantees. |
| security-coverage-a3 | — |
| ses-coverage-a1 | This directory contains test artifacts from an in-VPC SES coverage validation run executed on June 3, 2026, specifically a stage 4 integrity validation stub for verifying the completeness of the SES coverage test pipeline. |
| launch-rc-runs | The 'launch-rc-runs' directory contains production launch-window monitoring bundles that execute periodic health and usage freshness probes to track system state and billing data quality during critical post-launch periods. |
| may16_wave_deploy_verify | — |
| monitoring-coverage | — |
| privacy_com_contract | — |
| prod_db_leak_cleanup | This directory contains production database cleanup stages that terminate customer deployments (Stage 4) and soft-delete eligible tenants (Stage 5), with validation to ensure mutations complete exactly once and remain reproducible across reruns before final cleanup in Stage 6. |
| security-coverage-a3 | — |
| ses-coverage-a1 | The ses-coverage-a1 directory appears to be a test or evidence collection directory for SES (Simple Email Service) coverage validation, but the listed subdirectory (20260603T033009Z_in_vpc_rerun/) does not actually exist at that path. |
| staging-isolation | — |
| staging-metering | — |
| stripe-pre-gut-snapshot | — |
<!-- [scrai:end] -->
