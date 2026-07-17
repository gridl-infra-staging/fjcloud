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
| algolia_source | The algolia_source service lists Algolia indexes with cursor-based pagination, enforcing security practices like credential redaction and API-key-bound cursors while handling retries, validation, and catalog size limits. |
| cold_tier | The cold_tier module implements an automated storage tiering service that detects idle indexes and snapshots them to cold storage, managing the full lifecycle including export from source VMs, object storage upload, tenant transition, and failure recovery with configurable retries and alerting. |
| email | The email service module handles email composition and delivery, with support for template rendering and Mailpit integration for testing and development purposes. |
| flapjack_proxy | The flapjack_proxy module provides integration with Flapjack search-engine, including configuration settings normalization, lifecycle management, metrics collection via scraping, and compatibility testing. |
| migration | The migration module orchestrates three-phase index migrations between VMs: replication startup, lag convergence with source pause, and destination finalization with tenant reassignment. |
| provisioning | The provisioning service handles automatic provisioning of shared VMs across AWS, Hetzner, GCP, and OCI cloud providers, including VM creation, DNS registration, health verification, and database tracking with comprehensive error rollback. |
| scheduler | The scheduler service orchestrates VM load balancing by periodically scraping Prometheus metrics from all active VMs, computing per-dimension utilization (CPU, memory, disk, query/indexing RPS), and triggering index migrations when sustained overload, underload, or noisy-neighbor quota violations are detected. |
| algolia_source | The algolia_source service discovers and lists Algolia search indexes through paginated API calls, managing secure cursors bound to credentials with built-in validation, error handling, and catalog size enforcement. |
| cold_tier | The cold_tier service module appears to implement cold storage tier functionality for the billing and data management system, with a pipeline component for managing data transitions and queries across tiered storage layers. |
| email | Email service module providing transactional email rendering (verification, password reset, invoices, dunning, quota warnings) with HTML/text template generation, HTML escaping for security, and delivery via local Mailpit dev instance or AWS SES in production. |
| flapjack_proxy | The flapjack_proxy service module provides integration with the Flapjack search engine, including settings normalization, metrics scraping, lifecycle management, and engine compatibility testing. |
| migration | The migration service orchestrates a three-phase protocol to move search indexes between Flapjack nodes (begin replication, cut over with source pause, finalize with destination resume), while also handling rollback and failure recovery across various migration states. |
| provisioning | Orchestrates automatic provisioning of shared VMs across AWS, Hetzner, GCP, and OCI providers, including VM creation, DNS registration, secret management, and engine health verification with comprehensive rollback cleanup. |
| scheduler | A VM load-balancing scheduler that periodically scrapes Prometheus metrics from Flapjack endpoints to detect overload, underload, and noisy-neighbor quota violations, then triggers index migrations between VMs based on sustained threshold crossings. |
| storage | — |
<!-- [scrai:end] -->
