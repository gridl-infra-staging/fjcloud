use chrono::{DateTime, Utc};
use serde_json::json;
use uuid::Uuid;

use crate::models::algolia_import_job::{
    AlgoliaImportDestinationKind, AlgoliaImportJobStatus, AlgoliaImportPublicationDisposition,
    AlgoliaImportSummary,
};

use super::{
    AlgoliaImportObservationCursor, AlgoliaImportService, AlgoliaImportStatusObservation,
    AlgoliaImportStatusObservationError, AsyncMigrationPhase, AsyncMigrationStatusResponse,
};

const ENGINE_JOB_ID: &str = "9f11d0a0-4443-44d4-b6c6-1ed71dbeb0fb";

fn cursor(
    destination_kind: AlgoliaImportDestinationKind,
    status: AlgoliaImportJobStatus,
    summary: AlgoliaImportSummary,
) -> AlgoliaImportObservationCursor {
    AlgoliaImportObservationCursor::new(
        Uuid::parse_str(ENGINE_JOB_ID).unwrap(),
        destination_kind,
        status,
        summary,
    )
}

fn response(
    phase: AsyncMigrationPhase,
    disposition: &str,
    completed: u64,
    total: u64,
) -> AsyncMigrationStatusResponse {
    let terminal_at = (disposition != "running").then_some(json!("2026-07-22T00:00:02Z"));
    serde_json::from_value(json!({
        "jobId": ENGINE_JOB_ID,
        "phase": phase,
        "disposition": disposition,
        "createdAt": "2026-07-22T00:00:00Z",
        "updatedAt": "2026-07-22T00:00:01Z",
        "exportProgress": {"completed": completed, "total": total},
        "terminalAt": terminal_at,
    }))
    .unwrap()
}

#[test]
fn status_observation_maps_every_running_phase_to_the_canonical_cloud_sequence() {
    let cases = [
        (
            AsyncMigrationPhase::Submitted,
            AlgoliaImportJobStatus::ValidatingSource,
        ),
        (
            AsyncMigrationPhase::Exporting,
            AlgoliaImportJobStatus::CopyingConfiguration,
        ),
        (
            AsyncMigrationPhase::Preparing,
            AlgoliaImportJobStatus::CopyingDocuments,
        ),
        (
            AsyncMigrationPhase::Staging,
            AlgoliaImportJobStatus::Verifying,
        ),
        (
            AsyncMigrationPhase::Activating,
            AlgoliaImportJobStatus::Promoting,
        ),
    ];

    for (phase, expected_status) in cases {
        let observed = AlgoliaImportService::map_status_observation(
            &cursor(
                AlgoliaImportDestinationKind::Create,
                AlgoliaImportJobStatus::Queued,
                AlgoliaImportSummary::default(),
            ),
            response(phase, "running", 12, 20),
        )
        .unwrap();
        let AlgoliaImportStatusObservation::Running(observed) = observed else {
            panic!("{phase:?} must remain running");
        };
        assert_eq!(observed.status, expected_status, "{phase:?}");
        assert_eq!(observed.summary.documents_expected, 20, "{phase:?}");
        assert_eq!(observed.summary.documents_imported, 12, "{phase:?}");
    }
}

#[test]
fn status_observation_maps_only_the_pinned_terminal_outcomes() {
    let cases = [
        (
            AlgoliaImportDestinationKind::Create,
            "succeeded",
            AlgoliaImportJobStatus::Completed,
            AlgoliaImportPublicationDisposition::Promoted,
        ),
        (
            AlgoliaImportDestinationKind::Create,
            "cancelled",
            AlgoliaImportJobStatus::Cancelled,
            AlgoliaImportPublicationDisposition::Unchanged,
        ),
        (
            AlgoliaImportDestinationKind::Create,
            "failed",
            AlgoliaImportJobStatus::Failed,
            AlgoliaImportPublicationDisposition::NotStarted,
        ),
        (
            AlgoliaImportDestinationKind::Replace,
            "failed",
            AlgoliaImportJobStatus::Failed,
            AlgoliaImportPublicationDisposition::Unchanged,
        ),
    ];

    for (kind, disposition, expected_status, expected_publication) in cases {
        let observed = AlgoliaImportService::map_status_observation(
            &cursor(
                kind,
                AlgoliaImportJobStatus::Promoting,
                AlgoliaImportSummary::default(),
            ),
            response(AsyncMigrationPhase::Activating, disposition, 20, 20),
        )
        .unwrap();
        let AlgoliaImportStatusObservation::Terminal(fact) = observed else {
            panic!("{disposition} must produce a terminal fact");
        };
        assert_eq!(fact.engine_job_id, Uuid::parse_str(ENGINE_JOB_ID).unwrap());
        assert_eq!(fact.status, expected_status, "{kind:?} {disposition}");
        assert_eq!(
            fact.publication_disposition, expected_publication,
            "{kind:?} {disposition}"
        );
        assert_eq!(fact.summary.documents_imported, 20);
        assert_eq!(
            fact.terminal_at,
            "2026-07-22T00:00:02Z".parse::<DateTime<Utc>>().unwrap()
        );
        assert_eq!(fact.error_code, None);
        assert_eq!(fact.error_message, None);
    }
}

#[test]
fn status_observation_keeps_cancelling_running_and_closes_terminal_race_matrix() {
    let previous = AlgoliaImportSummary {
        documents_expected: 20,
        documents_imported: 10,
        ..Default::default()
    };
    let cancelling = cursor(
        AlgoliaImportDestinationKind::Replace,
        AlgoliaImportJobStatus::Cancelling,
        previous,
    );

    let observed = AlgoliaImportService::map_status_observation(
        &cancelling,
        response(AsyncMigrationPhase::Activating, "running", 12, 20),
    )
    .expect("a running engine response must retain the cloud cancel intent");
    let AlgoliaImportStatusObservation::Running(observed) = observed else {
        panic!("running response must remain nonterminal");
    };
    assert_eq!(observed.status, AlgoliaImportJobStatus::Cancelling);
    assert_eq!(observed.summary.documents_imported, 12);

    let cancelled = AlgoliaImportService::map_status_observation(
        &cancelling,
        response(AsyncMigrationPhase::Activating, "cancelled", 12, 20),
    )
    .expect("cancel may win the race");
    let AlgoliaImportStatusObservation::Terminal(cancelled) = cancelled else {
        panic!("cancelled response must produce a terminal fact");
    };
    assert_eq!(cancelled.status, AlgoliaImportJobStatus::Cancelled);
    assert_eq!(
        cancelled.publication_disposition,
        AlgoliaImportPublicationDisposition::Unchanged
    );

    let promoted = AlgoliaImportService::map_status_observation(
        &cancelling,
        response(AsyncMigrationPhase::Activating, "succeeded", 20, 20),
    )
    .expect("promotion may win after cancel intent");
    let AlgoliaImportStatusObservation::Terminal(promoted) = promoted else {
        panic!("promoted response must produce a terminal fact");
    };
    assert_eq!(promoted.status, AlgoliaImportJobStatus::Completed);
    assert_eq!(
        promoted.publication_disposition,
        AlgoliaImportPublicationDisposition::Promoted
    );

    for invalid_publication in [
        AlgoliaImportPublicationDisposition::Promoted,
        AlgoliaImportPublicationDisposition::NotStarted,
    ] {
        assert!(
            crate::models::algolia_import_job::AlgoliaImportTerminalFact::new(
                Uuid::parse_str(ENGINE_JOB_ID).unwrap(),
                AlgoliaImportJobStatus::Cancelled,
                invalid_publication,
                AlgoliaImportSummary::default(),
                "2026-07-22T00:00:02Z".parse().unwrap(),
                None,
                None,
            )
            .is_err()
        );
    }
}

#[test]
fn status_observation_rejects_identity_phase_and_progress_rewind() {
    let previous = AlgoliaImportSummary {
        documents_expected: 20,
        documents_imported: 12,
        ..Default::default()
    };
    let current = cursor(
        AlgoliaImportDestinationKind::Create,
        AlgoliaImportJobStatus::Verifying,
        previous,
    );

    assert_eq!(
        AlgoliaImportService::map_status_observation(
            &current,
            response(AsyncMigrationPhase::Preparing, "running", 12, 20),
        ),
        Err(AlgoliaImportStatusObservationError::PhaseRewind),
    );
    assert_eq!(
        AlgoliaImportService::map_status_observation(
            &current,
            response(AsyncMigrationPhase::Staging, "running", 11, 20),
        ),
        Err(AlgoliaImportStatusObservationError::ProgressRewind),
    );
    assert_eq!(
        AlgoliaImportService::map_status_observation(
            &current,
            response(AsyncMigrationPhase::Staging, "running", 12, 19),
        ),
        Err(AlgoliaImportStatusObservationError::ProgressRewind),
    );

    let mut wrong_job = response(AsyncMigrationPhase::Staging, "running", 12, 20);
    wrong_job.job_id = Uuid::new_v4();
    assert_eq!(
        AlgoliaImportService::map_status_observation(&current, wrong_job),
        Err(AlgoliaImportStatusObservationError::EngineJobMismatch),
    );

    assert_eq!(
        AlgoliaImportService::map_status_observation(
            &current,
            response(
                AsyncMigrationPhase::Staging,
                "running",
                i64::MAX as u64 + 1,
                i64::MAX as u64 + 1,
            ),
        ),
        Err(AlgoliaImportStatusObservationError::ProgressOutOfRange),
    );
}

#[test]
fn status_observation_preserves_progress_when_the_optional_engine_field_is_absent() {
    let summary = AlgoliaImportSummary {
        documents_expected: 20,
        documents_imported: 12,
        settings_applied: 3,
        ..Default::default()
    };
    let mut response = response(AsyncMigrationPhase::Staging, "running", 12, 20);
    response.export_progress = None;

    let observed = AlgoliaImportService::map_status_observation(
        &cursor(
            AlgoliaImportDestinationKind::Replace,
            AlgoliaImportJobStatus::CopyingDocuments,
            summary.clone(),
        ),
        response,
    )
    .unwrap();
    let AlgoliaImportStatusObservation::Running(observed) = observed else {
        panic!("running response must remain running");
    };
    assert_eq!(observed.summary, summary);
}

#[test]
fn status_observation_output_excludes_engine_metadata_and_unpinned_outcomes() {
    let response = response(AsyncMigrationPhase::Exporting, "running", 1, 2);
    let engine_timestamp = response.updated_at.to_rfc3339();
    let observed = AlgoliaImportService::map_status_observation(
        &cursor(
            AlgoliaImportDestinationKind::Replace,
            AlgoliaImportJobStatus::Queued,
            AlgoliaImportSummary::default(),
        ),
        response,
    )
    .unwrap();
    let debug = format!("{observed:?}");

    assert!(!debug.contains(ENGINE_JOB_ID));
    assert!(!debug.contains(&engine_timestamp));
    assert!(!debug.contains("physical_uid"));
    assert!(!debug.contains("source_changed"));
    assert!(!debug.contains("destination_changed"));
    assert!(!debug.contains("completed_with_warnings"));
    assert!(!debug.contains("interrupted"));
}
