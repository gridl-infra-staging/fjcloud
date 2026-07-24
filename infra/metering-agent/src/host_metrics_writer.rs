use crate::config::Config;
use crate::host_metrics::{collect_host_metrics, HostMetricsSample};
use anyhow::{anyhow, Context};
use std::time::Duration;
use uuid::Uuid;

pub(crate) struct VmHostMetricsWriter<'a> {
    pub(crate) pool: &'a sqlx::PgPool,
}

const WRITE_HOST_METRICS_SQL: &str = r#"
    INSERT INTO vm_host_metrics
        (vm_id, collected_at, cpu_pct, mem_used_bytes, mem_total_bytes,
         disk_used_bytes, disk_total_bytes, net_rx_bytes, net_tx_bytes)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
"#;

impl VmHostMetricsWriter<'_> {
    async fn write(&self, vm_id: Uuid, sample: &HostMetricsSample) -> anyhow::Result<()> {
        sqlx::query(WRITE_HOST_METRICS_SQL)
            .bind(vm_id)
            .bind(sample.collected_at)
            .bind(sample.cpu_pct)
            .bind(sample.mem_used_bytes)
            .bind(sample.mem_total_bytes)
            .bind(sample.disk_used_bytes)
            .bind(sample.disk_total_bytes)
            .bind(sample.net_rx_bytes)
            .bind(sample.net_tx_bytes)
            .execute(self.pool)
            .await
            .context("insert vm_host_metrics sample")?;
        Ok(())
    }
}

pub(crate) async fn resolve_vm_id(pool: &sqlx::PgPool, cfg: &Config) -> anyhow::Result<Uuid> {
    let resolved = match cfg.vm_id {
        Some(vm_id) => {
            sqlx::query_scalar("SELECT id FROM vm_inventory WHERE id = $1")
                .bind(vm_id)
                .fetch_optional(pool)
                .await
        }
        None => {
            sqlx::query_scalar("SELECT id FROM vm_inventory WHERE hostname = $1")
                .bind(&cfg.node_id)
                .fetch_optional(pool)
                .await
        }
    }
    .context("resolve host metrics VM identity")?;

    resolved.ok_or_else(|| match cfg.vm_id {
        Some(vm_id) => anyhow!("VM_ID {vm_id} does not exist in vm_inventory"),
        None => anyhow!(
            "NODE_ID hostname {} does not exist in vm_inventory",
            cfg.node_id
        ),
    })
}

async fn write_host_metrics_sample(
    cfg: &Config,
    writer: &VmHostMetricsWriter<'_>,
    sample: &HostMetricsSample,
) -> anyhow::Result<()> {
    let vm_id = resolve_vm_id(writer.pool, cfg).await?;
    writer.write(vm_id, sample).await
}

pub(crate) async fn run_host_metrics_cycle(
    cfg: &Config,
    writer: &VmHostMetricsWriter<'_>,
    cpu_sample_interval: Duration,
) -> anyhow::Result<()> {
    let proc_root = cfg.proc_root.clone();
    let disk_path = cfg.host_disk_path.clone();
    let sample = tokio::task::spawn_blocking(move || {
        collect_host_metrics(&proc_root, &disk_path, cpu_sample_interval)
    })
    .await
    .context("join host metrics collection task")??;

    write_host_metrics_sample(cfg, writer, &sample).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{DateTime, TimeZone, Timelike, Utc};
    use sqlx::postgres::PgPoolOptions;

    #[derive(Clone)]
    struct ValidatedSql(String);

    impl ValidatedSql {
        fn as_str(&self) -> &str {
            &self.0
        }
    }

    enum SchemaOperation {
        Create,
        SetSearchPath,
        Drop,
    }

    fn validated_schema_sql(schema_name: &str, operation: SchemaOperation) -> ValidatedSql {
        assert!(
            !schema_name.is_empty()
                && schema_name
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_'),
            "schema name must be a valid SQL identifier"
        );
        let quoted_schema = format!("\"{schema_name}\"");
        let statement = match operation {
            SchemaOperation::Create => format!("CREATE SCHEMA {quoted_schema}"),
            SchemaOperation::SetSearchPath => format!("SET search_path TO {quoted_schema}"),
            SchemaOperation::Drop => format!("DROP SCHEMA {quoted_schema} CASCADE"),
        };
        ValidatedSql(statement)
    }

    #[test]
    fn isolated_schema_sql_quotes_validated_identifiers() {
        let schema_name = "host_metrics_0123456789abcdef";

        assert_eq!(
            validated_schema_sql(schema_name, SchemaOperation::Create).as_str(),
            "CREATE SCHEMA \"host_metrics_0123456789abcdef\""
        );
        assert_eq!(
            validated_schema_sql(schema_name, SchemaOperation::SetSearchPath).as_str(),
            "SET search_path TO \"host_metrics_0123456789abcdef\""
        );
        assert_eq!(
            validated_schema_sql(schema_name, SchemaOperation::Drop).as_str(),
            "DROP SCHEMA \"host_metrics_0123456789abcdef\" CASCADE"
        );
    }

    #[test]
    #[should_panic(expected = "schema name must be a valid SQL identifier")]
    fn isolated_schema_sql_rejects_untrusted_identifiers() {
        validated_schema_sql(
            "host_metrics_safe; DROP SCHEMA public",
            SchemaOperation::Create,
        );
    }

    #[derive(Debug, PartialEq, sqlx::FromRow)]
    struct PersistedHostMetrics {
        vm_id: Uuid,
        collected_at: DateTime<Utc>,
        cpu_pct: f64,
        mem_used_bytes: i64,
        mem_total_bytes: i64,
        disk_used_bytes: Option<i64>,
        disk_total_bytes: Option<i64>,
        net_rx_bytes: i64,
        net_tx_bytes: i64,
    }

    struct TestDatabase {
        pool: sqlx::PgPool,
        admin_pool: sqlx::PgPool,
        schema_name: String,
    }

    impl TestDatabase {
        async fn connect_and_migrate() -> Self {
            let database_url = std::env::var("DATABASE_URL")
                .expect("DATABASE_URL must be set for the host metrics DB invariant test");
            let schema_name = format!("host_metrics_{}", Uuid::new_v4().simple());
            let admin_pool = PgPoolOptions::new()
                .max_connections(1)
                .connect(&database_url)
                .await
                .expect("connect to host metrics test database");
            let create_schema = validated_schema_sql(&schema_name, SchemaOperation::Create);
            sqlx::query(create_schema.as_str())
                .execute(&admin_pool)
                .await
                .expect("create isolated host metrics schema");

            let search_path = validated_schema_sql(&schema_name, SchemaOperation::SetSearchPath);
            let pool = PgPoolOptions::new()
                .max_connections(1)
                .after_connect(move |connection, _metadata| {
                    let search_path = search_path.clone();
                    Box::pin(async move {
                        sqlx::query(search_path.as_str())
                            .execute(connection)
                            .await?;
                        Ok(())
                    })
                })
                .connect(&database_url)
                .await
                .expect("connect pool to isolated host metrics schema");
            sqlx::migrate!("../migrations")
                .run(&pool)
                .await
                .expect("run migrations in isolated host metrics schema");

            Self {
                pool,
                admin_pool,
                schema_name,
            }
        }

        async fn cleanup(self) {
            self.pool.close().await;
            let drop_schema = validated_schema_sql(&self.schema_name, SchemaOperation::Drop);
            sqlx::query(drop_schema.as_str())
                .execute(&self.admin_pool)
                .await
                .expect("drop isolated host metrics schema");
            self.admin_pool.close().await;
        }
    }

    #[tokio::test]
    async fn host_metrics_cycle_writes_vm_host_metrics_without_usage_records() {
        let database = TestDatabase::connect_and_migrate().await;
        seed_billing_sentinel(&database.pool).await;
        let usage_count_before = usage_record_count(&database.pool).await;
        let explicit_vm_id = seed_vm_inventory(&database.pool, "explicit-host").await;
        let fallback_vm_id = seed_vm_inventory(&database.pool, "fallback-host").await;
        let writer = VmHostMetricsWriter {
            pool: &database.pool,
        };
        let fixed_sample = fixed_sample();

        write_host_metrics_sample(
            &host_metrics_test_config("fallback-host", Some(explicit_vm_id)),
            &writer,
            &fixed_sample,
        )
        .await
        .expect("explicit VM_ID sample should persist");
        write_host_metrics_sample(
            &host_metrics_test_config("fallback-host", None),
            &writer,
            &nullable_disk_sample(&fixed_sample),
        )
        .await
        .expect("NODE_ID hostname fallback sample should persist");

        let unknown_error = write_host_metrics_sample(
            &host_metrics_test_config("unknown-host", None),
            &writer,
            &fixed_sample,
        )
        .await
        .expect_err("unknown VM identity must fail closed");
        assert!(unknown_error.to_string().contains("unknown-host"));
        assert_eq!(usage_record_count(&database.pool).await, usage_count_before);
        assert_persisted_samples(
            &database.pool,
            explicit_vm_id,
            fallback_vm_id,
            &fixed_sample,
        )
        .await;

        database.cleanup().await;
    }

    fn host_metrics_test_config(node_id: &str, vm_id: Option<Uuid>) -> Config {
        Config::from_reader(|key| match key {
            "FLAPJACK_URL" => Ok("http://localhost:7700".into()),
            "FLAPJACK_API_KEY" => Ok("test-key".into()),
            "DATABASE_URL" => Ok("postgres://localhost/test".into()),
            "CUSTOMER_ID" => Ok("host-metrics-test".into()),
            "NODE_ID" => Ok(node_id.into()),
            "REGION" => Ok("us-east-1".into()),
            "VM_ID" => vm_id
                .map(|id| id.to_string())
                .ok_or(std::env::VarError::NotPresent),
            _ => Err(std::env::VarError::NotPresent),
        })
        .expect("host metrics test config should parse")
    }

    fn fixed_sample() -> HostMetricsSample {
        HostMetricsSample {
            collected_at: Utc
                .with_ymd_and_hms(2026, 7, 20, 12, 34, 56)
                .single()
                .expect("fixed timestamp should be valid")
                .with_nanosecond(123_456_000)
                .expect("fixed microseconds should be valid"),
            cpu_pct: 42.5,
            mem_used_bytes: 4_096,
            mem_total_bytes: 8_192,
            disk_used_bytes: Some(12_288),
            disk_total_bytes: Some(16_384),
            net_rx_bytes: 20_480,
            net_tx_bytes: 24_576,
        }
    }

    fn nullable_disk_sample(sample: &HostMetricsSample) -> HostMetricsSample {
        HostMetricsSample {
            collected_at: sample.collected_at + chrono::Duration::seconds(1),
            disk_used_bytes: None,
            disk_total_bytes: None,
            ..sample.clone()
        }
    }

    async fn seed_billing_sentinel(pool: &sqlx::PgPool) {
        let customer_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO customers (id, name, email) VALUES ($1, 'Host metrics guard', $2)",
        )
        .bind(customer_id)
        .bind(format!("host-metrics-{customer_id}@example.test"))
        .execute(pool)
        .await
        .expect("seed sentinel customer");
        sqlx::query(
            "INSERT INTO usage_records \
             (idempotency_key, customer_id, tenant_id, region, node_id, event_type, value, recorded_at, flapjack_ts) \
             VALUES ('host-metrics-sentinel', $1, 'sentinel', 'us-east-1', 'sentinel-node', \
                     'search_requests', 7, NOW(), NOW())",
        )
        .bind(customer_id)
        .execute(pool)
        .await
        .expect("seed sentinel usage record");
    }

    async fn seed_vm_inventory(pool: &sqlx::PgPool, hostname: &str) -> Uuid {
        let vm_id = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO vm_inventory (id, region, provider, hostname, flapjack_url) \
             VALUES ($1, 'us-east-1', 'aws', $2, $3)",
        )
        .bind(vm_id)
        .bind(hostname)
        .bind(format!("http://{hostname}:7700"))
        .execute(pool)
        .await
        .expect("seed VM inventory row");
        vm_id
    }

    async fn usage_record_count(pool: &sqlx::PgPool) -> i64 {
        sqlx::query_scalar("SELECT COUNT(*) FROM usage_records")
            .fetch_one(pool)
            .await
            .expect("count usage records")
    }

    async fn assert_persisted_samples(
        pool: &sqlx::PgPool,
        explicit_vm_id: Uuid,
        fallback_vm_id: Uuid,
        sample: &HostMetricsSample,
    ) {
        let rows = sqlx::query_as::<_, PersistedHostMetrics>(
            "SELECT vm_id, collected_at, cpu_pct, mem_used_bytes, mem_total_bytes, \
                    disk_used_bytes, disk_total_bytes, net_rx_bytes, net_tx_bytes \
             FROM vm_host_metrics ORDER BY collected_at",
        )
        .fetch_all(pool)
        .await
        .expect("load inserted host metrics rows");
        let expected = vec![
            persisted_sample(explicit_vm_id, sample),
            persisted_sample(fallback_vm_id, &nullable_disk_sample(sample)),
        ];
        assert_eq!(rows, expected, "unknown identity must not insert a row");
    }

    fn persisted_sample(vm_id: Uuid, sample: &HostMetricsSample) -> PersistedHostMetrics {
        PersistedHostMetrics {
            vm_id,
            collected_at: sample.collected_at,
            cpu_pct: sample.cpu_pct,
            mem_used_bytes: sample.mem_used_bytes,
            mem_total_bytes: sample.mem_total_bytes,
            disk_used_bytes: sample.disk_used_bytes,
            disk_total_bytes: sample.disk_total_bytes,
            net_rx_bytes: sample.net_rx_bytes,
            net_tx_bytes: sample.net_tx_bytes,
        }
    }
}
