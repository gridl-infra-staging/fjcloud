use std::sync::Arc;

use chrono::{Duration, Utc};
use serde_json::json;
use uuid::Uuid;

use crate::models::algolia_import_job::{
    AlgoliaImportEngineAckState, AlgoliaImportErrorCode, AlgoliaImportJobStatus,
    AlgoliaImportPublicationDisposition, SourceImportProvider,
};
use crate::services::alerting::MockAlertService;

use super::reconciliation::{AlgoliaImportReconciliationRuntime, ENGINE_STATUS_ABSENCE_GRACE};
use super::reconciliation_test_support::{
    config, harness, job, response, vm, FakeReconciliationStore, FixedVmRepo, ENGINE_JOB_ID,
};

#[tokio::test]
async fn reconcile_once_polls_retained_job_source_provider_route() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let mut retained = job(now, vm_id);
    retained.source_provider = SourceImportProvider::Meilisearch;
    let store = Arc::new(FakeReconciliationStore::new(retained));
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo {
            vm: Some(vm(now, vm_id)),
        }),
        Arc::new(MockAlertService::new()),
        config(),
    );
    let (service, http, _) = harness(vec![response(
        200,
        json!({
            "jobId": ENGINE_JOB_ID,
            "phase": "staging",
            "disposition": "running",
            "createdAt": "2026-07-22T00:00:00Z",
            "updatedAt": "2026-07-22T00:00:01Z",
            "exportProgress": {"completed": 12, "total": 20}
        }),
    )])
    .await;

    let report = service.reconcile_once(&runtime, now).await.unwrap();

    assert_eq!(report.persisted, 1);
    let requests = http.requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        format!("https://node-1.example/1/migrations/meilisearch/{ENGINE_JOB_ID}")
    );
}

#[tokio::test]
async fn reconcile_once_deduplicates_retained_unavailable_alerts_from_persisted_state() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let mut retained = job(now, vm_id);
    retained.error_code = None;
    retained.retryable = false;
    let store = Arc::new(FakeReconciliationStore::new(retained));
    let alert_service = Arc::new(MockAlertService::new());
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo {
            vm: Some(vm(now, vm_id)),
        }),
        alert_service.clone(),
        config(),
    );
    let not_found = || response(404, json!({"code": "migration_job_not_found"}));
    let (service, _, _) = harness(vec![not_found(), not_found()]).await;

    service.reconcile_once(&runtime, now).await.unwrap();
    service
        .reconcile_once(&runtime, now + Duration::seconds(1))
        .await
        .unwrap();

    let writes = store.writes();
    assert_eq!(writes.len(), 2);
    assert!(writes.iter().all(|state| {
        state.error_code == Some(AlgoliaImportErrorCode::BackendUnavailable) && state.retryable
    }));
    assert_eq!(alert_service.alert_count(), 1);
    let alert = &alert_service.recorded_alerts()[0];
    let serialized = serde_json::to_string(alert).unwrap();
    assert!(!serialized.contains("private-physical-uid"));
}

/// A status 404 is a transient engine loss inside the grace window — the
/// sibling dedup test proves it keeps retrying there. Past the grace the same
/// affirmation means the engine will never account for this job again, so the
/// retained row must fail closed instead of holding its node import reservation
/// forever and wedging the node against the active node import limit.
#[tokio::test]
async fn reconcile_once_fails_an_import_the_engine_has_disowned_past_the_status_grace() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let mut retained = job(now, vm_id);
    retained.status = AlgoliaImportJobStatus::Queued;
    retained.error_code = None;
    retained.retryable = false;
    let store = Arc::new(FakeReconciliationStore::new(retained));
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo {
            vm: Some(vm(now, vm_id)),
        }),
        Arc::new(MockAlertService::new()),
        config(),
    );
    let not_found = || response(404, json!({"code": "migration_job_not_found"}));
    let (service, http, _) = harness(vec![not_found(), not_found(), not_found()]).await;

    let first = service.reconcile_once(&runtime, now).await.unwrap();

    assert_eq!(first.persisted, 1);
    assert_eq!(first.terminal_finalized, 0);
    assert_eq!(store.current_job().status, AlgoliaImportJobStatus::Queued);

    let expired_at = now + ENGINE_STATUS_ABSENCE_GRACE + Duration::seconds(1);
    let expired = service.reconcile_once(&runtime, expired_at).await.unwrap();

    assert_eq!(expired.persisted, 0);
    assert_eq!(expired.terminal_finalized, 1);
    let finalizations = store.finalizations();
    assert_eq!(finalizations.len(), 1);
    assert_eq!(finalizations[0].fact.status, AlgoliaImportJobStatus::Failed);
    assert_eq!(
        finalizations[0].fact.publication_disposition,
        AlgoliaImportPublicationDisposition::Unchanged
    );
    assert_eq!(finalizations[0].fact.terminal_at, expired_at);
    assert_eq!(
        finalizations[0].fact.error_code,
        Some(AlgoliaImportErrorCode::BackendUnavailable)
    );
    let finalized = store.current_job();
    assert_eq!(finalized.status, AlgoliaImportJobStatus::Failed);
    assert_eq!(
        finalized.publication_disposition,
        AlgoliaImportPublicationDisposition::Unchanged
    );
    assert!(!finalized.retryable);
    assert_eq!(
        finalized.engine_ack_state,
        AlgoliaImportEngineAckState::Acknowledged
    );
    assert_eq!(store.acknowledgements(), vec![finalized.id]);
    let requests = http.requests.lock().unwrap();
    assert_eq!(requests.len(), 3);
    assert!(requests[..2]
        .iter()
        .all(|request| request.method == reqwest::Method::GET));
    assert_eq!(requests[2].method, reqwest::Method::POST);
    assert!(requests[2].url.ends_with("/acknowledge"));
}

/// Pins the grace boundary itself: at exactly the grace the engine is still
/// inside its recovery window, so the observation must keep retrying.
#[tokio::test]
async fn reconcile_once_still_retries_a_disowned_import_at_the_grace_boundary() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let mut retained = job(now, vm_id);
    retained.status = AlgoliaImportJobStatus::Queued;
    retained.error_code = None;
    retained.retryable = false;
    let store = Arc::new(FakeReconciliationStore::new(retained));
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo {
            vm: Some(vm(now, vm_id)),
        }),
        Arc::new(MockAlertService::new()),
        config(),
    );
    let not_found = || response(404, json!({"code": "migration_job_not_found"}));
    let (service, _, _) = harness(vec![not_found(), not_found()]).await;

    service.reconcile_once(&runtime, now).await.unwrap();
    let boundary = service
        .reconcile_once(&runtime, now + ENGINE_STATUS_ABSENCE_GRACE)
        .await
        .unwrap();

    assert_eq!(boundary.persisted, 1);
    assert_eq!(boundary.terminal_finalized, 0);
    assert!(store.finalizations().is_empty());
    assert_eq!(store.current_job().status, AlgoliaImportJobStatus::Queued);
}

/// TODO: Document reconcile_once_finalizes_terminal_fact_with_reconciliation_lease.
#[tokio::test]
async fn reconcile_once_acknowledges_retained_job_source_provider_route() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let mut retained = job(now, vm_id);
    retained.source_provider = SourceImportProvider::Typesense;
    retained.status = AlgoliaImportJobStatus::Promoting;
    retained.error_code = None;
    retained.retryable = false;
    let store = Arc::new(FakeReconciliationStore::new(retained));
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo {
            vm: Some(vm(now, vm_id)),
        }),
        Arc::new(MockAlertService::new()),
        config(),
    );
    let (service, http, _) = harness(vec![
        response(
            200,
            json!({
                "jobId": ENGINE_JOB_ID,
                "phase": "activating",
                "disposition": "succeeded",
                "createdAt": "2026-07-22T00:00:00Z",
                "updatedAt": "2026-07-22T00:00:01Z",
                "terminalAt": "2026-07-22T00:00:02Z",
                "exportProgress": {"completed": 20, "total": 20}
            }),
        ),
        response(204, json!({})),
    ])
    .await;

    let report = service.reconcile_once(&runtime, now).await.unwrap();

    assert_eq!(report.terminal_finalized, 1);
    assert_eq!(store.acknowledgements(), vec![store.current_job().id]);
    let requests = http.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert_eq!(
        requests[0].url,
        format!("https://node-1.example/1/migrations/typesense/{ENGINE_JOB_ID}")
    );
    assert_eq!(
        requests[1].url,
        format!("https://node-1.example/1/migrations/typesense/{ENGINE_JOB_ID}/acknowledge")
    );
}
#[tokio::test]
async fn reconcile_once_retains_outbox_when_engine_ack_send_fails() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let mut retained = job(now, vm_id);
    retained.status = AlgoliaImportJobStatus::Promoting;
    retained.error_code = None;
    retained.retryable = false;
    let store = Arc::new(FakeReconciliationStore::new(retained));
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo {
            vm: Some(vm(now, vm_id)),
        }),
        Arc::new(MockAlertService::new()),
        config(),
    );
    let (service, _, _) = harness(vec![
        response(
            200,
            json!({
                "jobId": ENGINE_JOB_ID,
                "phase": "activating",
                "disposition": "succeeded",
                "createdAt": "2026-07-22T00:00:00Z",
                "updatedAt": "2026-07-22T00:00:01Z",
                "terminalAt": "2026-07-22T00:00:02Z",
                "exportProgress": {"completed": 20, "total": 20}
            }),
        ),
        response(503, json!({"code": "ack_unavailable"})),
    ])
    .await;

    let report = service.reconcile_once(&runtime, now).await.unwrap();

    assert_eq!(report.terminal_finalized, 1);
    assert!(store.acknowledgements().is_empty());
    assert_eq!(
        store.current_job().engine_ack_state,
        AlgoliaImportEngineAckState::OutboxPending
    );
}

/// The pinned engine contract defines acknowledge HTTP 404 as `missing_job`:
/// "No durable migration phase record is currently retained for the UUID". There
/// is nothing left for the engine to acknowledge, so retrying forever would pin
/// the job's node import reservation permanently and eventually wedge the node
/// against `DEFAULT_ACTIVE_NODE_IMPORT_JOB_LIMIT`.
#[tokio::test]
async fn reconcile_once_finalizes_engine_ack_when_engine_no_longer_retains_the_job() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let mut retained = job(now, vm_id);
    retained.status = AlgoliaImportJobStatus::Promoting;
    retained.error_code = None;
    retained.retryable = false;
    let store = Arc::new(FakeReconciliationStore::new(retained));
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo {
            vm: Some(vm(now, vm_id)),
        }),
        Arc::new(MockAlertService::new()),
        config(),
    );
    let (service, _, _) = harness(vec![
        response(
            200,
            json!({
                "jobId": ENGINE_JOB_ID,
                "phase": "activating",
                "disposition": "succeeded",
                "createdAt": "2026-07-22T00:00:00Z",
                "updatedAt": "2026-07-22T00:00:01Z",
                "terminalAt": "2026-07-22T00:00:02Z",
                "exportProgress": {"completed": 20, "total": 20}
            }),
        ),
        // No `code` field: the classification must come from the pinned status.
        response(404, json!({"error": "no retained migration phase record"})),
    ])
    .await;

    let report = service.reconcile_once(&runtime, now).await.unwrap();

    assert_eq!(report.terminal_finalized, 1);
    assert_eq!(store.acknowledgements(), vec![store.current_job().id]);
    assert_eq!(
        store.current_job().engine_ack_state,
        AlgoliaImportEngineAckState::Acknowledged
    );
}
#[tokio::test]
async fn reconcile_once_finalizes_engine_ack_when_terminal_generation_is_superseded() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let mut retained = job(now, vm_id);
    retained.status = AlgoliaImportJobStatus::Promoting;
    retained.error_code = None;
    retained.retryable = false;
    let store = Arc::new(FakeReconciliationStore::new(retained));
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo {
            vm: Some(vm(now, vm_id)),
        }),
        Arc::new(MockAlertService::new()),
        config(),
    );
    let (service, _, _) = harness(vec![
        response(
            200,
            json!({
                "jobId": ENGINE_JOB_ID,
                "phase": "activating",
                "disposition": "succeeded",
                "createdAt": "2026-07-22T00:00:00Z",
                "updatedAt": "2026-07-22T00:00:01Z",
                "terminalAt": "2026-07-22T00:00:02Z",
                "exportProgress": {"completed": 20, "total": 20}
            }),
        ),
        response(
            409,
            json!({
                "status": 409,
                "code": "migration_ack_stale_generation",
                "message": "Migration publication generation evidence is stale or unavailable"
            }),
        ),
    ])
    .await;

    let report = service.reconcile_once(&runtime, now).await.unwrap();

    assert_eq!(report.terminal_finalized, 1);
    assert_eq!(store.acknowledgements(), vec![store.current_job().id]);
    assert_eq!(
        store.current_job().engine_ack_state,
        AlgoliaImportEngineAckState::Acknowledged
    );
}
