// Inline regression tests for the SES SNS payload deserialization in the
// parent `webhooks` module. Lives in a sibling file (declared via
// `#[path = "..."]` in webhooks.rs) so webhooks.rs stays under the file-size
// guardrail while the tests retain access to private items via
// `use super::*;`.
//
// Why this file exists:
//   The handler's `SesNotification` struct used `#[serde(rename = "notificationType")]`,
//   but our SES terraform stack uses `aws_sesv2_configuration_set_event_destination`
//   (see `ops/terraform/dns/main.tf:152`) which publishes to SNS using the
//   `eventType` discriminator instead. AWS sent `eventType`, our parser
//   demanded `notificationType`, every real bounce/complaint notification
//   was rejected as 400 BadRequest with `missing field 'notificationType'`,
//   and the entire SES bounce/complaint suppression path was silently broken
//   on staging. The integration tests in `tests/ses_bounce_complaint_handler_test.rs`
//   round-tripped through fixtures that ALSO used `notificationType` — so the
//   test fixture matched the bug, and 14 unit tests passed against a parser
//   that real AWS payloads could not pass through. This is the exact same
//   "test fixture pinned the buggy assumption" pattern that hid the SNS
//   canonical signing-string bug; see the sibling
//   `webhooks_canonical_sns_string_tests.rs` for that one.
//
//   The tests below assert the SesNotification struct deserializes from the
//   AWS-spec eventType payload. They run without DATABASE_URL so they cannot
//   silently skip the way the integration tests do.
//
// Spec: https://docs.aws.amazon.com/ses/latest/dg/event-publishing-retrieving-sns-contents.html

use super::*;

/// AWS-spec bounce payload published by SESv2 Configuration-Set Event
/// Destination → SNS. Field shape pinned by the AWS docs above; only the
/// fields our handler actually reads are populated, but the discriminator
/// must be `eventType` (NOT `notificationType`) to match real AWS traffic.
#[test]
fn ses_notification_deserializes_aws_spec_bounce_event() {
    let payload = r#"{
        "eventType": "Bounce",
        "mail": {
            "messageId": "msg-aws-event-001"
        },
        "bounce": {
            "bounceType": "Permanent",
            "bounceSubType": "General",
            "bouncedRecipients": [
                {"emailAddress": "hard-bounce@example.com"}
            ]
        }
    }"#;
    let parsed: SesNotification = serde_json::from_str(payload)
        .expect("AWS SESv2 event-destination payload (eventType=Bounce) must deserialize");
    assert_eq!(parsed.notification_type, "Bounce");
    assert_eq!(parsed.mail.message_id, "msg-aws-event-001");
    let bounce = parsed.bounce.expect("bounce payload must round-trip");
    assert_eq!(bounce.bounce_type, "Permanent");
    assert_eq!(bounce.bounce_sub_type, "General");
    assert_eq!(bounce.bounced_recipients.len(), 1);
    assert_eq!(
        bounce.bounced_recipients[0].email_address,
        "hard-bounce@example.com"
    );
}

/// Same shape for complaints. Pinned separately because complaint and bounce
/// take different inner payload variants.
#[test]
fn ses_notification_deserializes_aws_spec_complaint_event() {
    let payload = r#"{
        "eventType": "Complaint",
        "mail": {
            "messageId": "msg-aws-event-002"
        },
        "complaint": {
            "complainedRecipients": [
                {"emailAddress": "complaint@example.com"}
            ]
        }
    }"#;
    let parsed: SesNotification = serde_json::from_str(payload)
        .expect("AWS SESv2 event-destination payload (eventType=Complaint) must deserialize");
    assert_eq!(parsed.notification_type, "Complaint");
    let complaint = parsed.complaint.expect("complaint payload must round-trip");
    assert_eq!(complaint.complained_recipients.len(), 1);
    assert_eq!(
        complaint.complained_recipients[0].email_address,
        "complaint@example.com"
    );
}

/// Negative pin: a payload with the OLD `notificationType` discriminator
/// (the format SES Email Receiving uses, which we do NOT subscribe to) must
/// fail to deserialize. Without this assertion, a future "let's accept both"
/// regression could re-introduce the parser drift that hid the original bug.
#[test]
fn ses_notification_rejects_legacy_notification_type_payload() {
    let payload = r#"{
        "notificationType": "Bounce",
        "mail": {"messageId": "msg-legacy-001"},
        "bounce": {
            "bounceType": "Permanent",
            "bounceSubType": "General",
            "bouncedRecipients": [{"emailAddress": "x@example.com"}]
        }
    }"#;
    let result: Result<SesNotification, _> = serde_json::from_str(payload);
    assert!(
        result.is_err(),
        "legacy `notificationType` payload must be rejected; we are wired to SESv2 event destination only"
    );
}
