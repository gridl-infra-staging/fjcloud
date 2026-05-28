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
| cold_tier | The `cold_tier` service module contains client and pipeline implementations for managing cold storage tier operations, with a node_client for communicating with cold storage nodes and a pipeline for orchestrating cold tier data workflows. |
| email | The email directory provides local development email delivery and rendering functionality: `mailpit.rs` implements an email service that sends transactional and broadcast messages via the Mailpit HTTP API, while `render.rs` handles rendering various email types (verification, password reset, invoices, dunning, quotas) into structured RenderedEmail objects with validated HTML and text bodies. |
| flapjack_proxy | Proxies authenticated API requests from fjcloud to individual flapjack search VMs, managing admin API keys from SSM with in-memory TTL-based caching and stale-on-error fallback for resilience. |
| migration | The migration service module provides data migration infrastructure with components for alerting, protocol definition, replication, validation, and recovery operations. |
| provisioning | The provisioning directory contains provisioning-related logic, including auto_provision.rs which handles automated provisioning functionality. |
| scheduler | The scheduler service manages resource allocation and workload placement across the infrastructure, handling initial placement decisions, detection of overload/underload conditions, and noisy neighbor mitigation through coordinated run cycles. |
| storage | This storage service module implements S3-compatible object storage functionality for the fjcloud API, including authentication, proxying, error handling, XML processing, and usage metering for Garage-based storage. |
<!-- [scrai:end] -->
