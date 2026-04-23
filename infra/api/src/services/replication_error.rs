//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/replication_error.rs.
// ── Canonical contract constants ───────────────────────────────────────────
//
// These MUST be byte-identical to the matching constants in
// flapjack-replication/src/error.rs — they form the cross-repo contract.

/// The HTTP header carrying the node API key on outbound flapjack requests.
pub const INTERNAL_AUTH_HEADER: &str = "x-algolia-api-key";

/// The HTTP header identifying the calling application on outbound flapjack requests.
pub const INTERNAL_APP_ID_HEADER: &str = "x-algolia-application-id";

/// The static application-id value sent on all outbound flapjack requests.
pub const REPLICATION_APP_ID: &str = "flapjack-replication";

/// Reason codes — identical strings in both flapjack_dev and fjcloud.
pub const AUTH_FAILED_CODE: &str = "auth_failed";
pub const PEER_REJECTED_CODE: &str = "peer_rejected";
pub const TRANSPORT_ERROR_CODE: &str = "transport_error";
pub const TIMEOUT_CODE: &str = "timeout";

// ── Error taxonomy ─────────────────────────────────────────────────────────

/// Structured error type for replication orchestration failures.
///
/// Mirrors the taxonomy in `flapjack-replication::error::PeerError` so that
/// both sides classify errors identically. Used by `ReplicationOrchestrator`
/// to make policy decisions (e.g., circuit breaker behavior, retry strategy).
#[derive(Debug, thiserror::Error)]
pub enum ReplicationError {
    /// 401 Unauthorized — the node rejected our internal auth key.
    /// Deterministic failure: retrying with the same key will never succeed.
    #[error("{AUTH_FAILED_CODE}: {0}")]
    AuthFailed(String),

    /// 4xx (non-401) — the node understood the request but rejected it.
    #[error("{PEER_REJECTED_CODE}: HTTP {status}: {body}")]
    PeerRejected { status: u16, body: String },

    /// Network-level or 5xx server error — transient.
    #[error("{TRANSPORT_ERROR_CODE}: {0}")]
    TransportError(String),

    /// Request timed out.
    #[error("{TIMEOUT_CODE}")]
    Timeout,
}

impl ReplicationError {
    /// The canonical reason code for this error, suitable for logs.
    /// Never contains secrets.
    pub fn reason_code(&self) -> &'static str {
        match self {
            ReplicationError::AuthFailed(_) => AUTH_FAILED_CODE,
            ReplicationError::PeerRejected { .. } => PEER_REJECTED_CODE,
            ReplicationError::TransportError(_) => TRANSPORT_ERROR_CODE,
            ReplicationError::Timeout => TIMEOUT_CODE,
        }
    }

    /// Whether this error is deterministic (retrying won't help without
    /// external intervention like rotating a key).
    pub fn is_deterministic(&self) -> bool {
        matches!(self, ReplicationError::AuthFailed(_))
    }
}

/// Classify an HTTP response from a flapjack node into a `ReplicationError`.
///
/// `status` is the HTTP status code (u16, matching `MigrationHttpClient`
/// response format). `body` is the response body text.
pub fn classify_response(status: u16, body: &str) -> ReplicationError {
    if status == 401 {
        ReplicationError::AuthFailed(body.to_owned())
    } else if (400..500).contains(&status) {
        ReplicationError::PeerRejected {
            status,
            body: body.to_owned(),
        }
    } else {
        // 5xx and anything else unexpected
        ReplicationError::TransportError(format!("HTTP {status}: {body}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_401_as_auth_failed() {
        let err = classify_response(401, "bad key");
        assert!(matches!(err, ReplicationError::AuthFailed(_)));
        assert_eq!(err.reason_code(), AUTH_FAILED_CODE);
        assert!(err.is_deterministic());
    }

    #[test]
    fn classify_403_as_peer_rejected() {
        let err = classify_response(403, "forbidden");
        assert!(matches!(
            err,
            ReplicationError::PeerRejected { status: 403, .. }
        ));
        assert_eq!(err.reason_code(), PEER_REJECTED_CODE);
        assert!(!err.is_deterministic());
    }

    #[test]
    fn classify_404_as_peer_rejected() {
        let err = classify_response(404, "not found");
        assert!(matches!(
            err,
            ReplicationError::PeerRejected { status: 404, .. }
        ));
        assert_eq!(err.reason_code(), PEER_REJECTED_CODE);
    }

    #[test]
    fn classify_500_as_transport_error() {
        let err = classify_response(500, "internal server error");
        assert!(matches!(err, ReplicationError::TransportError(_)));
        assert_eq!(err.reason_code(), TRANSPORT_ERROR_CODE);
        assert!(!err.is_deterministic());
    }

    #[test]
    fn classify_502_as_transport_error() {
        let err = classify_response(502, "bad gateway");
        assert!(matches!(err, ReplicationError::TransportError(_)));
    }

    #[test]
    fn classify_503_as_transport_error() {
        let err = classify_response(503, "unavailable");
        assert!(matches!(err, ReplicationError::TransportError(_)));
    }

    /// Verifies that each `ReplicationError` variant's `reason_code()` method returns
    /// the corresponding canonical constant string (e.g., `AUTH_FAILURE`, `LAG_EXCEEDED`).
    #[test]
    fn reason_codes_match_canonical_constants() {
        assert_eq!(
            ReplicationError::AuthFailed("x".into()).reason_code(),
            "auth_failed"
        );
        assert_eq!(
            ReplicationError::PeerRejected {
                status: 404,
                body: "x".into()
            }
            .reason_code(),
            "peer_rejected"
        );
        assert_eq!(
            ReplicationError::TransportError("x".into()).reason_code(),
            "transport_error"
        );
        assert_eq!(ReplicationError::Timeout.reason_code(), "timeout");
    }

    /// Verifies that the `Display` implementation for each `ReplicationError` variant
    /// starts with the variant's reason code, ensuring structured error messages
    /// suitable for logging and alerting.
    #[test]
    fn display_includes_reason_code() {
        let auth = ReplicationError::AuthFailed("denied".into());
        assert!(auth.to_string().starts_with(AUTH_FAILED_CODE));

        let rejected = ReplicationError::PeerRejected {
            status: 404,
            body: "gone".into(),
        };
        assert!(rejected.to_string().starts_with(PEER_REJECTED_CODE));

        let transport = ReplicationError::TransportError("boom".into());
        assert!(transport.to_string().starts_with(TRANSPORT_ERROR_CODE));

        let timeout = ReplicationError::Timeout;
        assert!(timeout.to_string().starts_with(TIMEOUT_CODE));
    }

    #[test]
    fn constants_match_flapjack_dev_contract() {
        // These string values MUST be identical in flapjack-replication/src/error.rs
        assert_eq!(INTERNAL_AUTH_HEADER, "x-algolia-api-key");
        assert_eq!(INTERNAL_APP_ID_HEADER, "x-algolia-application-id");
        assert_eq!(REPLICATION_APP_ID, "flapjack-replication");
        assert_eq!(AUTH_FAILED_CODE, "auth_failed");
        assert_eq!(PEER_REJECTED_CODE, "peer_rejected");
        assert_eq!(TRANSPORT_ERROR_CODE, "transport_error");
        assert_eq!(TIMEOUT_CODE, "timeout");
    }
}
