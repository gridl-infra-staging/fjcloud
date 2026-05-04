use std::time::Duration;

use aws_sdk_cloudwatch::types::{Dimension, MetricDatum, StandardUnit};
use tokio::sync::watch;

const HEARTBEAT_NAMESPACE: &str = "fjcloud/api";
const HEARTBEAT_METRIC_NAME: &str = "Heartbeat";

pub struct HeartbeatPublisher {
    cloudwatch: aws_sdk_cloudwatch::Client,
    env: String,
    period: Duration,
}

impl HeartbeatPublisher {
    pub fn new(cloudwatch: aws_sdk_cloudwatch::Client, env: String, period: Duration) -> Self {
        Self {
            cloudwatch,
            env,
            period,
        }
    }

    async fn publish_once(
        &self,
    ) -> Result<
        (),
        aws_sdk_cloudwatch::error::SdkError<
            aws_sdk_cloudwatch::operation::put_metric_data::PutMetricDataError,
        >,
    > {
        self.cloudwatch
            .put_metric_data()
            .namespace(HEARTBEAT_NAMESPACE)
            .metric_data(
                MetricDatum::builder()
                    .metric_name(HEARTBEAT_METRIC_NAME)
                    .dimensions(
                        Dimension::builder()
                            .name("Env")
                            .value(self.env.clone())
                            .build(),
                    )
                    .unit(StandardUnit::Count)
                    .value(1.0)
                    .build(),
            )
            .send()
            .await?;
        Ok(())
    }

    pub async fn run(self, mut shutdown_rx: watch::Receiver<bool>) {
        let mut interval = tokio::time::interval(self.period);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            tokio::select! {
                _ = interval.tick() => {
                    if let Err(error) = self.publish_once().await {
                        tracing::warn!(error = %error, env = %self.env, "heartbeat metric publish failed");
                    }
                }
                _ = shutdown_rx.changed() => {
                    if *shutdown_rx.borrow() {
                        tracing::info!("heartbeat publisher shutting down");
                        return;
                    }
                }
            }
        }
    }
}
