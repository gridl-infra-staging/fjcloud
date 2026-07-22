pub mod advisory_lock;
pub mod algolia_import_job_repo;
pub mod api_key_repo;
pub mod cold_snapshot_repo;
pub mod customer_repo;
pub mod deployment_repo;
pub mod dispute_repo;
pub mod error;
pub mod in_memory_cold_snapshot_repo;
pub mod in_memory_index_replica_repo;
pub mod in_memory_restore_job_repo;
pub mod in_memory_storage_bucket_repo;
pub mod in_memory_storage_key_repo;
pub mod index_migration_repo;
pub mod index_replica_repo;
pub mod invoice_repo;
pub mod pg_algolia_import_job_repo;
pub mod pg_api_key_repo;
pub mod pg_cold_snapshot_repo;
pub mod pg_customer_repo;
pub mod pg_deployment_repo;
pub mod pg_dispute_repo;
pub mod pg_index_migration_repo;
pub mod pg_index_replica_repo;
pub mod pg_invoice_repo;
pub mod pg_rate_card_repo;
pub mod pg_restore_job_repo;
pub mod pg_storage_bucket_repo;
pub mod pg_storage_key_repo;
pub mod pg_tenant_repo;
pub mod pg_usage_repo;
pub mod pg_vm_host_metrics_repo;
pub mod pg_vm_inventory_repo;
pub mod pg_webhook_event_repo;
pub mod rate_card_repo;
pub mod restore_job_repo;
pub mod storage_bucket_repo;
pub mod storage_key_repo;
pub mod tenant_repo;
pub mod usage_repo;
pub mod vm_host_metrics_repo;
pub mod vm_inventory_repo;
pub mod webhook_event_repo;

pub use algolia_import_job_repo::{
    clamp_algolia_import_job_list_limit, AlgoliaImportCancelDispatch, AlgoliaImportCancelOutcome,
    AlgoliaImportJobAdmissionError, AlgoliaImportJobListCursor, AlgoliaImportJobListPage,
    AlgoliaImportJobRepo, AlgoliaImportResumeDispatch, AlgoliaImportResumeOutcome,
    AlgoliaImportTransitionDisposition, AlgoliaLifecycleError, CatalogLifecycleTargetGuard,
    CatalogLifecycleTargetIdentity, DestinationEligibilityError, DestinationEligibilitySnapshot,
    ALGOLIA_IMPORT_JOB_LIST_DEFAULT_LIMIT, ALGOLIA_IMPORT_JOB_LIST_MAX_LIMIT,
};
pub use api_key_repo::ApiKeyRepo;
pub use cold_snapshot_repo::ColdSnapshotRepo;
pub use customer_repo::{
    CustomerHardDeleteKind, CustomerHardDeleteOutcome, CustomerRepo, ResendPasswordResetOutcome,
    ResendPasswordResetReservation, ResendVerificationOutcome, ResendVerificationReservation,
    RESEND_VERIFICATION_COOLDOWN_SECONDS,
};
pub use deployment_repo::DeploymentRepo;
pub use dispute_repo::{DisputeRepo, DisputeRow, DisputeUpsertInput};
pub use error::RepoError;
pub use in_memory_cold_snapshot_repo::InMemoryColdSnapshotRepo;
pub use in_memory_index_replica_repo::InMemoryIndexReplicaRepo;
pub use in_memory_restore_job_repo::InMemoryRestoreJobRepo;
pub use in_memory_storage_bucket_repo::InMemoryStorageBucketRepo;
pub use in_memory_storage_key_repo::InMemoryStorageKeyRepo;
pub use index_migration_repo::IndexMigrationRepo;
pub use index_replica_repo::IndexReplicaRepo;
pub use invoice_repo::InvoiceRepo;
pub use pg_algolia_import_job_repo::PgAlgoliaImportJobRepo;
pub use pg_api_key_repo::PgApiKeyRepo;
pub use pg_cold_snapshot_repo::PgColdSnapshotRepo;
pub use pg_customer_repo::PgCustomerRepo;
pub use pg_deployment_repo::PgDeploymentRepo;
pub use pg_dispute_repo::PgDisputeRepo;
pub use pg_index_migration_repo::PgIndexMigrationRepo;
pub use pg_index_replica_repo::PgIndexReplicaRepo;
pub use pg_invoice_repo::PgInvoiceRepo;
pub use pg_rate_card_repo::PgRateCardRepo;
pub use pg_restore_job_repo::PgRestoreJobRepo;
pub use pg_storage_bucket_repo::PgStorageBucketRepo;
pub use pg_storage_key_repo::PgStorageKeyRepo;
pub use pg_tenant_repo::PgTenantRepo;
pub use pg_usage_repo::PgUsageRepo;
pub use pg_vm_host_metrics_repo::PgVmHostMetricsRepo;
pub use pg_vm_inventory_repo::PgVmInventoryRepo;
pub use pg_webhook_event_repo::PgWebhookEventRepo;
pub use rate_card_repo::RateCardRepo;
pub use restore_job_repo::RestoreJobRepo;
pub use storage_bucket_repo::StorageBucketRepo;
pub use storage_key_repo::StorageKeyRepo;
pub use tenant_repo::TenantRepo;
pub use usage_repo::UsageRepo;
pub use vm_host_metrics_repo::VmHostMetricsRepo;
pub use vm_inventory_repo::{
    VmDecommissionResult, VmInventoryRepo, VmRetirementAssessment, VmRetirementBlocker,
    VmRetirementConflict,
};
pub use webhook_event_repo::WebhookEventRepo;

#[cfg(test)]
mod tests {
    use std::path::Path;

    #[test]
    fn pg_customer_repo_directory_owns_stage1_query_modules() {
        let repos_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/repos");

        assert!(
            repos_dir.join("pg_customer_repo/mod.rs").is_file(),
            "PgCustomerRepo must be a directory module owner"
        );
        assert!(
            repos_dir.join("pg_customer_repo/queries.rs").is_file(),
            "Stage 1 query methods must live in the PgCustomerRepo directory"
        );
        assert!(
            repos_dir.join("pg_customer_repo/projection.rs").is_file(),
            "customer projection SQL must live beside the query seam"
        );
        assert!(
            !repos_dir.join("pg_customer_repo_columns.rs").exists(),
            "the flat projection sibling must be removed after relocation"
        );
    }

    #[test]
    fn pg_customer_repo_directory_owns_stage2_mutation_modules() {
        let repos_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/repos");
        let pg_customer_repo_dir = repos_dir.join("pg_customer_repo");

        for module in [
            "billing.rs",
            "lifecycle.rs",
            "lockout.rs",
            "password_reset.rs",
            "quota_warning.rs",
            "verification.rs",
        ] {
            assert!(
                pg_customer_repo_dir.join(module).is_file(),
                "Stage 2 mutation module {module} must live in the PgCustomerRepo directory"
            );
        }

        for flat_sibling in [
            "pg_customer_repo_password_reset_resend.rs",
            "pg_customer_repo_quota_warning.rs",
        ] {
            assert!(
                !repos_dir.join(flat_sibling).exists(),
                "Stage 2 helper {flat_sibling} must be nested under pg_customer_repo"
            );
        }
    }
}
