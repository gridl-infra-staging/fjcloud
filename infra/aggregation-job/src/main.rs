mod config;
mod rollup;

use anyhow::Result;
use aws_sdk_cloudwatch::types::{Dimension, MetricDatum, StandardUnit};
use config::Config;
use std::future::Future;
use tracing::{info, warn};
use tracing_subscriber::EnvFilter;

const ROLLUP_METRIC_NAMESPACE: &str = "fjcloud/aggregation-job";
const ROLLUP_SUCCESS_METRIC_NAME: &str = "UsageDailyRollupSuccess";
const AGGREGATION_JOB_LOG_TARGET: &str = env!("CARGO_CRATE_NAME");

/// Program entry point for the daily rollup job: initialize structured logging, load env config, open PostgreSQL, execute run, and report affected rows.
#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(default_log_filter())
        .init();

    let cfg = Config::from_env().map_err(|e| anyhow::anyhow!("{}", e))?;

    info!(
        target_date = %cfg.target_date,
        "aggregation job starting"
    );

    database_url::validate_database_url_tls(&cfg.database_url).map_err(anyhow::Error::msg)?;
    let pool = sqlx::PgPool::connect(&cfg.database_url).await?;
    let rows_affected = run(&cfg, &pool).await?;
    pool.close().await;

    info!(
        target_date = %cfg.target_date,
        rows_affected,
        "aggregation complete"
    );

    Ok(())
}

fn default_log_filter() -> EnvFilter {
    EnvFilter::from_default_env().add_directive(
        format!("{AGGREGATION_JOB_LOG_TARGET}=info")
            .parse()
            .expect("static aggregation-job log directive must parse"),
    )
}

async fn run(cfg: &Config, pool: &sqlx::PgPool) -> Result<u64> {
    let (window_start, window_end) = rollup::day_window(cfg.target_date);

    let result = sqlx::query(rollup::ROLLUP_SQL)
        .bind(window_start)
        .bind(window_end)
        .bind(cfg.target_date)
        .execute(pool)
        .await
        .map(|result| result.rows_affected())
        .map_err(anyhow::Error::from);

    handle_rollup_result(result, cfg, || async {
        let aws_config = aws_config::defaults(aws_config::BehaviorVersion::latest())
            .load()
            .await;
        let cloudwatch = aws_sdk_cloudwatch::Client::new(&aws_config);
        publish_usage_daily_rollup_success(
            &cloudwatch,
            cfg.rollup_metric_environment
                .as_deref()
                .expect("publish closure only runs for eligible environments"),
        )
        .await
    })
    .await
}

async fn handle_rollup_result<F, Fut>(
    rollup_result: Result<u64>,
    cfg: &Config,
    publish_success_metric: F,
) -> Result<u64>
where
    F: FnOnce() -> Fut,
    Fut: Future<Output = Result<()>>,
{
    let rows_affected = rollup_result?;
    let Some(env) = cfg.rollup_metric_environment.as_deref() else {
        info!(
            env = %std::env::var("ENVIRONMENT").unwrap_or_else(|_| "<unset>".to_string()),
            target_date = %cfg.target_date,
            "skipping aggregation rollup success metric publish"
        );
        return Ok(rows_affected);
    };

    if let Err(error) = publish_success_metric().await {
        warn!(
            error = %error,
            env = %env,
            target_date = %cfg.target_date,
            "aggregation rollup success metric publish failed"
        );
    }

    Ok(rows_affected)
}

async fn publish_usage_daily_rollup_success(
    cloudwatch: &aws_sdk_cloudwatch::Client,
    env: &str,
) -> Result<()> {
    cloudwatch
        .put_metric_data()
        .namespace(ROLLUP_METRIC_NAMESPACE)
        .metric_data(
            MetricDatum::builder()
                .metric_name(ROLLUP_SUCCESS_METRIC_NAME)
                .dimensions(Dimension::builder().name("Env").value(env).build())
                .unit(StandardUnit::Count)
                .value(1.0)
                .build(),
        )
        .send()
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;
    use serde_cbor::Value as CborValue;
    use std::collections::BTreeMap;
    use std::future;
    use std::sync::{Arc, Mutex};
    use tracing::field::{Field, Visit};
    use tracing::{Event, Level, Subscriber};
    use tracing_subscriber::filter::LevelFilter;
    use tracing_subscriber::layer::Context;
    use tracing_subscriber::prelude::*;
    use tracing_subscriber::Layer;
    use wiremock::matchers::any;
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[derive(Clone, Debug)]
    struct CapturedLog {
        level: Level,
        fields: BTreeMap<String, String>,
        message: String,
    }

    #[derive(Clone, Default)]
    struct LogCapture {
        events: Arc<Mutex<Vec<CapturedLog>>>,
    }

    impl<S> Layer<S> for LogCapture
    where
        S: Subscriber,
    {
        fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
            let mut visitor = LogVisitor::default();
            event.record(&mut visitor);
            self.events.lock().unwrap().push(CapturedLog {
                level: *event.metadata().level(),
                fields: visitor.fields,
                message: visitor.message,
            });
        }
    }

    #[derive(Default)]
    struct LogVisitor {
        fields: BTreeMap<String, String>,
        message: String,
    }

    impl Visit for LogVisitor {
        fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
            let rendered = format!("{value:?}");
            if field.name() == "message" {
                self.message = rendered.trim_matches('"').to_string();
            }
            self.fields.insert(field.name().to_string(), rendered);
        }
    }

    fn cfg(env: Option<&str>) -> Config {
        Config {
            database_url: "postgres://localhost/test".to_string(),
            target_date: NaiveDate::from_ymd_opt(2026, 7, 23).unwrap(),
            rollup_metric_environment: env.map(str::to_string),
        }
    }

    fn cfg_from_environment(raw_env: Option<&str>) -> Config {
        Config::from_reader(|key| match key {
            "DATABASE_URL" => Some("postgres://localhost/test".to_string()),
            "TARGET_DATE" => Some("2026-07-23".to_string()),
            "ENVIRONMENT" => raw_env.map(str::to_string),
            _ => None,
        })
        .unwrap()
    }

    async fn cloudwatch_client_for_mock_server(server: &MockServer) -> aws_sdk_cloudwatch::Client {
        let aws_config = aws_config::defaults(aws_config::BehaviorVersion::latest())
            .region(aws_sdk_cloudwatch::config::Region::new("us-east-1"))
            .load()
            .await;
        let credentials = aws_sdk_cloudwatch::config::Credentials::new(
            "test-access-key",
            "test-secret-key",
            None,
            None,
            "aggregation-rollup-test",
        );
        let cloudwatch_config = aws_sdk_cloudwatch::config::Builder::from(&aws_config)
            .endpoint_url(server.uri())
            .credentials_provider(credentials)
            .build();
        aws_sdk_cloudwatch::Client::from_conf(cloudwatch_config)
    }

    fn assert_json_metric_payload(body: &serde_json::Value, expected_env: &str) {
        assert_eq!(body["Namespace"].as_str(), Some("fjcloud/aggregation-job"));
        let metric_datum = body["MetricData"]
            .as_array()
            .and_then(|metric_data| metric_data.first())
            .expect("MetricData must include one datum");
        assert_eq!(
            metric_datum["MetricName"].as_str(),
            Some("UsageDailyRollupSuccess")
        );
        assert_eq!(metric_datum["Unit"].as_str(), Some("Count"));
        assert_eq!(metric_datum["Value"].as_f64(), Some(1.0));

        let dimensions = metric_datum["Dimensions"]
            .as_array()
            .expect("Dimensions must be an array");
        assert_eq!(dimensions.len(), 1);
        assert_eq!(dimensions[0]["Name"].as_str(), Some("Env"));
        assert_eq!(dimensions[0]["Value"].as_str(), Some(expected_env));
    }

    fn as_cbor_map(value: &CborValue) -> &BTreeMap<CborValue, CborValue> {
        match value {
            CborValue::Map(map) => map,
            other => panic!("expected CBOR map, got {other:?}"),
        }
    }

    fn as_cbor_array(value: &CborValue) -> &Vec<CborValue> {
        match value {
            CborValue::Array(array) => array,
            other => panic!("expected CBOR array, got {other:?}"),
        }
    }

    fn cbor_text(value: &CborValue) -> &str {
        match value {
            CborValue::Text(text) => text,
            other => panic!("expected CBOR text, got {other:?}"),
        }
    }

    fn cbor_f64(value: &CborValue) -> f64 {
        match value {
            CborValue::Float(float_value) => *float_value,
            CborValue::Integer(integer_value) => *integer_value as f64,
            other => panic!("expected CBOR numeric value, got {other:?}"),
        }
    }

    fn cbor_get<'a>(map: &'a BTreeMap<CborValue, CborValue>, key: &str) -> &'a CborValue {
        map.get(&CborValue::Text(key.to_string()))
            .unwrap_or_else(|| panic!("missing CBOR key '{key}'"))
    }

    fn assert_cbor_metric_payload(raw_body: &[u8], expected_env: &str) {
        let root_value: CborValue = serde_cbor::from_slice(raw_body).unwrap_or_else(|error| {
            panic!(
                "failed to parse CloudWatch request as CBOR after JSON parse miss: {error}; body={}",
                String::from_utf8_lossy(raw_body)
            )
        });
        let root = as_cbor_map(&root_value);
        assert_eq!(
            cbor_text(cbor_get(root, "Namespace")),
            "fjcloud/aggregation-job"
        );

        let metric_data = as_cbor_array(cbor_get(root, "MetricData"));
        assert_eq!(metric_data.len(), 1);
        let metric_datum = as_cbor_map(&metric_data[0]);
        assert_eq!(
            cbor_text(cbor_get(metric_datum, "MetricName")),
            "UsageDailyRollupSuccess"
        );
        assert_eq!(cbor_text(cbor_get(metric_datum, "Unit")), "Count");
        assert_eq!(cbor_f64(cbor_get(metric_datum, "Value")), 1.0);

        let dimensions = as_cbor_array(cbor_get(metric_datum, "Dimensions"));
        assert_eq!(dimensions.len(), 1);
        let env_dimension = as_cbor_map(&dimensions[0]);
        assert_eq!(cbor_text(cbor_get(env_dimension, "Name")), "Env");
        assert_eq!(cbor_text(cbor_get(env_dimension, "Value")), expected_env);
    }

    fn assert_put_metric_payload(raw_body: &[u8], expected_env: &str) {
        if let Ok(json_body) = serde_json::from_slice::<serde_json::Value>(raw_body) {
            assert_json_metric_payload(&json_body, expected_env);
        } else {
            assert_cbor_metric_payload(raw_body, expected_env);
        }
    }

    #[test]
    fn default_log_filter_enables_binary_target_completion_event() {
        let capture = LogCapture::default();
        let events = Arc::clone(&capture.events);
        let subscriber = tracing_subscriber::registry()
            .with(default_log_filter())
            .with(capture);

        let guard = tracing::subscriber::set_default(subscriber);
        tracing::info!(
            target: AGGREGATION_JOB_LOG_TARGET,
            target_date = "2026-07-24",
            rows_affected = 1_u64,
            "aggregation complete"
        );
        drop(guard);

        let logs = events.lock().unwrap();
        assert!(
            logs.iter().any(|event| {
                event.level == Level::INFO
                    && event.message == "aggregation complete"
                    && event
                        .fields
                        .get("rows_affected")
                        .is_some_and(|value| value == "1")
            }),
            "default filter must expose the completion event consumed by scripts/local_real_pipeline_probe.sh; logs={logs:?}"
        );
    }

    #[tokio::test]
    async fn rollup_success_publisher_sends_expected_metric_payload() {
        let server = MockServer::start().await;
        Mock::given(any())
            .respond_with(ResponseTemplate::new(200).set_body_string("{}"))
            .mount(&server)
            .await;
        let cloudwatch = cloudwatch_client_for_mock_server(&server).await;
        let env_value = "stage2-rollup-env-sentinel";

        publish_usage_daily_rollup_success(&cloudwatch, env_value)
            .await
            .expect("publisher should send metric to mock CloudWatch endpoint");

        let requests = server
            .received_requests()
            .await
            .expect("wiremock should capture CloudWatch requests");
        assert_eq!(requests.len(), 1, "publisher must emit exactly one request");
        assert_put_metric_payload(&requests[0].body, env_value);
    }

    #[tokio::test]
    async fn eligible_rollup_result_invokes_lazy_publisher_and_preserves_rows() {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let calls_for_publish = Arc::clone(&calls);

        let rows = handle_rollup_result(Ok(17), &cfg(Some("staging")), || {
            calls_for_publish.lock().unwrap().push("called");
            future::ready(Ok(()))
        })
        .await
        .unwrap();

        assert_eq!(rows, 17);
        assert_eq!(*calls.lock().unwrap(), vec!["called"]);
    }

    #[tokio::test]
    async fn ineligible_rollup_environment_logs_skip_without_invoking_publisher() {
        for raw_env in [
            None,
            Some(""),
            Some("local"),
            Some("dev"),
            Some("production"),
            Some("qa"),
        ] {
            let capture = LogCapture::default();
            let events = Arc::clone(&capture.events);
            let calls = Arc::new(Mutex::new(0));
            let calls_for_publish = Arc::clone(&calls);
            let subscriber = tracing_subscriber::registry()
                .with(LevelFilter::INFO)
                .with(capture);
            let cfg = cfg_from_environment(raw_env);

            let guard = tracing::subscriber::set_default(subscriber);
            let rows = handle_rollup_result(Ok(9), &cfg, || {
                *calls_for_publish.lock().unwrap() += 1;
                future::ready(Ok(()))
            })
            .await
            .unwrap();
            drop(guard);

            assert_eq!(rows, 9);
            assert_eq!(*calls.lock().unwrap(), 0);

            let logs = events.lock().unwrap();
            assert!(
                logs.iter().any(|event| {
                    event.level == Level::INFO
                        && event.message == "skipping aggregation rollup success metric publish"
                }),
                "expected info skip log for raw env {raw_env:?}; logs={logs:?}"
            );
        }
    }

    #[tokio::test]
    async fn sql_error_returns_before_invoking_publisher() {
        let calls = Arc::new(Mutex::new(0));
        let calls_for_publish = Arc::clone(&calls);

        let err = handle_rollup_result(
            Err(anyhow::anyhow!("sql write failed")),
            &cfg(Some("prod")),
            || {
                *calls_for_publish.lock().unwrap() += 1;
                future::ready(Ok(()))
            },
        )
        .await
        .unwrap_err();

        assert_eq!(err.to_string(), "sql write failed");
        assert_eq!(*calls.lock().unwrap(), 0);
    }

    #[tokio::test]
    async fn publish_error_warns_and_preserves_rows() {
        let capture = LogCapture::default();
        let events = Arc::clone(&capture.events);
        let subscriber = tracing_subscriber::registry()
            .with(LevelFilter::INFO)
            .with(capture);

        let guard = tracing::subscriber::set_default(subscriber);
        let rows = handle_rollup_result(Ok(23), &cfg(Some("prod")), || {
            future::ready(Err(anyhow::anyhow!("cloudwatch unavailable")))
        })
        .await
        .unwrap();
        drop(guard);

        assert_eq!(rows, 23);

        let logs = events.lock().unwrap();
        assert!(
            logs.iter().any(|event| {
                event.level == Level::WARN
                    && event.message == "aggregation rollup success metric publish failed"
                    && event
                        .fields
                        .get("env")
                        .is_some_and(|value| value.trim_matches('"') == "prod")
                    && event
                        .fields
                        .get("target_date")
                        .is_some_and(|value| value.trim_matches('"') == "2026-07-23")
            }),
            "expected warning with env and target_date; logs={logs:?}"
        );
    }
}
