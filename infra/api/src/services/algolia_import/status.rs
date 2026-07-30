use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize};
use uuid::Uuid;

use crate::models::algolia_import_job::{validate_algolia_import_warnings, AlgoliaImportWarning};

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", try_from = "AsyncMigrationStatusWire")]
pub struct AsyncMigrationStatusResponse {
    pub job_id: Uuid,
    pub phase: AsyncMigrationPhase,
    pub disposition: AsyncMigrationDisposition,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub export_progress: Option<AsyncMigrationExportProgress>,
    pub terminal_at: Option<DateTime<Utc>>,
    pub settings_applied: Option<bool>,
    pub synonyms_imported: Option<MigrateCount>,
    pub rules_imported: Option<MigrateCount>,
    pub objects_imported: Option<MigrateCount>,
    pub target_index: Option<String>,
    pub topology: Option<MigrationTopology>,
    pub warnings: Option<Vec<AlgoliaImportWarning>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AsyncMigrationStatusWire {
    job_id: Uuid,
    phase: AsyncMigrationPhase,
    disposition: AsyncMigrationDisposition,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    #[serde(default)]
    export_progress: Option<AsyncMigrationExportProgress>,
    #[serde(default)]
    terminal_at: Option<DateTime<Utc>>,
    #[serde(default)]
    settings_applied: WireOutcomeField<bool>,
    #[serde(default)]
    synonyms_imported: WireOutcomeField<MigrateCount>,
    #[serde(default)]
    rules_imported: WireOutcomeField<MigrateCount>,
    #[serde(default)]
    objects_imported: WireOutcomeField<MigrateCount>,
    #[serde(default)]
    target_index: Option<String>,
    #[serde(default)]
    topology: Option<MigrationTopology>,
    #[serde(default)]
    warnings: WireOutcomeField<Vec<AlgoliaImportWarning>>,
}

impl TryFrom<AsyncMigrationStatusWire> for AsyncMigrationStatusResponse {
    type Error = &'static str;

    fn try_from(wire: AsyncMigrationStatusWire) -> Result<Self, Self::Error> {
        if wire.updated_at < wire.created_at {
            return Err("migration status updated time precedes its created time");
        }
        if wire
            .terminal_at
            .is_some_and(|terminal_at| terminal_at < wire.updated_at)
        {
            return Err("migration status terminal time precedes its updated time");
        }
        if wire
            .export_progress
            .as_ref()
            .is_some_and(|progress| progress.completed > progress.total)
        {
            return Err("migration status progress exceeds its total");
        }
        match (wire.disposition, wire.terminal_at) {
            (AsyncMigrationDisposition::Running, Some(_)) => {
                return Err("running migration status cannot have a terminal time")
            }
            (AsyncMigrationDisposition::Running, None) => {}
            (_, None) => return Err("terminal migration status requires a terminal time"),
            (_, Some(_)) => {}
        }
        if wire.disposition == AsyncMigrationDisposition::Succeeded
            && wire.phase != AsyncMigrationPhase::Activating
        {
            return Err("successful migration status must be activating");
        }
        let has_outcome_field = wire.settings_applied.is_present()
            || wire.synonyms_imported.is_present()
            || wire.rules_imported.is_present()
            || wire.objects_imported.is_present()
            || wire.warnings.is_present();
        if has_outcome_field {
            validate_terminal_outcome(&wire)?;
        }
        if let WireOutcomeField::Present(warnings) = &wire.warnings {
            validate_algolia_import_warnings(warnings)?;
        }
        Ok(Self {
            job_id: wire.job_id,
            phase: wire.phase,
            disposition: wire.disposition,
            created_at: wire.created_at,
            updated_at: wire.updated_at,
            export_progress: wire.export_progress,
            terminal_at: wire.terminal_at,
            settings_applied: wire.settings_applied.into_option(),
            synonyms_imported: wire.synonyms_imported.into_option(),
            rules_imported: wire.rules_imported.into_option(),
            objects_imported: wire.objects_imported.into_option(),
            target_index: wire.target_index,
            topology: wire.topology,
            warnings: wire.warnings.into_option(),
        })
    }
}

fn validate_terminal_outcome(wire: &AsyncMigrationStatusWire) -> Result<(), &'static str> {
    if wire.disposition != AsyncMigrationDisposition::Succeeded || wire.terminal_at.is_none() {
        return Err("migration outcome fields require successful terminal status");
    }
    if wire.settings_applied.is_missing()
        || wire.synonyms_imported.is_missing()
        || wire.rules_imported.is_missing()
    {
        return Err("migration outcome requires complete settings and count fields");
    }
    Ok(())
}

#[derive(Debug, Default)]
enum WireOutcomeField<T> {
    #[default]
    Missing,
    Present(T),
}

impl<'de, T> Deserialize<'de> for WireOutcomeField<T>
where
    T: Deserialize<'de>,
{
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        T::deserialize(deserializer).map(Self::Present)
    }
}

impl<T> WireOutcomeField<T> {
    fn is_present(&self) -> bool {
        matches!(self, Self::Present(_))
    }

    fn is_missing(&self) -> bool {
        matches!(self, Self::Missing)
    }

    fn into_option(self) -> Option<T> {
        match self {
            Self::Missing => None,
            Self::Present(value) => Some(value),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AsyncMigrationPhase {
    Submitted,
    Exporting,
    Preparing,
    Staging,
    Activating,
}

impl AsyncMigrationPhase {
    pub const ALL: [Self; 5] = [
        Self::Submitted,
        Self::Exporting,
        Self::Preparing,
        Self::Staging,
        Self::Activating,
    ];
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AsyncMigrationDisposition {
    Running,
    Succeeded,
    Failed,
    Cancelled,
}

impl AsyncMigrationDisposition {
    pub const ALL: [Self; 4] = [
        Self::Running,
        Self::Succeeded,
        Self::Failed,
        Self::Cancelled,
    ];
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AsyncMigrationExportProgress {
    pub completed: u64,
    pub total: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MigrateCount {
    pub imported: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum MigrationTopology {
    SingleNodeOnly,
}
