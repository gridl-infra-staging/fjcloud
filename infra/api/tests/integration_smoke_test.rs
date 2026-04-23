// Integration smoke test — verifies the test harness boots and the API responds.
//
// This test is SKIPPED when INTEGRATION env var is not set.
// Run with: INTEGRATION=1 cargo test -p api --test integration_smoke_test

#[path = "common/integration_helpers.rs"]
mod integration_helpers;

use integration_helpers::{api_base, http_client};

integration_test!(integration_smoke_health_check, async {
    let client = http_client();
    let base = api_base();

    let resp = client
        .get(format!("{base}/health"))
        .send()
        .await
        .expect("health check request failed");

    assert_eq!(resp.status().as_u16(), 200, "GET /health should return 200");

    let body: serde_json::Value = resp.json().await.expect("health response not JSON");
    assert_eq!(
        body["status"], "ok",
        "health response should have status=ok"
    );
});
