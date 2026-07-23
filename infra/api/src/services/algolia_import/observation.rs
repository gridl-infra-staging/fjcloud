use uuid::Uuid;

use crate::models::algolia_import_job::{
    AlgoliaImportDestinationKind, AlgoliaImportJobStatus, AlgoliaImportPublicationDisposition,
    AlgoliaImportSummary,
};

use super::{
    AlgoliaImportService, AlgoliaImportTerminalHandoff, AsyncMigrationDisposition,
    AsyncMigrationExportProgress, AsyncMigrationPhase, AsyncMigrationStatusResponse,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlgoliaImportObservationCursor {
    engine_job_id: Uuid,
    destination_kind: AlgoliaImportDestinationKind,
    status: AlgoliaImportJobStatus,
    summary: AlgoliaImportSummary,
}

impl AlgoliaImportObservationCursor {
    pub fn new(
        engine_job_id: Uuid,
        destination_kind: AlgoliaImportDestinationKind,
        status: AlgoliaImportJobStatus,
        summary: AlgoliaImportSummary,
    ) -> Self {
        Self {
            engine_job_id,
            destination_kind,
            status,
            summary,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlgoliaImportRunningObservation {
    pub status: AlgoliaImportJobStatus,
    pub summary: AlgoliaImportSummary,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AlgoliaImportStatusObservation {
    Running(AlgoliaImportRunningObservation),
    Terminal(AlgoliaImportTerminalHandoff),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum AlgoliaImportStatusObservationError {
    #[error("engine status refers to a different migration job")]
    EngineJobMismatch,
    #[error("engine migration phase rewound")]
    PhaseRewind,
    #[error("engine migration progress rewound")]
    ProgressRewind,
    #[error("engine migration progress exceeds cloud integer bounds")]
    ProgressOutOfRange,
    #[error("cloud job status cannot consume a running engine observation")]
    UnsupportedCurrentStatus,
    #[error("engine terminal observation violates the cloud handoff contract")]
    InvalidTerminalHandoff,
}

impl AlgoliaImportService {
    pub fn map_status_observation(
        cursor: &AlgoliaImportObservationCursor,
        response: AsyncMigrationStatusResponse,
    ) -> Result<AlgoliaImportStatusObservation, AlgoliaImportStatusObservationError> {
        if response.job_id != cursor.engine_job_id {
            return Err(AlgoliaImportStatusObservationError::EngineJobMismatch);
        }

        let observed_status = cloud_status_for_phase(response.phase);
        reject_phase_rewind(cursor.status, observed_status, response.disposition)?;
        let summary = merge_export_progress(&cursor.summary, response.export_progress)?;

        match response.disposition {
            AsyncMigrationDisposition::Running => Ok(AlgoliaImportStatusObservation::Running(
                AlgoliaImportRunningObservation {
                    status: retained_running_status(cursor.status, observed_status),
                    summary,
                },
            )),
            AsyncMigrationDisposition::Succeeded => terminal_observation(
                AlgoliaImportJobStatus::Completed,
                AlgoliaImportPublicationDisposition::Promoted,
                summary,
            ),
            AsyncMigrationDisposition::Cancelled => terminal_observation(
                AlgoliaImportJobStatus::Cancelled,
                AlgoliaImportPublicationDisposition::Unchanged,
                summary,
            ),
            AsyncMigrationDisposition::Failed => terminal_observation(
                AlgoliaImportJobStatus::Failed,
                match cursor.destination_kind {
                    AlgoliaImportDestinationKind::Create => {
                        AlgoliaImportPublicationDisposition::NotStarted
                    }
                    AlgoliaImportDestinationKind::Replace => {
                        AlgoliaImportPublicationDisposition::Unchanged
                    }
                },
                summary,
            ),
        }
    }
}

fn cloud_status_for_phase(phase: AsyncMigrationPhase) -> AlgoliaImportJobStatus {
    match phase {
        AsyncMigrationPhase::Submitted => AlgoliaImportJobStatus::ValidatingSource,
        AsyncMigrationPhase::Exporting => AlgoliaImportJobStatus::CopyingConfiguration,
        AsyncMigrationPhase::Preparing => AlgoliaImportJobStatus::CopyingDocuments,
        AsyncMigrationPhase::Staging => AlgoliaImportJobStatus::Verifying,
        AsyncMigrationPhase::Activating => AlgoliaImportJobStatus::Promoting,
    }
}

fn reject_phase_rewind(
    current: AlgoliaImportJobStatus,
    observed: AlgoliaImportJobStatus,
    disposition: AsyncMigrationDisposition,
) -> Result<(), AlgoliaImportStatusObservationError> {
    if current == AlgoliaImportJobStatus::Cancelling {
        return Ok(());
    }
    let Some(current_rank) = running_status_rank(current) else {
        return if disposition == AsyncMigrationDisposition::Running {
            Err(AlgoliaImportStatusObservationError::UnsupportedCurrentStatus)
        } else {
            Ok(())
        };
    };
    if running_status_rank(observed).expect("engine phases map only to running statuses")
        < current_rank
    {
        return Err(AlgoliaImportStatusObservationError::PhaseRewind);
    }
    Ok(())
}

fn retained_running_status(
    current: AlgoliaImportJobStatus,
    observed: AlgoliaImportJobStatus,
) -> AlgoliaImportJobStatus {
    if current == AlgoliaImportJobStatus::Cancelling {
        AlgoliaImportJobStatus::Cancelling
    } else {
        observed
    }
}

fn running_status_rank(status: AlgoliaImportJobStatus) -> Option<u8> {
    match status {
        AlgoliaImportJobStatus::Queued => Some(0),
        AlgoliaImportJobStatus::ValidatingSource => Some(1),
        AlgoliaImportJobStatus::CopyingConfiguration => Some(2),
        AlgoliaImportJobStatus::CopyingDocuments => Some(3),
        AlgoliaImportJobStatus::Verifying => Some(4),
        AlgoliaImportJobStatus::Promoting => Some(5),
        _ => None,
    }
}

fn merge_export_progress(
    previous: &AlgoliaImportSummary,
    progress: Option<AsyncMigrationExportProgress>,
) -> Result<AlgoliaImportSummary, AlgoliaImportStatusObservationError> {
    let Some(progress) = progress else {
        return Ok(previous.clone());
    };
    let completed = i64::try_from(progress.completed)
        .map_err(|_| AlgoliaImportStatusObservationError::ProgressOutOfRange)?;
    let total = i64::try_from(progress.total)
        .map_err(|_| AlgoliaImportStatusObservationError::ProgressOutOfRange)?;
    if completed < previous.documents_imported || total < previous.documents_expected {
        return Err(AlgoliaImportStatusObservationError::ProgressRewind);
    }

    let mut summary = previous.clone();
    summary.documents_imported = completed;
    summary.documents_expected = total;
    Ok(summary)
}

fn terminal_observation(
    status: AlgoliaImportJobStatus,
    publication_disposition: AlgoliaImportPublicationDisposition,
    summary: AlgoliaImportSummary,
) -> Result<AlgoliaImportStatusObservation, AlgoliaImportStatusObservationError> {
    AlgoliaImportTerminalHandoff::new(status, publication_disposition, summary, None, None)
        .map(AlgoliaImportStatusObservation::Terminal)
        .map_err(|_| AlgoliaImportStatusObservationError::InvalidTerminalHandoff)
}
