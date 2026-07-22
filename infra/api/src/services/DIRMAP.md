<!-- [scrai:start] -->
## services

| File | Summary |
| --- | --- |
| algolia_source.rs | Stub summary for infra/api/src/services/algolia_source.rs. |
| audit_log.rs | Append-only audit-log writer for high-trust admin actions.



## Why this module exists (read before extending)



`audit_log` is the durable record of "who did what to whom and when" for

admin write paths whose abuse would be a customer-trust incident

(impersonation, suspend/reactivate, hard-erasure, etc.). |
| email.rs | Stub summary for infra/api/src/services/email.rs. |
| email_suppression.rs | Stub summary for email_suppression.rs. |
| engine_index_identity_observer.rs | Stub summary for infra/api/src/services/engine_index_identity_observer.rs. |
| health_monitor.rs | Stub summary for infra/api/src/services/health_monitor.rs. |
| heartbeat.rs | Stub summary for heartbeat.rs. |
| index_lifecycle_lease.rs | Stub summary for infra/api/src/services/index_lifecycle_lease.rs. |
| panics.rs | Stub summary for infra/api/src/services/panics.rs. |
| provisioning.rs | Stub summary for infra/api/src/services/provisioning.rs. |
| public_topology.rs | Stub summary for infra/api/src/services/public_topology.rs. |
| region_failover.rs | Stub summary for infra/api/src/services/region_failover.rs. |
| replica.rs | Stub summary for infra/api/src/services/replica.rs. |
| replication.rs | Stub summary for replication.rs. |
| restore.rs | Stub summary for infra/api/src/services/restore.rs. |
| tenant_quota.rs | Stub summary for tenant_quota.rs. |
| vm_health_rollup.rs | Stub summary for infra/api/src/services/vm_health_rollup.rs. |
| webhook_http.rs | Stub summary for webhook_http.rs. |
| webhook_lag.rs | Stub summary for webhook_lag.rs. |

| Directory | Summary |
| --- | --- |
| algolia_source | Tests for the AlgoliaSourceService, covering pagination with cursor validation, credential redaction, permission probing (settings and browse ACLs), error mapping, retry logic, and metadata handling for Algolia cloud index discovery. |
| cold_tier | The cold_tier module implements an automated system for archiving idle indexes to cold storage, featuring a background service that detects candidates based on access patterns, orchestrates snapshot export-upload-eviction pipelines with guarded lifecycle mutations, and manages retries with alerting and rollback on failure. |
| email | Email service module for rendering and sending transactional emails, with Mailpit integration for delivery and testing. |
| flapjack_proxy | The flapjack_proxy module provides integration with the Flapjack search-engine proxy, including settings normalization, lifecycle management, metrics scraping, and engine compatibility testing. |
| migration | The migration service module provides protocol definitions and recovery mechanisms for data migrations in the billing platform's API. |
| provisioning | The provisioning module automates the creation of shared VMs across multiple cloud providers (AWS, Hetzner, GCP, OCI) with DNS registration, API key management, and health verification, while supporting a local development bypass mode. |
| scheduler | The scheduler service periodically scrapes Prometheus metrics from VMs to monitor utilization across CPU, memory, disk, and query/indexing throughput dimensions, then triggers index migrations when sustained overload, underload, or noisy-neighbor quota violations are detected. |
| storage | — |
<!-- [scrai:end] -->
