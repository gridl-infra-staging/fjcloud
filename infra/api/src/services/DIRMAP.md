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
| tenant_quota.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/tenant_quota.rs. |
| webhook_http.rs | Stub summary for webhook_http.rs. |

| Directory | Summary |
| --- | --- |
| cold_tier | The cold_tier service manages archived or infrequently accessed data storage, with a node_client for communicating with cold storage nodes and a pipeline for orchestrating data movement and archival workflows. |
| flapjack_proxy | The flapjack_proxy module proxies management operations from the fjcloud API to individual flapjack VMs, handling authentication via admin keys cached from SSM with stale-on-error resilience. |
| migration | The migration service orchestrates index data movement between VMs, handling replication with near-zero-lag cutover, failure recovery, alerting on success/warnings/failures, and protocol negotiation between source and destination nodes. |
| provisioning | The provisioning service handles infrastructure resource provisioning, including automatic provisioning logic in auto_provision.rs for deploying and configuring cloud infrastructure components. |
| scheduler | The scheduler service manages cluster node state and resource allocation, handling initial workload placement, noisy neighbor detection (resource contention), and overload/underload conditions across execution cycles. |
| storage | The storage service provides S3-compatible API integration with Garage (a lightweight S3 backend), handling authentication, request proxying, XML response formatting, usage metering, and admin operations. |
<!-- [scrai:end] -->
