use api::dns::mock::MockDnsManager;
use api::dns::{DnsError, DnsManager, UnconfiguredDnsManager};

#[tokio::test]
async fn mock_create_and_delete_records() {
    let dns = MockDnsManager::new();

    // Create a record
    dns.create_record("vm-abcd1234.flapjack.foo", "203.0.113.1")
        .await
        .unwrap();

    let records = dns.get_records();
    assert_eq!(records.len(), 1);
    assert_eq!(records["vm-abcd1234.flapjack.foo"], "203.0.113.1");

    // Delete the record
    dns.delete_record("vm-abcd1234.flapjack.foo").await.unwrap();

    let records = dns.get_records();
    assert!(records.is_empty());
}

#[tokio::test]
async fn mock_create_is_idempotent_upsert() {
    let dns = MockDnsManager::new();

    // Create initial record
    dns.create_record("vm-abcd1234.flapjack.foo", "203.0.113.1")
        .await
        .unwrap();

    // Upsert with new IP — should overwrite, not error
    dns.create_record("vm-abcd1234.flapjack.foo", "203.0.113.99")
        .await
        .unwrap();

    let records = dns.get_records();
    assert_eq!(records.len(), 1);
    assert_eq!(records["vm-abcd1234.flapjack.foo"], "203.0.113.99");
}

#[tokio::test]
async fn mock_create_twice_same_params_succeeds() {
    let dns = MockDnsManager::new();

    let first = dns
        .create_record("vm-same.flapjack.foo", "203.0.113.7")
        .await;
    let second = dns
        .create_record("vm-same.flapjack.foo", "203.0.113.7")
        .await;

    assert!(first.is_ok());
    assert!(second.is_ok());

    let records = dns.get_records();
    assert_eq!(records.len(), 1);
    assert_eq!(records["vm-same.flapjack.foo"], "203.0.113.7");
}

#[tokio::test]
async fn mock_delete_nonexistent_is_idempotent() {
    let dns = MockDnsManager::new();

    // Deleting a hostname that doesn't exist should succeed (idempotent)
    let result = dns.delete_record("vm-doesnotexist.flapjack.foo").await;
    assert!(result.is_ok());
}

#[tokio::test]
async fn mock_failure_injection_works() {
    let dns = MockDnsManager::new();

    // Normal operations succeed
    dns.create_record("vm-abcd1234.flapjack.foo", "203.0.113.1")
        .await
        .unwrap();

    // Enable failure injection
    dns.set_should_fail(true);

    let create_err = dns.create_record("vm-fail.flapjack.foo", "1.2.3.4").await;
    assert!(matches!(create_err, Err(DnsError::Api(_))));

    let delete_err = dns.delete_record("vm-abcd1234.flapjack.foo").await;
    assert!(matches!(delete_err, Err(DnsError::Api(_))));

    // Previous record still exists (failure prevented delete)
    dns.set_should_fail(false);
    let records = dns.get_records();
    assert_eq!(records.len(), 1);
    assert_eq!(records["vm-abcd1234.flapjack.foo"], "203.0.113.1");
}

#[tokio::test]
async fn unconfigured_dns_manager_returns_not_configured() {
    let dns = UnconfiguredDnsManager;

    let create_err = dns.create_record("vm-test.flapjack.foo", "1.2.3.4").await;
    assert!(matches!(create_err, Err(DnsError::NotConfigured)));

    let delete_err = dns.delete_record("vm-test.flapjack.foo").await;
    assert!(matches!(delete_err, Err(DnsError::NotConfigured)));
}
