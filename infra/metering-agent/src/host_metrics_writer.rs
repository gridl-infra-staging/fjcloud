use crate::config::Config;
use crate::host_metrics::{collect_host_metrics, HostMetricsSample};
use anyhow::{anyhow, Context};
use async_trait::async_trait;
use chrono::{DateTime, Utc};
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

#[derive(Debug, PartialEq)]
struct HostMetricsInsert {
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

impl HostMetricsInsert {
    fn from_sample(vm_id: Uuid, sample: &HostMetricsSample) -> Self {
        Self {
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

impl VmHostMetricsWriter<'_> {
    async fn write(&self, insert: HostMetricsInsert) -> anyhow::Result<()> {
        sqlx::query(WRITE_HOST_METRICS_SQL)
            .bind(insert.vm_id)
            .bind(insert.collected_at)
            .bind(insert.cpu_pct)
            .bind(insert.mem_used_bytes)
            .bind(insert.mem_total_bytes)
            .bind(insert.disk_used_bytes)
            .bind(insert.disk_total_bytes)
            .bind(insert.net_rx_bytes)
            .bind(insert.net_tx_bytes)
            .execute(self.pool)
            .await
            .context("insert vm_host_metrics sample")?;
        Ok(())
    }
}

#[async_trait]
trait HostMetricsRepository {
    async fn find_vm_id(&self, vm_id: Uuid) -> anyhow::Result<Option<Uuid>>;
    async fn find_vm_id_by_hostname(&self, hostname: &str) -> anyhow::Result<Option<Uuid>>;
    async fn write_host_metrics(&self, insert: HostMetricsInsert) -> anyhow::Result<()>;
}

#[async_trait]
impl HostMetricsRepository for VmHostMetricsWriter<'_> {
    async fn find_vm_id(&self, vm_id: Uuid) -> anyhow::Result<Option<Uuid>> {
        sqlx::query_scalar("SELECT id FROM vm_inventory WHERE id = $1")
            .bind(vm_id)
            .fetch_optional(self.pool)
            .await
            .map_err(anyhow::Error::from)
    }

    async fn find_vm_id_by_hostname(&self, hostname: &str) -> anyhow::Result<Option<Uuid>> {
        sqlx::query_scalar("SELECT id FROM vm_inventory WHERE hostname = $1")
            .bind(hostname)
            .fetch_optional(self.pool)
            .await
            .map_err(anyhow::Error::from)
    }

    async fn write_host_metrics(&self, insert: HostMetricsInsert) -> anyhow::Result<()> {
        self.write(insert).await
    }
}

async fn resolve_vm_id(
    repository: &(impl HostMetricsRepository + Sync),
    cfg: &Config,
) -> anyhow::Result<Uuid> {
    let resolved = match cfg.vm_id {
        Some(vm_id) => repository.find_vm_id(vm_id).await,
        None => repository.find_vm_id_by_hostname(&cfg.node_id).await,
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
    repository: &(impl HostMetricsRepository + Sync),
    sample: &HostMetricsSample,
) -> anyhow::Result<()> {
    let vm_id = resolve_vm_id(repository, cfg).await?;
    repository
        .write_host_metrics(HostMetricsInsert::from_sample(vm_id, sample))
        .await
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
    use chrono::{TimeZone, Timelike};
    use std::collections::{HashMap, HashSet};
    use std::sync::Mutex;

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

    #[derive(Default)]
    struct FakeHostMetricsRepository {
        ids_by_hostname: HashMap<String, Uuid>,
        vm_ids: HashSet<Uuid>,
        inserts: Mutex<Vec<HostMetricsInsert>>,
    }

    #[async_trait]
    impl HostMetricsRepository for FakeHostMetricsRepository {
        async fn find_vm_id(&self, vm_id: Uuid) -> anyhow::Result<Option<Uuid>> {
            Ok(self.vm_ids.contains(&vm_id).then_some(vm_id))
        }

        async fn find_vm_id_by_hostname(&self, hostname: &str) -> anyhow::Result<Option<Uuid>> {
            Ok(self.ids_by_hostname.get(hostname).copied())
        }

        async fn write_host_metrics(&self, insert: HostMetricsInsert) -> anyhow::Result<()> {
            self.inserts
                .lock()
                .expect("insert capture mutex should lock")
                .push(insert);
            Ok(())
        }
    }

    #[test]
    fn host_metrics_insert_sql_targets_only_host_metrics_table() {
        let normalized_sql = WRITE_HOST_METRICS_SQL
            .split_whitespace()
            .collect::<Vec<_>>();

        assert_eq!(
            normalized_sql,
            [
                "INSERT",
                "INTO",
                "vm_host_metrics",
                "(vm_id,",
                "collected_at,",
                "cpu_pct,",
                "mem_used_bytes,",
                "mem_total_bytes,",
                "disk_used_bytes,",
                "disk_total_bytes,",
                "net_rx_bytes,",
                "net_tx_bytes)",
                "VALUES",
                "($1,",
                "$2,",
                "$3,",
                "$4,",
                "$5,",
                "$6,",
                "$7,",
                "$8,",
                "$9)",
            ],
            "host metrics persistence must target only the host metrics columns"
        );
    }

    #[tokio::test]
    async fn host_metrics_cycle_writes_vm_host_metrics_without_usage_records() {
        let explicit_vm_id = Uuid::new_v4();
        let fallback_vm_id = Uuid::new_v4();
        let repository = FakeHostMetricsRepository {
            ids_by_hostname: HashMap::from([("fallback-host".to_owned(), fallback_vm_id)]),
            vm_ids: HashSet::from([explicit_vm_id, fallback_vm_id]),
            ..Default::default()
        };
        let fixed_sample = fixed_sample();

        write_host_metrics_sample(
            &host_metrics_test_config("fallback-host", Some(explicit_vm_id)),
            &repository,
            &fixed_sample,
        )
        .await
        .expect("explicit VM_ID sample should persist");
        write_host_metrics_sample(
            &host_metrics_test_config("fallback-host", None),
            &repository,
            &nullable_disk_sample(&fixed_sample),
        )
        .await
        .expect("NODE_ID hostname fallback sample should persist");

        let unknown_error = write_host_metrics_sample(
            &host_metrics_test_config("unknown-host", None),
            &repository,
            &fixed_sample,
        )
        .await
        .expect_err("unknown VM identity must fail closed");
        assert!(unknown_error.to_string().contains("unknown-host"));
        assert_persisted_samples(&repository, explicit_vm_id, fallback_vm_id, &fixed_sample);
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

    fn assert_persisted_samples(
        repository: &FakeHostMetricsRepository,
        explicit_vm_id: Uuid,
        fallback_vm_id: Uuid,
        sample: &HostMetricsSample,
    ) {
        let rows = repository
            .inserts
            .lock()
            .expect("insert capture mutex should lock");
        let expected = vec![
            HostMetricsInsert::from_sample(explicit_vm_id, sample),
            HostMetricsInsert::from_sample(fallback_vm_id, &nullable_disk_sample(sample)),
        ];
        assert_eq!(*rows, expected, "unknown identity must not insert a row");
    }
}
