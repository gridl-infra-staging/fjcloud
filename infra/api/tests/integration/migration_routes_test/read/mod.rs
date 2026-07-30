use super::*;

mod lifecycle;
pub(super) mod support;

use support::{get_json, seed_retained_job_with_internals, setup_algolia_cloud_job_read_app};

async fn set_source_provider(pool: &sqlx::PgPool, id: Uuid, source_provider: &str) {
    sqlx::query("UPDATE algolia_import_jobs SET source_provider = $2 WHERE id = $1")
        .bind(id)
        .bind(source_provider)
        .execute(pool)
        .await
        .expect("update retained job source provider");
}

fn assert_public_job_history_contract(body: &serde_json::Value) {
    assert_eq!(body["sourceProvider"], json!("algolia"));
    assert_eq!(body["source"], json!({ "name": "source_products" }));
    assert_eq!(body["error"], json!({ "code": "backend_unavailable" }));
    for forbidden in [
        "customerId",
        "tenantId",
        "idempotencyKey",
        "canonicalFingerprint",
        "routingIdentity",
        "physicalUid",
        "reservedIndexCount",
        "resumeCheckpoint",
        "engineJobId",
        "workerLeaseExpiresAt",
    ] {
        assert!(
            body.get(forbidden).is_none(),
            "leaked internal field {forbidden}"
        );
    }
    assert!(
        body["source"].get("appId").is_none(),
        "public source must expose only the sanitized name"
    );
    assert!(
        body["error"].get("message").is_none(),
        "public error must expose only the stable code"
    );
    let serialized = body.to_string();
    for secret in [
        "TESTAPP123",
        "phys-secret-uid",
        "routing-secret-id",
        "idem-secret-get",
        "secret-fingerprint",
        "raw producer error canary",
    ] {
        assert!(
            !serialized.contains(secret),
            "leaked internal value {secret}"
        );
    }
    assert_eq!(body["terminalOutcomeObserved"], json!(false));
    assert_eq!(body["warnings"], json!([]));
}

#[tokio::test]
async fn algolia_cloud_job_read_get_returns_public_dto_without_internal_fields() {
    let db = connect_and_migrate_required("algolia_read_get_dto").await;
    let (app, jwt, customer_id) = setup_algolia_cloud_job_read_app(db.pool.clone(), true).await;
    let id = seed_retained_job_with_internals(&db.pool, customer_id, "products", "get", Utc::now())
        .await;

    let (status, body) = get_json(&app, &jwt, &format!("/migration/algolia/jobs/{id}")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["id"], id.to_string());
    assert_eq!(body["destination"]["target"], "products");
    assert_public_job_history_contract(&body);
}

#[tokio::test]
async fn algolia_cloud_job_read_get_missing_and_foreign_return_identical_404() {
    let db = connect_and_migrate_required("algolia_read_get_404").await;
    let (app, jwt, _customer_id) = setup_algolia_cloud_job_read_app(db.pool.clone(), true).await;
    let other = Uuid::new_v4();
    insert_active_customer(&db.pool, other, 1).await;
    let foreign_id =
        seed_retained_job_with_internals(&db.pool, other, "products", "foreign", Utc::now()).await;
    let missing_id = Uuid::new_v4();

    let (missing_status, missing_body) =
        get_json(&app, &jwt, &format!("/migration/algolia/jobs/{missing_id}")).await;
    let (foreign_status, foreign_body) =
        get_json(&app, &jwt, &format!("/migration/algolia/jobs/{foreign_id}")).await;

    assert_eq!(missing_status, StatusCode::NOT_FOUND);
    assert_eq!(foreign_status, StatusCode::NOT_FOUND);
    assert_eq!(missing_body, foreign_body);
}

#[tokio::test]
async fn algolia_cloud_job_read_get_hides_non_algolia_rows() {
    let db = connect_and_migrate_required("algolia_read_get_provider_scope").await;
    let (app, jwt, customer_id) = setup_algolia_cloud_job_read_app(db.pool.clone(), true).await;
    let id =
        seed_retained_job_with_internals(&db.pool, customer_id, "products", "provider", Utc::now())
            .await;
    set_source_provider(&db.pool, id, "meilisearch").await;

    let (status, body) = get_json(&app, &jwt, &format!("/migration/algolia/jobs/{id}")).await;

    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body, json!({ "error": "algolia_import_job_not_found" }));
}

#[tokio::test]
async fn algolia_cloud_job_read_list_paginates_with_signed_cursor() {
    let db = connect_and_migrate_required("algolia_read_list_page").await;
    let (app, jwt, customer_id) = setup_algolia_cloud_job_read_app(db.pool.clone(), true).await;
    let base = Utc::now();
    let mut ids = Vec::new();
    for index in 0..3 {
        ids.push(
            seed_retained_job_with_internals(
                &db.pool,
                customer_id,
                &format!("products-{index}"),
                &format!("page-{index}"),
                base - chrono::Duration::seconds(index),
            )
            .await,
        );
    }

    let (status, body) = get_json(&app, &jwt, "/migration/algolia/jobs?limit=2").await;
    assert_eq!(status, StatusCode::OK);
    let page: Vec<String> = body["jobs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|job| job["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(page, vec![ids[0].to_string(), ids[1].to_string()]);
    let cursor = body["nextCursor"]
        .as_str()
        .expect("full page yields a cursor");

    let (next_status, next_body) = get_json(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs?limit=2&cursor={cursor}"),
    )
    .await;
    assert_eq!(next_status, StatusCode::OK);
    let next_page: Vec<String> = next_body["jobs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|job| job["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(next_page, vec![ids[2].to_string()]);
    assert!(next_body["nextCursor"].is_null(), "last page has no cursor");
}

#[tokio::test]
async fn algolia_cloud_job_read_list_exact_full_page_has_no_cursor() {
    let db = connect_and_migrate_required("algolia_read_list_exact_full").await;
    let (app, jwt, customer_id) = setup_algolia_cloud_job_read_app(db.pool.clone(), true).await;
    let base = Utc::now();
    for index in 0..2 {
        seed_retained_job_with_internals(
            &db.pool,
            customer_id,
            &format!("products-{index}"),
            &format!("exact-{index}"),
            base - chrono::Duration::seconds(index),
        )
        .await;
    }

    let (status, body) = get_json(&app, &jwt, "/migration/algolia/jobs?limit=2").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["jobs"].as_array().unwrap().len(), 2);
    assert!(
        body["nextCursor"].is_null(),
        "an exact-full final page must not mint a cursor to an empty page"
    );
}

#[tokio::test]
async fn algolia_cloud_job_read_list_exact_multiple_final_page_has_no_cursor() {
    let db = connect_and_migrate_required("algolia_read_list_exact_multiple").await;
    let (app, jwt, customer_id) = setup_algolia_cloud_job_read_app(db.pool.clone(), true).await;
    let base = Utc::now();
    let mut ids = Vec::new();
    for index in 0..4 {
        ids.push(
            seed_retained_job_with_internals(
                &db.pool,
                customer_id,
                &format!("products-{index}"),
                &format!("mult-{index}"),
                base - chrono::Duration::seconds(index),
            )
            .await,
        );
    }

    let (_first_status, first) = get_json(&app, &jwt, "/migration/algolia/jobs?limit=2").await;
    let cursor = first["nextCursor"]
        .as_str()
        .expect("first full page of a longer list yields a cursor");
    let (status, second) = get_json(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs?limit=2&cursor={cursor}"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let second_ids: Vec<String> = second["jobs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|job| job["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(second_ids, vec![ids[2].to_string(), ids[3].to_string()]);
    assert!(
        second["nextCursor"].is_null(),
        "the final full page of an exact multiple must not mint a cursor"
    );
}

#[tokio::test]
async fn algolia_cloud_job_read_list_skips_non_algolia_rows_without_short_page() {
    let db = connect_and_migrate_required("algolia_read_list_provider_scope").await;
    let (app, jwt, customer_id) = setup_algolia_cloud_job_read_app(db.pool.clone(), true).await;
    let base = Utc::now();
    let mut ids = Vec::new();
    for index in 0..3 {
        ids.push(
            seed_retained_job_with_internals(
                &db.pool,
                customer_id,
                &format!("products-{index}"),
                &format!("provider-{index}"),
                base - chrono::Duration::seconds(index),
            )
            .await,
        );
    }
    set_source_provider(&db.pool, ids[0], "typesense").await;

    let (status, body) = get_json(&app, &jwt, "/migration/algolia/jobs?limit=2").await;

    assert_eq!(status, StatusCode::OK);
    let page: Vec<String> = body["jobs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|job| job["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(page, vec![ids[1].to_string(), ids[2].to_string()]);
    assert!(
        body["nextCursor"].is_null(),
        "provider-mismatched rows must not force a short page or a dead-end cursor"
    );
}

#[tokio::test]
async fn algolia_cloud_job_read_list_rejects_tampered_and_cross_customer_cursor() {
    let db = connect_and_migrate_required("algolia_read_list_cursor").await;
    let (app, jwt, customer_id) = setup_algolia_cloud_job_read_app(db.pool.clone(), true).await;
    let base = Utc::now();
    for index in 0..2 {
        seed_retained_job_with_internals(
            &db.pool,
            customer_id,
            &format!("products-{index}"),
            &format!("cursor-{index}"),
            base - chrono::Duration::seconds(index),
        )
        .await;
    }
    let (_status, body) = get_json(&app, &jwt, "/migration/algolia/jobs?limit=1").await;
    let cursor = body["nextCursor"].as_str().unwrap().to_string();

    let last = cursor.chars().last().unwrap();
    let flipped = if last == 'A' { 'B' } else { 'A' };
    let tampered = format!("{}{}", &cursor[..cursor.len() - 1], flipped);
    let (tamper_status, tamper_body) = get_json(
        &app,
        &jwt,
        &format!("/migration/algolia/jobs?limit=1&cursor={tampered}"),
    )
    .await;
    assert_eq!(tamper_status, StatusCode::BAD_REQUEST);
    assert_eq!(tamper_body, json!({ "error": "invalid_list_cursor" }));

    let intruder = mock_repo();
    let bob = intruder.seed_verified_free_customer("Bob", "bob@example.com");
    insert_active_customer(&db.pool, bob.id, 1).await;
    let intruder_app = axum::Router::new()
        .route(
            "/migration/algolia/jobs",
            axum::routing::get(api::routes::migration::list_algolia_import_jobs),
        )
        .with_state(
            TestStateBuilder::new()
                .with_pool(db.pool.clone())
                .with_customer_repo(intruder)
                .with_algolia_migration_enabled(true)
                .build(),
        );
    let (cross_status, cross_body) = get_json(
        &intruder_app,
        &create_test_jwt(bob.id),
        &format!("/migration/algolia/jobs?limit=1&cursor={cursor}"),
    )
    .await;
    assert_eq!(cross_status, StatusCode::BAD_REQUEST);
    assert_eq!(cross_body, json!({ "error": "invalid_list_cursor" }));
}

#[tokio::test]
async fn algolia_cloud_job_read_is_not_gated_by_exposure_flag() {
    let db = connect_and_migrate_required("algolia_read_exposure_off").await;
    let (app, jwt, customer_id) = setup_algolia_cloud_job_read_app(db.pool.clone(), false).await;
    let id =
        seed_retained_job_with_internals(&db.pool, customer_id, "products", "read", Utc::now())
            .await;

    let (list_status, list_body) = get_json(&app, &jwt, "/migration/algolia/jobs").await;
    assert_eq!(list_status, StatusCode::OK);
    assert_eq!(list_body["jobs"].as_array().unwrap().len(), 1);
    assert_public_job_history_contract(&list_body["jobs"][0]);

    let (get_status, _get_body) =
        get_json(&app, &jwt, &format!("/migration/algolia/jobs/{id}")).await;
    assert_eq!(get_status, StatusCode::OK);
}
