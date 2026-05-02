//! Repository initialization extracted from main startup.
// Startup helper: constructs all Pg-backed repos from a shared pool.
// Extracted from main() to keep main.rs under the 800-line limit.

use crate::repos::{
    PgApiKeyRepo, PgColdSnapshotRepo, PgCustomerRepo, PgDeploymentRepo, PgIndexMigrationRepo,
    PgInvoiceRepo, PgRateCardRepo, PgRestoreJobRepo, PgTenantRepo, PgUsageRepo, PgVmInventoryRepo,
    PgWebhookEventRepo,
};
use sqlx::PgPool;
use std::sync::Arc;

/// All Postgres-backed repositories, bundled for passing into AppState.
pub struct PgRepos {
    pub api_key_repo: Arc<PgApiKeyRepo>,
    pub customer_repo: Arc<PgCustomerRepo>,
    pub deployment_repo: Arc<PgDeploymentRepo>,
    pub usage_repo: Arc<PgUsageRepo>,
    pub rate_card_repo: Arc<PgRateCardRepo>,
    pub invoice_repo: Arc<PgInvoiceRepo>,
    pub tenant_repo: Arc<PgTenantRepo>,
    pub webhook_event_repo: Arc<PgWebhookEventRepo>,
    pub vm_inventory_repo: Arc<PgVmInventoryRepo>,
    pub index_migration_repo: Arc<PgIndexMigrationRepo>,
    pub cold_snapshot_repo: Arc<PgColdSnapshotRepo>,
    pub restore_job_repo: Arc<PgRestoreJobRepo>,
}

/// Construct every Pg-backed repo from a shared connection pool.
pub fn init_pg_repos(pool: &PgPool) -> PgRepos {
    PgRepos {
        api_key_repo: Arc::new(PgApiKeyRepo::new(pool.clone())),
        customer_repo: Arc::new(PgCustomerRepo::new(pool.clone())),
        deployment_repo: Arc::new(PgDeploymentRepo::new(pool.clone())),
        usage_repo: Arc::new(PgUsageRepo::new(pool.clone())),
        rate_card_repo: Arc::new(PgRateCardRepo::new(pool.clone())),
        invoice_repo: Arc::new(PgInvoiceRepo::new(pool.clone())),
        tenant_repo: Arc::new(PgTenantRepo::new(pool.clone())),
        webhook_event_repo: Arc::new(PgWebhookEventRepo::new(pool.clone())),
        vm_inventory_repo: Arc::new(PgVmInventoryRepo::new(pool.clone())),
        index_migration_repo: Arc::new(PgIndexMigrationRepo::new(pool.clone())),
        cold_snapshot_repo: Arc::new(PgColdSnapshotRepo::new(pool.clone())),
        restore_job_repo: Arc::new(PgRestoreJobRepo::new(pool.clone())),
    }
}
