//! T0.1 — webhook delivery smoke test.
//!
//! Why this exists: `alerting_test.rs` covers JSON-payload formatting and the
//! "no webhook URL configured" fallback path, but NOTHING in the existing test
//! suite proves that a `WebhookAlertService` constructed with a real URL actually
//! fires an HTTP POST when `send_alert` is called. Without that proof, a refactor
//! of `WebhookAlertService::send_alert` could silently drop the HTTP step and
//! every "alerting works" test would still pass — masking the regression until
//! a real production incident failed to page anyone.
//!
//! These tests close that gap by spinning up `wiremock::MockServer` in front of
//! the webhook URL and asserting:
//!   1. Exactly one POST request reached the mock server (catches "didn't fire").
//!   2. The request body's JSON has the exact shape the operator's Slack/Discord
//!      will see — including the *severity-derived color*, not just "any color"
//!      (catches "fired but with the wrong payload" regressions).
//!
//! Marked `#[ignore]` because they spin up local TCP listeners (wiremock) and
//! we run them on-demand / nightly rather than every PR. Invoke with:
//!   cargo test -p api alerting_webhook_smoke -- --ignored

mod common;

use std::collections::HashMap;

use api::services::alerting::{Alert, AlertService, AlertSeverity, WebhookAlertService};
use sqlx::postgres::PgPoolOptions;
use wiremock::matchers::method;
use wiremock::{Mock, MockServer, ResponseTemplate};

/// Build a `WebhookAlertService` wired to a wiremock URL, with a connect-lazy
/// pool that will never reach a real Postgres. We deliberately don't supply a
/// live DB here — the discriminating assertions are on the wiremock side
/// (HTTP body shape), not on the persist step. `send_alert` will return
/// `Err(DbError)` because persist fails; the wiremock having received the
/// expected POST still proves the webhook path runs end-to-end.
fn build_service_with_slack_only(slack_url: String) -> WebhookAlertService {
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(std::time::Duration::from_millis(100))
        // Port 1 (TCPMUX) reliably refuses connections — same pattern the
        // wider test suite uses (see common::lazy_pool comment for why).
        .connect_lazy("postgres://test:test@127.0.0.1:1/test")
        .expect("connect_lazy should never fail");

    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .expect("reqwest client");

    WebhookAlertService::new(pool, http_client, Some(slack_url), None, "smoke".into())
}

fn build_service_with_discord_only(discord_url: String) -> WebhookAlertService {
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(std::time::Duration::from_millis(100))
        .connect_lazy("postgres://test:test@127.0.0.1:1/test")
        .expect("connect_lazy should never fail");

    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .expect("reqwest client");

    WebhookAlertService::new(pool, http_client, None, Some(discord_url), "smoke".into())
}

// ---------------------------------------------------------------------------
// Test 1: a configured Slack URL receives a POST with the correct JSON body
//         (including severity-correct color — not just "some color").
// ---------------------------------------------------------------------------

#[tokio::test]
#[ignore = "wiremock smoke test; run with --ignored"]
async fn webhook_critical_alert_posts_correct_slack_body() {
    let mock = MockServer::start().await;

    // Match any POST to the mock's root. We assert the body shape AFTER the
    // request lands by reading received_requests() — that lets us inspect the
    // actual JSON the production code produced, not just match a substring.
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(200))
        .expect(1) // discriminating: zero POSTs would fail this expectation
        .mount(&mock)
        .await;

    let svc = build_service_with_slack_only(mock.uri());

    let alert = Alert {
        severity: AlertSeverity::Critical,
        title: "T0.1 smoke — critical".into(),
        message: "verifying webhook fires + body shape".into(),
        metadata: HashMap::from([("probe".into(), "t0.1".into())]),
    };

    // send_alert returns Err(DbError) because persist_alert can't reach a real
    // DB — that's expected and the test ignores it. The wiremock-side
    // assertions below are what carry the test's discriminating power: they
    // confirm the HTTP POST happened BEFORE the failed persist, with the
    // correct payload. If we asserted send_alert returned Ok we'd be testing
    // DB plumbing, not the webhook path.
    let _ = svc.send_alert(alert).await;

    let received = mock.received_requests().await.expect("mock alive");
    assert_eq!(
        received.len(),
        1,
        "expected exactly one POST to slack webhook, got {}",
        received.len()
    );

    let body: serde_json::Value =
        serde_json::from_slice(&received[0].body).expect("body must be valid JSON");

    // Discriminating shape assertions: a handler that POSTs an empty body or
    // wrong field names would all fail here.
    let attachments = body["attachments"]
        .as_array()
        .expect("slack payload must have 'attachments' array");
    assert_eq!(attachments.len(), 1, "expected exactly one attachment");

    let attachment = &attachments[0];

    // The CRITICAL discriminating assertion: severity → color. This catches a
    // regression where the formatter accidentally hardcodes one color or pulls
    // from the wrong severity field. AlertSeverity::Critical.slack_color() is
    // "#d00000" (red), per alerting.rs:36.
    assert_eq!(
        attachment["color"], "#d00000",
        "Critical alert MUST use the red slack color, not {}",
        attachment["color"]
    );

    assert_eq!(attachment["title"], "T0.1 smoke — critical");
    assert_eq!(attachment["text"], "verifying webhook fires + body shape");

    // Verify the environment field made it (proves the constructor's env
    // string isn't being silently dropped).
    let fields = attachment["fields"]
        .as_array()
        .expect("attachment must have 'fields' array");
    let env_field = fields
        .iter()
        .find(|f| f["title"] == "Environment")
        .expect("Environment field must be present");
    assert_eq!(env_field["value"], "smoke");
}

// ---------------------------------------------------------------------------
// Test 2: a Warning alert fires with the warning color (different from Critical).
//
// Why a second test rather than parameterizing test 1: catches the regression
// where every severity gets the same color (e.g. someone hardcodes "#d00000").
// Two severities → two distinct colors makes the test mutually-discriminating.
// ---------------------------------------------------------------------------

#[tokio::test]
#[ignore = "wiremock smoke test; run with --ignored"]
async fn webhook_warning_alert_posts_correct_slack_color() {
    let mock = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(200))
        .expect(1)
        .mount(&mock)
        .await;

    let svc = build_service_with_slack_only(mock.uri());

    let alert = Alert {
        severity: AlertSeverity::Warning,
        title: "T0.1 smoke — warning".into(),
        message: "verifying warning color path".into(),
        metadata: HashMap::new(),
    };
    let _ = svc.send_alert(alert).await;

    let received = mock.received_requests().await.expect("mock alive");
    let body: serde_json::Value = serde_json::from_slice(&received[0].body).unwrap();

    // Warning = #daa038 (yellow), per alerting.rs:35. If this matches Critical's
    // red, the test fails — so the pair (this test + the Critical test) catches
    // any "all severities get the same color" regression.
    assert_eq!(body["attachments"][0]["color"], "#daa038");
}

// ---------------------------------------------------------------------------
// Test 3: a configured Discord URL receives a POST with embed shape +
//         severity-correct integer color.
// ---------------------------------------------------------------------------

#[tokio::test]
#[ignore = "wiremock smoke test; run with --ignored"]
async fn webhook_critical_alert_posts_correct_discord_body() {
    let mock = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(200))
        .expect(1)
        .mount(&mock)
        .await;

    let svc = build_service_with_discord_only(mock.uri());

    let alert = Alert {
        severity: AlertSeverity::Critical,
        title: "T0.1 smoke — discord critical".into(),
        message: "verifying discord embed path".into(),
        metadata: HashMap::from([("probe".into(), "t0.1".into())]),
    };
    let _ = svc.send_alert(alert).await;

    let received = mock.received_requests().await.expect("mock alive");
    assert_eq!(received.len(), 1);

    let body: serde_json::Value = serde_json::from_slice(&received[0].body).unwrap();

    // Discord uses "embeds" with a *decimal integer* color (not a hex string).
    // Critical = 0xd00000 = 13631488. A regression that swapped the slack-
    // string-color into the discord payload would fail this assertion.
    let embeds = body["embeds"].as_array().expect("embeds array");
    assert_eq!(embeds.len(), 1);
    assert_eq!(embeds[0]["color"], 0xd00000_u32);
    assert_eq!(embeds[0]["title"], "T0.1 smoke — discord critical");
    assert_eq!(embeds[0]["description"], "verifying discord embed path");
}

// ---------------------------------------------------------------------------
// Test 4: when both Slack and Discord URLs are configured, ONE alert fires
//         BOTH POSTs (one to each channel). Catches the regression where the
//         second channel gets dropped.
// ---------------------------------------------------------------------------

#[tokio::test]
#[ignore = "wiremock smoke test; run with --ignored"]
async fn webhook_alert_with_both_channels_fires_both_posts() {
    let slack_mock = MockServer::start().await;
    let discord_mock = MockServer::start().await;

    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(200))
        .expect(1)
        .mount(&slack_mock)
        .await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(200))
        .expect(1)
        .mount(&discord_mock)
        .await;

    let pool = PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(std::time::Duration::from_millis(100))
        .connect_lazy("postgres://test:test@127.0.0.1:1/test")
        .expect("connect_lazy should never fail");

    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .unwrap();

    let svc = WebhookAlertService::new(
        pool,
        http_client,
        Some(slack_mock.uri()),
        Some(discord_mock.uri()),
        "smoke".into(),
    );

    let alert = Alert {
        severity: AlertSeverity::Info,
        title: "T0.1 smoke — both channels".into(),
        message: "verifying fan-out".into(),
        metadata: HashMap::new(),
    };
    let _ = svc.send_alert(alert).await;

    // Each mock's .expect(1) is checked when MockServer drops; the assertion
    // below makes the failure mode explicit.
    let slack_hits = slack_mock.received_requests().await.unwrap().len();
    let discord_hits = discord_mock.received_requests().await.unwrap().len();
    assert_eq!(slack_hits, 1, "slack should have received exactly 1 POST");
    assert_eq!(
        discord_hits, 1,
        "discord should have received exactly 1 POST"
    );
}
