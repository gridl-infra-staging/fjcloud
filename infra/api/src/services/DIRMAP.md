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
| region_failover.rs | Stub summary for infra/api/src/services/region_failover.rs. |
| replica.rs | Stub summary for infra/api/src/services/replica.rs. |
| replication.rs | Stub summary for replication.rs. |
| restore.rs | Stub summary for infra/api/src/services/restore.rs. |
| tenant_quota.rs | Stub summary for tenant_quota.rs. |
| webhook_http.rs | Stub summary for webhook_http.rs. |
| webhook_lag.rs | Stub summary for webhook_lag.rs. |

| Directory | Summary |
| --- | --- |
| algolia_source | The algolia_source directory contains tests for an Algolia cloud discovery service that handles paginated index listing, credential redaction, cursor-based state management, and permission validation for importing Algolia search indexes into a billing platform. |
| cold_tier | The cold_tier service manages automatic migration of idle customer indexes from hot storage (Flapjack VMs) to cold storage (object store snapshots), with configurable idleness thresholds, concurrent snapshot limits, retry logic with alerts, and lifecycle-guarded state transitions to prevent concurrent catalog conflicts. |
| email | The email service module handles email rendering, templating, and delivery with support for Mailpit integration for testing. |
| flapjack_proxy | The flapjack_proxy directory provides a proxy layer for the Flapjack search engine, handling lifecycle management, settings normalization, compatibility testing, and metrics collection. |
| migration | The migration service handles protocol definitions and recovery mechanisms for migrations within the API infrastructure. |
| provisioning | The provisioning service automates the creation and lifecycle management of shared virtual machines across multiple cloud providers (AWS, Hetzner, GCP, OCI), handling VM instantiation, API key generation, DNS registration, and engine health verification. |
| scheduler | The scheduler module implements VM load balancing by periodically scraping Prometheus metrics from active VMs, computing per-dimension utilization, and triggering index migrations when sustained overload, underload, or noisy-neighbor violations are detected. |
| storage | — |
<!-- [scrai:end] -->
