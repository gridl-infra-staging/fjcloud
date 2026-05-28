use api::services::replication_error::{
    classify_response, ReplicationError, AUTH_FAILED_CODE, INTERNAL_APP_ID_HEADER,
    INTERNAL_AUTH_HEADER, PEER_REJECTED_CODE, REPLICATION_APP_ID, TIMEOUT_CODE,
    TRANSPORT_ERROR_CODE,
};

#[test]
fn contract_constants_match_flapjack_dev() {
    assert_eq!(INTERNAL_AUTH_HEADER, "x-algolia-api-key");
    assert_eq!(INTERNAL_APP_ID_HEADER, "x-algolia-application-id");
    assert_eq!(REPLICATION_APP_ID, "flapjack-replication");
    assert_eq!(AUTH_FAILED_CODE, "auth_failed");
    assert_eq!(PEER_REJECTED_CODE, "peer_rejected");
    assert_eq!(TRANSPORT_ERROR_CODE, "transport_error");
    assert_eq!(TIMEOUT_CODE, "timeout");
}

#[test]
fn contract_401_classified_as_deterministic_auth_failure() {
    let err = classify_response(401, "bad key");
    assert!(matches!(err, ReplicationError::AuthFailed(_)));
    assert!(err.is_deterministic());
}

#[test]
fn contract_403_classified_as_peer_rejected() {
    let err = classify_response(403, "forbidden");
    assert!(matches!(
        err,
        ReplicationError::PeerRejected { status: 403, .. }
    ));
    assert!(!err.is_deterministic());
}

#[test]
fn contract_every_variant_has_nonempty_reason_code() {
    let variants = [
        ReplicationError::AuthFailed("denied".to_string()),
        ReplicationError::PeerRejected {
            status: 403,
            body: "forbidden".to_string(),
        },
        ReplicationError::TransportError("io error".to_string()),
        ReplicationError::Timeout,
    ];

    for variant in variants {
        assert!(!variant.reason_code().is_empty());
    }
}
