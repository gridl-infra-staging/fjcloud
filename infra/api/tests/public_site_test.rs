mod common;

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use http_body_util::BodyExt;
use tower::ServiceExt;

const ROBOTS_TAG: &str = "noindex, nofollow, noarchive, nosnippet, noimageindex";

async fn get(path: &str) -> axum::response::Response {
    let req = Request::builder()
        .uri(path)
        .body(Body::empty())
        .expect("test request should build");

    common::test_app()
        .oneshot(req)
        .await
        .expect("test router should respond")
}

async fn response_text(response: axum::response::Response) -> String {
    let body = response
        .into_body()
        .collect()
        .await
        .expect("response body should collect")
        .to_bytes();

    String::from_utf8(body.to_vec()).expect("response should be UTF-8")
}

async fn response_body_len(response: axum::response::Response) -> usize {
    response
        .into_body()
        .collect()
        .await
        .expect("response body should collect")
        .to_bytes()
        .len()
}

#[tokio::test]
async fn root_serves_public_landing_page_with_review_metadata() {
    let response = get("/").await;

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response
            .headers()
            .get("x-robots-tag")
            .and_then(|v| v.to_str().ok()),
        Some(ROBOTS_TAG),
        "public beta pages should discourage indexing while preserving direct access"
    );
    assert!(
        response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .is_some_and(|value| value.starts_with("text/html")),
        "root page should be served as HTML"
    );

    let body = response_text(response).await;
    assert!(body.contains("<title>Flapjack Cloud - Managed search hosting</title>"));
    assert!(body.contains("Managed hosting for Flapjack search."));
    assert!(body.contains("https://github.com/gridlhq/flapjack"));
    assert!(body.contains(r#"property="og:title" content="Flapjack Cloud""#));
    assert!(body.contains("https://cloud.flapjack.foo/flapjack_cloud_preview.png"));
    assert!(body.contains("BETA"));
    assert!(body.contains("Privacy Policy"));
    assert!(body.contains("Terms of Service"));
}

#[tokio::test]
async fn robots_txt_blocks_generic_crawlers_and_allows_unfurl_bots() {
    let response = get("/robots.txt").await;

    assert_eq!(response.status(), StatusCode::OK);
    assert!(
        response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .is_some_and(|value| value.starts_with("text/plain")),
        "robots.txt should be served as plain text"
    );

    let body = response_text(response).await;
    assert!(body.contains("User-agent: Slackbot-LinkExpanding"));
    assert!(body.contains("User-agent: Twitterbot"));
    assert!(body.contains("User-agent: facebookexternalhit"));
    assert!(body.contains("User-agent: *"));
    assert!(body.contains("Disallow: /"));
}

#[tokio::test]
async fn favicon_and_preview_image_are_served_with_asset_content_types() {
    let favicon = get("/favicon.ico").await;
    assert_eq!(favicon.status(), StatusCode::OK);
    assert_eq!(
        favicon
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok()),
        Some("image/x-icon")
    );
    assert!(
        response_body_len(favicon).await > 1_000,
        "favicon should be the real Flapjack icon, not an empty placeholder"
    );

    let preview = get("/flapjack_cloud_preview.png").await;
    assert_eq!(preview.status(), StatusCode::OK);
    assert_eq!(
        preview
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok()),
        Some("image/png")
    );
    assert!(
        response_body_len(preview).await > 10_000,
        "link preview image should be a meaningful preview asset"
    );
}
