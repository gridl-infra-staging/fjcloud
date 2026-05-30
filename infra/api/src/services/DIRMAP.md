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
| cold_tier | The cold_tier module manages automatic tiering of idle search indexes from hot tier VMs to cold storage via snapshot export, object store upload, and VM eviction, with configurable idle thresholds, retry logic, and failure alerts. |
| email | The email directory contains utilities for email rendering and Mailpit integration for testing and development purposes. |
| flapjack_proxy | This module provides a proxy service that forwards authenticated requests from the fjcloud API to flapjack VMs, with in-memory API key caching backed by SSM, TTL management, and stale-key fallback for resilience. |
| migration | The migration service module handles data migration operations with support for replication, validation, recovery, and alerting. |
| provisioning | Implements automatic provisioning of shared VMs for capacity fallback across multiple cloud providers (AWS, Hetzner, GCP, OCI), orchestrating VM creation, DNS record management, API key generation, and comprehensive failure cleanup. |
| scheduler | The scheduler service manages resource placement and load balancing across the infrastructure, handling initial placement of workloads and adaptive responses to various load conditions including overload, underload, and noisy neighbor scenarios through periodic scheduling cycles. |
| storage | The storage module implements S3-compatible object storage with authentication, error handling, XML response formatting, and metering integration for billing. |
| cold_tier | The cold_tier directory contains a Rust service module for managing cold storage tier operations, with components for node client communication and data pipeline processing. |
| email | Email module providing template rendering and mailpit integration for testing and development email capture. |
| flapjack_proxy | This module provides a proxy service that handles authenticated requests from the fjcloud API to individual flapjack VMs using SSM-backed admin keys with a 5-minute cache TTL. |
| migration | The migration service module provides data migration functionality across the API layer, with components for protocol definition, replication, validation, recovery, and alerting during migration operations. |
| provisioning | The provisioning directory contains infrastructure provisioning code, with auto_provision.rs as its primary component handling automated provisioning logic. |
| scheduler | The scheduler service manages task placement and resource allocation across infrastructure, with modules handling initial placement, load balancing through overload/underload detection, and noisy-neighbor isolation to prevent performance interference between workloads. |
| storage | The storage directory implements S3 API proxying and metering functionality, including authentication, request/response handling, XML parsing, error management, and usage tracking for object storage. |
<!-- [scrai:end] -->
