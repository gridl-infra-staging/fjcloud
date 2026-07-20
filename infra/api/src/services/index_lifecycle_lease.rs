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

    /// Runs `mutation` while holding the lifecycle guard for `logical_target`.
    ///
    /// Generic over the mutation's error type so callers that already carry a
    /// status-bearing error (e.g. `ApiError::ServiceUnavailable` from shared-VM
    /// auto-provisioning) keep that status instead of collapsing it into
    /// `RepoError::Other`, which would surface as a 500. Guard errors raised by
    /// this method are lifted through `E: From<RepoError>`, so existing
    /// `RepoError` callers are unaffected.
    pub async fn guarded_locked_mutation<F, Fut, T, E>(
        &self,
        customer_id: Uuid,
        logical_target: &str,
        mutation: F,
    ) -> Result<T, E>
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = Result<T, E>>,
        E: From<RepoError>,
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

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    use sqlx::postgres::PgPoolOptions;
    use tokio::sync::{mpsc, oneshot};

    use super::*;

    fn dead_pool_lease() -> IndexLifecycleLease {
        let pool = PgPoolOptions::new()
            .max_connections(2)
            .acquire_timeout(Duration::from_millis(200))
            .connect_lazy("postgres://test:test@127.0.0.1:1/test")
            .expect("connect_lazy should not connect");
        IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(pool))
    }

    #[tokio::test]
    async fn dead_pool_fallback_runs_mutation() {
        let lease = dead_pool_lease();
        let calls = Arc::new(AtomicUsize::new(0));
        let customer_id = Uuid::new_v4();

        let result = lease
            .guarded_locked_mutation(customer_id, "products", {
                let calls = Arc::clone(&calls);
                move || async move {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Ok::<_, RepoError>(42)
                }
            })
            .await;

        assert_eq!(result.expect("dead pool should use fallback guard"), 42);
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "mutation callback must run exactly once"
        );
    }

    #[tokio::test]
    async fn dead_pool_fallback_serializes_same_target() {
        let lease = Arc::new(dead_pool_lease());
        let customer_id = Uuid::new_v4();
        let (events_tx, mut events_rx) = mpsc::unbounded_channel::<&'static str>();
        let (release_tx, release_rx) = oneshot::channel::<()>();

        let first = {
            let lease = Arc::clone(&lease);
            let events_tx = events_tx.clone();
            tokio::spawn(async move {
                lease
                    .guarded_locked_mutation(customer_id, "products", move || async move {
                        events_tx.send("first_entered").expect("event receiver");
                        release_rx.await.expect("release first mutation");
                        events_tx.send("first_released").expect("event receiver");
                        Ok::<_, RepoError>("first")
                    })
                    .await
            })
        };

        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), events_rx.recv())
                .await
                .expect("first mutation should enter")
                .expect("first event"),
            "first_entered"
        );

        let second = {
            let lease = Arc::clone(&lease);
            let events_tx = events_tx.clone();
            tokio::spawn(async move {
                lease
                    .guarded_locked_mutation(customer_id, "products", move || async move {
                        events_tx.send("second_entered").expect("event receiver");
                        Ok::<_, RepoError>("second")
                    })
                    .await
            })
        };

        assert!(
            tokio::time::timeout(Duration::from_millis(350), events_rx.recv())
                .await
                .is_err(),
            "competing same-target mutation must not enter while first guard is held"
        );

        release_tx.send(()).expect("release first mutation");
        assert_eq!(
            first
                .await
                .expect("first task")
                .expect("first mutation result"),
            "first"
        );
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), events_rx.recv())
                .await
                .expect("second mutation should enter after release")
                .expect("second event"),
            "first_released"
        );
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), events_rx.recv())
                .await
                .expect("second mutation should enter after release")
                .expect("second event"),
            "second_entered"
        );
        assert_eq!(
            second
                .await
                .expect("second task")
                .expect("second mutation result"),
            "second"
        );
    }
}
