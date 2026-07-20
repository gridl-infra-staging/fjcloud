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
| algolia_source | This module contains comprehensive tests for the Algolia cloud discovery service, covering index listing with pagination, credential redaction, cursor management, error handling, permission validation, and catalog size limits. |
| cold_tier | The cold_tier module implements automatic archival of idle search indexes to cold storage by periodically detecting inactive tenants, snapshotting their data to object storage, and evicting them from hot compute resources, with configurable idle thresholds, concurrency limits, and retry logic with alerting on failures. |
| email | Email service for generating and sending transactional emails (verification, password reset, invoices, quota warnings, dunning notifications) with HTML template rendering, safe URL handling, and XSS protection. |
| flapjack_proxy | The flapjack_proxy directory implements a proxy service for the Flapjack search engine, including settings normalization, lifecycle management, metrics collection, and compatibility testing. |
| migration | The migration service directory contains protocol and recovery components for handling data migrations in the API layer. |
| provisioning | Implements automatic provisioning of shared VMs across multiple cloud providers (AWS, Hetzner, GCP, OCI) with cloud-init configuration, DNS registration, health checks, and rollback on failure. |
| scheduler | The scheduler service orchestrates VM load balancing by periodically scraping Prometheus metrics from all active VMs, computing per-dimension utilization, and triggering index migrations when sustained overload, underload, or noisy-neighbor violations are detected. |
| storage | — |
<!-- [scrai:end] -->
