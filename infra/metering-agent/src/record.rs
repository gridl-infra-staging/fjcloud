//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar19_3_load_testing_chaos/fjcloud_dev/infra/metering-agent/src/record.rs.
use async_trait::async_trait;
use chrono::{DateTime, Timelike, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventType {
    SearchRequests,
    WriteOperations,
    DocumentsIndexed,
    DocumentsDeleted,
    StorageBytes,
    DocumentCount,
}

impl EventType {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::SearchRequests => "search_requests",
            Self::WriteOperations => "write_operations",
            Self::DocumentsIndexed => "documents_indexed",
            Self::DocumentsDeleted => "documents_deleted",
            Self::StorageBytes => "storage_bytes",
            Self::DocumentCount => "document_count",
        }
    }
}

/// One usage event to persist in the database.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageRecord {
    /// Prevents double-counting on retry or replay.
    pub idempotency_key: String,
    pub customer_id: Uuid,
    /// The flapjack index name.
    pub tenant_id: String,
    pub region: String,
    pub node_id: String,
    pub event_type: EventType,
    /// For counters: the delta since the last scrape.
    /// For gauges: the point-in-time snapshot value.
    pub value: i64,
    /// When this record was written by the agent.
    pub recorded_at: DateTime<Utc>,
    /// The timestamp of the scrape that produced this record.
    pub flapjack_ts: DateTime<Utc>,
}

/// Build a stable idempotency key that is safe to replay.
///
/// Format: `{node_id}:{event_type}:{tenant_id}:{timestamp_bucket_utc}`
///
/// The timestamp is bucketed to the minute so that a retry within the same
/// scrape window produces the same key and is deduplicated by the DB unique
/// constraint on `idempotency_key`.
pub fn make_idempotency_key(
    node_id: &str,
    event_type: &EventType,
    tenant_id: &str,
    ts: DateTime<Utc>,
) -> String {
    let bucket = ts
        .date_naive()
        .and_hms_opt(ts.hour(), ts.minute(), 0)
        .map(|naive| naive.and_utc())
        .unwrap_or(ts);
    format!(
        "{}:{}:{}:{}",
        node_id,
        event_type.as_str(),
        tenant_id,
        bucket.format("%Y%m%dT%H%M%SZ"),
    )
}

// ============================================================================
// Record construction helper — single source of truth for record shape
// ============================================================================

/// Per-batch context shared across all records in one scrape cycle.
/// Bundles the invariants that are constant within a single scrape:
/// node identity, region, and the scrape timestamp.
pub struct RecordContext<'a> {
    pub node_id: &'a str,
    pub region: &'a str,
    pub now: DateTime<Utc>,
}

/// Build a `UsageRecord` with correct idempotency key, propagated
/// region/node_id, and matching `recorded_at`/`flapjack_ts`.
///
/// All call sites that construct `UsageRecord` should go through this
/// helper so that record shape has a single source of truth.
pub fn build_usage_record(
    ctx: &RecordContext<'_>,
    customer_id: Uuid,
    tenant_id: &str,
    event_type: EventType,
    value: i64,
) -> UsageRecord {
    UsageRecord {
        idempotency_key: make_idempotency_key(ctx.node_id, &event_type, tenant_id, ctx.now),
        customer_id,
        tenant_id: tenant_id.to_string(),
        region: ctx.region.to_string(),
        node_id: ctx.node_id.to_string(),
        event_type,
        value,
        recorded_at: ctx.now,
        flapjack_ts: ctx.now,
    }
}

// ============================================================================
// UsageRecordWriter trait — enables failure injection for testing
// ============================================================================

#[async_trait]
pub trait UsageRecordWriter: Send + Sync {
    async fn write(&self, rec: &UsageRecord) -> anyhow::Result<()>;
}

pub struct PgUsageRecordWriter<'a> {
    pub pool: &'a sqlx::PgPool,
}

#[async_trait]
impl UsageRecordWriter for PgUsageRecordWriter<'_> {
    async fn write(&self, rec: &UsageRecord) -> anyhow::Result<()> {
        write_usage_record(self.pool, rec).await.map_err(Into::into)
    }
}

const WRITE_USAGE_RECORD_SQL: &str = r#"
        INSERT INTO usage_records
            (idempotency_key, customer_id, tenant_id, region, node_id,
             event_type, value, recorded_at, flapjack_ts)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        ON CONFLICT (idempotency_key) DO NOTHING
        "#;

/// Persist a single [`UsageRecord`] to the `usage_records` table.
///
/// Uses an `ON CONFLICT (idempotency_key) DO NOTHING` guard so that retries
/// or replays within the same scrape-minute window are idempotent: a record
/// with a key that already exists in the table is silently dropped rather
/// than producing a duplicate charge.
///
/// Uses the runtime (non-macro) `sqlx::query` API so the crate compiles
/// without a live database.  The full SQL is defined in
/// [`WRITE_USAGE_RECORD_SQL`] for easy inspection and testing.
pub(crate) async fn write_usage_record(
    pool: &sqlx::PgPool,
    rec: &UsageRecord,
) -> Result<(), sqlx::Error> {
    // Use the non-macro query API so this crate compiles without a live database.
    // The schema is enforced at the DB level; the macro variant can be enabled
    // later by running `cargo sqlx prepare` against a real database.
    sqlx::query(WRITE_USAGE_RECORD_SQL)
        .bind(&rec.idempotency_key)
        .bind(rec.customer_id)
        .bind(&rec.tenant_id)
        .bind(&rec.region)
        .bind(&rec.node_id)
        .bind(rec.event_type.as_str())
        .bind(rec.value)
        .bind(rec.recorded_at)
        .bind(rec.flapjack_ts)
        .execute(pool)
        .await?;

    Ok(())
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::sync::Arc;

    // ---- FailableUsageRecordWriter test double ----

    pub(crate) struct FailableUsageRecordWriter {
        pub should_fail: Arc<AtomicBool>,
        pub write_count: Arc<AtomicU64>,
    }

    impl FailableUsageRecordWriter {
        pub fn new(should_fail: bool) -> Self {
            Self {
                should_fail: Arc::new(AtomicBool::new(should_fail)),
                write_count: Arc::new(AtomicU64::new(0)),
            }
        }
    }

    #[async_trait]
    impl UsageRecordWriter for FailableUsageRecordWriter {
        async fn write(&self, _rec: &UsageRecord) -> anyhow::Result<()> {
            if self.should_fail.load(Ordering::SeqCst) {
                anyhow::bail!("simulated DB disconnect");
            }
            self.write_count.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
    }

    fn ts(h: u32, m: u32, s: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 2, 15, h, m, s).unwrap()
    }

    #[test]
    fn idempotency_key_contains_all_components() {
        let key = make_idempotency_key(
            "node-a",
            &EventType::SearchRequests,
            "products",
            ts(14, 30, 45),
        );
        assert!(key.contains("node-a"));
        assert!(key.contains("search_requests"));
        assert!(key.contains("products"));
    }

    #[test]
    fn idempotency_key_is_bucketed_to_the_minute() {
        // Two different seconds within the same minute → same key.
        let k1 = make_idempotency_key("n", &EventType::WriteOperations, "idx", ts(10, 5, 0));
        let k2 = make_idempotency_key("n", &EventType::WriteOperations, "idx", ts(10, 5, 59));
        assert_eq!(k1, k2);
    }

    #[test]
    fn different_minutes_produce_different_keys() {
        let k1 = make_idempotency_key("n", &EventType::SearchRequests, "idx", ts(10, 5, 0));
        let k2 = make_idempotency_key("n", &EventType::SearchRequests, "idx", ts(10, 6, 0));
        assert_ne!(k1, k2);
    }

    #[test]
    fn different_nodes_produce_different_keys() {
        let t = ts(12, 0, 0);
        let k1 = make_idempotency_key("node-a", &EventType::StorageBytes, "idx", t);
        let k2 = make_idempotency_key("node-b", &EventType::StorageBytes, "idx", t);
        assert_ne!(k1, k2);
    }

    #[test]
    fn different_event_types_produce_different_keys() {
        let t = ts(12, 0, 0);
        let k1 = make_idempotency_key("n", &EventType::SearchRequests, "idx", t);
        let k2 = make_idempotency_key("n", &EventType::WriteOperations, "idx", t);
        assert_ne!(k1, k2);
    }

    #[test]
    fn different_tenants_produce_different_keys() {
        let t = ts(12, 0, 0);
        let k1 = make_idempotency_key("n", &EventType::SearchRequests, "products", t);
        let k2 = make_idempotency_key("n", &EventType::SearchRequests, "orders", t);
        assert_ne!(k1, k2);
    }

    #[test]
    fn key_format_is_human_readable() {
        let key = make_idempotency_key("node-a", &EventType::StorageBytes, "products", ts(9, 0, 0));
        // Should look like: "node-a:storage_bytes:products:20260215T090000Z"
        assert_eq!(key, "node-a:storage_bytes:products:20260215T090000Z");
    }

    #[test]
    fn idempotency_key_sql_contains_on_conflict() {
        assert!(
            WRITE_USAGE_RECORD_SQL.contains("ON CONFLICT (idempotency_key) DO NOTHING"),
            "write_usage_record SQL must contain ON CONFLICT idempotency guard"
        );
    }

    // ---- build_usage_record shape invariant tests ----

    fn test_ctx() -> RecordContext<'static> {
        RecordContext {
            node_id: "node-a",
            region: "us-east-1",
            now: Utc.with_ymd_and_hms(2026, 2, 15, 14, 30, 45).unwrap(),
        }
    }

    #[test]
    fn build_record_propagates_region_and_node_id() {
        let ctx = test_ctx();
        let rec = build_usage_record(
            &ctx,
            Uuid::new_v4(),
            "products",
            EventType::SearchRequests,
            10,
        );
        assert_eq!(rec.region, "us-east-1");
        assert_eq!(rec.node_id, "node-a");
    }

    #[test]
    fn build_record_sets_recorded_at_equal_to_flapjack_ts() {
        let ctx = test_ctx();
        let rec = build_usage_record(
            &ctx,
            Uuid::new_v4(),
            "products",
            EventType::StorageBytes,
            1024,
        );
        assert_eq!(rec.recorded_at, rec.flapjack_ts);
        assert_eq!(rec.recorded_at, ctx.now);
    }

    #[test]
    fn build_record_computes_deterministic_idempotency_key() {
        let ctx = test_ctx();
        let cid = Uuid::new_v4();
        let r1 = build_usage_record(&ctx, cid, "idx", EventType::WriteOperations, 5);
        let r2 = build_usage_record(&ctx, cid, "idx", EventType::WriteOperations, 99);
        // Same context + tenant + event_type → same key (value doesn't affect key)
        assert_eq!(r1.idempotency_key, r2.idempotency_key);
    }

    #[test]
    fn build_record_key_includes_event_type() {
        let ctx = test_ctx();
        let cid = Uuid::new_v4();
        let search = build_usage_record(&ctx, cid, "idx", EventType::SearchRequests, 1);
        let write = build_usage_record(&ctx, cid, "idx", EventType::WriteOperations, 1);
        assert_ne!(search.idempotency_key, write.idempotency_key);
        assert!(search.idempotency_key.contains("search_requests"));
        assert!(write.idempotency_key.contains("write_operations"));
    }

    #[test]
    fn build_record_key_includes_tenant_id() {
        let ctx = test_ctx();
        let cid = Uuid::new_v4();
        let r1 = build_usage_record(&ctx, cid, "products", EventType::StorageBytes, 1);
        let r2 = build_usage_record(&ctx, cid, "orders", EventType::StorageBytes, 1);
        assert_ne!(r1.idempotency_key, r2.idempotency_key);
    }

    #[test]
    fn build_record_preserves_customer_id_and_value() {
        let ctx = test_ctx();
        let cid = Uuid::new_v4();
        let rec = build_usage_record(&ctx, cid, "idx", EventType::DocumentCount, 42);
        assert_eq!(rec.customer_id, cid);
        assert_eq!(rec.value, 42);
        assert_eq!(rec.tenant_id, "idx");
        assert_eq!(rec.event_type, EventType::DocumentCount);
    }

    // ---- SQL-contract tests ----

    /// Guards the SQL schema contract: every field of [`UsageRecord`] must
    /// appear as a named column in [`WRITE_USAGE_RECORD_SQL`].
    ///
    /// This is a compile-time-style check on the SQL string itself.  It
    /// catches accidental omissions when new fields are added to the struct —
    /// e.g. adding a column to `usage_records` without updating the INSERT
    /// would silently write NULLs.  The test asserts each column name appears
    /// in the SQL literal so the failure message is unambiguous.
    #[test]
    fn write_sql_inserts_all_usage_record_fields() {
        // Every field of UsageRecord must appear as a column in the INSERT.
        let field_columns = [
            "idempotency_key",
            "customer_id",
            "tenant_id",
            "region",
            "node_id",
            "event_type",
            "value",
            "recorded_at",
            "flapjack_ts",
        ];
        for col in &field_columns {
            assert!(
                WRITE_USAGE_RECORD_SQL.contains(col),
                "WRITE_USAGE_RECORD_SQL must reference column '{col}'"
            );
        }
    }

    #[test]
    fn write_sql_binds_all_nine_parameters() {
        // The SQL uses positional parameters $1..$9 for the 9 fields.
        for i in 1..=9 {
            let param = format!("${i}");
            assert!(
                WRITE_USAGE_RECORD_SQL.contains(&param),
                "WRITE_USAGE_RECORD_SQL must bind parameter {param}"
            );
        }
    }

    fn sample_record() -> UsageRecord {
        UsageRecord {
            idempotency_key: "test:search_requests:idx:20260215T090000Z".to_string(),
            customer_id: uuid::Uuid::new_v4(),
            tenant_id: "idx".to_string(),
            region: "us-east-1".to_string(),
            node_id: "node-test".to_string(),
            event_type: EventType::SearchRequests,
            value: 42,
            recorded_at: Utc::now(),
            flapjack_ts: Utc::now(),
        }
    }

    /// Guards the error-handling contract of [`UsageRecordWriter::write`]:
    /// a simulated DB failure must surface as `Err(...)` and must not panic or
    /// abort the calling scrape loop.
    ///
    /// Also verifies recovery: after re-enabling writes, the next call
    /// succeeds and increments the write counter, confirming the writer is
    /// reusable after a transient failure.
    #[tokio::test]
    async fn write_failure_returns_error_not_panic() {
        let writer = FailableUsageRecordWriter::new(true);
        let rec = sample_record();

        // Should return Err, not panic.
        let result = writer.write(&rec).await;
        assert!(
            result.is_err(),
            "write should fail when should_fail is true"
        );

        // Recover: set should_fail to false.
        writer.should_fail.store(false, Ordering::SeqCst);
        let result = writer.write(&rec).await;
        assert!(result.is_ok(), "write should succeed after recovery");
        assert_eq!(writer.write_count.load(Ordering::SeqCst), 1);
    }

    /// Simulates DB disconnect → circuit-breaker opens → backoff intervals
    /// increase → DB recovers → circuit closes → normal interval resumes.
    /// This exercises the same logic path as main.rs run_loop.
    #[tokio::test]
    async fn db_disconnect_recovery_with_circuit_breaker() {
        use crate::circuit_breaker::CircuitBreaker;
        use std::time::Duration;

        let writer = FailableUsageRecordWriter::new(true); // DB is "down"
        let rec = sample_record();
        let normal_interval = Duration::from_secs(60);
        let mut cb = CircuitBreaker::new(normal_interval);

        // Phase 1: DB disconnect — 5 failures open the circuit
        for i in 1..=5u32 {
            let result = writer.write(&rec).await;
            assert!(result.is_err(), "write should fail during disconnect");

            let next_interval = cb.record_failure();
            if i < 5 {
                assert_eq!(
                    next_interval, normal_interval,
                    "interval should be normal before circuit opens"
                );
                assert!(!cb.is_open(), "circuit should be closed after {i} failures");
            } else {
                assert_eq!(
                    next_interval,
                    Duration::from_secs(30),
                    "first backoff interval should be 30s"
                );
                assert!(cb.is_open(), "circuit should be open after 5 failures");
            }
        }

        // Phase 2: Still disconnected — verify escalating backoff
        let result = writer.write(&rec).await;
        assert!(result.is_err());
        assert_eq!(cb.record_failure(), Duration::from_secs(60), "2nd backoff");

        let result = writer.write(&rec).await;
        assert!(result.is_err());
        assert_eq!(cb.record_failure(), Duration::from_secs(120), "3rd backoff");

        // Phase 3: DB recovers
        writer.should_fail.store(false, Ordering::SeqCst);
        let result = writer.write(&rec).await;
        assert!(result.is_ok(), "write should succeed after DB recovery");
        assert_eq!(writer.write_count.load(Ordering::SeqCst), 1);

        let next_interval = cb.record_success();
        assert_eq!(
            next_interval, normal_interval,
            "interval should return to normal after recovery"
        );
        assert!(!cb.is_open(), "circuit should close after successful write");

        // Phase 4: Verify full reset — 4 more failures should NOT open circuit
        writer.should_fail.store(true, Ordering::SeqCst);
        for _ in 0..4 {
            let _ = writer.write(&rec).await;
            cb.record_failure();
        }
        assert!(
            !cb.is_open(),
            "circuit should not be open after only 4 failures post-recovery"
        );
    }
}
