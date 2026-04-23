mod common;

use api::repos::index_replica_repo::IndexReplicaRepo;
use api::services::migration::{MigrationHttpClientError, MigrationHttpResponse};
use api::services::replication::ReplicationConfig;
use common::oplog_metric;

// ---------------------------------------------------------------------------
// Setup helpers
// ---------------------------------------------------------------------------

/// Core setup: creates VMs, replica, and orchestrator. The `seed_replica_key`
/// flag controls whether the replica VM's node API key is seeded (set to
/// false for secret-lookup-failure tests). Uses the provided config.
async fn setup_replication_inner(
    config: ReplicationConfig,
    seed_replica_key: bool,
) -> common::ReplicationHarness {
    common::setup_replication_harness(config, seed_replica_key).await
}

async fn setup_replication() -> common::ReplicationHarness {
    setup_replication_inner(ReplicationConfig::default(), true).await
}

async fn setup_replication_with_config(config: ReplicationConfig) -> common::ReplicationHarness {
    setup_replication_inner(config, true).await
}

async fn setup_replication_without_replica_key() -> common::ReplicationHarness {
    setup_replication_inner(ReplicationConfig::default(), false).await
}

// ---------------------------------------------------------------------------
// Class 1: Flapjack crash mid-replication
// ---------------------------------------------------------------------------

/// When the replica VM is unreachable during initial provisioning (connection
/// refused = Flapjack crash), the replica should be marked failed rather than
/// left stuck in provisioning.
#[tokio::test]
async fn provisioning_crash_mid_http_marks_replica_failed() {
    let h = setup_replication().await;

    // Replica is in "provisioning" state (default from create).
    // Enqueue a connection-refused error simulating a crashed Flapjack node.
    h.http_client
        .enqueue(Err(MigrationHttpClientError::Unreachable(
            "connection refused".to_string(),
        )));

    h.orchestrator.run_cycle().await;

    let updated = h.replica_repo.get(h.replica_id).await.unwrap().unwrap();
    assert_eq!(
        updated.status, "failed",
        "provisioning replica should be marked failed when node is unreachable"
    );

    // Only one HTTP call should have been attempted — no further retries within the same cycle.
    assert_eq!(h.http_client.recorded_requests().len(), 1);
}

/// When the source VM crashes (unreachable) during lag monitoring, the active
/// replica should be marked failed. fetch_replication_lag makes two HTTP calls
/// (source then replica) — this exercises the FIRST-call failure path.
#[tokio::test]
async fn lag_monitoring_source_crash_marks_replica_failed() {
    let h = setup_replication().await;

    // Promote replica to "active" so run_cycle dispatches to lag monitoring.
    h.replica_repo
        .set_status(h.replica_id, "active")
        .await
        .unwrap();

    // Source metrics fetch fails (source node crashed).
    h.http_client
        .enqueue(Err(MigrationHttpClientError::Unreachable(
            "connection refused".to_string(),
        )));

    h.orchestrator.run_cycle().await;

    let updated = h.replica_repo.get(h.replica_id).await.unwrap().unwrap();
    assert_eq!(
        updated.status, "failed",
        "active replica should be marked failed when source node is unreachable"
    );
}

/// When the replica VM crashes during lag monitoring (source succeeds but
/// replica metrics fetch fails), the replica should be marked failed. This
/// exercises the SECOND-call failure path in fetch_replication_lag.
#[tokio::test]
async fn lag_monitoring_replica_crash_marks_failed() {
    let h = setup_replication().await;

    h.replica_repo
        .set_status(h.replica_id, "active")
        .await
        .unwrap();

    // Source metrics succeeds.
    h.http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 100),
    }));
    // Replica metrics fails (replica node crashed).
    h.http_client
        .enqueue(Err(MigrationHttpClientError::Unreachable(
            "connection refused".to_string(),
        )));

    h.orchestrator.run_cycle().await;

    let updated = h.replica_repo.get(h.replica_id).await.unwrap().unwrap();
    assert_eq!(
        updated.status, "failed",
        "active replica should be marked failed when replica node crashes during lag check"
    );
}

/// A timeout (slow crash / network partition) during provisioning should be
/// treated the same as unreachable — replica marked failed.
#[tokio::test]
async fn timeout_during_provisioning_marks_failed() {
    let h = setup_replication().await;

    // Replica is in "provisioning" (default). Enqueue a timeout.
    h.http_client
        .enqueue(Err(MigrationHttpClientError::Timeout));

    h.orchestrator.run_cycle().await;

    let updated = h.replica_repo.get(h.replica_id).await.unwrap().unwrap();
    assert_eq!(
        updated.status, "failed",
        "provisioning replica should be marked failed on timeout"
    );
}

// ---------------------------------------------------------------------------
// Class 2: Auth circuit-breaker (401 threshold and recovery)
// ---------------------------------------------------------------------------

/// Five consecutive HTTP 401s during provisioning should trigger the
/// auth circuit-breaker and mark the replica failed.  Cycles 1-4 leave
/// the replica in provisioning; cycle 5 crosses the threshold.
#[tokio::test]
async fn auth_circuit_breaker_marks_failed_after_five_consecutive_401s() {
    let h = setup_replication().await;

    for cycle in 1..=5u32 {
        h.http_client.enqueue(Ok(MigrationHttpResponse {
            status: 401,
            body: "unauthorized".to_string(),
        }));
        h.orchestrator.run_cycle().await;

        let replica = h.replica_repo.get(h.replica_id).await.unwrap().unwrap();
        if cycle < 5 {
            assert_eq!(
                replica.status, "provisioning",
                "replica should stay provisioning after {} auth failures (threshold is 5)",
                cycle
            );
        } else {
            assert_eq!(
                replica.status, "failed",
                "replica should be marked failed after 5 consecutive auth failures"
            );
        }
    }
}

/// Four consecutive 401s followed by a successful response should clear the
/// auth-failure counter.  The replica transitions to syncing (not failed).
#[tokio::test]
async fn auth_recovery_clears_counter_after_success() {
    let h = setup_replication().await;

    // 4 consecutive 401s — below threshold
    for _ in 0..4 {
        h.http_client.enqueue(Ok(MigrationHttpResponse {
            status: 401,
            body: "unauthorized".to_string(),
        }));
        h.orchestrator.run_cycle().await;
    }

    let replica = h.replica_repo.get(h.replica_id).await.unwrap().unwrap();
    assert_eq!(
        replica.status, "provisioning",
        "replica should remain provisioning after 4 auth failures"
    );

    // Success response clears the counter and transitions to syncing
    h.http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: "ok".to_string(),
    }));
    h.orchestrator.run_cycle().await;

    let replica = h.replica_repo.get(h.replica_id).await.unwrap().unwrap();
    assert_eq!(
        replica.status, "syncing",
        "successful response after 4 failures should clear counter and transition to syncing"
    );
}

// ---------------------------------------------------------------------------
// Class 3: Syncing timeout and legacy status
// ---------------------------------------------------------------------------

/// A syncing replica whose updated_at exceeds syncing_timeout_secs should
/// be marked failed with a timeout message on the next cycle.
#[tokio::test]
async fn syncing_replica_timeout_marks_failed() {
    let h = setup_replication_with_config(ReplicationConfig {
        syncing_timeout_secs: 1, // 1 second for fast testing
        ..ReplicationConfig::default()
    })
    .await;

    // Transition to syncing and back-date updated_at so it appears timed out
    h.replica_repo
        .set_status(h.replica_id, "syncing")
        .await
        .unwrap();
    h.replica_repo.set_updated_at(
        h.replica_id,
        chrono::Utc::now() - chrono::Duration::seconds(10),
    );

    h.orchestrator.run_cycle().await;

    let replica = h.replica_repo.get(h.replica_id).await.unwrap().unwrap();
    assert_eq!(
        replica.status, "failed",
        "syncing replica past timeout should be marked failed"
    );
}

/// A legacy "replicating" replica that has timed out should also be marked
/// failed — the timeout check applies to both syncing and replicating.
#[tokio::test]
async fn legacy_replicating_replica_timeout_marks_failed() {
    let h = setup_replication_with_config(ReplicationConfig {
        syncing_timeout_secs: 1,
        ..ReplicationConfig::default()
    })
    .await;

    h.replica_repo
        .set_status(h.replica_id, "replicating")
        .await
        .unwrap();
    h.replica_repo.set_updated_at(
        h.replica_id,
        chrono::Utc::now() - chrono::Duration::seconds(10),
    );

    h.orchestrator.run_cycle().await;

    let replica = h.replica_repo.get(h.replica_id).await.unwrap().unwrap();
    assert_eq!(
        replica.status, "failed",
        "legacy replicating replica past timeout should be marked failed"
    );
}

// ---------------------------------------------------------------------------
// Class 4: Lag regression and recovery
// ---------------------------------------------------------------------------

/// An active replica whose replication lag exceeds max_acceptable_lag_ops
/// should be marked failed.
#[tokio::test]
async fn active_replica_lag_regression_marks_failed() {
    let h = setup_replication().await;

    h.replica_repo
        .set_status(h.replica_id, "active")
        .await
        .unwrap();

    // Source is far ahead of replica: lag = 200_000 > default max 100_000
    h.http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 300_000),
    }));
    h.http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 100_000),
    }));

    h.orchestrator.run_cycle().await;

    let replica = h.replica_repo.get(h.replica_id).await.unwrap().unwrap();
    assert_eq!(
        replica.status, "failed",
        "active replica with lag exceeding max should be marked failed"
    );
}

/// A syncing replica whose lag drops to near_zero_lag_ops should be
/// promoted to active.
#[tokio::test]
async fn syncing_replica_lag_recovery_transitions_to_active() {
    let h = setup_replication().await;

    h.replica_repo
        .set_status(h.replica_id, "syncing")
        .await
        .unwrap();

    // Both source and replica at nearly the same position: lag = 50 ≤ default near_zero 100
    h.http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 1050),
    }));
    h.http_client.enqueue(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric("products", 1000),
    }));

    h.orchestrator.run_cycle().await;

    let replica = h.replica_repo.get(h.replica_id).await.unwrap().unwrap();
    assert_eq!(
        replica.status, "active",
        "syncing replica at near-zero lag should transition to active"
    );
}

// ---------------------------------------------------------------------------
// Class 5: Node secret lookup failure
// ---------------------------------------------------------------------------

/// When build_auth_headers fails because get_node_api_key returns an error,
/// the provisioning replica should be immediately marked failed with an
/// auth error context message.
#[tokio::test]
async fn secret_lookup_failure_marks_replica_failed() {
    let h = setup_replication_without_replica_key().await;

    // No HTTP response needed — build_auth_headers will fail before the
    // HTTP call because no key exists for the replica VM.

    h.orchestrator.run_cycle().await;

    let replica = h.replica_repo.get(h.replica_id).await.unwrap().unwrap();
    assert_eq!(
        replica.status, "failed",
        "replica should be marked failed when secret lookup fails"
    );
}
