use std::sync::Arc;
use std::time::Duration;

use aws_sdk_cloudwatch::types::{Dimension, MetricDatum, StandardUnit};
use tokio::sync::watch;

use crate::repos::WebhookEventRepo;

const WEBHOOK_LAG_NAMESPACE: &str = "fjcloud/api";
const WEBHOOK_LAG_METRIC_NAME: &str = "WebhookBacklog";

pub struct WebhookLagPublisher {
    cloudwatch: aws_sdk_cloudwatch::Client,
    webhook_event_repo: Arc<dyn WebhookEventRepo + Send + Sync>,
    env: String,
    period: Duration,
    stale_after: Duration,
}

impl WebhookLagPublisher {
    pub fn new(
        cloudwatch: aws_sdk_cloudwatch::Client,
        webhook_event_repo: Arc<dyn WebhookEventRepo + Send + Sync>,
        env: String,
        period: Duration,
        stale_after: Duration,
    ) -> Self {
        Self {
            cloudwatch,
            webhook_event_repo,
            env,
            period,
            stale_after,
        }
    }

    async fn publish_once(&self) -> Result<(), String> {
        let stale_count = self
            .webhook_event_repo
            .count_stale_unprocessed(self.stale_after)
            .await
            .map_err(|error| format!("count stale webhook backlog failed: {error}"))?;

        self.cloudwatch
            .put_metric_data()
            .namespace(WEBHOOK_LAG_NAMESPACE)
            .metric_data(
                MetricDatum::builder()
                    .metric_name(WEBHOOK_LAG_METRIC_NAME)
                    .dimensions(
                        Dimension::builder()
                            .name("Env")
                            .value(self.env.clone())
                            .build(),
                    )
                    .unit(StandardUnit::Count)
                    .value(stale_count as f64)
                    .build(),
            )
            .send()
            .await
            .map_err(|error| format!("publish webhook backlog metric failed: {error}"))?;

        Ok(())
    }

    pub async fn run(self, mut shutdown_rx: watch::Receiver<bool>) {
        let mut interval = tokio::time::interval(self.period);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            tokio::select! {
                _ = interval.tick() => {
                    if let Err(error) = self.publish_once().await {
                        tracing::warn!(
                            error = %error,
                            env = %self.env,
                            stale_after_seconds = self.stale_after.as_secs(),
                            "webhook backlog metric publish failed"
                        );
                    }
                }
                _ = shutdown_rx.changed() => {
                    if *shutdown_rx.borrow() {
                        tracing::info!("webhook lag publisher shutting down");
                        return;
                    }
                }
            }
        }
    }
}
