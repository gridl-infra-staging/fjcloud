// Inline regression tests for `canonical_sns_string` in the parent
// `webhooks` module. Lives in a sibling file (declared via `#[path = "..."]`
// in webhooks.rs) so webhooks.rs stays under the file-size guardrail while
// the tests retain access to private items via `use super::*;`.
//
// These tests pin the AWS-SNS-spec canonical signing-string format directly,
// independent of any test-side canonicalization helper. They exist because
// the previous test in tests/ses_bounce_complaint_handler_test.rs round-tripped
// through its own copy of canonical_sns_string — when production drifted from
// the AWS spec by missing the trailing `\n`, the test fixture drifted with it
// and every signature produced/verified by tests still matched, but real AWS
// signatures did not. The tests below assert byte-equality against an
// expected canonical string written by hand from the AWS spec, so they fail
// loudly the moment production diverges from AWS regardless of what the test
// fixtures do.
//
// Spec: https://docs.aws.amazon.com/sns/latest/dg/sns-verify-signature-of-message.html

use super::*;

/// Build a Notification-shaped SnsEnvelope with literals that make the
/// canonical string easy to read in test failure output.
fn notification_envelope(subject: Option<&str>) -> SnsEnvelope {
    SnsEnvelope {
        sns_type: "Notification".to_string(),
        message_id: "msg-id-001".to_string(),
        topic_arn: "arn:aws:sns:us-east-1:111111111111:test-topic".to_string(),
        message: "hello".to_string(),
        timestamp: "2026-04-30T00:00:00.000Z".to_string(),
        signature_version: "1".to_string(),
        signature: "sig-base64".to_string(),
        signing_cert_url: "https://sns.us-east-1.amazonaws.com/cert.pem".to_string(),
        subject: subject.map(str::to_string),
        token: None,
        subscribe_url: None,
    }
}

fn subscription_envelope(sns_type: &str) -> SnsEnvelope {
    SnsEnvelope {
        sns_type: sns_type.to_string(),
        message_id: "msg-id-002".to_string(),
        topic_arn: "arn:aws:sns:us-east-1:111111111111:test-topic".to_string(),
        message: "please subscribe".to_string(),
        timestamp: "2026-04-30T00:00:00.000Z".to_string(),
        signature_version: "1".to_string(),
        signature: "sig-base64".to_string(),
        signing_cert_url: "https://sns.us-east-1.amazonaws.com/cert.pem".to_string(),
        subject: None,
        token: Some("token-abc".to_string()),
        subscribe_url: Some(
            "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription".to_string(),
        ),
    }
}

/// Spec: every key and every value is terminated by `\n`, including the
/// last value. Notification field order is
/// Message, MessageId, [Subject?], Timestamp, TopicArn, Type.
#[test]
fn notification_canonical_matches_aws_spec_with_trailing_newlines() {
    let envelope = notification_envelope(None);
    let actual = canonical_sns_string(&envelope, SnsType::Notification).unwrap();
    let expected = concat!(
        "Message\n",
        "hello\n",
        "MessageId\n",
        "msg-id-001\n",
        "Timestamp\n",
        "2026-04-30T00:00:00.000Z\n",
        "TopicArn\n",
        "arn:aws:sns:us-east-1:111111111111:test-topic\n",
        "Type\n",
        "Notification\n",
    );
    assert_eq!(
        actual, expected,
        "Notification canonical string must terminate every key AND every value with `\\n`. \
         A previous version of canonical_sns_string used `join(\"\\n\")` which silently \
         dropped the trailing `\\n` on the final value; AWS-signed payloads then failed \
         signature verification while same-fixture round-trip tests still passed."
    );
}

/// Spec: when Subject is present and non-empty, it appears between
/// MessageId and Timestamp. Both pieces still get trailing newlines.
#[test]
fn notification_with_subject_canonical_matches_aws_spec() {
    let envelope = notification_envelope(Some("monthly invoice"));
    let actual = canonical_sns_string(&envelope, SnsType::Notification).unwrap();
    let expected = concat!(
        "Message\n",
        "hello\n",
        "MessageId\n",
        "msg-id-001\n",
        "Subject\n",
        "monthly invoice\n",
        "Timestamp\n",
        "2026-04-30T00:00:00.000Z\n",
        "TopicArn\n",
        "arn:aws:sns:us-east-1:111111111111:test-topic\n",
        "Type\n",
        "Notification\n",
    );
    assert_eq!(actual, expected);
}

/// Spec: SubscriptionConfirmation field order is
/// Message, MessageId, SubscribeURL, Timestamp, Token, TopicArn, Type.
/// This is the exact canonicalization AWS uses when it signs the
/// confirmation message that arrives at our `/webhooks/ses/sns` endpoint;
/// the bug we just fixed broke this end-to-end despite all 14 round-trip
/// tests in tests/ses_bounce_complaint_handler_test.rs passing.
#[test]
fn subscription_confirmation_canonical_matches_aws_spec() {
    let envelope = subscription_envelope("SubscriptionConfirmation");
    let actual = canonical_sns_string(&envelope, SnsType::SubscriptionConfirmation).unwrap();
    let expected = concat!(
        "Message\n",
        "please subscribe\n",
        "MessageId\n",
        "msg-id-002\n",
        "SubscribeURL\n",
        "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription\n",
        "Timestamp\n",
        "2026-04-30T00:00:00.000Z\n",
        "Token\n",
        "token-abc\n",
        "TopicArn\n",
        "arn:aws:sns:us-east-1:111111111111:test-topic\n",
        "Type\n",
        "SubscriptionConfirmation\n",
    );
    assert_eq!(actual, expected);
}

/// UnsubscribeConfirmation uses the same field order as
/// SubscriptionConfirmation (per AWS spec) — only the Type value differs.
#[test]
fn unsubscribe_confirmation_canonical_matches_aws_spec() {
    let envelope = subscription_envelope("UnsubscribeConfirmation");
    let actual = canonical_sns_string(&envelope, SnsType::UnsubscribeConfirmation).unwrap();
    let expected = concat!(
        "Message\n",
        "please subscribe\n",
        "MessageId\n",
        "msg-id-002\n",
        "SubscribeURL\n",
        "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription\n",
        "Timestamp\n",
        "2026-04-30T00:00:00.000Z\n",
        "Token\n",
        "token-abc\n",
        "TopicArn\n",
        "arn:aws:sns:us-east-1:111111111111:test-topic\n",
        "Type\n",
        "UnsubscribeConfirmation\n",
    );
    assert_eq!(actual, expected);
}

/// Direct invariant assertion: the AWS spec terminates every value with
/// `\n`, so the canonical string must end with `\n`. Pinning this on its
/// own (rather than relying solely on the byte-equal tests) makes the
/// off-by-one regression class impossible to reintroduce silently.
#[test]
fn canonical_string_must_end_with_newline_for_every_variant() {
    let cases = [
        (
            notification_envelope(None),
            SnsType::Notification,
            "Notification w/o Subject",
        ),
        (
            notification_envelope(Some("x")),
            SnsType::Notification,
            "Notification with Subject",
        ),
        (
            subscription_envelope("SubscriptionConfirmation"),
            SnsType::SubscriptionConfirmation,
            "SubscriptionConfirmation",
        ),
        (
            subscription_envelope("UnsubscribeConfirmation"),
            SnsType::UnsubscribeConfirmation,
            "UnsubscribeConfirmation",
        ),
    ];
    for (envelope, sns_type, label) in cases {
        let canonical = canonical_sns_string(&envelope, sns_type).unwrap();
        assert!(
            canonical.ends_with('\n'),
            "{label} canonical string must end with `\\n` per AWS spec; got: {canonical:?}"
        );
    }
}
