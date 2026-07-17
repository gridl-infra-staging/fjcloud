use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::helpers;
use crate::models::vm_inventory::VmInventory;
use crate::services::engine_index_identity_observer::{
    record_caller, record_physical_caller, PhysicalCallerObservation,
};
use crate::services::flapjack_node::flapjack_index_uid;
use crate::services::migration::{MigrationError, MigrationRequest, MigrationStatus};
use crate::services::replication_error::REPLICATION_APP_ID;
use crate::state::AppState;

const DEFAULT_MIGRATION_LIMIT: i64 = 50;
const MAX_MIGRATION_LIMIT: i64 = 500;
const PROBE_RECOVERY_SEAMS_ENV: &str = "ENGINE_INDEX_IDENTITY_PROBE_RECOVERY_SEAMS";

const STATUS_ACTIVE: &str = "active";
const STATUS_PENDING: &str = "pending";
const STATUS_REPLICATING: &str = "replicating";
const STATUS_CUTTING_OVER: &str = "cutting_over";
const STATUS_COMPLETED: &str = "completed";
const STATUS_FAILED: &str = "failed";
const STATUS_ROLLED_BACK: &str = "rolled_back";

#[derive(Debug, Deserialize)]
pub struct TriggerMigrationRequest {
    pub index_name: String,
    pub customer_id: Option<Uuid>,
    pub dest_vm_id: Uuid,
}

#[derive(Debug, Serialize)]
pub struct TriggerMigrationResponse {
    pub migration_id: Uuid,
    pub status: String,
}

#[derive(Debug, Serialize)]
pub struct ProbeRecoveryResponse {
    pub migration_id: Uuid,
    pub status: String,
    pub scenario: String,
}

#[derive(Debug, Deserialize)]
pub struct ListMigrationsQuery {
    pub status: Option<String>,
    pub limit: Option<i64>,
}

enum MigrationStatusFilter {
    Active,
    Exact(&'static str),
}

/// Parse the `status` query parameter into a migration status filter.
///
/// `"active"` maps to a composite filter (pending + replicating + cutting_over);
/// other values map to an exact single-status match. Returns 400 for
/// unrecognized values.
fn parse_status_filter(raw: Option<&str>) -> Result<Option<MigrationStatusFilter>, ApiError> {
    let Some(value) = raw.map(str::trim).filter(|value| !value.is_empty()) else {
        return Ok(None);
    };

    match value {
        STATUS_ACTIVE => Ok(Some(MigrationStatusFilter::Active)),
        STATUS_PENDING => Ok(Some(MigrationStatusFilter::Exact(STATUS_PENDING))),
        STATUS_REPLICATING => Ok(Some(MigrationStatusFilter::Exact(STATUS_REPLICATING))),
        STATUS_CUTTING_OVER => Ok(Some(MigrationStatusFilter::Exact(STATUS_CUTTING_OVER))),
        STATUS_COMPLETED => Ok(Some(MigrationStatusFilter::Exact(STATUS_COMPLETED))),
        STATUS_FAILED => Ok(Some(MigrationStatusFilter::Exact(STATUS_FAILED))),
        STATUS_ROLLED_BACK => Ok(Some(MigrationStatusFilter::Exact(STATUS_ROLLED_BACK))),
        _ => Err(ApiError::BadRequest(
            "status must be one of: active, pending, replicating, cutting_over, completed, failed, rolled_back".to_string(),
        )),
    }
}

fn migration_error_to_api(error: MigrationError) -> ApiError {
    match error {
        MigrationError::ConcurrencyLimitReached { .. }
        | MigrationError::DestinationConflict
        | MigrationError::DestinationChanged => ApiError::Conflict(error.to_string()),
        MigrationError::VmNotFound(_) | MigrationError::MigrationNotFound(_) => {
            ApiError::NotFound(error.to_string())
        }
        MigrationError::RollbackWindowExpired { .. }
        | MigrationError::RollbackUnsupportedStatus { .. }
        | MigrationError::Protocol(_) => ApiError::BadRequest(error.to_string()),
        MigrationError::Http(_)
        | MigrationError::ReplicationLagTimeout { .. }
        | MigrationError::Repo(_) => ApiError::Internal(error.to_string()),
    }
}

fn require_probe_recovery_seams_enabled() -> Result<(), ApiError> {
    if std::env::var(PROBE_RECOVERY_SEAMS_ENV).as_deref() == Ok("1") {
        return Ok(());
    }

    Err(ApiError::Forbidden(
        "engine index identity probe recovery seams are disabled".to_string(),
    ))
}

/// Find the single customer that owns an index by name, rejecting ambiguity.
///
/// Iterates all customers checking for a matching index. Returns 409 if
/// multiple customers own an index with the same name; 404 if none match.
async fn resolve_unique_tenant_for_index(
    state: &AppState,
    index_name: &str,
) -> Result<crate::models::tenant::CustomerTenant, ApiError> {
    let customers = state.customer_repo.list().await?;
    let mut matching_customer_id: Option<Uuid> = None;

    for customer in customers {
        if state
            .tenant_repo
            .find_by_name(customer.id, index_name)
            .await?
            .is_some()
        {
            if matching_customer_id.is_some() {
                return Err(ApiError::Conflict(format!(
                    "index '{}' is ambiguous across multiple customers",
                    index_name
                )));
            }
            matching_customer_id = Some(customer.id);
        }
    }

    let customer_id =
        matching_customer_id.ok_or_else(|| ApiError::NotFound("index not found".to_string()))?;

    state
        .tenant_repo
        .find_raw(customer_id, index_name)
        .await?
        .ok_or_else(|| ApiError::NotFound("index not found".to_string()))
}

async fn resolve_migration_tenant(
    state: &AppState,
    customer_id: Option<Uuid>,
    index_name: &str,
) -> Result<crate::models::tenant::CustomerTenant, ApiError> {
    match customer_id {
        Some(customer_id) => state
            .tenant_repo
            .find_raw(customer_id, index_name)
            .await?
            .ok_or_else(|| ApiError::NotFound("index not found".to_string())),
        None => resolve_unique_tenant_for_index(state, index_name).await,
    }
}

/// Validated migration context returned by `validate_migration_request`.
struct ValidatedMigration {
    index_name: String,
    customer_id: Uuid,
    source_vm_id: Uuid,
    source_provider: String,
    dest_vm_id: Uuid,
    dest_provider: String,
    dest_vm: VmInventory,
}

/// Shared validation for migration trigger endpoints. Resolves index → tenant → source VM,
/// validates dest VM exists and is active, checks no duplicate in-flight migration.
async fn validate_migration_request(
    state: &AppState,
    req: &TriggerMigrationRequest,
) -> Result<ValidatedMigration, ApiError> {
    record_caller("routes.admin.migrations.validate_migration_request");
    let index_name = req.index_name.trim();
    if index_name.is_empty() {
        return Err(ApiError::BadRequest(
            "index_name must not be empty".to_string(),
        ));
    }

    let tenant = resolve_migration_tenant(state, req.customer_id, index_name).await?;

    if tenant.tier == "migrating" {
        return Err(ApiError::Conflict("index is already migrating".to_string()));
    }

    let source_vm_id = tenant
        .vm_id
        .ok_or_else(|| ApiError::BadRequest("index is not assigned to a VM".to_string()))?;

    let source_vm = state
        .vm_inventory_repo
        .get(source_vm_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("source VM not found".to_string()))?;

    if source_vm.status != "active" {
        return Err(ApiError::BadRequest("source VM must be active".to_string()));
    }

    let dest_vm = state
        .vm_inventory_repo
        .get(req.dest_vm_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("destination VM not found".to_string()))?;

    if source_vm_id == req.dest_vm_id {
        return Err(ApiError::BadRequest(
            "source VM and destination VM must differ".to_string(),
        ));
    }

    if dest_vm.status != "active" {
        return Err(ApiError::BadRequest(
            "destination VM must be active".to_string(),
        ));
    }

    let active_migrations = state.index_migration_repo.list_active().await?;
    let already_migrating = active_migrations.iter().any(|migration| {
        migration.customer_id == tenant.customer_id && migration.index_name == index_name
    });
    if already_migrating {
        return Err(ApiError::Conflict("index is already migrating".to_string()));
    }

    Ok(ValidatedMigration {
        index_name: index_name.to_string(),
        customer_id: tenant.customer_id,
        source_vm_id,
        source_provider: source_vm.provider,
        dest_vm_id: req.dest_vm_id,
        dest_provider: dest_vm.provider.clone(),
        dest_vm,
    })
}

/// Execute a validated migration and return the standard response.
async fn execute_migration(
    state: &AppState,
    validated: &ValidatedMigration,
    requested_by: &str,
) -> Result<impl IntoResponse, ApiError> {
    let migration_outcome = state
        .migration_service
        .execute_with_observation(MigrationRequest {
            index_name: validated.index_name.clone(),
            customer_id: validated.customer_id,
            source_vm_id: validated.source_vm_id,
            dest_vm_id: validated.dest_vm_id,
            requested_by: requested_by.to_string(),
        })
        .await
        .map_err(migration_error_to_api)?;
    let physical_uid = flapjack_index_uid(validated.customer_id, &validated.index_name);
    record_physical_caller(
        "routes.admin.migrations.execute_migration",
        PhysicalCallerObservation {
            physical_uid: &physical_uid,
            logical_uid: &validated.index_name,
            node_secret_id: validated.dest_vm.node_secret_id(),
            auth_secret_id: validated.dest_vm.node_secret_id(),
            auth_header_value: &migration_outcome.start_replication_auth_header_value,
            upstream_path: "/internal/replicate",
            application_id: REPLICATION_APP_ID,
            http_status: 200,
        },
    );

    Ok((
        StatusCode::OK,
        Json(TriggerMigrationResponse {
            migration_id: migration_outcome.migration_id,
            status: MigrationStatus::Completed.as_str().to_string(),
        }),
    ))
}

/// `POST /admin/migrations` — trigger a same-provider migration.
/// Rejects cross-provider migrations; use `POST /admin/migrations/cross-provider` instead.
pub async fn trigger_migration(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Json(req): Json<TriggerMigrationRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let validated = validate_migration_request(&state, &req).await?;

    if validated.source_provider != validated.dest_provider {
        return Err(ApiError::BadRequest(format!(
            "cross-provider migration not allowed via this endpoint (source: {}, dest: {}); use POST /admin/migrations/cross-provider",
            validated.source_provider, validated.dest_provider
        )));
    }

    execute_migration(&state, &validated, "admin").await
}

/// `POST /admin/migrations/cross-provider` — explicitly trigger a cross-provider migration.
/// Same validation as `trigger_migration` but allows source and dest to be on different providers.
pub async fn trigger_cross_provider_migration(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Json(req): Json<TriggerMigrationRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let validated = validate_migration_request(&state, &req).await?;
    if validated.source_provider == validated.dest_provider {
        return Err(ApiError::BadRequest(format!(
            "same-provider migration should use POST /admin/migrations (provider: {})",
            validated.source_provider
        )));
    }
    execute_migration(&state, &validated, "admin-cross-provider").await
}

pub async fn probe_rollback_after_replication(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Json(req): Json<TriggerMigrationRequest>,
) -> Result<impl IntoResponse, ApiError> {
    require_probe_recovery_seams_enabled()?;
    let validated = validate_migration_request(&state, &req).await?;
    let migration_id = state
        .migration_service
        .probe_rollback_after_replication(MigrationRequest {
            index_name: validated.index_name,
            customer_id: validated.customer_id,
            source_vm_id: validated.source_vm_id,
            dest_vm_id: validated.dest_vm_id,
            requested_by: "engine-index-identity-probe-rollback".to_string(),
        })
        .await
        .map_err(migration_error_to_api)?;

    Ok((
        StatusCode::OK,
        Json(ProbeRecoveryResponse {
            migration_id,
            status: MigrationStatus::RolledBack.as_str().to_string(),
            scenario: "rollback_after_replication".to_string(),
        }),
    ))
}

pub async fn probe_failure_after_replication(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Json(req): Json<TriggerMigrationRequest>,
) -> Result<impl IntoResponse, ApiError> {
    require_probe_recovery_seams_enabled()?;
    let validated = validate_migration_request(&state, &req).await?;
    let migration_id = state
        .migration_service
        .probe_failure_after_replication(MigrationRequest {
            index_name: validated.index_name,
            customer_id: validated.customer_id,
            source_vm_id: validated.source_vm_id,
            dest_vm_id: validated.dest_vm_id,
            requested_by: "engine-index-identity-probe-failure".to_string(),
        })
        .await
        .map_err(migration_error_to_api)?;

    Ok((
        StatusCode::OK,
        Json(ProbeRecoveryResponse {
            migration_id,
            status: MigrationStatus::Failed(String::new()).as_str().to_string(),
            scenario: "failure_after_replication".to_string(),
        }),
    ))
}

/// `GET /admin/migrations` — list recent migrations with optional status filter.
///
/// **Auth:** `AdminAuth`.
/// Accepts `status` (active, pending, replicating, cutting_over, completed,
/// failed, rolled_back) and `limit` (default 50, max 500). The `active`
/// filter returns in-flight migrations; exact filters apply in-memory after
/// fetching up to `MAX_MIGRATION_LIMIT` rows.
pub async fn list_migrations(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Query(query): Query<ListMigrationsQuery>,
) -> Result<impl IntoResponse, ApiError> {
    record_caller("routes.admin.migrations.list_migrations");
    let limit = helpers::parse_limit(query.limit, DEFAULT_MIGRATION_LIMIT, MAX_MIGRATION_LIMIT)?;
    let status_filter = parse_status_filter(query.status.as_deref())?;

    let migrations = match status_filter {
        None => state.index_migration_repo.list_recent(limit).await?,
        Some(MigrationStatusFilter::Active) => {
            let mut active = state.index_migration_repo.list_active().await?;
            active.truncate(limit as usize);
            active
        }
        Some(MigrationStatusFilter::Exact(status)) => {
            let mut rows = state
                .index_migration_repo
                .list_recent(MAX_MIGRATION_LIMIT)
                .await?;
            rows.retain(|row| row.status == status);
            rows.truncate(limit as usize);
            rows
        }
    };

    Ok(Json(migrations))
}
