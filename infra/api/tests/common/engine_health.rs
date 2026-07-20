#![allow(dead_code)]

use std::collections::VecDeque;
use std::future;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use api::services::health_monitor::{HealthCheckClient, HealthCheckResult};
use async_trait::async_trait;
use tokio::sync::Notify;

#[derive(Clone, Debug)]
pub enum EngineHealthBehavior {
    Healthy2xx,
    UnhealthyNon2xx(u16),
    RetryableUnreachable(&'static str),
    NeverAnswering,
    BlockedUntilRelease(Box<EngineHealthBehavior>),
}

pub struct EngineHealthClient {
    behaviors: Mutex<VecDeque<EngineHealthBehavior>>,
    attempts: AtomicUsize,
    attempt_entered: Notify,
    blocked_attempts: AtomicUsize,
    blocked_attempt_entered: Notify,
    attempt_release: Notify,
    release_requested: AtomicUsize,
}

impl EngineHealthClient {
    pub fn new(behaviors: impl Into<VecDeque<EngineHealthBehavior>>) -> Arc<Self> {
        Arc::new(Self {
            behaviors: Mutex::new(behaviors.into()),
            attempts: AtomicUsize::new(0),
            attempt_entered: Notify::new(),
            blocked_attempts: AtomicUsize::new(0),
            blocked_attempt_entered: Notify::new(),
            attempt_release: Notify::new(),
            release_requested: AtomicUsize::new(0),
        })
    }

    pub fn healthy() -> Arc<Self> {
        Self::new([EngineHealthBehavior::Healthy2xx])
    }

    pub fn unhealthy(status: u16) -> Arc<Self> {
        Self::new([EngineHealthBehavior::UnhealthyNon2xx(status)])
    }

    pub fn unreachable(reason: &'static str) -> Arc<Self> {
        Self::new([EngineHealthBehavior::RetryableUnreachable(reason)])
    }

    pub fn never_answering() -> Arc<Self> {
        Self::new(
            (0..64)
                .map(|_| EngineHealthBehavior::NeverAnswering)
                .collect::<Vec<_>>(),
        )
    }

    pub fn healthy_after_release() -> Arc<Self> {
        Self::new([EngineHealthBehavior::BlockedUntilRelease(Box::new(
            EngineHealthBehavior::Healthy2xx,
        ))])
    }

    pub fn attempts(&self) -> usize {
        self.attempts.load(Ordering::SeqCst)
    }

    pub async fn wait_for_attempt(&self) {
        while self.attempts() == 0 {
            self.attempt_entered.notified().await;
        }
    }

    pub fn blocked_attempts(&self) -> usize {
        self.blocked_attempts.load(Ordering::SeqCst)
    }

    pub async fn wait_for_blocked_attempt(&self) {
        while self.blocked_attempts() == 0 {
            self.blocked_attempt_entered.notified().await;
        }
    }

    pub fn release_attempt(&self) {
        self.release_requested.fetch_add(1, Ordering::SeqCst);
        self.attempt_release.notify_waiters();
    }

    async fn wait_for_release(&self) {
        while self.release_requested.load(Ordering::SeqCst) == 0 {
            self.attempt_release.notified().await;
        }
    }

    /// Resolves one scripted health-check behavior for paused-time awaiter tests.
    async fn resolve_behavior(&self, behavior: EngineHealthBehavior) -> HealthCheckResult {
        let behavior = match behavior {
            EngineHealthBehavior::BlockedUntilRelease(next) => {
                self.blocked_attempts.fetch_add(1, Ordering::SeqCst);
                self.attempt_entered.notify_waiters();
                self.blocked_attempt_entered.notify_waiters();
                self.wait_for_release().await;
                *next
            }
            behavior => behavior,
        };

        match behavior {
            EngineHealthBehavior::Healthy2xx => HealthCheckResult::Healthy,
            EngineHealthBehavior::UnhealthyNon2xx(status) => {
                HealthCheckResult::Unhealthy(format!("HTTP {status}"))
            }
            EngineHealthBehavior::RetryableUnreachable(reason) => {
                HealthCheckResult::Unreachable(reason.to_string())
            }
            EngineHealthBehavior::NeverAnswering => future::pending().await,
            EngineHealthBehavior::BlockedUntilRelease(_) => {
                panic!("blocked engine-health behavior must resolve to a concrete result")
            }
        }
    }
}

#[async_trait]
impl HealthCheckClient for EngineHealthClient {
    async fn check(&self, _flapjack_url: Option<String>) -> HealthCheckResult {
        self.attempts.fetch_add(1, Ordering::SeqCst);
        let behavior = {
            let mut behaviors = self.behaviors.lock().unwrap();
            behaviors
                .pop_front()
                .unwrap_or(EngineHealthBehavior::Healthy2xx)
        };
        self.resolve_behavior(behavior).await
    }
}
