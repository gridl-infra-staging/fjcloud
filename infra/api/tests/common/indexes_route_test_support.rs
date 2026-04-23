//! Shared helpers for index route integration tests.
//!
//! `MockFlapjackHttpClient` and `setup_ready_index` live in
//! `flapjack_proxy_test_support` — re-exported here so existing test
//! files can keep their imports unchanged.

use axum::body::Body;
use axum::http::StatusCode;
use http_body_util::BodyExt;
use serde_json::Value;

// Re-export the canonical mock client and index fixture so consumers of
// this module don't need to reach into flapjack_proxy_test_support directly.
#[allow(unused_imports)]
pub use super::flapjack_proxy_test_support::{setup_ready_index, MockFlapjackHttpClient};

pub async fn response_json(resp: axum::http::Response<Body>) -> (StatusCode, Value) {
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let json: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, json)
}
