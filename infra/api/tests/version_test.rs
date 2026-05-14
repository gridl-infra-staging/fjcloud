//! `/version` endpoint contract.
//!
//! Asserts the JSON shape — every field downstream tooling
//! (`scripts/deploy_status.sh`, operator probes) depends on — and pins the
//! local-dev fallback so this test runs in any environment without CI env
//! vars set. CI is responsible for asserting that real builds inject real
//! SHAs (separate concern, lives in the mirror CI workflow).
mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use tower::ServiceExt;

#[tokio::test]
async fn version_returns_all_four_provenance_fields() {
    let app = common::test_app();

    let req = Request::builder()
        .uri("/version")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();

    // Pin the exact contract — every key downstream callers read must be
    // present. Failure here means a deploy-visibility regression.
    for key in ["dev_sha", "mirror_sha", "synced_at", "build_time"] {
        let value = json
            .get(key)
            .unwrap_or_else(|| panic!("/version response missing `{}` field: {}", key, json));
        let s = value.as_str().unwrap_or_else(|| {
            panic!(
                "/version field `{}` must be a string, got: {:?}",
                key, value
            )
        });
        // Empty string would silently break parsers — never acceptable, even
        // for the local-dev fallback.
        assert!(
            !s.is_empty(),
            "/version field `{}` must not be empty (got empty string)",
            key
        );
    }
}

#[tokio::test]
async fn version_falls_back_to_local_dev_when_env_vars_unset() {
    // build.rs defaults all four to "local-dev" when env vars are unset.
    // This is the test-time path (CI for the dev repo doesn't set the
    // FJCLOUD_* vars). Confirms the fallback is wired correctly — a future
    // refactor that changes the literal would surface here.
    let app = common::test_app();

    let req = Request::builder()
        .uri("/version")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();

    // The dev repo's own `cargo test` runs without FJCLOUD_DEV_SHA set, so
    // every field should be the literal "local-dev". If CI starts setting
    // these for the dev-repo test job in the future, this test will need to
    // tolerate real SHAs — but until then, the pin catches accidental
    // hardcoding of stale values.
    assert_eq!(json["dev_sha"], "local-dev");
    assert_eq!(json["mirror_sha"], "local-dev");
    assert_eq!(json["synced_at"], "local-dev");
    assert_eq!(json["build_time"], "local-dev");
}
