use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use uuid::Uuid;

use crate::repos::{
    AlgoliaImportJobRepo, CatalogLifecycleTargetGuard, CatalogLifecycleTargetIdentity,
    PgAlgoliaImportJobRepo, RepoError,
};

/// Test-only hook fired while a lifecycle guard is held, immediately before the
/// guarded service mutation runs. Integration tests use it to prove — without
/// timing races — that an open service window excludes competing catalog
/// admission. Production always leaves this unset; it is wired only through
/// service `*_for_tests` constructors.
pub type LifecycleGuardPauseHook =
    Arc<dyn Fn() -> Pin<Box<dyn Future<Output = ()> + Send>> + Send + Sync>;

#[derive(Clone)]
pub struct IndexLifecycleLease {
    import_jobs: Arc<PgAlgoliaImportJobRepo>,
}

impl IndexLifecycleLease {
    pub fn new(repo: PgAlgoliaImportJobRepo) -> Self {
        Self {
            import_jobs: Arc::new(repo),
        }
    }

    pub async fn begin(
        &self,
        customer_id: Uuid,
        logical_target: &str,
    ) -> Result<CatalogLifecycleTargetGuard, RepoError> {
        self.import_jobs
            .begin_lifecycle_target_guard(customer_id, logical_target)
            .await
    }

    pub async fn commit(
        &self,
        guard: CatalogLifecycleTargetGuard,
        expected_identity: Option<&CatalogLifecycleTargetIdentity>,
    ) -> Result<(), RepoError> {
        self.import_jobs
            .commit_lifecycle_target_guard(guard, expected_identity)
            .await
    }

    pub async fn guarded_mutation<F, Fut, T>(
        &self,
        customer_id: Uuid,
        logical_target: &str,
        expected_identity: Option<&CatalogLifecycleTargetIdentity>,
        mutation: F,
    ) -> Result<T, RepoError>
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = Result<T, RepoError>>,
    {
        let mut guard = self.begin(customer_id, logical_target).await?;
        self.import_jobs
            .assert_guarded_target_identity(&mut guard, expected_identity)
            .await?;
        let result = mutation().await?;
        self.commit_without_identity_check(guard).await?;
        Ok(result)
    }

    pub async fn guarded_locked_mutation<F, Fut, T>(
        &self,
        customer_id: Uuid,
        logical_target: &str,
        mutation: F,
    ) -> Result<T, RepoError>
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = Result<T, RepoError>>,
    {
        let guard = self.begin(customer_id, logical_target).await?;
        let result = mutation().await?;
        self.commit_without_identity_check(guard).await?;
        Ok(result)
    }

    async fn commit_without_identity_check(
        &self,
        guard: CatalogLifecycleTargetGuard,
    ) -> Result<(), RepoError> {
        self.import_jobs.commit_guarded_target_mutation(guard).await
    }
}
