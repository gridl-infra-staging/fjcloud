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
| algolia_source | The algolia_source directory contains service code for integrating with Algolia, with tests.rs providing test coverage for this integration module. |
| cold_tier | — |
| email | The email directory contains email service implementations for the API server, including a Mailpit integration for local development email delivery, rendering logic for generating email content, and template definitions for various notification types like verification, invoice, password reset, and billing-related emails. |
| flapjack_proxy | The flapjack_proxy module provides a proxy service layer for the Flapjack search engine, handling engine compatibility testing, index metrics collection, service lifecycle management, and settings configuration. |
| migration | The migration service executes a three-phase protocol for moving indexes between VMs (begin replication, cut-over with lag convergence, and finalization), with comprehensive rollback and failure recovery mechanisms to restore the source index and maintain consistency throughout the migration lifecycle. |
| provisioning | The provisioning directory implements automatic shared VM provisioning across cloud providers (AWS, Hetzner, GCP, OCI) with DNS registration, health verification, and provider-specific cloud-init secret delivery, plus optional local development bypass. |
| scheduler | The scheduler service orchestrates VM load balancing by periodically scraping Prometheus metrics from all active nodes, computing per-dimension utilization, and triggering index migrations when sustained overload, underload, or noisy-neighbor quota violations are detected. |
| storage | — |
<!-- [scrai:end] -->
