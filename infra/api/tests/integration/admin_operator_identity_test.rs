//! Live-DB operator-identity contract tests for admin authentication.

use api::auth::admin::{bootstrap_admin_user_if_empty, ADMIN_CREDENTIAL_PREFIX_LENGTH};
use api::auth::{AdminAuth, AuthError};
use api::services::audit_log::ACTION_IMPERSONATION_TOKEN_CREATED;
use axum::extract::FromRequestParts;
use axum::http::{Request, StatusCode};
use sqlx::{PgPool, Row};
use tower::ServiceExt;
use uuid::Uuid;

use crate::common::admin_audit_test_support::{
    actor_ids_for_action_and_target, admin_token_request, admin_token_request_with_key,
    admin_users_row_count, admin_users_table_exists, audit_row_count_for_target, cleanup_target,
    connect_shared_public_and_migrate, credential_is_registered, impersonation_app,
    latest_actor_id, latest_metadata, register_operator, register_operator_with_credential,
    require_admin_users_contract, response_json, revoke_operator, sole_admin_user_id,
    sole_admin_user_identifier,
};
use crate::common::support::pg_schema_harness;

async fn extract_admin_auth(pool: &PgPool, credential: &str) -> Result<AdminAuth, AuthError> {
    let state = crate::common::TestStateBuilder::new()
        .with_pool(pool.clone())
        .build();
    let request = Request::builder()
        .header("x-admin-key", credential)
        .body(())
        .expect("build admin-auth extractor request");
    let (mut parts, _) = request.into_parts();
    AdminAuth::from_request_parts(&mut parts, &state).await
}

#[path = "durable_admin_session_contract.rs"]
mod durable_admin_session_contract;

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn admin_users_schema_contract() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("stage2_admin_users_schema").await
    else {
        return;
    };

    let columns = sqlx::query(
        "SELECT column_name, is_nullable, data_type, column_default \
         FROM information_schema.columns \
         WHERE table_schema = current_schema() AND table_name = 'admin_users' \
         ORDER BY ordinal_position",
    )
    .fetch_all(&harness.pool)
    .await
    .expect("query admin_users columns");
    let actual_columns: Vec<(String, String, String, Option<String>)> = columns
        .iter()
        .map(|row| {
            (
                row.get("column_name"),
                row.get("is_nullable"),
                row.get("data_type"),
                row.get("column_default"),
            )
        })
        .collect();
    assert_eq!(
        actual_columns,
        vec![
            (
                "id".into(),
                "NO".into(),
                "uuid".into(),
                Some("gen_random_uuid()".into())
            ),
            ("identifier".into(), "NO".into(), "text".into(), None),
            ("credential_prefix".into(), "NO".into(), "text".into(), None),
            ("credential_sha256".into(), "NO".into(), "text".into(), None),
            (
                "created_at".into(),
                "NO".into(),
                "timestamp with time zone".into(),
                Some("now()".into()),
            ),
            (
                "revoked_at".into(),
                "YES".into(),
                "timestamp with time zone".into(),
                None,
            ),
        ],
        "admin_users must expose exactly the Stage 2 persistence contract"
    );

    let constraints: Vec<(String, Vec<String>)> = sqlx::query_as(
        "SELECT tc.constraint_type, array_agg(kcu.column_name ORDER BY kcu.ordinal_position)::TEXT[] \
         FROM information_schema.table_constraints tc \
         JOIN information_schema.key_column_usage kcu \
           ON tc.constraint_schema = kcu.constraint_schema \
          AND tc.constraint_name = kcu.constraint_name \
         WHERE tc.table_schema = current_schema() \
           AND tc.table_name = 'admin_users' \
           AND tc.constraint_type IN ('PRIMARY KEY', 'UNIQUE') \
         GROUP BY tc.constraint_type, tc.constraint_name \
         ORDER BY tc.constraint_type, array_agg(kcu.column_name ORDER BY kcu.ordinal_position)::TEXT[]",
    )
    .fetch_all(&harness.pool)
    .await
    .expect("query admin_users uniqueness constraints");
    assert_eq!(
        constraints,
        vec![
            ("PRIMARY KEY".into(), vec!["id".into()]),
            ("UNIQUE".into(), vec!["credential_sha256".into()]),
            ("UNIQUE".into(), vec!["identifier".into()]),
        ]
    );

    let prefix_indexes: Vec<(String, bool)> = sqlx::query_as(
        "SELECT index_class.relname, index_meta.indisunique \
         FROM pg_catalog.pg_class table_class \
         JOIN pg_catalog.pg_namespace namespace ON namespace.oid = table_class.relnamespace \
         JOIN pg_catalog.pg_index index_meta ON index_meta.indrelid = table_class.oid \
         JOIN pg_catalog.pg_class index_class ON index_class.oid = index_meta.indexrelid \
         JOIN pg_catalog.pg_attribute attribute \
           ON attribute.attrelid = table_class.oid \
          AND attribute.attnum = ANY(index_meta.indkey) \
         WHERE namespace.nspname = current_schema() \
           AND table_class.relname = 'admin_users' \
           AND attribute.attname = 'credential_prefix'",
    )
    .fetch_all(&harness.pool)
    .await
    .expect("query admin_users credential-prefix index");
    assert_eq!(
        prefix_indexes.len(),
        1,
        "credential_prefix needs one lookup index"
    );
    assert!(
        !prefix_indexes[0].1,
        "credential_prefix collisions must remain representable"
    );
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn stage2_admin_auth_registered_credential_resolves_operator() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("stage2_auth_registered").await
    else {
        return;
    };
    let identifier = format!("stage2-registered-{}", Uuid::new_v4());
    let (operator_id, credential) = register_operator(&harness.pool, &identifier).await;

    let auth = extract_admin_auth(&harness.pool, &credential)
        .await
        .expect("registered operator credential must resolve");
    assert_eq!(auth.operator_id, operator_id);
    assert_eq!(auth.identifier, identifier);
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn stage2_admin_auth_distinct_credentials_resolve_distinct_operators() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("stage2_auth_distinct").await else {
        return;
    };
    let identifier_a = format!("stage2-distinct-a-{}", Uuid::new_v4());
    let identifier_b = format!("stage2-distinct-b-{}", Uuid::new_v4());
    let (operator_a, credential_a) = register_operator(&harness.pool, &identifier_a).await;
    let (operator_b, credential_b) = register_operator(&harness.pool, &identifier_b).await;

    let auth_a = extract_admin_auth(&harness.pool, &credential_a)
        .await
        .expect("first operator credential must resolve");
    let auth_b = extract_admin_auth(&harness.pool, &credential_b)
        .await
        .expect("second operator credential must resolve");
    assert_eq!(
        (auth_a.operator_id, auth_a.identifier),
        (operator_a, identifier_a)
    );
    assert_eq!(
        (auth_b.operator_id, auth_b.identifier),
        (operator_b, identifier_b)
    );
    assert_ne!(auth_a.operator_id, auth_b.operator_id);
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn stage2_admin_auth_short_credentials_are_rejected() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("stage2_auth_short").await else {
        return;
    };
    let one_character_short = "s".repeat(ADMIN_CREDENTIAL_PREFIX_LENGTH - 1);

    for credential in ["", "short", one_character_short.as_str()] {
        assert!(
            matches!(
                extract_admin_auth(&harness.pool, credential).await,
                Err(AuthError::InvalidAdminKey)
            ),
            "a credential shorter than the shared prefix length must return InvalidAdminKey"
        );
    }
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn stage2_admin_auth_unregistered_credential_is_rejected() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("stage2_auth_unregistered").await
    else {
        return;
    };
    let credential = format!("fjop_unregistered_{}", Uuid::new_v4().simple());

    assert!(matches!(
        extract_admin_auth(&harness.pool, &credential).await,
        Err(AuthError::InvalidAdminKey)
    ));
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn stage2_admin_auth_revoked_credential_is_rejected() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("stage2_auth_revoked").await else {
        return;
    };
    let identifier = format!("stage2-revoked-{}", Uuid::new_v4());
    let (operator_id, credential) = register_operator(&harness.pool, &identifier).await;
    let active = extract_admin_auth(&harness.pool, &credential)
        .await
        .expect("active control credential must resolve before revocation");
    assert_eq!(active.operator_id, operator_id);

    revoke_operator(&harness.pool, operator_id).await;
    assert!(matches!(
        extract_admin_auth(&harness.pool, &credential).await,
        Err(AuthError::InvalidAdminKey)
    ));
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn stage2_admin_auth_prefix_collision_resolves_full_hash_match() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("stage2_auth_collision").await
    else {
        return;
    };
    let shared_prefix = "p".repeat(ADMIN_CREDENTIAL_PREFIX_LENGTH);
    let credential_a = format!("{shared_prefix}-candidate-a");
    let credential_b = format!("{shared_prefix}-candidate-b");
    let identifier_a = format!("stage2-collision-a-{}", Uuid::new_v4());
    let identifier_b = format!("stage2-collision-b-{}", Uuid::new_v4());
    let operator_a =
        register_operator_with_credential(&harness.pool, &identifier_a, &credential_a).await;
    let operator_b =
        register_operator_with_credential(&harness.pool, &identifier_b, &credential_b).await;

    let auth_a = extract_admin_auth(&harness.pool, &credential_a)
        .await
        .expect("first colliding credential must resolve by full hash");
    let auth_b = extract_admin_auth(&harness.pool, &credential_b)
        .await
        .expect("second colliding credential must resolve by full hash");
    assert_eq!(
        (auth_a.operator_id, auth_a.identifier),
        (operator_a, identifier_a)
    );
    assert_eq!(
        (auth_b.operator_id, auth_b.identifier),
        (operator_b, identifier_b)
    );
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn stage2_admin_bootstrap_is_idempotent_before_route_request() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("stage2_admin_bootstrap").await
    else {
        return;
    };
    sqlx::query("DELETE FROM admin_users")
        .execute(&harness.pool)
        .await
        .expect("start with no admin operators");

    assert!(
        bootstrap_admin_user_if_empty(&harness.pool, crate::common::TEST_ADMIN_KEY)
            .await
            .expect("first bootstrap call")
    );
    assert!(
        !bootstrap_admin_user_if_empty(&harness.pool, crate::common::TEST_ADMIN_KEY)
            .await
            .expect("second bootstrap call"),
        "the repeated startup call must be an idempotent no-op"
    );
    assert_eq!(admin_users_row_count(&harness.pool).await, 1);
    assert_eq!(
        sole_admin_user_identifier(&harness.pool).await,
        "bootstrap-admin-key"
    );
    assert!(credential_is_registered(&harness.pool, crate::common::TEST_ADMIN_KEY).await);

    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("Stage 2 Bootstrap", "stage2-bootstrap@example.com");
    cleanup_target(&harness.pool, customer.id).await;
    let app = impersonation_app(harness.pool.clone(), customer_repo);
    let response = app
        .oneshot(admin_token_request(
            customer.id,
            Some(30),
            Some("impersonation"),
        ))
        .await
        .expect("request with pre-bootstrapped credential");
    assert_eq!(response.status(), StatusCode::OK);
    cleanup_target(&harness.pool, customer.id).await;
}

// ===========================================================================
// Operator-identity contract for route attribution.
//
// These pin FJ-R-AUTHZ-01: "every privileged action must be attributable to
// an individual identity, not a shared credential". `AdminAuth` resolves
// persisted operator identities, and audited route call sites must write that
// operator ID into `audit_log`.
//
// `admin_users` is reached through RUNTIME sql (`sqlx::query`, never the
// `sqlx::query!` macros) so this file compiles before the migration exists.
// Migration 070 owns this persisted operator contract:
//
//   admin_users(
//     id                UUID        PRIMARY KEY,
//     identifier        TEXT        NOT NULL UNIQUE,
//     credential_prefix TEXT        NOT NULL,
//     credential_sha256 TEXT        NOT NULL UNIQUE,  -- lowercase hex SHA-256
//     created_at        TIMESTAMPTZ NOT NULL,
//     revoked_at        TIMESTAMPTZ NULL
//   )
//
// SHA-256 + constant-time compare mirrors `infra/api/src/auth/api_key.rs`,
// the repo's existing scheme for machine-generated high-entropy credentials.
// Argon2 (`infra/api/src/password.rs`) is deliberately NOT used here: it is
// for low-entropy user-chosen passwords.
// ===========================================================================

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn post_admin_tokens_from_two_operators_writes_two_distinct_non_nil_actor_ids() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("stage1_two_operators").await else {
        return;
    };
    let pool = harness.pool.clone();
    require_admin_users_contract(&pool).await;

    let (operator_a, credential_a) =
        register_operator(&pool, &format!("op-a-{}@example.com", Uuid::new_v4())).await;
    let (operator_b, credential_b) =
        register_operator(&pool, &format!("op-b-{}@example.com", Uuid::new_v4())).await;

    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("Two Operator Target", "two-operator-target@example.com");
    cleanup_target(&pool, customer.id).await;
    let app = impersonation_app(pool.clone(), customer_repo);

    for credential in [&credential_a, &credential_b] {
        let resp = app
            .clone()
            .oneshot(admin_token_request_with_key(
                credential,
                customer.id,
                Some(30),
                Some("impersonation"),
            ))
            .await
            .unwrap();
        let (status, body) = response_json(resp).await;
        assert_eq!(
            status,
            StatusCode::OK,
            "a registered operator credential must authenticate"
        );
        assert!(body["token"].as_str().is_some());
    }

    let actors =
        actor_ids_for_action_and_target(&pool, ACTION_IMPERSONATION_TOKEN_CREATED, customer.id)
            .await;
    assert_eq!(
        actors.len(),
        2,
        "each operator's mint must write its own audit row"
    );
    assert!(
        !actors.contains(&Uuid::nil()),
        "the shared-credential sentinel (Uuid::nil()) must never be written as an operator actor"
    );
    let observed: std::collections::HashSet<Uuid> = actors.into_iter().collect();
    assert_eq!(
        observed,
        std::collections::HashSet::from([operator_a, operator_b]),
        "two distinct operators must produce two distinct audit actors equal to their admin_users ids"
    );

    let metadata = latest_metadata(&pool, ACTION_IMPERSONATION_TOKEN_CREATED, customer.id).await;
    assert_eq!(
        metadata["duration_secs"], 60,
        "per-operator attribution must not disturb the existing metadata contract"
    );

    cleanup_target(&pool, customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn post_admin_tokens_with_unregistered_credential_is_rejected_without_audit_row() {
    let Some(pool) = connect_shared_public_and_migrate().await else {
        return;
    };

    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed(
        "Unregistered Credential",
        "unregistered-credential@example.com",
    );
    cleanup_target(&pool, customer.id).await;
    let app = impersonation_app(pool.clone(), customer_repo);

    // Well-formed and long enough, but belongs to no operator row.
    let unregistered = format!("fjop_{}", Uuid::new_v4().simple());
    let resp = app
        .oneshot(admin_token_request_with_key(
            &unregistered,
            customer.id,
            Some(30),
            Some("impersonation"),
        ))
        .await
        .unwrap();

    assert_eq!(
        resp.status(),
        StatusCode::UNAUTHORIZED,
        "an unregistered operator credential must be rejected"
    );
    assert_eq!(
        audit_row_count_for_target(&pool, customer.id).await,
        0,
        "rejection must happen before the mutation, so no audit row may exist for the target"
    );

    cleanup_target(&pool, customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn post_admin_tokens_with_revoked_operator_credential_is_rejected_without_audit_row() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("stage1_revoked_operator").await
    else {
        return;
    };
    let pool = harness.pool.clone();
    require_admin_users_contract(&pool).await;

    let (operator, credential) =
        register_operator(&pool, &format!("op-revoked-{}@example.com", Uuid::new_v4())).await;

    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("Revoked Operator Target", "revoked-operator@example.com");
    cleanup_target(&pool, customer.id).await;
    let app = impersonation_app(pool.clone(), customer_repo);

    // Control: while active the credential works and is attributed. Without
    // this arm a route that rejected everything would pass the revocation
    // assertion below for the wrong reason.
    let active_resp = app
        .clone()
        .oneshot(admin_token_request_with_key(
            &credential,
            customer.id,
            Some(30),
            Some("impersonation"),
        ))
        .await
        .unwrap();
    assert_eq!(active_resp.status(), StatusCode::OK);
    assert_eq!(
        latest_actor_id(&pool, ACTION_IMPERSONATION_TOKEN_CREATED, customer.id).await,
        operator,
        "an active operator's action must be attributed to that operator"
    );
    assert_eq!(audit_row_count_for_target(&pool, customer.id).await, 1);

    revoke_operator(&pool, operator).await;

    let revoked_resp = app
        .oneshot(admin_token_request_with_key(
            &credential,
            customer.id,
            Some(30),
            Some("impersonation"),
        ))
        .await
        .unwrap();
    assert_eq!(
        revoked_resp.status(),
        StatusCode::UNAUTHORIZED,
        "a revoked operator credential must be rejected even though it is still well-formed"
    );
    assert_eq!(
        audit_row_count_for_target(&pool, customer.id).await,
        1,
        "the revoked attempt must not add a second audit row"
    );

    cleanup_target(&pool, customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn post_admin_tokens_with_short_credential_prefix_fails_closed_without_audit_row() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("stage1_short_credential").await
    else {
        return;
    };
    let pool = harness.pool.clone();

    // Slice prefixes off whichever credential actually authenticates in the
    // current model, so the "prefix of a valid credential" cases stay real
    // once operator rows replace the shared key.
    let registered_operator = if admin_users_table_exists(&pool).await {
        Some(register_operator(&pool, &format!("op-short-{}@example.com", Uuid::new_v4())).await)
    } else {
        None
    };
    let valid_credential = match &registered_operator {
        Some((_, credential)) => credential.clone(),
        None => crate::common::TEST_ADMIN_KEY.to_string(),
    };
    assert!(
        valid_credential.len() > 16,
        "the fixture credential must be longer than 16 chars for the prefix cases to be strict prefixes"
    );

    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("Short Credential", "short-credential@example.com");
    cleanup_target(&pool, customer.id).await;
    let app = impersonation_app(pool.clone(), customer_repo);

    let cases: [(&str, &str); 4] = [
        ("", "an empty credential"),
        ("short", "a 5-character credential"),
        (
            &valid_credential[..15],
            "a 15-character strict prefix of a valid credential",
        ),
        (
            &valid_credential[..16],
            "a 16-character prefix — exactly the slice a prefix-lookup scheme takes",
        ),
    ];

    for (credential, label) in cases {
        let resp = app
            .clone()
            .oneshot(admin_token_request_with_key(
                credential,
                customer.id,
                Some(30),
                Some("impersonation"),
            ))
            .await
            .unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::UNAUTHORIZED,
            "{label} must fail closed with 401 — never authenticate, never 500 from a panic \
             or an out-of-range prefix slice"
        );
        assert_eq!(
            audit_row_count_for_target(&pool, customer.id).await,
            0,
            "{label} must not write an audit row"
        );
    }

    // Discriminating control: the full credential still authenticates, so a
    // route that rejected every request cannot satisfy this test.
    let ok_resp = app
        .oneshot(admin_token_request_with_key(
            &valid_credential,
            customer.id,
            Some(30),
            Some("impersonation"),
        ))
        .await
        .unwrap();
    assert_eq!(ok_resp.status(), StatusCode::OK);
    assert_eq!(audit_row_count_for_target(&pool, customer.id).await, 1);
    if let Some((operator_id, _)) = &registered_operator {
        assert_eq!(
            latest_actor_id(&pool, ACTION_IMPERSONATION_TOKEN_CREATED, customer.id).await,
            *operator_id,
            "the accepted full-length credential must attribute to its operator"
        );
    }

    cleanup_target(&pool, customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn configured_admin_key_seeds_bootstrap_operator_when_admin_users_is_empty() {
    let Some(harness) =
        pg_schema_harness::connect_and_migrate("stage1_admin_bootstrap_empty").await
    else {
        return;
    };
    let pool = harness.pool.clone();
    require_admin_users_contract(&pool).await;

    sqlx::query("DELETE FROM admin_users")
        .execute(&pool)
        .await
        .expect("clear admin_users inside the isolated test schema");
    assert_eq!(admin_users_row_count(&pool).await, 0);

    bootstrap_admin_user_if_empty(&pool, crate::common::TEST_ADMIN_KEY)
        .await
        .expect("seed the configured admin key before serving requests");
    assert!(credential_is_registered(&pool, crate::common::TEST_ADMIN_KEY).await);

    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("Bootstrap Target", "bootstrap-target@example.com");
    let app = impersonation_app(pool.clone(), customer_repo);

    let resp = app
        .oneshot(admin_token_request(
            customer.id,
            Some(30),
            Some("impersonation"),
        ))
        .await
        .unwrap();
    let (status, _body) = response_json(resp).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "with zero registered operators the configured ADMIN_KEY must still authenticate — \
         a system nobody can authenticate to is not shippable"
    );

    assert_eq!(
        admin_users_row_count(&pool).await,
        1,
        "the bootstrap credential must seed exactly one operator row rather than authenticating anonymously"
    );
    let bootstrap_operator = sole_admin_user_id(&pool).await;
    assert_ne!(
        bootstrap_operator,
        Uuid::nil(),
        "the seeded bootstrap operator must have a real id, not the sentinel"
    );
    assert_eq!(
        latest_actor_id(&pool, ACTION_IMPERSONATION_TOKEN_CREATED, customer.id).await,
        bootstrap_operator,
        "the bootstrap action must be attributed to the seeded bootstrap operator"
    );
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn configured_admin_key_does_not_bypass_identity_when_admin_users_is_non_empty() {
    let Some(harness) =
        pg_schema_harness::connect_and_migrate("stage1_admin_bootstrap_seeded").await
    else {
        return;
    };
    let pool = harness.pool.clone();
    require_admin_users_contract(&pool).await;

    sqlx::query("DELETE FROM admin_users")
        .execute(&pool)
        .await
        .expect("clear admin_users inside the isolated test schema");
    let (operator, credential) = register_operator(&pool, "registered-operator@example.com").await;
    assert_eq!(admin_users_row_count(&pool).await, 1);
    assert!(
        !bootstrap_admin_user_if_empty(&pool, crate::common::TEST_ADMIN_KEY)
            .await
            .expect("skip bootstrap when an operator already exists")
    );
    assert_eq!(admin_users_row_count(&pool).await, 1);
    assert!(
        !credential_is_registered(&pool, crate::common::TEST_ADMIN_KEY).await,
        "premise guard: the shared bootstrap key must not itself be a registered operator \
         credential, or the bypass assertion below would prove nothing"
    );

    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("Non Empty Bootstrap", "non-empty-bootstrap@example.com");
    let app = impersonation_app(pool.clone(), customer_repo);

    let bootstrap_resp = app
        .clone()
        .oneshot(admin_token_request(
            customer.id,
            Some(30),
            Some("impersonation"),
        ))
        .await
        .unwrap();
    assert_eq!(
        bootstrap_resp.status(),
        StatusCode::UNAUTHORIZED,
        "once operators are registered the shared bootstrap credential must stop bypassing \
         per-operator identity"
    );
    assert_eq!(
        audit_row_count_for_target(&pool, customer.id).await,
        0,
        "a rejected bootstrap bypass must not write an audit row"
    );

    // Control: the registered operator still works, so the assertion above is
    // not satisfied by a route that rejects everything.
    let operator_resp = app
        .oneshot(admin_token_request_with_key(
            &credential,
            customer.id,
            Some(30),
            Some("impersonation"),
        ))
        .await
        .unwrap();
    assert_eq!(operator_resp.status(), StatusCode::OK);
    assert_eq!(
        latest_actor_id(&pool, ACTION_IMPERSONATION_TOKEN_CREATED, customer.id).await,
        operator,
        "the registered operator's action must be attributed to that operator"
    );
}
