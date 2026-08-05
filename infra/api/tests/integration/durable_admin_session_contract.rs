//! Durable admin-session request contracts nested under the operator-identity owner.

use api::services::audit_log::ACTION_IMPERSONATION_TOKEN_CREATED;
use axum::http::StatusCode;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use sqlx::PgPool;
use tower::ServiceExt;
use uuid::Uuid;

use crate::common::admin_audit_test_support::{
    admin_session_absolute_lifetime_seconds, admin_session_current_request,
    admin_session_current_request_with_key, admin_session_last_activity,
    admin_session_login_request_with_key, admin_session_revoke_all_request,
    admin_session_revoke_current_request, admin_session_secret_sha256,
    admin_token_request_with_key_and_session, admin_token_request_with_session,
    audit_row_count_for_target, backdate_admin_session_last_activity, cleanup_target,
    expire_admin_session, impersonation_app, latest_actor_id,
    latest_admin_session_record_id_for_operator, latest_metadata, register_operator,
    require_admin_users_contract, response_json, revoke_operator, set_admin_session_secret_sha256,
};
use crate::common::support::pg_schema_harness;

async fn create_admin_session(
    app: axum::Router,
    credential: &str,
    max_age_seconds: Option<u64>,
) -> String {
    let response = app
        .oneshot(admin_session_login_request_with_key(
            credential,
            max_age_seconds,
        ))
        .await
        .expect("request durable admin session");
    let (status, body) = response_json(response).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "POST /admin/sessions must mint a durable session for an active operator"
    );
    let token = body["session_id"]
        .as_str()
        .expect("durable session response must include session_id")
        .to_string();
    assert_session_token_shape(&token);
    token
}

fn assert_session_token_shape(token: &str) {
    let (session_id, encoded_secret) = token
        .split_once('.')
        .expect("durable session token must contain one separator");
    Uuid::parse_str(session_id).expect("durable session token must start with a UUID");
    let secret = URL_SAFE_NO_PAD
        .decode(encoded_secret)
        .expect("durable session secret must use URL-safe no-padding encoding");
    assert!(
        secret.len() >= 32,
        "durable session secret must have at least 256 bits of entropy"
    );
}

async fn assert_session_token_status(
    app: axum::Router,
    session_id: &str,
    customer_id: Uuid,
    expected_status: StatusCode,
) {
    let response = app
        .oneshot(admin_token_request_with_session(
            session_id,
            customer_id,
            Some(30),
            Some("impersonation"),
        ))
        .await
        .expect("request admin token with durable session");
    assert_eq!(response.status(), expected_status);
}

async fn register_session_operator(pool: &PgPool, test_name: &str) -> (Uuid, String) {
    require_admin_users_contract(pool).await;
    register_operator(
        pool,
        &format!("op-session-{test_name}-{}@example.com", Uuid::new_v4()),
    )
    .await
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn durable_admin_sessions_schema_contract() {
    let Some(harness) =
        pg_schema_harness::connect_and_migrate("stage2_admin_sessions_schema").await
    else {
        return;
    };

    let columns: Vec<(String, String, String, Option<String>)> = sqlx::query_as(
        "SELECT column_name, is_nullable, data_type, column_default \
         FROM information_schema.columns \
         WHERE table_schema = current_schema() AND table_name = 'admin_sessions' \
         ORDER BY ordinal_position",
    )
    .fetch_all(&harness.pool)
    .await
    .expect("query admin_sessions columns");
    assert_eq!(
        columns,
        vec![
            schema_column("id", "NO", "uuid", Some("gen_random_uuid()")),
            schema_column("admin_user_id", "NO", "uuid", None),
            schema_column("secret_sha256", "NO", "text", None),
            schema_column(
                "created_at",
                "NO",
                "timestamp with time zone",
                Some("now()")
            ),
            schema_column(
                "last_activity_at",
                "NO",
                "timestamp with time zone",
                Some("now()")
            ),
            schema_column("expires_at", "NO", "timestamp with time zone", None),
            schema_column("revoked_at", "YES", "timestamp with time zone", None),
        ]
    );

    let constraints: Vec<(String, String, Option<String>, Option<String>)> = sqlx::query_as(
        "SELECT tc.constraint_type, kcu.column_name, ccu.table_name, ccu.column_name \
         FROM information_schema.table_constraints tc \
         JOIN information_schema.key_column_usage kcu \
           ON tc.constraint_schema = kcu.constraint_schema \
          AND tc.constraint_name = kcu.constraint_name \
         LEFT JOIN information_schema.constraint_column_usage ccu \
           ON tc.constraint_schema = ccu.constraint_schema \
          AND tc.constraint_name = ccu.constraint_name \
         WHERE tc.table_schema = current_schema() \
           AND tc.table_name = 'admin_sessions' \
           AND tc.constraint_type IN ('PRIMARY KEY', 'FOREIGN KEY') \
         ORDER BY tc.constraint_type DESC",
    )
    .fetch_all(&harness.pool)
    .await
    .expect("query admin_sessions constraints");
    assert_eq!(
        constraints,
        vec![
            (
                "PRIMARY KEY".into(),
                "id".into(),
                Some("admin_sessions".into()),
                Some("id".into())
            ),
            (
                "FOREIGN KEY".into(),
                "admin_user_id".into(),
                Some("admin_users".into()),
                Some("id".into())
            ),
        ]
    );

    let indexes: Vec<(String, String)> = sqlx::query_as(
        "SELECT indexname, indexdef FROM pg_indexes \
         WHERE schemaname = current_schema() \
           AND tablename = 'admin_sessions' \
           AND indexname NOT LIKE '%_pkey' \
         ORDER BY indexname",
    )
    .fetch_all(&harness.pool)
    .await
    .expect("query admin_sessions indexes");
    assert_eq!(
        indexes.len(),
        1,
        "admin_sessions must have only the active-operator partial index beyond its primary key"
    );
    assert_eq!(indexes[0].0, "idx_admin_sessions_active_admin_user");
    assert!(indexes[0].1.contains("USING btree (admin_user_id)"));
    assert!(indexes[0].1.contains("WHERE (revoked_at IS NULL)"));
}

fn schema_column(
    name: &str,
    nullable: &str,
    data_type: &str,
    default: Option<&str>,
) -> (String, String, String, Option<String>) {
    (
        name.into(),
        nullable.into(),
        data_type.into(),
        default.map(Into::into),
    )
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn durable_admin_session_omitted_lifetime_defaults_to_24_hours() {
    let Some(harness) =
        pg_schema_harness::connect_and_migrate("stage2_session_default_lifetime").await
    else {
        return;
    };
    let pool = harness.pool.clone();
    let (operator, credential) = register_session_operator(&pool, "default").await;
    let app = impersonation_app(pool.clone(), crate::common::mock_repo());

    create_admin_session(app, &credential, None).await;
    let session_record_id = latest_admin_session_record_id_for_operator(&pool, operator).await;
    assert_eq!(
        admin_session_absolute_lifetime_seconds(&pool, session_record_id).await,
        86_400
    );
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn durable_admin_session_rejects_malformed_and_ambiguous_credentials() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("stage2_session_malformed").await
    else {
        return;
    };
    let pool = harness.pool.clone();
    let (_operator, credential) = register_session_operator(&pool, "malformed").await;
    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("Malformed Session", "session-malformed@example.com");
    let app = impersonation_app(pool, customer_repo);
    let session_id = create_admin_session(app.clone(), &credential, Some(3600)).await;

    for malformed in [
        "missing-separator",
        "not-a-uuid.c2VjcmV0",
        "00000000-0000-0000-0000-000000000000.!!!",
        "00000000-0000-0000-0000-000000000000.c2hvcnQ",
    ] {
        assert_session_token_status(
            app.clone(),
            malformed,
            customer.id,
            StatusCode::UNAUTHORIZED,
        )
        .await;
    }
    let dual_response = app
        .oneshot(admin_token_request_with_key_and_session(
            &credential,
            &session_id,
            customer.id,
        ))
        .await
        .expect("request with simultaneous admin credentials");
    assert_eq!(dual_response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn durable_admin_session_touches_activity_only_after_secret_validation() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("stage2_session_touch_order").await
    else {
        return;
    };
    let pool = harness.pool.clone();
    let (operator, credential) = register_session_operator(&pool, "touch").await;
    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("Session Touch", "session-touch@example.com");
    let app = impersonation_app(pool.clone(), customer_repo);
    let session_id = create_admin_session(app.clone(), &credential, Some(3600)).await;
    let record_id = latest_admin_session_record_id_for_operator(&pool, operator).await;
    backdate_admin_session_last_activity(&pool, record_id, 120).await;
    let original_activity = admin_session_last_activity(&pool, record_id).await;
    let original_hash = admin_session_secret_sha256(&pool, record_id).await;

    set_admin_session_secret_sha256(&pool, record_id, &"0".repeat(64)).await;
    assert_session_token_status(
        app.clone(),
        &session_id,
        customer.id,
        StatusCode::UNAUTHORIZED,
    )
    .await;
    assert_eq!(
        admin_session_last_activity(&pool, record_id).await,
        original_activity
    );

    set_admin_session_secret_sha256(&pool, record_id, &original_hash).await;
    assert_session_token_status(app, &session_id, customer.id, StatusCode::OK).await;
    assert!(admin_session_last_activity(&pool, record_id).await > original_activity);
}

/// `GET /admin/sessions/current` is the non-destructive validation seam the web
/// admin layout calls on every request. It must reuse the `AdminAuth` extractor
/// (so it touches last activity exactly like any other session-authenticated
/// route), return only non-secret operator metadata, and fail closed for every
/// credential shape that is not a live durable session.
#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn durable_admin_session_current_returns_operator_identity_and_fails_closed() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("stage3_session_current_get").await
    else {
        return;
    };
    let pool = harness.pool.clone();
    let (operator, credential) = register_session_operator(&pool, "current-get").await;
    let app = impersonation_app(pool.clone(), crate::common::mock_repo());
    let session_id = create_admin_session(app.clone(), &credential, Some(3600)).await;
    let session_record_id = latest_admin_session_record_id_for_operator(&pool, operator).await;

    backdate_admin_session_last_activity(&pool, session_record_id, 120).await;
    let activity_before_validation = admin_session_last_activity(&pool, session_record_id).await;

    let (status, body) = response_json(
        app.clone()
            .oneshot(admin_session_current_request(Some(&session_id)))
            .await
            .expect("validate current durable admin session"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body,
        serde_json::json!({ "operator_id": operator }),
        "the validation endpoint must expose the operator id and nothing else"
    );
    assert!(
        admin_session_last_activity(&pool, session_record_id).await > activity_before_validation,
        "validating the current session must touch last activity through validate_and_touch"
    );

    // Fail-closed arms: no credential, malformed token, and a raw admin key are
    // all "not a live durable session" and must not report an active session.
    for request in [
        admin_session_current_request(None),
        admin_session_current_request(Some("missing-separator")),
        admin_session_current_request(Some("00000000-0000-0000-0000-000000000000.c2hvcnQ")),
        admin_session_current_request_with_key(&credential),
    ] {
        let response = app
            .clone()
            .oneshot(request)
            .await
            .expect("probe current durable admin session without a live session");
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    // An absolute-lifetime expiry must invalidate the session for validation too.
    let expired_session_id = create_admin_session(app.clone(), &credential, Some(3600)).await;
    let expired_record_id = latest_admin_session_record_id_for_operator(&pool, operator).await;
    expire_admin_session(&pool, expired_record_id).await;
    let expired_response = app
        .clone()
        .oneshot(admin_session_current_request(Some(&expired_session_id)))
        .await
        .expect("validate expired durable admin session");
    assert_eq!(expired_response.status(), StatusCode::UNAUTHORIZED);

    let revoke_response = app
        .clone()
        .oneshot(admin_session_revoke_current_request(&session_id))
        .await
        .expect("revoke current durable admin session");
    assert_eq!(revoke_response.status(), StatusCode::NO_CONTENT);
    let revoked_response = app
        .oneshot(admin_session_current_request(Some(&session_id)))
        .await
        .expect("validate revoked durable admin session");
    assert_eq!(revoked_response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn durable_admin_session_revoke_current_rejects_copied_session() {
    let Some(harness) =
        pg_schema_harness::connect_and_migrate("stage1_session_revoke_current").await
    else {
        return;
    };
    let pool = harness.pool.clone();
    let (_operator, credential) = register_session_operator(&pool, "current").await;
    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("Session Current", "session-current@example.com");
    cleanup_target(&pool, customer.id).await;
    let app = impersonation_app(pool.clone(), customer_repo);
    let session_id = create_admin_session(app.clone(), &credential, Some(3600)).await;
    let second_session_id = create_admin_session(app.clone(), &credential, Some(3600)).await;
    let copied_session_id = session_id.clone();

    assert_session_token_status(app.clone(), &session_id, customer.id, StatusCode::OK).await;
    assert_session_token_status(app.clone(), &second_session_id, customer.id, StatusCode::OK).await;
    let revoke_response = app
        .clone()
        .oneshot(admin_session_revoke_current_request(&session_id))
        .await
        .expect("revoke current durable admin session");
    assert_eq!(revoke_response.status(), StatusCode::NO_CONTENT);
    assert_session_token_status(
        app.clone(),
        &copied_session_id,
        customer.id,
        StatusCode::UNAUTHORIZED,
    )
    .await;
    assert_session_token_status(app, &second_session_id, customer.id, StatusCode::OK).await;
    cleanup_target(&pool, customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn durable_admin_session_revoke_all_rejects_all_operator_sessions() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("stage1_session_revoke_all").await
    else {
        return;
    };
    let pool = harness.pool.clone();
    let (_operator, credential) = register_session_operator(&pool, "all").await;
    let (_other_operator, other_credential) = register_session_operator(&pool, "other").await;
    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("Session All", "session-all@example.com");
    cleanup_target(&pool, customer.id).await;
    let app = impersonation_app(pool.clone(), customer_repo);
    let session_a = create_admin_session(app.clone(), &credential, Some(3600)).await;
    let session_b = create_admin_session(app.clone(), &credential, Some(3600)).await;
    let other_operator_session =
        create_admin_session(app.clone(), &other_credential, Some(3600)).await;

    let revoke_response = app
        .clone()
        .oneshot(admin_session_revoke_all_request(&session_a))
        .await
        .expect("revoke all durable admin sessions");
    assert_eq!(revoke_response.status(), StatusCode::NO_CONTENT);
    for session_id in [&session_a, &session_b] {
        assert_session_token_status(
            app.clone(),
            session_id,
            customer.id,
            StatusCode::UNAUTHORIZED,
        )
        .await;
    }
    assert_session_token_status(app, &other_operator_session, customer.id, StatusCode::OK).await;
    cleanup_target(&pool, customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn durable_admin_session_inactivity_timeout_is_enforced_at_request_boundary() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("stage1_session_idle").await else {
        return;
    };
    let pool = harness.pool.clone();
    let (operator, credential) = register_session_operator(&pool, "idle").await;
    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("Session Idle", "session-idle@example.com");
    cleanup_target(&pool, customer.id).await;
    let app = impersonation_app(pool.clone(), customer_repo);
    let session_id = create_admin_session(app.clone(), &credential, Some(7200)).await;
    let session_record_id = latest_admin_session_record_id_for_operator(&pool, operator).await;

    backdate_admin_session_last_activity(&pool, session_record_id, 3595).await;
    assert_session_token_status(app.clone(), &session_id, customer.id, StatusCode::OK).await;
    backdate_admin_session_last_activity(&pool, session_record_id, 3601).await;
    assert_session_token_status(app, &session_id, customer.id, StatusCode::UNAUTHORIZED).await;
    cleanup_target(&pool, customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn durable_admin_session_login_clamps_absolute_lifetime_to_24_hours() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("stage1_session_absolute_cap").await
    else {
        return;
    };
    let pool = harness.pool.clone();
    let (operator, credential) = register_session_operator(&pool, "cap").await;
    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("Session Absolute Cap", "session-cap@example.com");
    cleanup_target(&pool, customer.id).await;
    let app = impersonation_app(pool.clone(), customer_repo);

    let session_id = create_admin_session(app.clone(), &credential, Some(90_000)).await;
    let session_record_id = latest_admin_session_record_id_for_operator(&pool, operator).await;
    assert_eq!(
        admin_session_absolute_lifetime_seconds(&pool, session_record_id).await,
        86_400,
        "the persisted absolute lifetime must be clamped to 24 hours"
    );
    assert_session_token_status(app.clone(), &session_id, customer.id, StatusCode::OK).await;
    expire_admin_session(&pool, session_record_id).await;
    assert_session_token_status(app, &session_id, customer.id, StatusCode::UNAUTHORIZED).await;
    cleanup_target(&pool, customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn durable_admin_session_expiry_cannot_be_overridden_by_requested_token_lifetime() {
    let Some(harness) =
        pg_schema_harness::connect_and_migrate("stage1_session_tampered_expiry").await
    else {
        return;
    };
    let pool = harness.pool.clone();
    let (operator, credential) = register_session_operator(&pool, "tampered").await;
    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("Session Tampered", "session-tampered@example.com");
    let control_customer = customer_repo.seed(
        "Session Requested Lifetime",
        "session-requested-lifetime@example.com",
    );
    cleanup_target(&pool, customer.id).await;
    cleanup_target(&pool, control_customer.id).await;
    let app = impersonation_app(pool.clone(), customer_repo);
    let session_id = create_admin_session(app.clone(), &credential, Some(3600)).await;
    let session_record_id = latest_admin_session_record_id_for_operator(&pool, operator).await;

    const REQUESTED_TOKEN_LIFETIME_SECONDS: u64 = 365 * 24 * 60 * 60;
    const MAX_TOKEN_LIFETIME_SECONDS: u64 = 30 * 24 * 60 * 60;
    const BELOW_CAP_TOKEN_LIFETIME_SECONDS: u64 = 12 * 60 * 60;
    let active_response = app
        .clone()
        .oneshot(admin_token_request_with_session(
            &session_id,
            customer.id,
            Some(REQUESTED_TOKEN_LIFETIME_SECONDS),
            Some("impersonation"),
        ))
        .await
        .expect("request long-lived token with active durable session");
    assert_eq!(active_response.status(), StatusCode::OK);
    assert_eq!(
        latest_metadata(&pool, ACTION_IMPERSONATION_TOKEN_CREATED, customer.id).await,
        serde_json::json!({
            "duration_secs": MAX_TOKEN_LIFETIME_SECONDS,
            "purpose": "impersonation",
        })
    );

    let control_response = app
        .clone()
        .oneshot(admin_token_request_with_session(
            &session_id,
            control_customer.id,
            Some(BELOW_CAP_TOKEN_LIFETIME_SECONDS),
            Some("impersonation"),
        ))
        .await
        .expect("request below-cap token with active durable session");
    assert_eq!(control_response.status(), StatusCode::OK);
    assert_eq!(
        latest_metadata(
            &pool,
            ACTION_IMPERSONATION_TOKEN_CREATED,
            control_customer.id,
        )
        .await,
        serde_json::json!({
            "duration_secs": BELOW_CAP_TOKEN_LIFETIME_SECONDS,
            "purpose": "impersonation",
        })
    );

    expire_admin_session(&pool, session_record_id).await;
    let expired_response = app
        .oneshot(admin_token_request_with_session(
            &session_id,
            customer.id,
            Some(REQUESTED_TOKEN_LIFETIME_SECONDS),
            Some("impersonation"),
        ))
        .await
        .expect("request long-lived token with expired durable session");
    assert_eq!(expired_response.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(audit_row_count_for_target(&pool, customer.id).await, 1);
    cleanup_target(&pool, customer.id).await;
    cleanup_target(&pool, control_customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn durable_admin_session_preserves_operator_identity_and_rechecks_revocation() {
    let Some(harness) =
        pg_schema_harness::connect_and_migrate("stage1_session_operator_identity").await
    else {
        return;
    };
    let pool = harness.pool.clone();
    let (operator, credential) = register_session_operator(&pool, "identity").await;
    let customer_repo = crate::common::mock_repo();
    let customer = customer_repo.seed("Session Identity", "session-identity@example.com");
    cleanup_target(&pool, customer.id).await;
    let app = impersonation_app(pool.clone(), customer_repo);
    let session_id = create_admin_session(app.clone(), &credential, Some(3600)).await;

    assert_session_token_status(app.clone(), &session_id, customer.id, StatusCode::OK).await;
    assert_eq!(
        latest_actor_id(&pool, ACTION_IMPERSONATION_TOKEN_CREATED, customer.id).await,
        operator,
        "session-authenticated actions must retain the registered admin_users identity"
    );
    revoke_operator(&pool, operator).await;
    assert_session_token_status(app, &session_id, customer.id, StatusCode::UNAUTHORIZED).await;
    assert_eq!(audit_row_count_for_target(&pool, customer.id).await, 1);
    cleanup_target(&pool, customer.id).await;
}
