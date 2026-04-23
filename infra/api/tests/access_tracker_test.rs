mod common;

use std::time::Duration;

use api::services::access_tracker::AccessTracker;
use chrono::Utc;
use common::mock_tenant_repo;
use uuid::Uuid;

#[tokio::test]
async fn record_access_updates_in_memory() {
    let repo = mock_tenant_repo();
    let tracker = AccessTracker::new(repo);
    let customer_id = Uuid::new_v4();

    tracker.record_access(customer_id, "products");

    assert_eq!(tracker.pending_count(), 1);
    assert!(tracker.has_pending(customer_id, "products"));
}

#[tokio::test]
async fn flush_writes_to_repo() {
    let repo = mock_tenant_repo();
    let tracker = AccessTracker::new(repo.clone());
    let customer_id = Uuid::new_v4();

    tracker.record_access(customer_id, "products");
    tracker.flush().await.expect("flush should succeed");

    assert_eq!(repo.update_last_accessed_call_count(), 1);
    assert_eq!(repo.last_accessed_updates().len(), 1);
    assert_eq!(tracker.pending_count(), 0);
}

#[tokio::test]
async fn flush_no_ops_when_empty() {
    let repo = mock_tenant_repo();
    let tracker = AccessTracker::new(repo.clone());

    tracker.flush().await.expect("empty flush should succeed");

    assert_eq!(repo.update_last_accessed_call_count(), 0);
}

#[tokio::test]
async fn multiple_accesses_same_index_coalesce() {
    let repo = mock_tenant_repo();
    let tracker = AccessTracker::new(repo.clone());
    let customer_id = Uuid::new_v4();

    tracker.record_access(customer_id, "products");
    tokio::time::sleep(Duration::from_millis(5)).await;
    let cutoff = Utc::now();
    tokio::time::sleep(Duration::from_millis(5)).await;
    tracker.record_access(customer_id, "products");
    tracker.flush().await.expect("flush should succeed");

    let updates = repo.last_accessed_updates();
    assert_eq!(updates.len(), 1);
    assert_eq!(updates[0].0, customer_id);
    assert_eq!(updates[0].1, "products");
    assert!(
        updates[0].2 >= cutoff,
        "coalesced timestamp should reflect latest access"
    );
}
