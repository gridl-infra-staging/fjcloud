use super::*;
use crate::secrets::mock::MockNodeSecretManager;
use async_trait::async_trait;
use serde_json::json;
use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;

#[derive(Default)]
struct MockCompatibilityHttpClient {
    responses: Mutex<VecDeque<Result<FlapjackHttpResponse, ProxyError>>>,
    requests: Mutex<Vec<FlapjackHttpRequest>>,
}

impl MockCompatibilityHttpClient {
    fn push_health(&self, body: serde_json::Value) {
        self.responses
            .lock()
            .unwrap()
            .push_back(Ok(FlapjackHttpResponse {
                status: 200,
                body: body.to_string(),
                request_api_key: String::new(),
            }));
    }

    fn push_text(&self, status: u16, body: &str) {
        self.responses
            .lock()
            .unwrap()
            .push_back(Ok(FlapjackHttpResponse {
                status,
                body: body.to_string(),
                request_api_key: String::new(),
            }));
    }

    fn push_error(&self, error: ProxyError) {
        self.responses.lock().unwrap().push_back(Err(error));
    }

    fn take_requests(&self) -> Vec<FlapjackHttpRequest> {
        self.requests.lock().unwrap().clone()
    }
}

#[async_trait]
impl FlapjackHttpClient for MockCompatibilityHttpClient {
    async fn send(&self, request: FlapjackHttpRequest) -> Result<FlapjackHttpResponse, ProxyError> {
        self.requests.lock().unwrap().push(request);
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("queued compatibility response")
    }
}

fn strict_requirements() -> FlapjackEngineRequirements {
    FlapjackEngineRequirements::new(
        Some("1.0.10"),
        Some("abc123"),
        Some("build-1"),
        Some("sha-1"),
        Some("preview_events_v1"),
    )
}

async fn classify_health(
    requirements: FlapjackEngineRequirements,
    body: serde_json::Value,
) -> FlapjackRuntimeIdentityReason {
    let http = Arc::new(MockCompatibilityHttpClient::default());
    http.push_health(body);
    let proxy =
        FlapjackProxy::with_http_client(http.clone(), Arc::new(MockNodeSecretManager::new()));
    let result = proxy
        .check_engine_compatibility("https://flapjack.example/", &requirements)
        .await;
    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(requests[0].url, "https://flapjack.example/health");
    assert_eq!(requests[0].api_key, "");
    result.reason
}

#[tokio::test]
async fn flapjack_engine_compatibility_classifies_stage_one_reasons() {
    let cases = [
        (
            json!({
                "version": "1.0.10",
                "producer_revision": "abc123",
                "build_id": "build-1",
                "binary_sha256": "sha-1",
                "dirty": false,
                "capabilities": ["preview_events_v1"]
            }),
            FlapjackRuntimeIdentityReason::Match,
        ),
        (
            json!({
                "version": "1.0.11",
                "producer_revision": "abc123",
                "build_id": "build-1",
                "binary_sha256": "sha-1",
                "dirty": false,
                "capabilities": ["preview_events_v1"]
            }),
            FlapjackRuntimeIdentityReason::VersionMismatch,
        ),
        (
            json!({
                "version": "1.0.10",
                "revision": "def456",
                "workspaceDigest": "build-1",
                "sha256": "sha-1",
                "dirty": false,
                "capabilities": ["preview_events_v1"]
            }),
            FlapjackRuntimeIdentityReason::RevisionMismatch,
        ),
        (
            json!({
                "version": "1.0.10",
                "revision": "abc123",
                "workspaceDigest": "build-2",
                "sha256": "sha-1",
                "dirty": false,
                "capabilities": ["preview_events_v1"]
            }),
            FlapjackRuntimeIdentityReason::BuildIdMismatch,
        ),
        (
            json!({
                "version": "1.0.10",
                "revision": "abc123",
                "workspaceDigest": "build-1",
                "sha256": "sha-2",
                "dirty": false,
                "capabilities": ["preview_events_v1"]
            }),
            FlapjackRuntimeIdentityReason::ChecksumMismatch,
        ),
        (
            json!({
                "version": "1.0.10",
                "producer_revision": "abc123",
                "build_id": "build-1",
                "binary_sha256": "sha-1",
                "dirty": true,
                "capabilities": ["preview_events_v1"]
            }),
            FlapjackRuntimeIdentityReason::DirtyLocalBuild,
        ),
        (
            json!({
                "version": "1.0.10",
                "producer_revision": "abc123",
                "build_id": "build-1",
                "binary_sha256": "sha-1",
                "dirty": false,
                "capabilities": {"preview_events_v1": false}
            }),
            FlapjackRuntimeIdentityReason::MissingCapability,
        ),
        (
            json!({"version": "1.0.10"}),
            FlapjackRuntimeIdentityReason::LegacyMalformedHealth,
        ),
    ];

    for (body, expected) in cases {
        let actual = classify_health(strict_requirements(), body).await;
        assert_eq!(actual, expected);
        assert_eq!(actual.as_str(), expected.as_str());
    }
}

#[tokio::test]
async fn flapjack_engine_compatibility_accepts_nested_build_health_and_map_capabilities() {
    let reason = classify_health(
        strict_requirements(),
        json!({
            "build": {
                "version": "1.0.10",
                "producer_revision": "abc123",
                "build_id": "build-1",
                "binary_sha256": "sha-1",
                "dirty": false,
                "capabilities": {"preview_events_v1": true}
            }
        }),
    )
    .await;

    assert_eq!(reason, FlapjackRuntimeIdentityReason::Match);
}

#[tokio::test]
async fn flapjack_engine_compatibility_classifies_runtime_unreachable() {
    let http = Arc::new(MockCompatibilityHttpClient::default());
    http.push_error(ProxyError::Unreachable("connection refused".into()));
    let proxy = FlapjackProxy::with_http_client(http, Arc::new(MockNodeSecretManager::new()));

    let result = proxy
        .check_engine_compatibility("https://flapjack.example", &strict_requirements())
        .await;

    assert_eq!(
        result.reason,
        FlapjackRuntimeIdentityReason::RuntimeUnreachable
    );
}

#[tokio::test]
async fn flapjack_engine_compatibility_classifies_non_success_health_as_runtime_unreachable() {
    let http = Arc::new(MockCompatibilityHttpClient::default());
    http.push_text(503, "warming");
    let proxy = FlapjackProxy::with_http_client(http, Arc::new(MockNodeSecretManager::new()));

    let result = proxy
        .check_engine_compatibility("https://flapjack.example", &strict_requirements())
        .await;

    assert_eq!(
        result.reason,
        FlapjackRuntimeIdentityReason::RuntimeUnreachable
    );
}

#[test]
fn flapjack_engine_compatibility_env_requirements_use_stage_one_contract_names() {
    let configured = HashMap::from([
        ("FJCLOUD_FLAPJACK_VERSION", "1.0.10"),
        ("FJCLOUD_FLAPJACK_REQUIRED_REVISION", "abc123"),
        ("FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID", "build-1"),
        ("FJCLOUD_FLAPJACK_REQUIRED_SHA256", "sha-1"),
        ("FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY", "preview_events_v1"),
    ]);
    let mut requested_names = Vec::new();
    let requirements = FlapjackEngineRequirements::from_lookup(|name| {
        requested_names.push(name.to_string());
        configured.get(name).map(|value| (*value).to_string())
    })
    .expect("complete Stage 1 identity configuration must be accepted");

    assert_eq!(requirements.expected_version.as_deref(), Some("1.0.10"));
    assert_eq!(requirements.required_revision.as_deref(), Some("abc123"));
    assert_eq!(requirements.required_build_id.as_deref(), Some("build-1"));
    assert_eq!(requirements.required_sha256.as_deref(), Some("sha-1"));
    assert_eq!(
        requirements.required_capability.as_deref(),
        Some("preview_events_v1")
    );
    assert_eq!(
        requested_names,
        [
            "FJCLOUD_FLAPJACK_VERSION",
            "FJCLOUD_FLAPJACK_REQUIRED_REVISION",
            "FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID",
            "FJCLOUD_FLAPJACK_REQUIRED_SHA256",
            "FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY",
        ]
    );
}

#[test]
fn flapjack_engine_compatibility_env_requirements_reject_absent_or_partial_identity() {
    let identity_names = [
        "FJCLOUD_FLAPJACK_VERSION",
        "FJCLOUD_FLAPJACK_REQUIRED_REVISION",
        "FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID",
        "FJCLOUD_FLAPJACK_REQUIRED_SHA256",
    ];
    let absent = FlapjackEngineRequirements::from_lookup(|_| None)
        .expect_err("absent expected identity must fail closed");
    assert_eq!(absent.missing_variables(), identity_names.as_slice());

    let partial = FlapjackEngineRequirements::from_lookup(|name| match name {
        "FJCLOUD_FLAPJACK_VERSION" => Some("1.0.10".to_string()),
        "FJCLOUD_FLAPJACK_REQUIRED_REVISION" => Some("abc123".to_string()),
        _ => None,
    })
    .expect_err("partial expected identity must fail closed");
    assert_eq!(
        partial.missing_variables(),
        [
            "FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID",
            "FJCLOUD_FLAPJACK_REQUIRED_SHA256",
        ]
    );
}

/// A fully-matching build health payload that ALSO carries a runtime_security
/// object with future/unknown keys must still classify as Match: the runtime
/// security seam never affects build/capability compatibility, and unknown
/// runtime-security fields are tolerated (no deny_unknown_fields).
#[tokio::test]
async fn flapjack_engine_compatibility_engine_build_identity_ignores_unknown_runtime_security_fields(
) {
    let reason = classify_health(
        strict_requirements(),
        json!({
            "version": "1.0.10",
            "producer_revision": "abc123",
            "build_id": "build-1",
            "binary_sha256": "sha-1",
            "dirty": false,
            "capabilities": ["preview_events_v1"],
            "runtime_security": {
                "posture": "enforcing",
                "enforced": true,
                "future_unknown_field": {"nested": [1, 2, 3]},
                "another_unknown": "ignored"
            }
        }),
    )
    .await;

    assert_eq!(reason, FlapjackRuntimeIdentityReason::Match);
}

/// A payload that is malformed for BUILD identity (missing revision/build/sha/
/// dirty) must still fail closed to LegacyMalformedHealth even when it carries
/// a runtime_security object. The runtime-security seam must never rescue a
/// build-malformed payload.
#[tokio::test]
async fn flapjack_engine_compatibility_engine_build_identity_preserves_malformed_health_fail_closed(
) {
    let reason = classify_health(
        strict_requirements(),
        json!({
            "version": "1.0.10",
            "runtime_security": {
                "posture": "enforcing",
                "enforced": true
            }
        }),
    )
    .await;

    assert_eq!(reason, FlapjackRuntimeIdentityReason::LegacyMalformedHealth);
}

/// The typed runtime-security seam must be genuinely populated from the health
/// payload (proving it is real, not dead code) and absent when the payload
/// omits runtime_security. Unknown/future fields are ignored while typed
/// accessors expose the recognized observations.
#[test]
fn flapjack_engine_compatibility_engine_build_identity_populates_typed_runtime_security_seam() {
    let with_security = json!({
        "version": "1.0.10",
        "runtime_security": {
            "posture": "enforcing",
            "enforced": true,
            "future_unknown_field": 42
        }
    });
    let with_map = with_security.as_object().expect("health object");
    let observed = observed_identity(with_map, with_map);
    let security = observed
        .runtime_security
        .as_ref()
        .expect("runtime_security must be parsed from the payload");
    assert_eq!(security.posture(), Some("enforcing"));
    assert_eq!(security.enforced(), Some(true));

    let without_security = json!({ "version": "1.0.10" });
    let without_map = without_security.as_object().expect("health object");
    let observed_absent = observed_identity(without_map, without_map);
    assert!(observed_absent.runtime_security.is_none());
}
