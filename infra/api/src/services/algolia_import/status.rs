use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

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
        Ok(Self {
            job_id: wire.job_id,
            phase: wire.phase,
            disposition: wire.disposition,
            created_at: wire.created_at,
            updated_at: wire.updated_at,
            export_progress: wire.export_progress,
            terminal_at: wire.terminal_at,
        })
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
