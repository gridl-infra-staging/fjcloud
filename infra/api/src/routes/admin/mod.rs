pub mod alerts;
pub mod broadcast;
pub mod cold;
pub mod deployments;
pub mod indexes;
pub mod invoices;
pub mod migrations;
pub mod providers;
pub mod rate_cards;
pub mod replicas;
pub mod tenants;
pub mod tokens;
pub mod usage;
pub mod vms;

use axum::routing::{get, post, put};
use axum::Router;

use crate::state::AppState;

pub fn admin_routes() -> Router<AppState> {
    Router::new()
        .route("/tokens", post(tokens::create_token))
        .route(
            "/tenants",
            get(tenants::list_tenants).post(tenants::create_tenant),
        )
        .route(
            "/tenants/:id",
            get(tenants::get_tenant)
                .put(tenants::update_tenant)
                .delete(tenants::delete_tenant),
        )
        .route(
            "/tenants/:id/deployments",
            get(deployments::list_deployments).post(deployments::create_deployment),
        )
        .route(
            "/deployments/:id",
            put(deployments::update_deployment).delete(deployments::terminate_deployment),
        )
        .route(
            "/deployments/:id/health-check",
            post(deployments::health_check_deployment),
        )
        .route("/fleet", get(deployments::list_fleet))
        .route("/providers", get(providers::list_providers))
        .route("/tenants/:id/usage", get(usage::get_tenant_usage))
        .route(
            "/tenants/:id/rate-card",
            get(rate_cards::get_rate_card).put(rate_cards::set_rate_override),
        )
        .route(
            "/tenants/:id/quotas",
            get(tenants::get_quotas).put(tenants::update_quotas),
        )
        .route(
            "/tenants/:id/invoices",
            get(invoices::list_tenant_invoices).post(invoices::generate_invoice),
        )
        .route("/invoices/:id/finalize", post(invoices::finalize_invoice))
        .route("/customers/:id/sync-stripe", post(tenants::sync_stripe))
        .route(
            "/customers/:id/reactivate",
            post(tenants::reactivate_customer),
        )
        .route("/customers/:id/suspend", post(tenants::suspend_customer))
        .route("/customers/:id/audit", get(tenants::get_customer_audit))
        .route(
            "/customers/:id/snapshot",
            get(tenants::get_customer_snapshot),
        )
        .route("/alerts", get(alerts::list_alerts))
        .route("/broadcast", post(broadcast::broadcast_email))
        .route("/cold", get(cold::list_cold_snapshots))
        .route("/cold/:snapshot_id", get(cold::get_cold_snapshot))
        .route("/cold/:snapshot_id/restore", post(cold::admin_restore))
        .route(
            "/migrations",
            get(migrations::list_migrations).post(migrations::trigger_migration),
        )
        .route(
            "/migrations/cross-provider",
            post(migrations::trigger_cross_provider_migration),
        )
        .route("/billing/run", post(invoices::run_batch_billing))
        .route("/vms", get(vms::list_vms))
        .route("/vms/:id", get(vms::get_vm_detail))
        .route("/vms/:id/kill", post(vms::kill_vm))
        .route("/replicas", get(replicas::list_replicas))
        .route("/tenants/:id/indexes", post(indexes::seed_index))
}

pub fn nest_admin_subtree(
    router: Router<AppState>,
    wrap_admin_routes: impl FnOnce(Router<AppState>) -> Router<AppState>,
) -> Router<AppState> {
    router.nest("/admin", wrap_admin_routes(admin_routes()))
}
