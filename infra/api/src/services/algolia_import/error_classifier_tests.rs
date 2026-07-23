use crate::models::AlgoliaImportErrorCode;

use super::{
    AlgoliaImportEngineError, AlgoliaImportEngineErrorClassification, AlgoliaImportEngineOperation,
    AlgoliaImportService,
};

fn engine_error(status: u16, code: &str) -> AlgoliaImportEngineError {
    AlgoliaImportEngineError::Engine {
        status,
        code: Some(code.to_string()),
    }
}

#[test]
fn engine_error_classifier_maps_only_operation_specific_pinned_codes() {
    use AlgoliaImportEngineOperation::{Cancel, Status, Submit};

    let cases = [
        (
            Submit,
            engine_error(503, "migration_ha_unsupported"),
            AlgoliaImportErrorCode::MigrationHaNotSupported,
            false,
        ),
        (
            Submit,
            engine_error(503, "migration_capacity_exhausted"),
            AlgoliaImportErrorCode::BackendUnavailable,
            true,
        ),
        (
            Status,
            engine_error(404, "migration_job_not_found"),
            AlgoliaImportErrorCode::BackendUnavailable,
            true,
        ),
        (
            Cancel,
            engine_error(409, "cancel_too_late"),
            AlgoliaImportErrorCode::CancelNotPermitted,
            false,
        ),
    ];

    for (operation, error, code, retryable) in cases {
        assert_eq!(
            AlgoliaImportService::classify_engine_error(operation, &error),
            AlgoliaImportEngineErrorClassification { code, retryable },
            "{operation:?} {error:?}",
        );
    }
}

#[test]
fn engine_error_classifier_fails_closed_for_wrong_operation_status_or_unknown_code() {
    use AlgoliaImportEngineOperation::{Cancel, Status, Submit};

    for (operation, error) in [
        (Status, engine_error(503, "migration_ha_unsupported")),
        (Cancel, engine_error(503, "migration_capacity_exhausted")),
        (Submit, engine_error(500, "migration_ha_unsupported")),
        (Status, engine_error(410, "migration_job_not_found")),
        (Cancel, engine_error(400, "cancel_too_late")),
        (Submit, engine_error(503, "future_engine_code")),
        (
            Status,
            AlgoliaImportEngineError::Engine {
                status: 404,
                code: None,
            },
        ),
        (
            Submit,
            AlgoliaImportEngineError::MalformedResponse("raw body".to_string()),
        ),
        (
            Status,
            AlgoliaImportEngineError::Transport("private endpoint".to_string()),
        ),
    ] {
        let classification = AlgoliaImportService::classify_engine_error(operation, &error);
        assert_eq!(
            classification,
            AlgoliaImportEngineErrorClassification {
                code: AlgoliaImportErrorCode::BackendUnavailable,
                retryable: true,
            },
            "{operation:?} {error:?}",
        );
        let sanitized = format!("{classification:?}");
        assert!(!sanitized.contains("raw body"));
        assert!(!sanitized.contains("private endpoint"));
        assert!(!sanitized.contains("future_engine_code"));
    }
}
