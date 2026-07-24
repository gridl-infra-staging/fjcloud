use api::models::Customer;
use api::repos::{CustomerRepo, PgCustomerRepo, RepoError};
use async_trait::async_trait;
use chrono::{DateTime, Duration, Utc};
use reqwest::redirect::Policy;
use serde::Serialize;
use sqlx::PgPool;
use std::time::Duration as StdDuration;
use thiserror::Error;
use uuid::Uuid;

use crate::config::Config;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RunOptions {
    pub now: DateTime<Utc>,
    pub retention_days: i64,
    pub dry_run: bool,
    pub max_erase_per_run: usize,
}

impl RunOptions {
    pub fn cutoff(self) -> DateTime<Utc> {
        self.now - Duration::days(self.retention_days)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RetentionSummary {
    pub candidates: usize,
    pub erased: usize,
    pub failed: usize,
    #[serde(rename = "skipped-by-bound")]
    pub skipped_by_bound: usize,
}

impl RetentionSummary {
    pub fn json_line(&self) -> String {
        serde_json::to_string(self).expect("RetentionSummary serialization should not fail")
    }
}

#[derive(Debug, Error)]
pub enum RetentionJobError {
    #[error("invalid retention job option {name}: {reason}")]
    InvalidOption { name: &'static str, reason: String },
    #[error("customer repo error: {0}")]
    Repo(String),
    #[error("hard-erase request failed for customer {customer_id}: {message}")]
    HardErase { customer_id: Uuid, message: String },
}

impl From<RepoError> for RetentionJobError {
    fn from(err: RepoError) -> Self {
        Self::Repo(err.to_string())
    }
}

#[async_trait]
pub trait HardEraseClient {
    async fn hard_erase_customer(&self, customer_id: Uuid) -> Result<(), String>;
}

#[async_trait]
pub trait RetentionCandidateRepo {
    async fn list_deleted_before_cutoff(
        &self,
        cutoff: DateTime<Utc>,
    ) -> Result<Vec<Customer>, RepoError>;
}

#[async_trait]
impl<T> RetentionCandidateRepo for T
where
    T: CustomerRepo + Sync,
{
    async fn list_deleted_before_cutoff(
        &self,
        cutoff: DateTime<Utc>,
    ) -> Result<Vec<Customer>, RepoError> {
        CustomerRepo::list_deleted_before_cutoff(self, cutoff).await
    }
}

pub struct HttpHardEraseClient {
    api_url: String,
    admin_key: String,
    client: reqwest::Client,
}

impl HttpHardEraseClient {
    pub fn new(api_url: String, admin_key: String) -> Self {
        Self {
            api_url,
            admin_key,
            client: reqwest::Client::builder()
                .redirect(Policy::none())
                .timeout(StdDuration::from_secs(30))
                .build()
                .expect("hard erase HTTP client should build"),
        }
    }
}

#[async_trait]
impl HardEraseClient for HttpHardEraseClient {
    async fn hard_erase_customer(&self, customer_id: Uuid) -> Result<(), String> {
        let url = format!(
            "{}/admin/customers/{}/hard-erase",
            self.api_url, customer_id
        );
        let response = self
            .client
            .post(url)
            .header("x-admin-key", &self.admin_key)
            .send()
            .await
            .map_err(|err| err.to_string())?;

        if response.status().is_success() {
            Ok(())
        } else {
            Err(format!("HTTP {}", response.status()))
        }
    }
}

pub async fn run_retention<R, E>(
    repo: &R,
    eraser: &E,
    options: RunOptions,
) -> Result<RetentionSummary, RetentionJobError>
where
    R: RetentionCandidateRepo + Sync,
    E: HardEraseClient + Sync,
{
    if options.retention_days < 0 {
        return Err(RetentionJobError::InvalidOption {
            name: "retention_days",
            reason: "must be non-negative".to_string(),
        });
    }

    let candidates = repo.list_deleted_before_cutoff(options.cutoff()).await?;
    let candidates_count = candidates.len();
    let capped_count = candidates_count.min(options.max_erase_per_run);
    let skipped_by_bound = candidates_count.saturating_sub(capped_count);

    if options.dry_run {
        return Ok(RetentionSummary {
            candidates: candidates_count,
            erased: 0,
            failed: 0,
            skipped_by_bound,
        });
    }

    let mut erased = 0;
    let mut failed = 0;
    for customer in candidates.iter().take(capped_count) {
        match eraser.hard_erase_customer(customer.id).await {
            Ok(()) => erased += 1,
            Err(err) => {
                failed += 1;
                tracing::warn!(
                    customer_id = %customer.id,
                    error = %err,
                    "hard erase request failed; continuing"
                );
            }
        }
    }

    Ok(RetentionSummary {
        candidates: candidates_count,
        erased,
        failed,
        skipped_by_bound,
    })
}

pub async fn run_from_config(
    cfg: &Config,
    pool: PgPool,
) -> Result<RetentionSummary, RetentionJobError> {
    let repo = PgCustomerRepo::new(pool);
    let eraser = HttpHardEraseClient::new(cfg.api_url.clone(), cfg.admin_key.clone());
    run_retention(
        &repo,
        &eraser,
        RunOptions {
            now: Utc::now(),
            retention_days: cfg.retention_days,
            dry_run: cfg.dry_run,
            max_erase_per_run: cfg.max_erase_per_run,
        },
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use api::models::IngestQuotaWarningsSentState;
    use rust_decimal::Decimal;
    use sqlx::types::Json;
    use std::sync::{Arc, Mutex};

    struct RecordingRepo {
        candidates: Vec<Customer>,
        observed_cutoff: Mutex<Option<DateTime<Utc>>>,
    }

    #[async_trait]
    impl RetentionCandidateRepo for RecordingRepo {
        async fn list_deleted_before_cutoff(
            &self,
            cutoff: DateTime<Utc>,
        ) -> Result<Vec<Customer>, RepoError> {
            *self.observed_cutoff.lock().unwrap() = Some(cutoff);
            Ok(self.candidates.clone())
        }
    }

    struct RecordingEraser {
        calls: Arc<Mutex<Vec<Uuid>>>,
        fail_ids: Vec<Uuid>,
    }

    #[async_trait]
    impl HardEraseClient for RecordingEraser {
        async fn hard_erase_customer(&self, customer_id: Uuid) -> Result<(), String> {
            self.calls.lock().unwrap().push(customer_id);
            if self.fail_ids.contains(&customer_id) {
                Err("simulated failure".into())
            } else {
                Ok(())
            }
        }
    }

    fn customer(id: Uuid) -> Customer {
        let now = Utc::now();
        Customer {
            id,
            name: "Deleted Customer".into(),
            email: format!("{id}@example.test"),
            stripe_customer_id: None,
            status: "deleted".into(),
            lifecycle_generation: 1,
            deleted_at: Some(now),
            billing_plan: "free".into(),
            subscription_cycle_anchor_at: None,
            quota_warning_sent_at: None,
            quota_warnings_sent: Json(IngestQuotaWarningsSentState::default()),
            created_at: now,
            updated_at: now,
            password_hash: None,
            email_verified_at: None,
            email_verify_token: None,
            email_verify_expires_at: None,
            resend_verification_sent_at: None,
            password_reset_token: None,
            password_reset_expires_at: None,
            resend_password_reset_sent_at: None,
            last_accessed_at: None,
            overdue_invoice_count: 0,
            object_storage_egress_carryforward_cents: Decimal::ZERO,
            failed_login_count: 0,
            failed_login_window_start: None,
            login_locked_until: None,
            failed_verify_count: 0,
            failed_verify_window_start: None,
            verify_locked_until: None,
            failed_reset_count: 0,
            failed_reset_window_start: None,
            reset_locked_until: None,
        }
    }

    fn repo_with(candidates: Vec<Customer>) -> RecordingRepo {
        RecordingRepo {
            candidates,
            observed_cutoff: Mutex::new(None),
        }
    }

    fn eraser(fail_ids: Vec<Uuid>) -> RecordingEraser {
        RecordingEraser {
            calls: Arc::new(Mutex::new(Vec::new())),
            fail_ids,
        }
    }

    fn options(now: DateTime<Utc>, dry_run: bool, max_erase_per_run: usize) -> RunOptions {
        RunOptions {
            now,
            retention_days: 30,
            dry_run,
            max_erase_per_run,
        }
    }

    #[tokio::test]
    async fn passes_cutoff_selection_input_through_unchanged() {
        let now = DateTime::parse_from_rfc3339("2026-07-07T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let repo = repo_with(Vec::new());
        let eraser = eraser(Vec::new());

        run_retention(&repo, &eraser, options(now, false, 25))
            .await
            .unwrap();

        assert_eq!(
            *repo.observed_cutoff.lock().unwrap(),
            Some(
                DateTime::parse_from_rfc3339("2026-06-07T12:00:00Z")
                    .unwrap()
                    .with_timezone(&Utc)
            )
        );
    }

    #[tokio::test]
    async fn rejects_negative_retention_days_before_listing_candidates() {
        let repo = repo_with(vec![customer(Uuid::new_v4())]);
        let eraser = eraser(Vec::new());

        let err = run_retention(
            &repo,
            &eraser,
            RunOptions {
                now: Utc::now(),
                retention_days: -1,
                dry_run: false,
                max_erase_per_run: 25,
            },
        )
        .await
        .unwrap_err();

        assert!(matches!(
            err,
            RetentionJobError::InvalidOption {
                name: "retention_days",
                ref reason,
            } if reason == "must be non-negative"
        ));
        assert!(repo.observed_cutoff.lock().unwrap().is_none());
        assert!(eraser.calls.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn max_per_run_cap_counts_skipped_by_bound_before_erasing() {
        let ids = [Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4()];
        let repo = repo_with(ids.iter().copied().map(customer).collect());
        let eraser = eraser(Vec::new());

        let summary = run_retention(&repo, &eraser, options(Utc::now(), false, 2))
            .await
            .unwrap();

        assert_eq!(
            summary,
            RetentionSummary {
                candidates: 3,
                erased: 2,
                failed: 0,
                skipped_by_bound: 1,
            }
        );
        assert_eq!(*eraser.calls.lock().unwrap(), vec![ids[0], ids[1]]);
    }

    #[tokio::test]
    async fn dry_run_makes_zero_http_calls() {
        let ids = [Uuid::new_v4(), Uuid::new_v4()];
        let repo = repo_with(ids.iter().copied().map(customer).collect());
        let eraser = eraser(Vec::new());

        let summary = run_retention(&repo, &eraser, options(Utc::now(), true, 25))
            .await
            .unwrap();

        assert_eq!(summary.candidates, 2);
        assert_eq!(summary.erased, 0);
        assert_eq!(summary.failed, 0);
        assert_eq!(summary.skipped_by_bound, 0);
        assert!(eraser.calls.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn continue_on_error_reports_failed_and_attempts_later_customers() {
        let ids = [
            Uuid::new_v4(),
            Uuid::new_v4(),
            Uuid::new_v4(),
            Uuid::new_v4(),
        ];
        let repo = repo_with(ids.iter().copied().map(customer).collect());
        let eraser = eraser(vec![ids[1]]);

        let summary = run_retention(&repo, &eraser, options(Utc::now(), false, 3))
            .await
            .unwrap();

        assert_eq!(
            summary,
            RetentionSummary {
                candidates: 4,
                erased: 2,
                failed: 1,
                skipped_by_bound: 1,
            }
        );
        assert_eq!(*eraser.calls.lock().unwrap(), vec![ids[0], ids[1], ids[2]]);
    }

    #[test]
    fn summary_json_line_is_machine_readable_and_stable() {
        let summary = RetentionSummary {
            candidates: 3,
            erased: 1,
            failed: 1,
            skipped_by_bound: 1,
        };

        assert_eq!(
            summary.json_line(),
            r#"{"candidates":3,"erased":1,"failed":1,"skipped-by-bound":1}"#
        );
    }
}
