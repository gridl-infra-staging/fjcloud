use super::*;

#[derive(Clone, Copy)]
enum SoftDeleteBoundary {
    PrePromotion,
    Cancelling,
    CancelledBeforeAck,
    TerminalFailed,
    PostPromotion,
}

impl SoftDeleteBoundary {
    fn schema_prefix(self) -> &'static str {
        match self {
            Self::PrePromotion => "algolia_soft_delete_pre_promotion",
            Self::Cancelling => "algolia_soft_delete_cancelling",
            Self::CancelledBeforeAck => "algolia_soft_delete_cancelled",
            Self::TerminalFailed => "algolia_soft_delete_failed",
            Self::PostPromotion => "algolia_soft_delete_post_promotion",
        }
    }

    fn key(self) -> &'static str {
        match self {
            Self::PrePromotion => "pre-promotion",
            Self::Cancelling => "cancelling",
            Self::CancelledBeforeAck => "cancelled-before-ack",
            Self::TerminalFailed => "terminal-failed",
            Self::PostPromotion => "post-promotion",
        }
    }
}

async fn import_at_boundary(
    repo: &PgAlgoliaImportJobRepo,
    pool: &PgPool,
    customer_id: Uuid,
    boundary: SoftDeleteBoundary,
) -> AlgoliaImportJob {
    let running = seed_promoting_race_job(
        repo,
        pool,
        customer_id,
        FinalizationRaceImportKind::Replace,
        boundary.key(),
    )
    .await;
    match boundary {
        SoftDeleteBoundary::PrePromotion => running,
        SoftDeleteBoundary::Cancelling => request_cancel(repo, running).await,
        SoftDeleteBoundary::CancelledBeforeAck => {
            let cancelling = request_cancel(repo, running).await;
            finalize_boundary(
                repo,
                cancelling,
                AlgoliaImportJobStatus::Cancelled,
                AlgoliaImportPublicationDisposition::Unchanged,
            )
            .await
        }
        SoftDeleteBoundary::TerminalFailed => {
            finalize_boundary(
                repo,
                running,
                AlgoliaImportJobStatus::Failed,
                AlgoliaImportPublicationDisposition::Unchanged,
            )
            .await
        }
        SoftDeleteBoundary::PostPromotion => {
            finalize_boundary(
                repo,
                running,
                AlgoliaImportJobStatus::Completed,
                AlgoliaImportPublicationDisposition::Promoted,
            )
            .await
        }
    }
}

async fn request_cancel(
    repo: &PgAlgoliaImportJobRepo,
    running: AlgoliaImportJob,
) -> AlgoliaImportJob {
    repo.request_cancel(running.id)
        .await
        .expect("request cancellation at soft-delete boundary")
        .job
}

async fn finalize_boundary(
    repo: &PgAlgoliaImportJobRepo,
    current: AlgoliaImportJob,
    status: AlgoliaImportJobStatus,
    disposition: AlgoliaImportPublicationDisposition,
) -> AlgoliaImportJob {
    let claim = claim_for_finalization(repo, current.id).await;
    let outcome = repo
        .finalize_terminal_observation(
            AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(claim.lease),
            matrix_terminal_fact(
                current
                    .engine_job_id
                    .expect("boundary fixture is linked to an engine job"),
                status,
                disposition,
                postgres_timestamp(Utc::now()),
            ),
        )
        .await
        .expect("finalize soft-delete boundary through production repository");
    let AlgoliaImportTerminalFinalizationOutcome::Applied(finalized) = outcome else {
        panic!("soft-delete boundary finalization must apply");
    };
    finalized
}

fn assert_import_identity_retained(before: &AlgoliaImportJob, after: &AlgoliaImportJob) {
    assert_eq!(after.id, before.id);
    assert_eq!(after.customer_id, before.customer_id);
    assert_eq!(after.algolia_app_id, before.algolia_app_id);
    assert_eq!(after.source_name, before.source_name);
    assert_eq!(after.logical_target, before.logical_target);
    assert_eq!(after.canonical_fingerprint, before.canonical_fingerprint);
    assert_eq!(after.cloud_job_id, before.cloud_job_id);
    assert_eq!(after.engine_job_id, before.engine_job_id);
    assert_eq!(after.destination_vm_id, before.destination_vm_id);
    assert_eq!(after.physical_uid, before.physical_uid);
    assert_eq!(after.routing_identity, before.routing_identity);
}

async fn assert_soft_delete_boundary(boundary: SoftDeleteBoundary) {
    let live_binding = CatalogLiveBinding::begin().await;
    let db = connect_and_migrate_required(boundary.schema_prefix()).await;
    let import_repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_repo = PgCustomerRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let before = import_at_boundary(&import_repo, &db.pool, customer_id, boundary).await;

    assert_catalog_counts(&db.pool, customer_id, 1, boundary.key()).await;
    assert!(has_active_reservation(&db.pool, before.id).await);
    assert!(
        customer_repo
            .soft_delete(customer_id)
            .await
            .expect("soft delete through production customer repository"),
        "{}: active customer must transition to deleted",
        boundary.key()
    );

    assert_customer_soft_deleted_generation(
        &db.pool,
        customer_id,
        before.lifecycle_generation,
        boundary.key(),
    )
    .await;
    assert_claim_excludes_job(&import_repo, before.id, boundary.key()).await;
    let retained = import_repo
        .get(before.id)
        .await
        .expect("read retained import after soft delete")
        .expect("soft delete must retain import evidence");
    if before.status.is_terminal() {
        assert_terminal_snapshot(&retained, &before, boundary.key());
    } else {
        assert_unfinalized_snapshot_unchanged(&before, &retained, boundary.key());
    }
    assert_import_identity_retained(&before, &retained);
    assert_catalog_counts(&db.pool, customer_id, 1, boundary.key()).await;
    assert!(has_active_reservation(&db.pool, retained.id).await);
    assert_any_ack_conflict(
        import_repo.mark_engine_acknowledged(retained.id).await,
        "soft-deleted import must remain ACK-fenced",
    );
    if let Some(binding) = live_binding {
        binding.finish().await;
    }
}

#[tokio::test]
async fn soft_delete_pre_promotion_retains_target_and_fences_ack() {
    assert_soft_delete_boundary(SoftDeleteBoundary::PrePromotion).await;
}

#[tokio::test]
async fn soft_delete_cancelling_retains_target_and_fences_ack() {
    assert_soft_delete_boundary(SoftDeleteBoundary::Cancelling).await;
}

#[tokio::test]
async fn soft_delete_cancelled_before_ack_retains_target_and_fences_ack() {
    assert_soft_delete_boundary(SoftDeleteBoundary::CancelledBeforeAck).await;
}

#[tokio::test]
async fn soft_delete_terminal_failed_retains_target_and_fences_ack() {
    assert_soft_delete_boundary(SoftDeleteBoundary::TerminalFailed).await;
}

#[tokio::test]
async fn soft_delete_post_promotion_retains_target_and_fences_ack() {
    assert_soft_delete_boundary(SoftDeleteBoundary::PostPromotion).await;
}
