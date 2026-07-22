use api::models::NewVmHostMetrics;
use api::repos::{PgVmHostMetricsRepo, RepoError, VmHostMetricsRepo};
use chrono::{TimeZone, Utc};
use uuid::Uuid;

use crate::common::support::pg_schema_harness::connect_and_migrate;

async fn seed_vm(pool: &sqlx::PgPool, hostname: &str) -> Uuid {
    let vm_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO vm_inventory (id, region, provider, hostname, flapjack_url) \
         VALUES ($1, 'us-east-1', 'aws', $2, $3)",
    )
    .bind(vm_id)
    .bind(hostname)
    .bind(format!("https://{hostname}"))
    .execute(pool)
    .await
    .expect("seed VM inventory row");
    vm_id
}

fn sample(vm_id: Uuid, collected_at: chrono::DateTime<Utc>) -> NewVmHostMetrics {
    NewVmHostMetrics {
        vm_id,
        collected_at,
        cpu_pct: 37.5,
        mem_used_bytes: 4_294_967_296,
        mem_total_bytes: 8_589_934_592,
        disk_used_bytes: None,
        disk_total_bytes: None,
        net_rx_bytes: 123_456_789,
        net_tx_bytes: 98_765_432,
    }
}

#[tokio::test]
async fn vm_host_metrics_repo_round_trips_and_returns_latest_sample() {
    let db = connect_and_migrate("it_vm_host_metrics_repo")
        .await
        .expect("DATABASE_URL and PostgreSQL are required for vm_host_metrics repository tests");
    let repo = PgVmHostMetricsRepo::new(db.pool.clone());
    let vm_id = seed_vm(&db.pool, "metrics-primary.test").await;
    let empty_vm_id = seed_vm(&db.pool, "metrics-empty.test").await;
    let older_at = Utc
        .with_ymd_and_hms(2026, 7, 20, 12, 0, 0)
        .single()
        .expect("valid older timestamp");

    let older_input = sample(vm_id, older_at);
    let older = repo
        .insert(&older_input)
        .await
        .expect("insert metrics with unavailable disk readings");

    assert_ne!(older.id, Uuid::nil());
    assert_eq!(older.vm_id, older_input.vm_id);
    assert_eq!(older.collected_at, older_input.collected_at);
    assert_eq!(older.cpu_pct, older_input.cpu_pct);
    assert_eq!(older.mem_used_bytes, older_input.mem_used_bytes);
    assert_eq!(older.mem_total_bytes, older_input.mem_total_bytes);
    assert_eq!(older.disk_used_bytes, None);
    assert_eq!(older.disk_total_bytes, None);
    assert_eq!(older.net_rx_bytes, older_input.net_rx_bytes);
    assert_eq!(older.net_tx_bytes, older_input.net_tx_bytes);

    let newer_at = Utc
        .with_ymd_and_hms(2026, 7, 20, 12, 5, 0)
        .single()
        .expect("valid newer timestamp");
    let newer_input = NewVmHostMetrics {
        vm_id,
        collected_at: newer_at,
        cpu_pct: 62.25,
        mem_used_bytes: 5_368_709_120,
        mem_total_bytes: 8_589_934_592,
        disk_used_bytes: Some(53_687_091_200),
        disk_total_bytes: Some(107_374_182_400),
        net_rx_bytes: 223_456_789,
        net_tx_bytes: 198_765_432,
    };
    let newer = repo
        .insert(&newer_input)
        .await
        .expect("insert newer metrics sample");

    let latest = repo
        .latest_for_vm(vm_id)
        .await
        .expect("load latest metrics sample")
        .expect("seeded VM has metrics samples");
    assert_eq!(latest.id, newer.id);
    assert_eq!(latest.vm_id, vm_id);
    assert_eq!(latest.collected_at, newer_at);
    assert_eq!(latest.cpu_pct, 62.25);
    assert_eq!(latest.mem_used_bytes, 5_368_709_120);
    assert_eq!(latest.mem_total_bytes, 8_589_934_592);
    assert_eq!(latest.disk_used_bytes, Some(53_687_091_200));
    assert_eq!(latest.disk_total_bytes, Some(107_374_182_400));
    assert_eq!(latest.net_rx_bytes, 223_456_789);
    assert_eq!(latest.net_tx_bytes, 198_765_432);
    assert_eq!(
        repo.latest_for_vm(empty_vm_id)
            .await
            .expect("query VM without samples"),
        None
    );

    let unknown_vm_error = repo
        .insert(&sample(Uuid::new_v4(), newer_at))
        .await
        .expect_err("vm_host_metrics must reference canonical vm_inventory identity");
    match unknown_vm_error {
        RepoError::Other(message) => assert!(
            message.contains("foreign key constraint"),
            "expected PostgreSQL foreign-key failure, got: {message}"
        ),
        other => panic!("expected repository database error, got: {other}"),
    }
}
