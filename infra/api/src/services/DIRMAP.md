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
| vm_orphan_reconcile.rs | Stub summary for infra/api/src/services/vm_orphan_reconcile.rs. |
| webhook_http.rs | Stub summary for webhook_http.rs. |
| webhook_lag.rs | Stub summary for webhook_lag.rs. |

| Directory | Summary |
| --- | --- |
| algolia_source | The algolia_source directory contains test stubs for the Algolia search integration service within the API crate. |
| cold_tier | The cold_tier module implements an automated index archival service that periodically scans for idle tenants and migrates them to cold storage through a coordinated snapshot pipeline (export, upload, transition, evict, verify). |
| email | The email directory is a service module that handles email functionality, including template management, email rendering from templates, and integration with Mailpit for local email testing and delivery. |
| flapjack_proxy | The flapjack_proxy service module provides integration with Flapjack search engine, including lifecycle management, metrics scraping, compatibility testing, and settings normalization for the proxy layer. |
| migration | The migration service defines protocols for data and schema migrations, with support for recovery and error handling when migrations fail or need to be retried. |
| provisioning | Handles automatic provisioning of shared VMs for capacity fallback across multiple cloud providers (AWS, Hetzner, GCP, OCI, bare metal), including VM creation, DNS registration, inventory tracking, health verification, and comprehensive rollback on failure. |
| scheduler | The scheduler service periodically scrapes Prometheus metrics from all active VMs to monitor resource utilization across CPU, memory, disk, query RPS, and indexing RPS dimensions, then triggers index migrations when sustained overload, underload, or noisy-neighbor quota violations are detected. |
| storage | — |
| vm_orphan_reconcile | — |
<!-- [scrai:end] -->
