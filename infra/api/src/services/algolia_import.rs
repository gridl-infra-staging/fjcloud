use std::fmt;
use std::sync::Arc;

use serde::Serialize;
use zeroize::{Zeroize, Zeroizing};

use crate::models::algolia_import_job::{
    AlgoliaImportErrorCode, AlgoliaImportJobStatus, AlgoliaImportPublicationDisposition,
    AlgoliaImportSummary,
};
use crate::services::flapjack_proxy::{FlapjackProxy, ProxyError};

#[path = "algolia_import/admission.rs"]
mod admission;
#[cfg(test)]
#[path = "algolia_import/admission_tests.rs"]
mod admission_tests;
#[path = "algolia_import/cancel.rs"]
mod cancel;
#[path = "algolia_import/error_classifier.rs"]
mod error_classifier;
#[cfg(test)]
#[path = "algolia_import/error_classifier_tests.rs"]
mod error_classifier_tests;
#[path = "algolia_import/observation.rs"]
mod observation;
#[cfg(test)]
#[path = "algolia_import/observation_tests.rs"]
mod observation_tests;
#[path = "algolia_import/reconciliation.rs"]
mod reconciliation;
#[cfg(test)]
#[path = "algolia_import/reconciliation_tests.rs"]
mod reconciliation_tests;
#[path = "algolia_import/status.rs"]
mod status_response;
#[cfg(test)]
#[path = "algolia_import/status_tests.rs"]
mod status_tests;

pub use admission::{
    AlgoliaImportAdmissionError, AlgoliaImportAdmissionOutcome, AlgoliaImportAdmissionRequest,
};
pub(crate) use cancel::AlgoliaImportCancelContext;
pub use error_classifier::{AlgoliaImportEngineErrorClassification, AlgoliaImportEngineOperation};
pub use observation::{
    AlgoliaImportObservationCursor, AlgoliaImportRunningObservation,
    AlgoliaImportStatusObservation, AlgoliaImportStatusObservationError,
};
pub(crate) use reconciliation::{
    AlgoliaImportReconciliationConfig, AlgoliaImportReconciliationRuntime,
};
pub use status_response::{
    AsyncMigrationDisposition, AsyncMigrationExportProgress, AsyncMigrationPhase,
    AsyncMigrationStatusResponse,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlgoliaImportTerminalHandoff {
    pub status: AlgoliaImportJobStatus,
    pub publication_disposition: AlgoliaImportPublicationDisposition,
    pub summary: AlgoliaImportSummary,
    pub error_code: Option<AlgoliaImportErrorCode>,
    pub error_message: Option<String>,
}

impl AlgoliaImportTerminalHandoff {
    pub fn new(
        status: AlgoliaImportJobStatus,
        publication_disposition: AlgoliaImportPublicationDisposition,
        summary: AlgoliaImportSummary,
        error_code: Option<AlgoliaImportErrorCode>,
        error_message: Option<String>,
    ) -> Result<Self, &'static str> {
        if !status.has_valid_terminal_disposition(publication_disposition) {
            return Err("terminal handoff has an invalid publication disposition");
        }
        Ok(Self {
            status,
            publication_disposition,
            summary,
            error_code,
            error_message,
        })
    }
}

#[derive(Clone)]
pub struct AlgoliaImportService {
    proxy: Arc<FlapjackProxy>,
}

impl AlgoliaImportService {
    pub fn new(proxy: Arc<FlapjackProxy>) -> Self {
        Self { proxy }
    }

    pub async fn submit(
        &self,
        target: EngineTarget,
        request: AlgoliaImportSubmitRequest,
    ) -> Result<AsyncMigrationStatusResponse, AlgoliaImportEngineError> {
        self.proxy
            .submit_algolia_migration(
                &target.flapjack_url,
                &target.node_id,
                &target.region,
                request.into_payload(),
            )
            .await
            .map_err(AlgoliaImportEngineError::from_proxy)
    }

    pub async fn status(
        &self,
        target: EngineTarget,
        engine_job_id: &str,
    ) -> Result<AsyncMigrationStatusResponse, AlgoliaImportEngineError> {
        self.proxy
            .algolia_migration_status(
                &target.flapjack_url,
                &target.node_id,
                &target.region,
                engine_job_id,
            )
            .await
            .map_err(AlgoliaImportEngineError::from_proxy)
    }

    pub async fn cancel(
        &self,
        target: EngineTarget,
        engine_job_id: &str,
    ) -> Result<AsyncMigrationStatusResponse, AlgoliaImportEngineError> {
        self.proxy
            .cancel_algolia_migration(
                &target.flapjack_url,
                &target.node_id,
                &target.region,
                engine_job_id,
            )
            .await
            .map_err(AlgoliaImportEngineError::from_proxy)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineTarget {
    flapjack_url: String,
    node_id: String,
    region: String,
}

impl EngineTarget {
    pub fn new(
        flapjack_url: impl Into<String>,
        node_id: impl Into<String>,
        region: impl Into<String>,
    ) -> Self {
        Self {
            flapjack_url: flapjack_url.into(),
            node_id: node_id.into(),
            region: region.into(),
        }
    }
}

pub struct AlgoliaImportSubmitRequest {
    app_id: Zeroizing<String>,
    api_key: Zeroizing<String>,
    source_index: String,
    target_index: Option<String>,
    overwrite: bool,
    #[cfg(test)]
    wipe_probe: Option<std::sync::Arc<std::sync::atomic::AtomicU8>>,
}

impl AlgoliaImportSubmitRequest {
    pub fn new(
        app_id: String,
        api_key: Zeroizing<String>,
        source_index: String,
        target_index: Option<String>,
        overwrite: bool,
    ) -> Self {
        Self {
            app_id: Zeroizing::new(app_id),
            api_key,
            source_index,
            target_index,
            overwrite,
            #[cfg(test)]
            wipe_probe: None,
        }
    }

    fn into_payload(self) -> AlgoliaImportSubmitPayload {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct WireRequest<'a> {
            app_id: &'a str,
            api_key: &'a str,
            source_index: &'a str,
            #[serde(skip_serializing_if = "Option::is_none")]
            target_index: Option<&'a str>,
            overwrite: bool,
        }

        let wire = WireRequest {
            app_id: self.app_id.as_str(),
            api_key: self.api_key.as_str(),
            source_index: &self.source_index,
            target_index: self.target_index.as_deref(),
            overwrite: self.overwrite,
        };
        let json = serde_json::to_string(&wire)
            .expect("serializing the Algolia import wire request cannot fail");
        AlgoliaImportSubmitPayload {
            json: Zeroizing::new(json),
            #[cfg(test)]
            wipe_probe: self.wipe_probe.clone(),
        }
    }

    #[cfg(test)]
    fn with_wipe_probe(mut self, probe: std::sync::Arc<std::sync::atomic::AtomicU8>) -> Self {
        self.wipe_probe = Some(probe);
        self
    }
}

pub(crate) struct AlgoliaImportSubmitPayload {
    json: Zeroizing<String>,
    #[cfg(test)]
    wipe_probe: Option<std::sync::Arc<std::sync::atomic::AtomicU8>>,
}

impl AlgoliaImportSubmitPayload {
    pub(crate) fn as_json(&self) -> &str {
        self.json.as_str()
    }
}

impl Drop for AlgoliaImportSubmitPayload {
    fn drop(&mut self) {
        self.json.zeroize();
        #[cfg(test)]
        if let Some(probe) = &self.wipe_probe {
            let was_zeroized = self.json.as_bytes().iter().all(|byte| *byte == 0);
            probe.store(
                if was_zeroized { 1 } else { 2 },
                std::sync::atomic::Ordering::SeqCst,
            );
        }
    }
}

impl fmt::Debug for AlgoliaImportSubmitRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AlgoliaImportSubmitRequest")
            .field("app_id", &"<redacted>")
            .field("api_key", &"<redacted>")
            .field("source_index", &self.source_index)
            .field("target_index", &self.target_index)
            .field("overwrite", &self.overwrite)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AlgoliaImportEngineError {
    #[error("engine request failed with HTTP {status}")]
    Engine { status: u16, code: Option<String> },
    #[error("malformed engine response: {0}")]
    MalformedResponse(String),
    #[error("engine transport failed: {0}")]
    Transport(String),
}

impl AlgoliaImportEngineError {
    fn from_proxy(error: ProxyError) -> Self {
        match error {
            ProxyError::FlapjackError {
                status: 200,
                message,
            } => Self::MalformedResponse(message),
            ProxyError::FlapjackError { status, message } => Self::Engine {
                status,
                code: parse_error_code(&message),
            },
            ProxyError::Unreachable(message) | ProxyError::SecretError(message) => {
                Self::Transport(message)
            }
            ProxyError::Timeout => Self::Transport("request timed out".to_string()),
        }
    }
}

fn parse_error_code(message: &str) -> Option<String> {
    serde_json::from_str::<serde_json::Value>(message)
        .ok()
        .and_then(|value| {
            value
                .get("code")
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned)
        })
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use serde_json::json;

    use crate::secrets::mock::MockNodeSecretManager;
    use crate::secrets::NodeSecretManager;
    use crate::services::flapjack_proxy::{
        FlapjackHttpClient, FlapjackHttpRequest, FlapjackHttpResponse, FlapjackProxy, ProxyError,
        SensitiveFlapjackHttpRequest,
    };

    use super::*;

    struct CapturingHttpClient {
        request: std::sync::Mutex<Option<FlapjackHttpRequest>>,
        sensitive_request: std::sync::Mutex<Option<(reqwest::Method, String, String)>>,
        responses:
            std::sync::Mutex<std::collections::VecDeque<Result<FlapjackHttpResponse, ProxyError>>>,
    }

    #[async_trait::async_trait]
    impl FlapjackHttpClient for CapturingHttpClient {
        async fn send(
            &self,
            request: FlapjackHttpRequest,
        ) -> Result<FlapjackHttpResponse, ProxyError> {
            *self.request.lock().unwrap() = Some(request);
            self.responses
                .lock()
                .unwrap()
                .pop_front()
                .expect("test response must be configured")
        }

        async fn send_sensitive(
            &self,
            request: SensitiveFlapjackHttpRequest<'_>,
        ) -> Result<FlapjackHttpResponse, ProxyError> {
            assert_eq!(
                request.json_body,
                r#"{"appId":"app-id","apiKey":"source-key","sourceIndex":"products","targetIndex":"products_next","overwrite":true}"#
            );
            *self.sensitive_request.lock().unwrap() = Some((
                request.method,
                request.url.to_string(),
                request.api_key.to_string(),
            ));
            self.responses
                .lock()
                .unwrap()
                .pop_front()
                .expect("test response must be configured")
        }
    }

    async fn service_with_results(
        responses: Vec<Result<FlapjackHttpResponse, ProxyError>>,
        secret_failure: bool,
    ) -> (Arc<CapturingHttpClient>, AlgoliaImportService) {
        let http = Arc::new(CapturingHttpClient {
            responses: std::sync::Mutex::new(responses.into()),
            request: std::sync::Mutex::new(None),
            sensitive_request: std::sync::Mutex::new(None),
        });
        let secrets = Arc::new(MockNodeSecretManager::new());
        secrets
            .create_node_api_key("node-a1", "us-east-1")
            .await
            .unwrap();
        secrets.set_should_fail(secret_failure);
        let proxy = Arc::new(FlapjackProxy::with_http_client(http.clone(), secrets));
        (http, AlgoliaImportService::new(proxy))
    }

    async fn service_with_responses(
        responses: Vec<(u16, serde_json::Value)>,
    ) -> (Arc<CapturingHttpClient>, AlgoliaImportService) {
        let responses = responses
            .into_iter()
            .map(|(status, body)| {
                Ok(FlapjackHttpResponse {
                    status,
                    body: body.to_string(),
                    request_api_key: String::new(),
                })
            })
            .collect();
        service_with_results(responses, false).await
    }

    async fn service_with_response(
        status: u16,
        body: serde_json::Value,
    ) -> (Arc<CapturingHttpClient>, AlgoliaImportService) {
        service_with_responses(vec![(status, body)]).await
    }

    fn status_body() -> serde_json::Value {
        json!({
            "jobId": "9f11d0a0-4443-44d4-b6c6-1ed71dbeb0fb",
            "phase": "exporting",
            "disposition": "running",
            "createdAt": "2026-07-22T00:00:00Z",
            "updatedAt": "2026-07-22T00:00:01Z",
            "exportProgress": {"completed": 10, "total": 25}
        })
    }

    #[tokio::test]
    async fn submit_sends_exact_authenticated_request_and_decodes_status() {
        let (http, service) = service_with_response(202, status_body()).await;
        let request = AlgoliaImportSubmitRequest::new(
            "app-id".to_string(),
            Zeroizing::new("source-key".to_string()),
            "products".to_string(),
            Some("products_next".to_string()),
            true,
        );

        let response = service
            .submit(
                EngineTarget::new("https://vm-a1.flapjack.foo", "node-a1", "us-east-1"),
                request,
            )
            .await
            .expect("submit should decode typed status");

        assert_eq!(
            response.job_id,
            uuid::Uuid::parse_str("9f11d0a0-4443-44d4-b6c6-1ed71dbeb0fb").unwrap()
        );
        assert_eq!(response.phase, AsyncMigrationPhase::Exporting);
        assert_eq!(response.disposition, AsyncMigrationDisposition::Running);
        assert_eq!(
            response.export_progress,
            Some(AsyncMigrationExportProgress {
                completed: 10,
                total: 25,
            })
        );

        let request = http.sensitive_request.lock().unwrap().clone().unwrap();
        assert_eq!(request.0, reqwest::Method::POST);
        assert_eq!(request.1, "https://vm-a1.flapjack.foo/1/migrations/algolia");
        assert!(!request.2.is_empty());
    }

    /// Only an exact engine `202` acknowledges an async submit. A stray 2xx
    /// (200/201/204) — even one carrying a well-formed UUID job id — must surface
    /// as an engine error so it can never narrow ambiguous intent to committed.
    #[tokio::test]
    async fn submit_rejects_non_202_success_status() {
        for status in [200u16, 201, 204] {
            let (_http, service) = service_with_response(status, status_body()).await;
            let request = AlgoliaImportSubmitRequest::new(
                "app-id".to_string(),
                Zeroizing::new("source-key".to_string()),
                "products".to_string(),
                Some("products_next".to_string()),
                true,
            );

            let err = service
                .submit(
                    EngineTarget::new("https://vm-a1.flapjack.foo", "node-a1", "us-east-1"),
                    request,
                )
                .await
                .unwrap_err();

            // A stray 200 is normalized to a malformed-response error; other
            // non-202 statuses surface as typed engine errors. Neither can yield
            // a decoded status a caller could treat as a committed acceptance.
            match status {
                200 => assert!(
                    matches!(err, AlgoliaImportEngineError::MalformedResponse(_)),
                    "status 200 must not decode as a submit acceptance, got {err:?}"
                ),
                other => assert_eq!(
                    err,
                    AlgoliaImportEngineError::Engine {
                        status: other,
                        code: None,
                    },
                    "status {other} must be rejected as a non-202 submit"
                ),
            }
        }
    }

    #[tokio::test]
    async fn status_and_cancel_send_no_algolia_credentials() {
        let (http, service) =
            service_with_responses(vec![(200, status_body()), (200, status_body())]).await;
        service
            .status(
                EngineTarget::new("https://vm-a1.flapjack.foo/", "node-a1", "us-east-1"),
                "engine job/1",
            )
            .await
            .expect("status should decode");
        let status_request = http.request.lock().unwrap().clone().unwrap();
        assert_eq!(status_request.method, reqwest::Method::GET);
        assert_eq!(
            status_request.url,
            "https://vm-a1.flapjack.foo/1/migrations/algolia/engine%20job%2F1"
        );
        assert_eq!(status_request.json_body, None);

        service
            .cancel(
                EngineTarget::new("https://vm-a1.flapjack.foo", "node-a1", "us-east-1"),
                "engine-job-1",
            )
            .await
            .expect("cancel should decode");
        let cancel_request = http.request.lock().unwrap().clone().unwrap();
        assert_eq!(cancel_request.method, reqwest::Method::POST);
        assert_eq!(
            cancel_request.url,
            "https://vm-a1.flapjack.foo/1/migrations/algolia/engine-job-1/cancel"
        );
        assert_eq!(cancel_request.json_body, None);
    }

    #[tokio::test]
    async fn non_success_and_malformed_responses_are_typed_errors() {
        let (_, service) = service_with_response(
            503,
            json!({"code": "migration_capacity_exhausted", "message": "full"}),
        )
        .await;
        let err = service
            .status(
                EngineTarget::new("https://vm-a1.flapjack.foo", "node-a1", "us-east-1"),
                "job-1",
            )
            .await
            .unwrap_err();
        assert_eq!(
            err,
            AlgoliaImportEngineError::Engine {
                status: 503,
                code: Some("migration_capacity_exhausted".to_string()),
            }
        );

        let (_, service) = service_with_response(200, json!({"phase": "unknown"})).await;
        let err = service
            .status(
                EngineTarget::new("https://vm-a1.flapjack.foo", "node-a1", "us-east-1"),
                "job-1",
            )
            .await
            .unwrap_err();
        assert!(matches!(
            err,
            AlgoliaImportEngineError::MalformedResponse(_)
        ));
    }

    async fn assert_submit_payload_wiped(
        response: Result<FlapjackHttpResponse, ProxyError>,
        secret_failure: bool,
    ) {
        use std::sync::atomic::{AtomicU8, Ordering};

        let (_, service) = service_with_results(vec![response], secret_failure).await;
        let probe = Arc::new(AtomicU8::new(0));
        let request = AlgoliaImportSubmitRequest::new(
            "app-id".to_string(),
            Zeroizing::new("source-key".to_string()),
            "products".to_string(),
            Some("products_next".to_string()),
            true,
        )
        .with_wipe_probe(probe.clone());
        let _ = service
            .submit(
                EngineTarget::new("https://vm-a1.flapjack.foo", "node-a1", "us-east-1"),
                request,
            )
            .await;
        assert_eq!(probe.load(Ordering::SeqCst), 1);
    }

    fn response(status: u16, body: serde_json::Value) -> FlapjackHttpResponse {
        FlapjackHttpResponse {
            status,
            body: body.to_string(),
            request_api_key: String::new(),
        }
    }

    #[tokio::test]
    async fn submit_payload_is_zeroized_on_every_service_exit() {
        assert_submit_payload_wiped(Ok(response(202, status_body())), false).await;
        assert_submit_payload_wiped(Ok(response(503, json!({"code": "full"}))), false).await;
        assert_submit_payload_wiped(Ok(response(202, json!({"phase": "unknown"}))), false).await;
        assert_submit_payload_wiped(Err(ProxyError::Unreachable("offline".into())), false).await;
        assert_submit_payload_wiped(Err(ProxyError::Timeout), false).await;
        assert_submit_payload_wiped(Err(ProxyError::Timeout), true).await;
    }

    #[test]
    fn enum_decoding_is_exhaustive_against_contract_fixture() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../tests/fixtures/algolia_migration_engine_contract.json"
        ))
        .unwrap();
        let phases = fixture["enums"]["phase"].as_array().unwrap();
        assert_eq!(phases.len(), AsyncMigrationPhase::ALL.len());
        for phase in phases {
            assert!(serde_json::from_value::<AsyncMigrationPhase>(phase.clone()).is_ok());
        }

        let dispositions = fixture["enums"]["disposition"].as_array().unwrap();
        assert_eq!(dispositions.len(), AsyncMigrationDisposition::ALL.len());
        for disposition in dispositions {
            assert!(
                serde_json::from_value::<AsyncMigrationDisposition>(disposition.clone()).is_ok()
            );
        }
    }

    #[test]
    fn terminal_handoff_accepts_only_canonical_terminal_pairs() {
        use crate::models::algolia_import_job::{
            AlgoliaImportErrorCode, AlgoliaImportJobStatus, AlgoliaImportPublicationDisposition,
            AlgoliaImportSummary,
        };
        use AlgoliaImportJobStatus::{
            Cancelled, Completed, CompletedWithWarnings, Failed, Interrupted,
        };
        use AlgoliaImportPublicationDisposition::{NotStarted, Promoted, Unchanged, Unknown};

        let legal_pairs = [
            (Completed, Promoted),
            (CompletedWithWarnings, Promoted),
            (Cancelled, Unchanged),
            (Failed, Unchanged),
            (Failed, NotStarted),
            (Interrupted, Unchanged),
            (Interrupted, NotStarted),
        ];
        for status in [
            Completed,
            CompletedWithWarnings,
            Cancelled,
            Failed,
            Interrupted,
        ] {
            for disposition in [NotStarted, Unchanged, Promoted, Unknown] {
                let summary = AlgoliaImportSummary {
                    documents_expected: 25,
                    documents_imported: 20,
                    ..AlgoliaImportSummary::default()
                };
                let result = AlgoliaImportTerminalHandoff::new(
                    status,
                    disposition,
                    summary.clone(),
                    Some(AlgoliaImportErrorCode::BackendUnavailable),
                    Some("sanitized terminal detail".to_string()),
                );
                assert_eq!(
                    result.is_ok(),
                    legal_pairs.contains(&(status, disposition)),
                    "terminal handoff pair {status:?}+{disposition:?}"
                );
                if let Ok(handoff) = result {
                    assert_eq!(handoff.status, status);
                    assert_eq!(handoff.publication_disposition, disposition);
                    assert_eq!(handoff.summary, summary);
                    assert_eq!(
                        handoff.error_code,
                        Some(AlgoliaImportErrorCode::BackendUnavailable)
                    );
                    assert_eq!(
                        handoff.error_message.as_deref(),
                        Some("sanitized terminal detail")
                    );
                }
            }
        }
    }

    #[test]
    fn pinned_submit_request_has_no_cloud_reservation_bound_field() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../tests/fixtures/algolia_migration_engine_contract.json"
        ))
        .unwrap();
        assert_eq!(
            fixture["pinned_engine_sha"],
            "a025a5eb43025b0680cfc78e5e07ec6c052695a4"
        );
        let required = fixture["request"]["required_fields"]
            .as_array()
            .expect("request required fields");
        let optional = fixture["request"]["optional_fields"]
            .as_array()
            .expect("request optional fields");
        let mut fields: Vec<&str> = required
            .iter()
            .chain(optional.iter())
            .map(|field| field.as_str().expect("request field name"))
            .collect();
        fields.sort_unstable();
        assert_eq!(
            fields,
            vec!["apiKey", "appId", "overwrite", "sourceIndex", "targetIndex"]
        );
        for absent in [
            "cloudJobId",
            "reservationBytes",
            "reservedBytes",
            "maxSourceBytes",
            "maxStagedBytes",
            "stagedBytesBound",
        ] {
            assert!(
                !fields.contains(&absent),
                "pinned submit request unexpectedly contains reservation-bound field {absent}"
            );
        }
    }

    #[test]
    fn credential_bearing_request_does_not_reveal_secret_in_debug() {
        let request = AlgoliaImportSubmitRequest::new(
            "app-id".to_string(),
            Zeroizing::new("super-secret-source-key".to_string()),
            "products".to_string(),
            None,
            false,
        );
        let debug = format!("{request:?}");
        assert!(!debug.contains("super-secret-source-key"));
        assert!(!debug.contains("app-id"));
    }
}
