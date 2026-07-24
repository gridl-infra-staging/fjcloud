use std::sync::Arc;
use std::time::Duration;

use aws_sdk_cloudwatch::types::{Dimension, MetricDatum, StandardUnit};
use tokio::sync::watch;

use crate::services::metrics::MetricsCollector;

const PANICS_NAMESPACE: &str = "fjcloud/api";
const PANICS_METRIC_NAME: &str = "PanicsPerPeriod";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ShutdownState {
    Continue,
    Requested,
    SenderDropped,
}

pub struct PanicsPublisher {
    cloudwatch: aws_sdk_cloudwatch::Client,
    env: String,
    period: Duration,
    metrics: Arc<MetricsCollector>,
    last_published_total: u64,
}

impl PanicsPublisher {
    pub fn new(
        cloudwatch: aws_sdk_cloudwatch::Client,
        env: String,
        period: Duration,
        metrics: Arc<MetricsCollector>,
    ) -> Self {
        Self {
            cloudwatch,
            env,
            period,
            metrics,
            last_published_total: 0,
        }
    }

    pub async fn publish_once(&mut self) -> Result<(), String> {
        let current_total = self.metrics.panic_total();
        let panics_this_period = current_total.saturating_sub(self.last_published_total);

        self.cloudwatch
            .put_metric_data()
            .namespace(PANICS_NAMESPACE)
            .metric_data(
                MetricDatum::builder()
                    .metric_name(PANICS_METRIC_NAME)
                    .dimensions(
                        Dimension::builder()
                            .name("Env")
                            .value(self.env.clone())
                            .build(),
                    )
                    .unit(StandardUnit::Count)
                    .value(panics_this_period as f64)
                    .build(),
            )
            .send()
            .await
            .map_err(|error| format!("publish panic metric failed: {error}"))?;

        self.last_published_total = current_total;
        Ok(())
    }

    pub async fn run(mut self, mut shutdown_rx: watch::Receiver<bool>) {
        let mut interval = tokio::time::interval(self.period);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            tokio::select! {
                _ = interval.tick() => {
                    if let Err(error) = self.publish_once().await {
                        tracing::warn!(
                            error = %error,
                            env = %self.env,
                            "panic metric publish failed"
                        );
                    }
                }
                shutdown_result = shutdown_rx.changed() => {
                    match shutdown_state(shutdown_result, &shutdown_rx) {
                        ShutdownState::Continue => {}
                        ShutdownState::Requested => {
                            tracing::info!("panic publisher shutting down");
                            return;
                        }
                        ShutdownState::SenderDropped => {
                            tracing::info!("panic publisher shutdown sender dropped");
                            return;
                        }
                    }
                }
            }
        }
    }
}

fn shutdown_state(
    shutdown_result: Result<(), watch::error::RecvError>,
    shutdown_rx: &watch::Receiver<bool>,
) -> ShutdownState {
    if shutdown_result.is_err() {
        return ShutdownState::SenderDropped;
    }
    if *shutdown_rx.borrow() {
        return ShutdownState::Requested;
    }
    ShutdownState::Continue
}

#[cfg(test)]
mod tests {
    use super::{shutdown_state, ShutdownState};
    use tokio::sync::watch;

    #[test]
    fn shutdown_state_stops_when_requested() {
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        shutdown_tx
            .send(true)
            .expect("sending shutdown request should succeed");

        assert_eq!(
            shutdown_state(Ok(()), &shutdown_rx),
            ShutdownState::Requested
        );
    }

    #[tokio::test]
    async fn shutdown_state_stops_when_sender_drops() {
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let mut closed_rx = shutdown_rx.clone();
        drop(shutdown_tx);
        let recv_error = closed_rx
            .changed()
            .await
            .expect_err("closed watch channel should surface a receive error");

        assert_eq!(
            shutdown_state(Err(recv_error), &shutdown_rx),
            ShutdownState::SenderDropped
        );
    }

    #[test]
    fn shutdown_state_continues_without_shutdown_request() {
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);

        assert_eq!(
            shutdown_state(Ok(()), &shutdown_rx),
            ShutdownState::Continue
        );
    }
}
