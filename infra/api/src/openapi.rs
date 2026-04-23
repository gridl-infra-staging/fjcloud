use utoipa::openapi::security::{HttpAuthScheme, HttpBuilder, SecurityScheme};
use utoipa::{Modify, OpenApi};

/// Security scheme name used across all authenticated endpoints.
/// Reference this constant when adding `security(("bearer_jwt" = []))` to path attributes.
pub const BEARER_SCHEME_NAME: &str = "bearer_jwt";

#[derive(OpenApi)]
#[openapi(
    info(
        title = "fjcloud API",
        description = "Cloud infrastructure and billing platform API",
        version = "0.1.0",
    ),
    modifiers(&SecurityAddon),
    security(
        ("bearer_jwt" = [])
    ),
    paths(
        crate::routes::auth::register,
        crate::routes::auth::login,
        crate::routes::auth::verify_email,
        crate::routes::auth::forgot_password,
        crate::routes::auth::reset_password,
        crate::routes::auth::resend_verification,
        crate::routes::onboarding::get_status,
        crate::routes::onboarding::generate_credentials,
        crate::routes::account::get_profile,
        crate::routes::account::update_profile,
        crate::routes::account::change_password,
        crate::routes::account::delete_account,
        crate::routes::api_keys::create_api_key,
        crate::routes::api_keys::list_api_keys,
        crate::routes::api_keys::delete_api_key,
        crate::routes::billing::get_estimate,
        crate::routes::billing::create_setup_intent,
        crate::routes::billing::list_payment_methods,
        crate::routes::billing::delete_payment_method,
        crate::routes::billing::set_default_payment_method,
        crate::routes::billing::create_checkout_session,
        crate::routes::billing::get_subscription,
        crate::routes::billing::cancel_subscription,
        crate::routes::billing::upgrade_subscription,
        crate::routes::billing::downgrade_subscription,
        // Stage 4 — Index lifecycle and search
        crate::routes::indexes::lifecycle::create_index,
        crate::routes::indexes::lifecycle::list_indexes,
        crate::routes::indexes::lifecycle::get_index,
        crate::routes::indexes::lifecycle::delete_index,
        crate::routes::indexes::search::test_search,
        crate::routes::indexes::lifecycle::create_replica,
        crate::routes::indexes::lifecycle::list_replicas,
        crate::routes::indexes::lifecycle::delete_replica,
        crate::routes::indexes::lifecycle::restore_index,
        crate::routes::indexes::lifecycle::restore_status,
        // Stage 4 — Configuration proxy
        crate::routes::indexes::settings::get_settings,
        crate::routes::indexes::settings::update_settings,
        crate::routes::indexes::rules::search_rules,
        crate::routes::indexes::rules::get_rule,
        crate::routes::indexes::rules::save_rule,
        crate::routes::indexes::rules::delete_rule,
        crate::routes::indexes::synonyms::search_synonyms,
        crate::routes::indexes::synonyms::get_synonym,
        crate::routes::indexes::synonyms::save_synonym,
        crate::routes::indexes::synonyms::delete_synonym,
        crate::routes::indexes::dictionaries::get_dictionary_languages,
        crate::routes::indexes::dictionaries::search_dictionary_entries,
        crate::routes::indexes::dictionaries::batch_dictionary_entries,
        crate::routes::indexes::dictionaries::get_dictionary_settings,
        crate::routes::indexes::dictionaries::save_dictionary_settings,
        // Stage 4 — Documents, AI, and advanced features
        crate::routes::indexes::documents::batch_documents,
        crate::routes::indexes::documents::browse_documents,
        crate::routes::indexes::documents::get_document,
        crate::routes::indexes::documents::delete_document,
        crate::routes::indexes::personalization::get_personalization_strategy,
        crate::routes::indexes::personalization::save_personalization_strategy,
        crate::routes::indexes::personalization::delete_personalization_strategy,
        crate::routes::indexes::personalization::get_personalization_profile,
        crate::routes::indexes::personalization::delete_personalization_profile,
        crate::routes::indexes::security_sources::get_security_sources,
        crate::routes::indexes::security_sources::append_security_source,
        crate::routes::indexes::security_sources::delete_security_source,
        crate::routes::indexes::recommendations::recommend,
        crate::routes::indexes::chat::chat,
        crate::routes::indexes::suggestions::get_qs_config,
        crate::routes::indexes::suggestions::save_qs_config,
        crate::routes::indexes::suggestions::delete_qs_config,
        crate::routes::indexes::suggestions::get_qs_status,
        // Stage 5 — Usage and invoices
        crate::routes::usage::get_usage,
        crate::routes::usage::get_usage_daily,
        crate::routes::invoices::list_invoices,
        crate::routes::invoices::get_invoice,
        // Stage 5 — Pricing (public, no auth)
        crate::routes::pricing::compare,
        // Stage 5 — Analytics proxy
        crate::routes::indexes::analytics::get_analytics_searches,
        crate::routes::indexes::analytics::get_analytics_searches_count,
        crate::routes::indexes::analytics::get_analytics_no_results,
        crate::routes::indexes::analytics::get_analytics_no_result_rate,
        crate::routes::indexes::analytics::get_analytics_status,
        // Stage 5 — Experiments proxy
        crate::routes::indexes::experiments::list_experiments,
        crate::routes::indexes::experiments::create_experiment,
        crate::routes::indexes::experiments::get_experiment,
        crate::routes::indexes::experiments::update_experiment,
        crate::routes::indexes::experiments::delete_experiment,
        crate::routes::indexes::experiments::start_experiment,
        crate::routes::indexes::experiments::stop_experiment,
        crate::routes::indexes::experiments::conclude_experiment,
        crate::routes::indexes::experiments::get_experiment_results,
        // Stage 5 — Debug events and index keys
        crate::routes::indexes::debug::get_debug_events,
        crate::routes::indexes::lifecycle::create_key,
        // Stage 5 — AllYourBase instances
        crate::routes::allyourbase::list_instances,
        crate::routes::allyourbase::get_instance,
        crate::routes::allyourbase::delete_instance,
        // Stage 5 — Algolia migration
        crate::routes::migration::algolia_list_indexes,
        crate::routes::migration::algolia_migrate,
    ),
    components(schemas(
        crate::routes::auth::RegisterRequest,
        crate::routes::auth::AuthResponse,
        crate::routes::auth::LoginRequest,
        crate::routes::auth::VerifyEmailRequest,
        crate::routes::auth::ForgotPasswordRequest,
        crate::routes::auth::ResetPasswordRequest,
        crate::routes::auth::MessageResponse,
        crate::errors::ErrorResponse,
        crate::models::customer::BillingPlan,
        crate::routes::onboarding::OnboardingStatusResponse,
        crate::routes::onboarding::FreeTierLimitsResponse,
        crate::routes::onboarding::CredentialsResponse,
        crate::routes::account::CustomerProfileResponse,
        crate::routes::account::UpdateProfileRequest,
        crate::routes::account::ChangePasswordRequest,
        crate::routes::account::DeleteAccountRequest,
        crate::routes::api_keys::CreateApiKeyRequest,
        crate::routes::api_keys::CreateApiKeyResponse,
        crate::routes::api_keys::ApiKeyListItem,
        billing::plan::PlanTier,
        crate::routes::billing::SetupIntentResponse,
        crate::routes::billing::PaymentMethodResponse,
        crate::routes::billing::EstimateLineItem,
        crate::routes::billing::EstimatedBillResponse,
        crate::routes::billing::CreateCheckoutSessionRequest,
        crate::routes::billing::CheckoutSessionResponseBody,
        crate::routes::billing::CancelSubscriptionRequest,
        crate::routes::billing::SubscriptionResponse,
        crate::routes::billing::UpdateSubscriptionRequest,
        // Stage 4 — Index lifecycle and search DTOs
        crate::routes::indexes::CreateIndexRequest,
        crate::routes::indexes::DeleteIndexRequest,
        crate::routes::indexes::SearchRequest,
        crate::routes::indexes::CreateReplicaRequest,
        crate::routes::indexes::IndexResponse,
        crate::models::index_replica::CustomerIndexReplicaSummary,
        // Stage 4 — Configuration DTOs
        crate::routes::indexes::RulesSearchRequest,
        crate::routes::indexes::SynonymsSearchRequest,
        // Stage 4 — Document DTOs
        crate::routes::indexes::BatchDocumentsRequest,
        crate::routes::indexes::BatchDocumentOperation,
        crate::routes::indexes::BrowseDocumentsRequest,
        // Stage 5 — Usage and invoice DTOs
        crate::usage::DailyUsageEntry,
        crate::usage::UsageSummaryResponse,
        crate::usage::RegionUsageSummary,
        crate::routes::invoices::InvoiceListItem,
        crate::routes::invoices::LineItemResponse,
        crate::routes::invoices::InvoiceDetailResponse,
        // Stage 5 — Index keys DTO
        crate::routes::indexes::CreateKeyRequest,
        // Stage 5 — AllYourBase DTO
        crate::routes::allyourbase::InstanceResponse,
    ))
)]
pub struct ApiDoc;

/// Registers the bearer JWT security scheme component in the OpenAPI spec.
/// Defined once here so later stages reference the same scheme name.
struct SecurityAddon;

impl Modify for SecurityAddon {
    fn modify(&self, openapi: &mut utoipa::openapi::OpenApi) {
        let components = openapi.components.get_or_insert_with(Default::default);
        components.add_security_scheme(
            BEARER_SCHEME_NAME,
            SecurityScheme::Http(
                HttpBuilder::new()
                    .scheme(HttpAuthScheme::Bearer)
                    .bearer_format("JWT")
                    .build(),
            ),
        );
    }
}
