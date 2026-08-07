use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use std::collections::BTreeSet;
use tower::ServiceExt;

fn json_post(uri: &str, body: serde_json::Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

fn valid_workload() -> serde_json::Value {
    serde_json::json!({
        "document_count": 100_000,
        "avg_document_size_bytes": 2048,
        "search_requests_per_month": 1_000_000,
        "write_operations_per_month": 50_000,
        "sort_directions": 2,
        "num_indexes": 1,
        "high_availability": false
    })
}

#[tokio::test]
async fn pricing_compare_returns_comparison_result_for_valid_workload() {
    let app = crate::common::test_app();
    let req = json_post("/pricing/compare", valid_workload());

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_json(resp).await;

    // Response must contain workload echo and estimates array
    assert!(
        body["workload"].is_object(),
        "response must echo the workload"
    );
    assert!(
        body["estimates"].is_array(),
        "response must contain estimates"
    );
    assert!(
        body["generated_at"].is_string(),
        "response must contain generated_at timestamp"
    );

    let estimates = body["estimates"].as_array().unwrap();
    assert!(!estimates.is_empty(), "estimates must not be empty");

    // Each estimate must have provider, monthly_total_cents, line_items
    let first = &estimates[0];
    assert!(first["provider"].is_string(), "estimate must have provider");
    assert!(
        first["monthly_total_cents"].is_number(),
        "estimate must have monthly_total_cents"
    );
    assert!(
        first["line_items"].is_array(),
        "estimate must have line_items"
    );
}

#[tokio::test]
async fn pricing_compare_estimates_sorted_cheapest_first() {
    let app = crate::common::test_app();
    let req = json_post("/pricing/compare", valid_workload());

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_json(resp).await;
    let estimates = body["estimates"].as_array().unwrap();

    // Verify cheapest-first sorting
    for window in estimates.windows(2) {
        let a = window[0]["monthly_total_cents"].as_i64().unwrap();
        let b = window[1]["monthly_total_cents"].as_i64().unwrap();
        assert!(
            a <= b,
            "estimates must be sorted cheapest-first: {} > {}",
            a,
            b
        );
    }
}

#[tokio::test]
async fn pricing_compare_exposes_verification_labels() {
    let app = crate::common::test_app();
    let req = json_post("/pricing/compare", valid_workload());

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_json(resp).await;
    let estimates = body["estimates"].as_array().unwrap();

    let algolia = estimates
        .iter()
        .find(|estimate| estimate["provider"].as_str() == Some("Algolia"))
        .expect("Algolia estimate must be present");
    assert_eq!(algolia["verification_label"], "2026-07-06");

    let flapjack_cloud = estimates
        .iter()
        .find(|estimate| estimate["provider"].as_str() == Some("Flapjack Cloud"))
        .expect("Flapjack Cloud estimate must be present");
    // Stamped in 6c0638125; the date is the one carried by griddle.rs:14.
    assert_eq!(flapjack_cloud["verification_label"], "2026-08-05");
}

#[tokio::test]
async fn pricing_compare_exposes_withheld_providers_from_publication_rule() {
    let app = crate::common::test_app();
    let req = json_post("/pricing/compare", valid_workload());

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_json(resp).await;
    let estimates = body["estimates"]
        .as_array()
        .expect("estimates must be an array");
    let withheld = body["withheld_providers"]
        .as_array()
        .expect("withheld_providers must be an array");

    let expected_withheld: Vec<_> = pricing_calculator::providers::all_metadata()
        .into_iter()
        .filter(|metadata| !pricing_calculator::providers::is_published(metadata))
        .collect();
    assert_eq!(
        withheld.len(),
        expected_withheld.len(),
        "withheld_providers must expose every registered provider withheld by is_published"
    );

    let estimate_providers: BTreeSet<&str> = estimates
        .iter()
        .map(|estimate| {
            estimate["provider"]
                .as_str()
                .expect("estimate provider must be serialized")
        })
        .collect();

    for metadata in &expected_withheld {
        let serialized_provider = serde_json::to_value(metadata.id)
            .expect("provider id must serialize")
            .as_str()
            .expect("provider id must serialize as a string")
            .to_string();
        assert!(
            !estimate_providers.contains(serialized_provider.as_str()),
            "withheld provider {} must not appear in estimates",
            serialized_provider
        );
        assert!(
            withheld.iter().any(|entry| {
                entry["provider"] == serialized_provider
                    && entry["display_name"] == metadata.display_name
                    && entry["reason"] == metadata.verification_label()
            }),
            "withheld_providers must include provider id, display name, and reason for {}",
            metadata.display_name
        );
    }

    for metadata in pricing_calculator::providers::all_metadata()
        .into_iter()
        .filter(pricing_calculator::providers::is_published)
    {
        let serialized_provider = serde_json::to_value(metadata.id)
            .expect("provider id must serialize")
            .as_str()
            .expect("provider id must serialize as a string")
            .to_string();
        assert!(
            estimate_providers.contains(serialized_provider.as_str()),
            "published provider {} must remain present in estimates",
            serialized_provider
        );
    }
}

#[tokio::test]
async fn pricing_compare_rejects_invalid_document_count() {
    let app = crate::common::test_app();
    let mut workload = valid_workload();
    workload["document_count"] = serde_json::json!(-1);

    let req = json_post("/pricing/compare", workload);
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let body = body_json(resp).await;
    assert!(
        body["error"].is_string(),
        "error response must have error field"
    );
}

#[tokio::test]
async fn pricing_compare_rejects_invalid_avg_document_size() {
    let app = crate::common::test_app();
    let mut workload = valid_workload();
    workload["avg_document_size_bytes"] = serde_json::json!(0);

    let req = json_post("/pricing/compare", workload);
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let body = body_json(resp).await;
    assert!(
        body["error"].is_string(),
        "error response must have error field"
    );
}

#[tokio::test]
async fn pricing_compare_rejects_malformed_json() {
    let app = crate::common::test_app();

    let req = Request::builder()
        .method("POST")
        .uri("/pricing/compare")
        .header("content-type", "application/json")
        .body(Body::from("not json"))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    // Axum returns 400 for syntactically invalid JSON
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn pricing_compare_rejects_missing_fields() {
    let app = crate::common::test_app();

    // Only provide one field — all others missing
    let req = json_post(
        "/pricing/compare",
        serde_json::json!({
            "document_count": 100
        }),
    );

    let resp = app.oneshot(req).await.unwrap();
    // Axum returns 422 for missing required fields
    assert_eq!(resp.status(), StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
async fn pricing_compare_requires_no_authentication() {
    // No auth header — should still succeed for public endpoint
    let app = crate::common::test_app();
    let req = json_post("/pricing/compare", valid_workload());

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn pricing_compare_line_items_have_required_fields() {
    let app = crate::common::test_app();
    let req = json_post("/pricing/compare", valid_workload());

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_json(resp).await;
    let estimates = body["estimates"].as_array().unwrap();

    for estimate in estimates {
        let line_items = estimate["line_items"].as_array().unwrap();
        for item in line_items {
            assert!(
                item["description"].is_string(),
                "line item must have description"
            );
            assert!(
                item["amount_cents"].is_number(),
                "line item must have amount_cents"
            );
        }
    }
}

/// Meilisearch usage-based pricing was retired 2026-07-07 per the evidence bundle
/// `docs/runbooks/evidence/competitor-pricing/20260707T172320Z_meilisearch/` (the
/// public pricing page no longer publishes the modeled Build/Pro rate card). The
/// compare surface must not return that provider or its display name for any
/// valid workload.
#[tokio::test]
async fn pricing_compare_omits_retired_meilisearch_usage_provider() {
    let app = crate::common::test_app();
    let req = json_post("/pricing/compare", valid_workload());

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_json(resp).await;
    let estimates = body["estimates"]
        .as_array()
        .expect("estimates must be an array");

    // The compare surface publishes exactly the source-verified providers. Derive the
    // expected count from the calculator's own publication predicate (the single owner of
    // "published") rather than a magic number, so withholding unverified providers — e.g.
    // Elastic Cloud / AWS OpenSearch, currently never-verified — keeps this test honest.
    let published_count = pricing_calculator::providers::all_metadata()
        .into_iter()
        .filter(pricing_calculator::providers::is_published)
        .count();
    assert_eq!(
        estimates.len(),
        published_count,
        "compare output must expose exactly the published (source-verified) providers"
    );

    for estimate in estimates {
        let provider_name = estimate["provider"]
            .as_str()
            .expect("estimate must expose the serialized provider display name");
        assert_ne!(
            provider_name, "Meilisearch Cloud (Usage-Based)",
            "retired Meilisearch usage-based provider name must not appear in compare output"
        );
    }
}

/// Flapjack Cloud contract: the API must return its managed estimate with storage-only
/// pricing (5 cents/MB, $10 minimum) and no search/write line items.
#[tokio::test]
async fn pricing_compare_flapjack_cloud_contract() {
    let app = crate::common::test_app();
    let req = json_post("/pricing/compare", valid_workload());

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_json(resp).await;
    let estimates = body["estimates"].as_array().unwrap();

    // The managed provider must be present under the public Flapjack Cloud brand.
    let flapjack_cloud = estimates
        .iter()
        .find(|e| e["provider"].as_str() == Some("Flapjack Cloud"))
        .expect("Flapjack Cloud must be present in estimates");

    // valid_workload: 100k docs × 2048 bytes = 204,800,000 bytes = 204.8 MB
    // 204.8 MB × 5 cents/MB = 1024 cents raw, which lands below the paid-plan
    // monthly minimum, so the floor applies: SHARED_MINIMUM_MONTHLY_CENTS = 1500
    // (infra/pricing-calculator/src/providers/griddle.rs:46, raised from $5 to
    // $15 in 68b6d95e4). The billed total is the floor, not the raw cost.
    assert_eq!(
        flapjack_cloud["monthly_total_cents"].as_i64().unwrap(),
        1500,
        "Flapjack Cloud monthly total should be the 1500-cent monthly minimum, \
         which floors the 1024-cent raw storage cost"
    );

    // No search or write line items — pricing is storage-only
    let line_items = flapjack_cloud["line_items"].as_array().unwrap();
    for item in line_items {
        let desc = item["description"].as_str().unwrap().to_lowercase();
        assert!(
            !desc.contains("search"),
            "Flapjack Cloud must not have search line items, got: {}",
            desc
        );
        assert!(
            !desc.contains("write"),
            "Flapjack Cloud must not have write line items, got: {}",
            desc
        );
    }

    // Line item amounts must sum to monthly_total_cents
    let sum: i64 = line_items
        .iter()
        .map(|li| li["amount_cents"].as_i64().unwrap())
        .sum();
    assert_eq!(
        sum,
        flapjack_cloud["monthly_total_cents"].as_i64().unwrap(),
        "line item amounts must sum to monthly_total_cents"
    );
}
