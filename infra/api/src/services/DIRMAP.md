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
| cold_tier | The cold_tier service module provides infrastructure for managing cold/archived data, with a node client for communicating with cold storage nodes and a pipeline for processing data transitions between storage tiers. |
| email | The email directory handles email rendering and mailpit integration for the billing platform, supporting template rendering for transactional emails and test email capture for validation. |
| flapjack_proxy | The flapjack_proxy module provides a proxy service that forwards authenticated management operations from the fjcloud API to flapjack VMs, with built-in caching of node admin keys from SSM and fallback to stale cache entries during outages. |
| migration | The migration module provides infrastructure for managing data migrations with components for replication, validation, recovery, alerting, and protocol handling. |
| provisioning | The provisioning directory contains auto_provision.rs, which handles automatic provisioning functionality. |
| scheduler | The scheduler service manages workload placement and load balancing with strategies for different capacity conditions, including initial placement, noisy neighbor isolation, and responses to overload and underload scenarios. |
| storage | This storage service module implements S3-compatible object storage integration, featuring authentication, XML serialization, error handling, request proxying, and usage metering for the Garage distributed storage backend. |
<!-- [scrai:end] -->
