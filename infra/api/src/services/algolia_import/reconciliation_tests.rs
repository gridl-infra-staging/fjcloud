use std::sync::Arc;

use chrono::{DateTime, Duration, Utc};
use serde_json::json;
use uuid::Uuid;

use crate::models::algolia_import_job::{
    AlgoliaImportEngineAckState, AlgoliaImportErrorCode, AlgoliaImportJobStatus,
    AlgoliaImportPublicationDisposition,
};
use crate::repos::{
    AlgoliaImportTerminalFinalizationAuthority, AlgoliaImportTerminalFinalizationOutcome,
};
use crate::services::alerting::MockAlertService;

use super::reconciliation::AlgoliaImportReconciliationRuntime;
use super::reconciliation_test_support::{
    config, harness, job, response, vm, FakeReconciliationStore, FixedVmRepo, ENGINE_JOB_ID,
};

#[tokio::test]
async fn reconcile_once_persists_monotonic_running_progress_and_clears_only_unavailable() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let store = Arc::new(FakeReconciliationStore::new(job(now, vm_id)));
    let alert_service = Arc::new(MockAlertService::new());
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo {
            vm: Some(vm(now, vm_id)),
        }),
        alert_service.clone(),
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

    assert_eq!(report.claimed, 1);
    assert_eq!(report.persisted, 1);
    assert_eq!(report.terminal_finalized, 0);
    let writes = store.writes();
    assert_eq!(writes.len(), 1);
    assert_eq!(writes[0].status, AlgoliaImportJobStatus::Verifying);
    assert_eq!(writes[0].summary.documents_imported, 12);
    assert_eq!(writes[0].error_code, None);
    assert!(!writes[0].retryable);
    assert_eq!(alert_service.alert_count(), 0);
    let requests = http.requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        format!("https://node-1.example/1/migrations/algolia/{ENGINE_JOB_ID}")
    );
    assert_eq!(requests[0].json_body, None);
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

#[tokio::test]
async fn reconcile_once_finalizes_terminal_fact_with_reconciliation_lease() {
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

    assert_eq!(report.claimed, 1);
    assert_eq!(report.persisted, 0);
    assert_eq!(report.terminal_finalized, 1);
    assert!(store.writes().is_empty());
    let finalizations = store.finalizations();
    assert_eq!(finalizations.len(), 1);
    let recorded = &finalizations[0];
    let AlgoliaImportTerminalFinalizationAuthority::ReconciliationLease(lease) =
        &recorded.authority
    else {
        panic!("reconciliation must finalize with its exact lease");
    };
    assert_eq!(lease.job_id, store.current_job().id);
    assert_eq!(lease.lifecycle_generation, 3);
    assert_eq!(lease.claimed_at, now);
    assert_eq!(lease.expires_at, now + config().lease_duration);
    assert_eq!(
        recorded.fact.engine_job_id,
        Uuid::parse_str(ENGINE_JOB_ID).unwrap()
    );
    assert_eq!(recorded.fact.status, AlgoliaImportJobStatus::Completed);
    assert_eq!(
        recorded.fact.publication_disposition,
        AlgoliaImportPublicationDisposition::Promoted
    );
    assert_eq!(
        recorded.fact.terminal_at,
        "2026-07-22T00:00:02Z".parse::<DateTime<Utc>>().unwrap()
    );
    assert_eq!(store.acknowledgements(), vec![store.current_job().id]);
    let requests = http.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(requests[1].method, reqwest::Method::POST);
    assert!(requests[1].url.ends_with("/acknowledge"));
}

#[tokio::test]
async fn reconcile_once_acknowledges_engine_only_after_durable_terminal_finalization() {
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

    assert_eq!(report.claimed, 1);
    assert_eq!(report.terminal_finalized, 1);
    assert_eq!(store.finalizations().len(), 1);
    assert_eq!(store.acknowledgements(), vec![store.current_job().id]);
    assert_eq!(
        store.current_job().engine_ack_state,
        AlgoliaImportEngineAckState::Acknowledged
    );
    let requests = http.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(requests[1].method, reqwest::Method::POST);
    assert_eq!(
        requests[1].url,
        format!("https://node-1.example/1/migrations/algolia/{ENGINE_JOB_ID}/acknowledge")
    );
    assert_eq!(requests[1].json_body, None);
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

#[tokio::test]
async fn reconcile_once_alerts_rejected_terminal_finalization() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let mut retained = job(now, vm_id);
    retained.status = AlgoliaImportJobStatus::Promoting;
    retained.error_code = None;
    retained.retryable = false;
    let store = Arc::new(FakeReconciliationStore::with_terminal_outcomes(
        retained,
        vec![AlgoliaImportTerminalFinalizationOutcome::Rejected(
            "destination_changed".to_string(),
        )],
    ));
    let alert_service = Arc::new(MockAlertService::new());
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo {
            vm: Some(vm(now, vm_id)),
        }),
        alert_service.clone(),
        config(),
    );
    let (service, _, _) = harness(vec![response(
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
    )])
    .await;

    let report = service.reconcile_once(&runtime, now).await.unwrap();

    assert_eq!(report.terminal_finalized, 0);
    assert_eq!(report.terminal_rejected, 1);
    assert_eq!(report.terminal_already_applied, 0);
    assert_eq!(report.lease_lost, 0);
    assert_eq!(alert_service.alert_count(), 1);
    let alert = &alert_service.recorded_alerts()[0];
    assert_eq!(alert.title, "Algolia import terminal finalization rejected");
    assert_eq!(
        alert.severity,
        crate::services::alerting::AlertSeverity::Critical
    );
    assert_eq!(alert.metadata["reason"], "destination_changed");
}

#[tokio::test]
async fn reconcile_once_counts_already_applied_and_rejected_terminal_outcomes() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let mut retained = job(now, vm_id);
    retained.status = AlgoliaImportJobStatus::Promoting;
    retained.error_code = None;
    retained.retryable = false;
    let mut replayed = retained.clone();
    replayed.status = AlgoliaImportJobStatus::Completed;
    replayed.publication_disposition = AlgoliaImportPublicationDisposition::Promoted;
    replayed.engine_ack_state = AlgoliaImportEngineAckState::OutboxPending;
    replayed.terminal_at = Some(now);
    let store = Arc::new(FakeReconciliationStore::with_terminal_outcomes(
        retained,
        vec![AlgoliaImportTerminalFinalizationOutcome::AlreadyApplied(
            replayed,
        )],
    ));
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

    assert_eq!(report.terminal_finalized, 0);
    assert_eq!(report.terminal_already_applied, 1);
    assert_eq!(report.terminal_rejected, 0);
    assert_eq!(store.acknowledgements(), vec![store.current_job().id]);
    let requests = http.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[1].method, reqwest::Method::POST);
    assert!(requests[1].url.ends_with("/acknowledge"));
}

#[tokio::test]
async fn reconcile_once_does_not_alert_lost_terminal_fence() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let mut retained = job(now, vm_id);
    retained.status = AlgoliaImportJobStatus::Promoting;
    retained.error_code = None;
    retained.retryable = false;
    let store = Arc::new(FakeReconciliationStore::with_terminal_outcomes(
        retained,
        vec![AlgoliaImportTerminalFinalizationOutcome::FenceLost],
    ));
    let alert_service = Arc::new(MockAlertService::new());
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo {
            vm: Some(vm(now, vm_id)),
        }),
        alert_service.clone(),
        config(),
    );
    let (service, _, _) = harness(vec![response(
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
    )])
    .await;

    let report = service.reconcile_once(&runtime, now).await.unwrap();

    assert_eq!(report.terminal_finalized, 0);
    assert_eq!(report.lease_lost, 1);
    assert_eq!(alert_service.alert_count(), 0);
}

#[tokio::test]
async fn reconcile_once_retains_cancel_intent_across_loss_restart_and_promotion_race() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let mut cancelling = job(now, vm_id);
    cancelling.status = AlgoliaImportJobStatus::Cancelling;
    cancelling.cancel_requested_at = Some(now - Duration::seconds(1));
    let original_cancel_requested_at = cancelling.cancel_requested_at;
    let store = Arc::new(FakeReconciliationStore::new(cancelling));
    let alert_service = Arc::new(MockAlertService::new());
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo {
            vm: Some(vm(now, vm_id)),
        }),
        alert_service.clone(),
        config(),
    );
    let (service, http, _) = harness(vec![
        response(404, json!({"code": "migration_job_not_found"})),
        response(
            200,
            json!({
                "jobId": ENGINE_JOB_ID,
                "phase": "staging",
                "disposition": "running",
                "createdAt": "2026-07-22T00:00:00Z",
                "updatedAt": "2026-07-22T00:00:01Z",
                "exportProgress": {"completed": 12, "total": 20}
            }),
        ),
        response(
            200,
            json!({
                "jobId": ENGINE_JOB_ID,
                "phase": "activating",
                "disposition": "succeeded",
                "createdAt": "2026-07-22T00:00:00Z",
                "updatedAt": "2026-07-22T00:00:02Z",
                "terminalAt": "2026-07-22T00:00:02Z",
                "exportProgress": {"completed": 20, "total": 20}
            }),
        ),
        response(204, json!({})),
    ])
    .await;

    let lost = service.reconcile_once(&runtime, now).await.unwrap();
    assert_eq!(lost.persisted, 1);
    assert_eq!(lost.terminal_finalized, 0);
    assert_eq!(
        store.current_job().status,
        AlgoliaImportJobStatus::Cancelling
    );

    let restarted = service
        .reconcile_once(
            &runtime,
            now + config().lease_duration + Duration::seconds(1),
        )
        .await
        .unwrap();
    assert_eq!(restarted.persisted, 1);
    assert_eq!(restarted.terminal_finalized, 0);
    let restarted_job = store.current_job();
    assert_eq!(restarted_job.status, AlgoliaImportJobStatus::Cancelling);
    assert_eq!(restarted_job.summary.documents_imported, 12);
    assert_eq!(restarted_job.error_code, None);
    assert_eq!(
        restarted_job.cancel_requested_at,
        original_cancel_requested_at
    );

    let promoted = service
        .reconcile_once(
            &runtime,
            now + config().lease_duration * 2 + Duration::seconds(2),
        )
        .await
        .unwrap();
    assert_eq!(promoted.persisted, 0);
    assert_eq!(promoted.terminal_finalized, 1);
    assert_eq!(
        store.current_job().status,
        AlgoliaImportJobStatus::Completed
    );
    assert_eq!(
        store.current_job().cancel_requested_at,
        original_cancel_requested_at
    );
    assert_eq!(store.writes().len(), 2);
    assert_eq!(store.claim_calls(), 3);
    let requests = http.requests.lock().unwrap();
    assert_eq!(requests.len(), 4);
    assert!(requests[..3].iter().all(|request| {
        request.method == reqwest::Method::GET
            && request.json_body.is_none()
            && request.url.ends_with(ENGINE_JOB_ID)
    }));
    assert_eq!(requests[3].method, reqwest::Method::POST);
    assert!(requests[3].url.ends_with("/acknowledge"));
    assert_eq!(requests[3].json_body, None);
}

#[tokio::test]
async fn reconciliation_loop_honors_an_already_requested_shutdown_without_claiming() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let store = Arc::new(FakeReconciliationStore::new(job(now, vm_id)));
    let runtime = AlgoliaImportReconciliationRuntime::new(
        store.clone(),
        Arc::new(FixedVmRepo { vm: None }),
        Arc::new(MockAlertService::new()),
        config(),
    );
    let (service, _, _) = harness(Vec::new()).await;
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(true);

    service.run_reconciliation_loop(runtime, shutdown_rx).await;

    assert_eq!(store.claim_calls(), 0);
    drop(shutdown_tx);
}
