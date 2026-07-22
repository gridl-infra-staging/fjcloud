use axum::extract::State;
use axum::Json;

use crate::auth::AdminAuth;
use crate::services::vm_orphan_reconcile::VmOrphanReport;
use crate::state::AppState;

/// Returns a read-only reconciliation report. Source failures are represented
/// inside the successful report so operators cannot mistake partial facts for
/// a clean fleet.
pub async fn get_vm_orphans(
    _auth: AdminAuth,
    State(state): State<AppState>,
) -> Json<VmOrphanReport> {
    Json(state.vm_orphan_reconciler.reconcile().await)
}
