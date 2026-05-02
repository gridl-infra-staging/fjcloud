use axum::{
    extract::DefaultBodyLimit,
    middleware,
    routing::{delete, get, post},
    Router,
};

use crate::openapi::ApiDoc;
use crate::routes::account;
use crate::routes::admin::nest_admin_subtree;
use crate::routes::auth;
use crate::routes::billing;
use crate::routes::browser_error_reporting;
use crate::routes::health;
use crate::routes::indexes;
use crate::routes::migration;
use crate::routes::onboarding;
use crate::routes::pricing;
use crate::routes::public_site;
use crate::routes::webhooks;
use crate::state::AppState;
use utoipa::OpenApi;
use utoipa_scalar::{Scalar, Servable as _};

const BROWSER_ERROR_ROUTE_BODY_LIMIT_BYTES: usize = 4096;

pub(super) fn build_auth_rate_limited_routes(
    auth_rate_limiter: super::RateLimiter,
) -> Router<AppState> {
    Router::new()
        .route(
            "/browser-errors",
            post(browser_error_reporting::report_browser_error)
                .layer(DefaultBodyLimit::max(BROWSER_ERROR_ROUTE_BODY_LIMIT_BYTES)),
        )
        .route("/auth/register", post(auth::register))
        .route("/auth/login", post(auth::login))
        .route("/auth/verify-email", post(auth::verify_email))
        .route("/auth/forgot-password", post(auth::forgot_password))
        .route("/auth/resend-verification", post(auth::resend_verification))
        .route("/pricing/compare", post(pricing::compare))
        .route_layer(middleware::from_fn_with_state(
            auth_rate_limiter,
            super::middleware::auth_rate_limit_middleware,
        ))
}

pub(super) fn build_tenant_routes(
    state: &AppState,
    rate_config: &super::RateLimitConfig,
) -> Router<AppState> {
    let tenant_routes = tenant_authenticated_routes();

    if let Some(tenant_rpm) = rate_config.tenant_rpm {
        let tenant_rate_state = super::middleware::TenantRateLimitState {
            limiter: super::RateLimiter::new(tenant_rpm, rate_config.tenant_window),
            jwt_secret: state.jwt_secret.clone(),
        };
        tenant_routes.route_layer(middleware::from_fn_with_state(
            tenant_rate_state,
            super::middleware::tenant_rate_limit_middleware,
        ))
    } else {
        tenant_routes
    }
}

/// Merges all route subtrees—auth-limited, health, OpenAPI docs, tenant,
/// webhook, internal, and v1—into a single router before middleware layers
/// are applied.
pub(super) fn build_router_without_layers(
    state: &AppState,
    auth_rate_limited_routes: Router<AppState>,
    tenant_routes: Router<AppState>,
) -> Router<AppState> {
    let internal = super::internal_routes().route_layer(middleware::from_fn_with_state(
        state.clone(),
        crate::routes::internal::internal_auth_middleware,
    ));

    Router::new()
        .route("/", get(public_site::landing_page))
        .route("/robots.txt", get(public_site::robots_txt))
        .route("/favicon.ico", get(public_site::favicon))
        .route(
            "/flapjack_cloud_preview.png",
            get(public_site::preview_image),
        )
        .merge(auth_rate_limited_routes)
        .route("/health", get(health::health))
        .merge(Scalar::with_url("/docs", ApiDoc::openapi()))
        .merge(tenant_routes)
        .route("/auth/reset-password", post(auth::reset_password))
        .route("/webhooks/stripe", post(webhooks::stripe_webhook))
        .route("/webhooks/ses/sns", post(webhooks::ses_sns_webhook))
        .nest("/internal", internal)
        .nest("/v1", super::v1_routes())
}

pub(super) fn nest_admin_routes_with_optional_rate_limit(
    router: Router<AppState>,
    rate_config: &super::RateLimitConfig,
) -> Router<AppState> {
    nest_admin_subtree(router, |admin| {
        if let Some(admin_rpm) = rate_config.admin_rpm {
            let admin_limiter = super::RateLimiter::new(admin_rpm, rate_config.admin_window);
            admin.route_layer(middleware::from_fn_with_state(
                admin_limiter,
                super::middleware::admin_rate_limit_middleware,
            ))
        } else {
            admin
        }
    })
}

fn tenant_authenticated_routes() -> Router<AppState> {
    let tenant_routes = add_usage_and_invoice_routes(Router::new());
    let tenant_routes = add_billing_routes(tenant_routes);
    let tenant_routes = add_account_and_api_key_routes(tenant_routes);
    let tenant_routes = add_index_lifecycle_and_replica_routes(tenant_routes);
    let tenant_routes = add_index_configuration_routes(tenant_routes);
    let tenant_routes = add_index_analytics_routes(tenant_routes);
    let tenant_routes = add_index_experiment_debug_and_key_routes(tenant_routes);

    let tenant_routes = add_migration_routes(tenant_routes);

    add_onboarding_routes(tenant_routes)
}

fn add_usage_and_invoice_routes(router: Router<AppState>) -> Router<AppState> {
    router
        .route("/usage", get(crate::routes::usage::get_usage))
        .route("/usage/daily", get(crate::routes::usage::get_usage_daily))
        .route("/invoices", get(crate::routes::invoices::list_invoices))
        .route(
            "/invoices/:invoice_id",
            get(crate::routes::invoices::get_invoice),
        )
}

/// Registers billing routes: estimate, setup-intent, portal,
/// and payment method management.
fn add_billing_routes(router: Router<AppState>) -> Router<AppState> {
    router
        .route("/billing/estimate", get(billing::get_estimate))
        .route(
            "/billing/publishable-key",
            get(billing::get_publishable_key),
        )
        .route("/billing/setup-intent", post(billing::create_setup_intent))
        .route(
            "/billing/portal",
            post(billing::create_billing_portal_session),
        )
        .route(
            "/billing/payment-methods",
            get(billing::list_payment_methods),
        )
        .route(
            "/billing/payment-methods/:pm_id",
            delete(billing::delete_payment_method),
        )
        .route(
            "/billing/payment-methods/:pm_id/default",
            post(billing::set_default_payment_method),
        )
}

/// Registers account profile CRUD, password change, and API key
/// management routes.
fn add_account_and_api_key_routes(router: Router<AppState>) -> Router<AppState> {
    router
        .route(
            "/account",
            get(account::get_profile)
                .patch(account::update_profile)
                .delete(account::delete_account),
        )
        .route("/account/export", get(account::export_account))
        .route("/account/change-password", post(account::change_password))
        .route(
            "/api-keys",
            get(crate::routes::api_keys::list_api_keys)
                .post(crate::routes::api_keys::create_api_key),
        )
        .route(
            "/api-keys/:key_id",
            delete(crate::routes::api_keys::delete_api_key),
        )
}

/// Registers index CRUD, search, replica management, and restore routes.
fn add_index_lifecycle_and_replica_routes(router: Router<AppState>) -> Router<AppState> {
    router
        .route(
            "/indexes",
            get(indexes::list_indexes).post(indexes::create_index),
        )
        .route(
            "/indexes/:name",
            get(indexes::get_index).delete(indexes::delete_index),
        )
        .route("/indexes/:name/search", post(indexes::test_search))
        .route(
            "/indexes/:name/replicas",
            get(indexes::list_replicas).post(indexes::create_replica),
        )
        .route(
            "/indexes/:name/replicas/:replica_id",
            delete(indexes::delete_replica),
        )
        .route("/indexes/:name/restore", post(indexes::restore_index))
        .route(
            "/indexes/:name/restore-status",
            get(indexes::restore_status),
        )
}

/// Registers index configuration routes: settings, rules, synonyms,
/// dictionaries, documents, personalization, security, recommendations,
/// chat, and suggestion endpoints.
fn add_index_configuration_routes(router: Router<AppState>) -> Router<AppState> {
    router
        .route(
            "/indexes/:name/settings",
            get(indexes::get_settings).put(indexes::update_settings),
        )
        .route("/indexes/:name/rules/search", post(indexes::search_rules))
        .route(
            "/indexes/:name/rules/:object_id",
            get(indexes::get_rule)
                .put(indexes::save_rule)
                .delete(indexes::delete_rule),
        )
        .route(
            "/indexes/:name/synonyms/search",
            post(indexes::search_synonyms),
        )
        .route(
            "/indexes/:name/synonyms/:object_id",
            get(indexes::get_synonym)
                .put(indexes::save_synonym)
                .delete(indexes::delete_synonym),
        )
        .route(
            "/indexes/:name/dictionaries/languages",
            get(indexes::get_dictionary_languages),
        )
        .route(
            "/indexes/:name/dictionaries/:dictionary_name/search",
            post(indexes::search_dictionary_entries),
        )
        .route(
            "/indexes/:name/dictionaries/:dictionary_name/batch",
            post(indexes::batch_dictionary_entries),
        )
        .route(
            "/indexes/:name/dictionaries/settings",
            get(indexes::get_dictionary_settings).put(indexes::save_dictionary_settings),
        )
        .route("/indexes/:name/batch", post(indexes::batch_documents))
        .route("/indexes/:name/browse", post(indexes::browse_documents))
        .route(
            "/indexes/:name/objects/:object_id",
            get(indexes::get_document).delete(indexes::delete_document),
        )
        .route(
            "/indexes/:name/personalization/strategy",
            get(indexes::get_personalization_strategy)
                .put(indexes::save_personalization_strategy)
                .delete(indexes::delete_personalization_strategy),
        )
        .route(
            "/indexes/:name/personalization/profiles/:user_token",
            get(indexes::get_personalization_profile)
                .delete(indexes::delete_personalization_profile),
        )
        .route(
            "/indexes/:name/security/sources",
            get(indexes::get_security_sources).post(indexes::append_security_source),
        )
        .route(
            "/indexes/:name/security/sources/:source",
            delete(indexes::delete_security_source),
        )
        .route("/indexes/:name/recommendations", post(indexes::recommend))
        .route("/indexes/:name/chat", post(indexes::chat))
        .route(
            "/indexes/:name/suggestions",
            get(indexes::get_qs_config)
                .put(indexes::save_qs_config)
                .delete(indexes::delete_qs_config),
        )
        .route(
            "/indexes/:name/suggestions/status",
            get(indexes::get_qs_status),
        )
}

/// Registers search analytics routes: search counts, no-result queries,
/// no-result rate, and analytics status.
fn add_index_analytics_routes(router: Router<AppState>) -> Router<AppState> {
    router
        .route(
            "/indexes/:name/analytics/searches",
            get(indexes::get_analytics_searches),
        )
        .route(
            "/indexes/:name/analytics/searches/count",
            get(indexes::get_analytics_searches_count),
        )
        .route(
            "/indexes/:name/analytics/searches/noResults",
            get(indexes::get_analytics_no_results),
        )
        .route(
            "/indexes/:name/analytics/searches/noResultRate",
            get(indexes::get_analytics_no_result_rate),
        )
        .route(
            "/indexes/:name/analytics/status",
            get(indexes::get_analytics_status),
        )
}

/// Registers experiment lifecycle routes (CRUD, start/stop/conclude/results),
/// debug event endpoints, and API key creation.
fn add_index_experiment_debug_and_key_routes(router: Router<AppState>) -> Router<AppState> {
    router
        .route(
            "/indexes/:name/experiments",
            get(indexes::list_experiments).post(indexes::create_experiment),
        )
        .route(
            "/indexes/:name/experiments/:id",
            get(indexes::get_experiment)
                .put(indexes::update_experiment)
                .delete(indexes::delete_experiment),
        )
        .route(
            "/indexes/:name/experiments/:id/start",
            post(indexes::start_experiment),
        )
        .route(
            "/indexes/:name/experiments/:id/stop",
            post(indexes::stop_experiment),
        )
        .route(
            "/indexes/:name/experiments/:id/conclude",
            post(indexes::conclude_experiment),
        )
        .route(
            "/indexes/:name/experiments/:id/results",
            get(indexes::get_experiment_results),
        )
        .route(
            "/indexes/:name/events/debug",
            get(indexes::get_debug_events),
        )
        .route("/indexes/:name/keys", post(indexes::create_key))
}

fn add_migration_routes(router: Router<AppState>) -> Router<AppState> {
    router
        .route(
            "/migration/algolia/list-indexes",
            post(migration::algolia_list_indexes),
        )
        .route(
            "/migration/algolia/migrate",
            post(migration::algolia_migrate),
        )
}

fn add_onboarding_routes(router: Router<AppState>) -> Router<AppState> {
    router
        .route("/onboarding/status", get(onboarding::get_status))
        .route(
            "/onboarding/credentials",
            post(onboarding::generate_credentials),
        )
}
