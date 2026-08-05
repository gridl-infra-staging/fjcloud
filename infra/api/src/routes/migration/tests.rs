use super::*;

mod compute_availability_tests {
    use super::*;

    fn capabilities(
        cancel: bool,
        preview: bool,
        resume: bool,
        replace: bool,
        verify: bool,
    ) -> AlgoliaMigrationCapabilities {
        AlgoliaMigrationCapabilities {
            cancel,
            preview,
            resume,
            replace,
            verify,
        }
    }

    #[test]
    fn available_when_flag_on_and_engine_supports_migration() {
        let response = compute_availability(
            true,
            capabilities(true, true, false, true, true),
            capabilities(true, true, false, true, true),
        );

        assert!(response.available);
        assert_eq!(response.reason, None);
        assert_eq!(response.message, "Algolia migration is available.");
        assert_eq!(
            response.capabilities,
            capabilities(true, true, false, true, true)
        );
    }

    #[test]
    fn unavailable_when_flag_off() {
        let response = compute_availability(
            false,
            capabilities(true, true, false, true, true),
            capabilities(true, true, false, true, true),
        );

        assert_eq!(
            response,
            AlgoliaMigrationAvailabilityResponse::unavailable()
        );
    }

    #[test]
    fn unavailable_when_engine_does_not_support_cancel() {
        let response = compute_availability(
            true,
            capabilities(true, true, false, true, true),
            capabilities(false, true, false, true, true),
        );

        assert_eq!(
            response,
            AlgoliaMigrationAvailabilityResponse::unavailable()
        );
    }

    #[test]
    fn replace_reflects_engine_support() {
        let response = compute_availability(
            true,
            capabilities(true, true, false, true, true),
            capabilities(true, true, false, false, true),
        );

        assert!(response.available);
        assert_eq!(
            response.capabilities,
            capabilities(true, true, false, false, true)
        );
    }

    /// The console only offers cutover verification where the backend can
    /// actually serve it, so provider-scoped availability must publish
    /// `verify` alongside the other lifecycle operations.
    #[test]
    fn verify_is_published_only_for_algolia_sources() {
        let expectations = [
            (SourceImportProvider::Algolia, true, true),
            (SourceImportProvider::Meilisearch, false, true),
            (SourceImportProvider::Typesense, false, false),
        ];

        for (provider, expected_verify, expected_preview) in expectations {
            let response = compute_availability(
                true,
                capabilities::route_mounted_migration_capabilities(),
                capabilities::engine_supported_migration_capabilities(provider),
            );

            assert!(response.available, "{} availability", provider.as_str());
            assert_eq!(
                response.capabilities,
                capabilities(true, expected_preview, false, true, expected_verify),
                "{} must publish its exact provider-scoped capability set",
                provider.as_str()
            );
        }
    }

    #[test]
    fn resume_is_never_true_even_when_both_inputs_say_true() {
        let response = compute_availability(
            true,
            capabilities(true, true, true, true, true),
            capabilities(true, true, true, true, true),
        );

        assert!(response.available);
        assert!(!response.capabilities.resume);
    }
}

fn provider_claims() -> SignedEligibilityClaims {
    SignedEligibilityClaims {
        domain: DESTINATION_ELIGIBILITY_DOMAIN.to_string(),
        version: 1,
        phase: AlgoliaEligibilityPhase::Provider,
        mode: AlgoliaImportDestinationKind::Create,
        customer_id: "11111111-1111-1111-1111-111111111111".to_string(),
        region: "us-east-1".to_string(),
        name: "products".to_string(),
        lifecycle_generation: None,
        routing_identity: None,
        exp: 2_000_000_000,
    }
}

fn target(region: &str, name: &str) -> eligibility::AlgoliaDestinationEligibilityTargetRequest {
    eligibility::AlgoliaDestinationEligibilityTargetRequest {
        region: region.to_string(),
        name: name.to_string(),
    }
}

fn migration_failure(error: ApiError) -> (StatusCode, String) {
    match error {
        ApiError::Migration {
            status, message, ..
        } => (status, message),
        other => panic!("expected migration error, got {other:?}"),
    }
}

fn assert_migration_failure(error: ApiError, expected_status: StatusCode, expected_message: &str) {
    let (status, message) = migration_failure(error);
    assert_eq!(status, expected_status);
    assert_eq!(message, expected_message);
}

#[test]
fn serde_offending_field_extracts_labelled_field_names_by_value() {
    let unknown = serde_json::from_str::<ListMeilisearchIndexesRequest>(
        r#"{"endpoint":"https://meili.example","apiKey":"key","appId":"wrong"}"#,
    )
    .expect_err("unknown fields must produce a labelled serde error");
    let missing = serde_json::from_str::<ListMeilisearchIndexesRequest>(
        r#"{"endpoint":"https://meili.example"}"#,
    )
    .expect_err("missing fields must produce a labelled serde error");
    let duplicate = serde_json::from_str::<ListMeilisearchIndexesRequest>(
        r#"{"endpoint":"https://meili.example","apiKey":"key","apiKey":"again"}"#,
    )
    .expect_err("duplicate fields must produce a labelled serde error");

    assert_eq!(serde_offending_field(&unknown), Some("appId".to_string()));
    assert_eq!(serde_offending_field(&missing), Some("apiKey".to_string()));
    assert_eq!(
        serde_offending_field(&duplicate),
        Some("apiKey".to_string())
    );
}

#[test]
fn valid_provider_claims_are_accepted() {
    let claims = provider_claims();
    assert!(validate_provider_claims(
        &claims,
        claims.exp - 1,
        "11111111-1111-1111-1111-111111111111",
        AlgoliaImportDestinationKind::Create,
        &target("us-east-1", "products"),
    )
    .is_ok());
}

#[test]
fn provider_claims_accept_later_selected_create_destination_name() {
    let claims = provider_claims();
    assert!(validate_provider_claims(
        &claims,
        claims.exp - 1,
        "11111111-1111-1111-1111-111111111111",
        AlgoliaImportDestinationKind::Create,
        &target("us-east-1", "customer_selected_products"),
    )
    .is_ok());
}

#[test]
fn expired_provider_envelope_is_rejected() {
    let claims = provider_claims();
    let error = validate_provider_claims(
        &claims,
        claims.exp,
        "11111111-1111-1111-1111-111111111111",
        AlgoliaImportDestinationKind::Create,
        &target("us-east-1", "products"),
    )
    .expect_err("an envelope at or past its expiry is rejected");
    assert_migration_failure(error, StatusCode::BAD_REQUEST, "eligibility_token_expired");
}

#[test]
fn non_provider_phase_envelope_is_rejected() {
    let mut claims = provider_claims();
    claims.phase = AlgoliaEligibilityPhase::Target;
    let error = validate_provider_claims(
        &claims,
        claims.exp - 1,
        "11111111-1111-1111-1111-111111111111",
        AlgoliaImportDestinationKind::Create,
        &target("us-east-1", "products"),
    )
    .expect_err("only provider-phase envelopes may be replayed into the target phase");
    assert_migration_failure(error, StatusCode::BAD_REQUEST, "eligibility_phase_mismatch");
}

#[test]
fn cross_customer_envelope_is_rejected() {
    let claims = provider_claims();
    let error = validate_provider_claims(
        &claims,
        claims.exp - 1,
        "22222222-2222-2222-2222-222222222222",
        AlgoliaImportDestinationKind::Create,
        &target("us-east-1", "products"),
    )
    .expect_err("an envelope minted for another customer is rejected");
    assert_migration_failure(
        error,
        StatusCode::FORBIDDEN,
        "eligibility_customer_mismatch",
    );
}

#[test]
fn changed_destination_binding_is_rejected() {
    let claims = provider_claims();
    let error = validate_provider_claims(
        &claims,
        claims.exp - 1,
        "11111111-1111-1111-1111-111111111111",
        AlgoliaImportDestinationKind::Create,
        &target("eu-west-1", "products"),
    )
    .expect_err("a region change invalidates the provider envelope binding");
    assert_migration_failure(error, StatusCode::BAD_REQUEST, "destination_changed");
}

#[test]
fn changed_provider_mode_is_rejected() {
    let claims = provider_claims();
    let error = validate_provider_claims(
        &claims,
        claims.exp - 1,
        "11111111-1111-1111-1111-111111111111",
        AlgoliaImportDestinationKind::Replace,
        &target("us-east-1", "customer_selected_products"),
    )
    .expect_err("a mode change invalidates the provider envelope binding");
    assert_migration_failure(error, StatusCode::BAD_REQUEST, "destination_changed");
}

fn list_cursor_claims() -> SignedListCursorClaims {
    SignedListCursorClaims {
        domain: LIST_CURSOR_DOMAIN.to_string(),
        version: 1,
        customer_id: "11111111-1111-1111-1111-111111111111".to_string(),
        created_at_micros: 1_700_000_000_000_000,
        id: "01890f4f-a0b1-7298-9f0b-7e6fdf45d111".to_string(),
        exp: 2_000_000_000,
    }
}

fn bad_request_message(error: ApiError) -> String {
    match error {
        ApiError::BadRequest(message) => message,
        other => panic!("expected bad-request error, got {other:?}"),
    }
}

#[test]
fn valid_list_cursor_claims_are_accepted() {
    let claims = list_cursor_claims();
    let cursor = validate_list_cursor_claims(
        &claims,
        claims.exp - 1,
        "11111111-1111-1111-1111-111111111111",
    )
    .expect("a fresh, matching cursor is accepted");
    assert_eq!(cursor.id.to_string(), claims.id);
    assert_eq!(
        cursor.created_at.timestamp_micros(),
        claims.created_at_micros
    );
}

#[test]
fn expired_list_cursor_is_rejected() {
    let claims = list_cursor_claims();
    // Clock exactly at expiry is already stale: rejection is inclusive of `exp`.
    let error =
        validate_list_cursor_claims(&claims, claims.exp, "11111111-1111-1111-1111-111111111111")
            .expect_err("a cursor at or past its expiry is rejected");
    assert_eq!(bad_request_message(error), "list_cursor_expired");
}

#[test]
fn cross_customer_list_cursor_is_rejected() {
    let claims = list_cursor_claims();
    // A non-expired cursor minted for another tenant must never be honored,
    // and the rejection must be indistinguishable from a tampered cursor.
    let error = validate_list_cursor_claims(
        &claims,
        claims.exp - 1,
        "22222222-2222-2222-2222-222222222222",
    )
    .expect_err("a cursor minted for another customer is rejected");
    assert_eq!(bad_request_message(error), "invalid_list_cursor");
}

#[test]
fn foreign_domain_list_cursor_is_rejected() {
    let mut claims = list_cursor_claims();
    claims.domain = "fjcloud.some_other_domain.v1".to_string();
    let error = validate_list_cursor_claims(
        &claims,
        claims.exp - 1,
        "11111111-1111-1111-1111-111111111111",
    )
    .expect_err("a cursor from a different token domain is rejected");
    assert_eq!(bad_request_message(error), "invalid_list_cursor");
}

#[test]
fn foreign_domain_envelope_is_rejected() {
    let mut claims = provider_claims();
    claims.domain = "fjcloud.some_other_domain.v1".to_string();
    let error = validate_provider_claims(
        &claims,
        claims.exp - 1,
        "11111111-1111-1111-1111-111111111111",
        AlgoliaImportDestinationKind::Create,
        &target("us-east-1", "products"),
    )
    .expect_err("an envelope from a different HMAC domain is rejected");
    assert_migration_failure(error, StatusCode::BAD_REQUEST, "invalid_eligibility_token");
}

#[test]
fn foreign_version_envelope_is_rejected() {
    let mut claims = provider_claims();
    claims.version = 2;
    let error = validate_provider_claims(
        &claims,
        claims.exp - 1,
        "11111111-1111-1111-1111-111111111111",
        AlgoliaImportDestinationKind::Create,
        &target("us-east-1", "products"),
    )
    .expect_err("an envelope from a different contract version is rejected");
    assert_migration_failure(error, StatusCode::BAD_REQUEST, "invalid_eligibility_token");
}
