use crate::models::AlgoliaImportErrorCode;

use super::{AlgoliaImportEngineError, AlgoliaImportService};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlgoliaImportEngineOperation {
    Submit,
    Status,
    Cancel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AlgoliaImportEngineErrorClassification {
    pub code: AlgoliaImportErrorCode,
    pub retryable: bool,
}

impl AlgoliaImportService {
    pub fn classify_engine_error(
        operation: AlgoliaImportEngineOperation,
        error: &AlgoliaImportEngineError,
    ) -> AlgoliaImportEngineErrorClassification {
        use AlgoliaImportEngineOperation::{Cancel, Status, Submit};

        let pinned = match (operation, error) {
            (
                Submit,
                AlgoliaImportEngineError::Engine {
                    status: 503,
                    code: Some(code),
                },
            ) if code == "migration_ha_unsupported" => {
                Some((AlgoliaImportErrorCode::MigrationHaNotSupported, false))
            }
            (
                Submit,
                AlgoliaImportEngineError::Engine {
                    status: 503,
                    code: Some(code),
                },
            ) if code == "migration_capacity_exhausted" => {
                Some((AlgoliaImportErrorCode::BackendUnavailable, true))
            }
            (
                Status,
                AlgoliaImportEngineError::Engine {
                    status: 404,
                    code: Some(code),
                },
            ) if code == "migration_job_not_found" => {
                Some((AlgoliaImportErrorCode::BackendUnavailable, true))
            }
            (
                Cancel,
                AlgoliaImportEngineError::Engine {
                    status: 409,
                    code: Some(code),
                },
            ) if code == "cancel_too_late" => {
                Some((AlgoliaImportErrorCode::CancelNotPermitted, false))
            }
            _ => None,
        };
        let (code, retryable) =
            pinned.unwrap_or((AlgoliaImportErrorCode::BackendUnavailable, true));
        AlgoliaImportEngineErrorClassification { code, retryable }
    }
}
