use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;
use uuid::Uuid;

use super::{AlgoliaImportErrorCode, AlgoliaImportJobStatus};

pub(crate) const MAX_ALGOLIA_IMPORT_WARNINGS: usize = 100;
pub(crate) const MAX_ALGOLIA_IMPORT_WARNING_CODE_BYTES: usize = 128;
pub(crate) const MAX_ALGOLIA_IMPORT_WARNING_MESSAGE_BYTES: usize = 1024;
pub(crate) const MAX_ALGOLIA_IMPORT_WARNING_RESOURCE_BYTES: usize = 128;
pub(crate) const MAX_ALGOLIA_IMPORT_WARNING_JSON_PATH_BYTES: usize = 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum AlgoliaImportPublicationDisposition {
    NotStarted,
    Unchanged,
    Promoted,
    Unknown,
}

impl AlgoliaImportPublicationDisposition {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NotStarted => "not_started",
            Self::Unchanged => "unchanged",
            Self::Promoted => "promoted",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct AlgoliaImportSummary {
    pub documents_expected: i64,
    pub documents_imported: i64,
    pub documents_rejected: i64,
    pub settings_applied: i64,
    pub settings_unsupported: i64,
    pub synonyms_expected: i64,
    pub synonyms_imported: i64,
    pub synonyms_rejected: i64,
    pub rules_expected: i64,
    pub rules_imported: i64,
    pub rules_rejected: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AlgoliaImportWarning {
    pub code: String,
    pub message: String,
    pub resource: String,
    pub page_index: Option<u64>,
    pub item_index: Option<u64>,
    #[serde(rename = "jsonPath")]
    pub json_path: String,
}

pub(crate) fn validate_algolia_import_warnings(
    warnings: &[AlgoliaImportWarning],
) -> Result<(), &'static str> {
    if warnings.len() > MAX_ALGOLIA_IMPORT_WARNINGS {
        return Err("migration outcome exceeds the warning count limit");
    }
    for warning in warnings {
        if warning.code.len() > MAX_ALGOLIA_IMPORT_WARNING_CODE_BYTES {
            return Err("migration warning code exceeds its byte limit");
        }
        if warning.message.len() > MAX_ALGOLIA_IMPORT_WARNING_MESSAGE_BYTES {
            return Err("migration warning message exceeds its byte limit");
        }
        if warning.resource.len() > MAX_ALGOLIA_IMPORT_WARNING_RESOURCE_BYTES {
            return Err("migration warning resource exceeds its byte limit");
        }
        if warning.json_path.len() > MAX_ALGOLIA_IMPORT_WARNING_JSON_PATH_BYTES {
            return Err("migration warning JSON path exceeds its byte limit");
        }
    }
    Ok(())
}

pub(crate) fn canonical_persisted_warnings(
    terminal_outcome_observed: bool,
    value: serde_json::Value,
) -> Vec<AlgoliaImportWarning> {
    if !terminal_outcome_observed
        || value
            .as_array()
            .is_none_or(|warnings| warnings.len() > MAX_ALGOLIA_IMPORT_WARNINGS)
    {
        return Vec::new();
    }
    let Ok(warnings): Result<Vec<AlgoliaImportWarning>, _> = serde_json::from_value(value) else {
        return Vec::new();
    };
    if validate_algolia_import_warnings(&warnings).is_err() {
        return Vec::new();
    }
    warnings
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlgoliaImportTerminalFact {
    pub engine_job_id: Uuid,
    pub status: AlgoliaImportJobStatus,
    pub publication_disposition: AlgoliaImportPublicationDisposition,
    pub summary: AlgoliaImportSummary,
    pub terminal_outcome_observed: bool,
    pub warnings: Vec<AlgoliaImportWarning>,
    pub error_code: Option<AlgoliaImportErrorCode>,
    pub error_message: Option<String>,
    pub terminal_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlgoliaImportTerminalDetails {
    pub summary: AlgoliaImportSummary,
    pub terminal_outcome_observed: bool,
    pub warnings: Vec<AlgoliaImportWarning>,
    pub error_code: Option<AlgoliaImportErrorCode>,
    pub error_message: Option<String>,
}

impl AlgoliaImportTerminalFact {
    pub fn new(
        engine_job_id: Uuid,
        status: AlgoliaImportJobStatus,
        publication_disposition: AlgoliaImportPublicationDisposition,
        terminal_at: DateTime<Utc>,
        details: AlgoliaImportTerminalDetails,
    ) -> Result<Self, &'static str> {
        if !status.has_valid_terminal_disposition(publication_disposition) {
            return Err("terminal fact has an invalid publication disposition");
        }
        validate_algolia_import_warnings(&details.warnings)?;
        if !matches!(
            status,
            AlgoliaImportJobStatus::Completed | AlgoliaImportJobStatus::CompletedWithWarnings
        ) && (details.terminal_outcome_observed || !details.warnings.is_empty())
        {
            return Err("terminal outcome details require successful terminal status");
        }
        if !details.terminal_outcome_observed && !details.warnings.is_empty() {
            return Err("terminal warnings require an observed terminal outcome");
        }
        if status == AlgoliaImportJobStatus::Completed && !details.warnings.is_empty() {
            return Err("completed status cannot carry terminal warnings");
        }
        if status == AlgoliaImportJobStatus::CompletedWithWarnings
            && (!details.terminal_outcome_observed || details.warnings.is_empty())
        {
            return Err("completed-with-warnings status requires observed terminal warnings");
        }
        Ok(Self {
            engine_job_id,
            status,
            publication_disposition,
            summary: details.summary,
            terminal_outcome_observed: details.terminal_outcome_observed,
            warnings: details.warnings,
            error_code: details.error_code,
            error_message: details.error_message,
            terminal_at,
        })
    }
}
