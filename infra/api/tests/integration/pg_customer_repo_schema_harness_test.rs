use crate::common::support::pg_schema_harness;
use std::time::Duration;

#[test]
fn missing_database_url_is_a_hard_test_failure() {
    let missing = std::env::VarError::NotPresent;
    let result = std::panic::catch_unwind(|| pg_schema_harness::require_database_url(Err(missing)));

    assert!(
        result.is_err(),
        "PostgreSQL integration tests must not silently pass without DATABASE_URL"
    );
}

#[tokio::test]
async fn cleanup_schema_drops_isolated_schema() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();

    assert!(
        pg_schema_harness::schema_exists(&pool, &db.schema).await,
        "isolated schema should exist after connect_and_migrate"
    );

    pg_schema_harness::cleanup_schema(&pool, &db.schema).await;

    assert!(
        !pg_schema_harness::schema_exists(&pool, &db.schema).await,
        "cleanup_schema should drop the isolated test schema"
    );
}

#[tokio::test]
async fn db_harness_drop_cleans_schema_after_panic_unwind() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let schema = db.schema.clone();

    assert!(
        pg_schema_harness::schema_exists(&pool, &schema).await,
        "isolated schema should exist before panic-path teardown"
    );

    let panic_result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _harness = db;
        panic!("intentional panic to validate panic-safe schema teardown");
    }));
    assert!(
        panic_result.is_err(),
        "test precondition requires unwinding panic path"
    );

    assert!(
        !pg_schema_harness::schema_exists(&pool, &schema).await,
        "DbHarness must drop isolated schema even when test panics"
    );
}

#[tokio::test]
async fn db_harness_drop_returns_when_schema_cleanup_is_blocked() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo_drop_block").await
    else {
        return;
    };
    let schema = db.schema.clone();
    let blocker_pool = pg_schema_harness::pool_in_schema(&schema, 1).await;
    let mut blocker = blocker_pool.begin().await.expect("begin cleanup blocker");
    sqlx::query("LOCK TABLE vm_inventory IN ACCESS SHARE MODE")
        .execute(&mut *blocker)
        .await
        .expect("hold lock that blocks DROP SCHEMA");

    let (dropped_tx, dropped_rx) = std::sync::mpsc::channel();
    let drop_thread = std::thread::spawn(move || {
        drop(db);
        let _ = dropped_tx.send(());
    });

    let drop_returned_while_blocked = dropped_rx.recv_timeout(Duration::from_millis(750)).is_ok();
    blocker.commit().await.expect("release cleanup blocker");
    drop_thread.join().expect("join harness drop thread");

    assert!(
        drop_returned_while_blocked,
        "DbHarness::drop must not wait on blocked schema cleanup after a timed-out test"
    );
    for _ in 0..20 {
        if !pg_schema_harness::schema_exists(&blocker_pool, &schema).await {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(
        !pg_schema_harness::schema_exists(&blocker_pool, &schema).await,
        "schema cleanup should finish after the blocking lock is released"
    );
}
