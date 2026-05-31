<!-- [scrai:start] -->
## services

| File | Summary |
| --- | --- |
| alerting.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/alerting.rs. |
| audit_log.rs | Append-only audit-log writer for high-trust admin actions.



## Why this module exists (read before extending)



`audit_log` is the durable record of "who did what to whom and when" for

admin write paths whose abuse would be a customer-trust incident

(impersonation, suspend/reactivate, hard-erasure, etc.). |
| discovery.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/discovery.rs. |
| email.rs | Stub summary for email.rs. |
| email_suppression.rs | Stub summary for email_suppression.rs. |
| health_monitor.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/health_monitor.rs. |
| heartbeat.rs | Stub summary for heartbeat.rs. |
| metrics.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/metrics.rs. |
| object_store.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/object_store.rs. |
| placement.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/placement.rs. |
| prometheus_parser.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/prometheus_parser.rs. |
| provisioning.rs | Stub summary for provisioning.rs. |
| region_failover.rs | Stub summary for region_failover.rs. |
| replica.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/replica.rs. |
| replication.rs | Stub summary for replication.rs. |
| replication_error.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/replication_error.rs. |
| restore.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/restore.rs. |
| tenant_quota.rs | Stub summary for tenant_quota.rs. |
| webhook_http.rs | Stub summary for webhook_http.rs. |
| webhook_lag.rs | Stub summary for webhook_lag.rs. |

| Directory | Summary |
| --- | --- |
| cold_tier | The cold_tier service manages cold storage data access and pipelines in the API layer, providing a client for communicating with cold storage nodes and a processing pipeline for handling infrequently accessed data. |
| email | The email directory provides email handling utilities including Mailpit integration for email testing and template rendering functionality. |
| flapjack_proxy | The flapjack_proxy module provides a proxy service that forwards management operations from the fjcloud API to flapjack VMs, handling authentication via cached admin API keys retrieved from SSM with a 5-minute TTL. |
| migration | The migration service module provides infrastructure for managing data migrations, including protocols for replication, validation of migration correctness, recovery mechanisms for failure scenarios, and alerting during the migration process. |
| provisioning | The `provisioning` directory contains automatic VM provisioning logic that creates and registers shared virtual machines across multiple cloud providers (AWS, Hetzner, GCP, OCI) with cloud-init configuration, DNS setup, and comprehensive error-handling cleanup. |
| scheduler | The scheduler service manages resource placement and load balancing across indexes, with modules for initial placement, overload/underload detection, noisy neighbor identification, and the main scheduling cycle that orchestrates these operations. |
| storage | This storage service module provides S3-compatible object storage access with authentication, error handling, XML serialization, and metering capabilities, alongside Garage admin integration for managing the underlying storage backend. |
<!-- [scrai:end] -->
