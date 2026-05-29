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
| cold_tier | I cannot access those files as they're in a different branch (`MAR17_11_2_data_management_features`) than the current working directory. |
| email | The email directory handles email rendering and local testing infrastructure, with mailpit integration for development email capture and render utilities for email template processing. |
| flapjack_proxy | The flapjack_proxy service proxies authenticated management operations from the fjcloud API to individual flapjack VMs using node admin keys fetched from SSM. |
| migration | The migration service module provides infrastructure for managing data migrations with support for protocol definition, replication, validation, recovery mechanisms, and alerting. |
| provisioning | The provisioning directory handles automatic VM provisioning across multiple cloud providers (AWS, Hetzner, GCP, OCI), orchestrating VM creation, secret management, inventory tracking, and resource cleanup through the ProvisioningService. |
| scheduler | The scheduler service manages resource allocation and load balancing for the metering infrastructure, with modules for initial placement, detecting noisy neighbors, and handling overload and underload conditions through periodic scheduling cycles. |
| storage | This storage service module provides S3-compatible object storage integration with Garage backend, implementing S3 authentication, XML request/response handling, error translation, object metering for billing, and administrative operations. |
| cold_tier | The cold_tier service appears to manage cold storage data operations, with a node client for communicating with remote nodes and a pipeline for orchestrating data workflows across the cold storage tier. |
| email | The email directory handles email template rendering and delivery integration, with modules for rendering email content and interfacing with Mailpit for email testing and delivery. |
| flapjack_proxy | The flapjack_proxy service proxies authenticated HTTP requests from the fjcloud API to individual flapjack VMs, managing admin key retrieval from SSM with in-memory caching and TTL-based expiry, while providing error handling and helper methods for request construction and response parsing across various operation types (analytics, search, documents, settings, etc.). |
| migration | The migration service module provides database migration capabilities including data replication, validation, recovery, alerting, and protocol coordination for the API. |
| provisioning | The provisioning directory contains auto-provisioning logic for infrastructure setup and configuration management. |
| scheduler | The scheduler service manages resource placement and load balancing, with modules for initial task placement, load monitoring (overload/underload detection), noisy neighbor interference management, and run cycle orchestration. |
| storage | The storage directory implements S3-compatible object storage services with modules for authentication, error handling, XML serialization, proxy request handling, object metering, and garage admin operations. |
<!-- [scrai:end] -->
