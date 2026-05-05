use crate::errors::ApiError;
use crate::models::Customer;
use crate::repos::advisory_lock::{account_lifecycle_lock_key, advisory_lock, AdvisoryLockGuard};
use crate::repos::CustomerRepo;
use crate::state::AppState;
use tracing::warn;
use uuid::Uuid;

pub fn parse_limit(limit: Option<i64>, default: i64, max: i64) -> Result<i64, ApiError> {
    match limit {
        None => Ok(default),
        Some(value) if value <= 0 => Err(ApiError::BadRequest(
            "limit must be a positive integer".to_string(),
        )),
        Some(value) => Ok(value.min(max)),
    }
}

/// Reads an environment variable via the `read` closure and attempts to parse it.
/// Warns and falls back to `default` when the value is missing or unparseable.
pub fn parse_with_default<F, T>(read: &F, key: &str, default: T) -> T
where
    F: Fn(&str) -> Option<String>,
    T: std::str::FromStr + std::fmt::Display + Copy,
{
    match read(key) {
        Some(value) => value.trim().parse::<T>().unwrap_or_else(|_| {
            warn!(
                env_key = %key,
                value = %value,
                fallback = %default,
                "invalid env var; using default"
            );
            default
        }),
        None => default,
    }
}

pub async fn require_active_customer(
    repo: &(dyn CustomerRepo + Send + Sync),
    customer_id: Uuid,
) -> Result<Customer, ApiError> {
    let customer = repo
        .find_by_id(customer_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("customer not found".to_string()))?;

    if customer.status == "deleted" {
        return Err(ApiError::NotFound("customer not found".to_string()));
    }

    Ok(customer)
}

pub async fn lock_account_lifecycle<'a>(
    state: &'a AppState,
    customer_id: Uuid,
) -> Result<AdvisoryLockGuard<'a>, ApiError> {
    let lock_key = account_lifecycle_lock_key(&state.pool, customer_id)
        .await
        .map_err(|e| {
            ApiError::ServiceUnavailable(format!(
                "failed to compute account lifecycle lock key: {e}"
            ))
        })?;

    advisory_lock(&state.pool, lock_key).await.map_err(|e| {
        ApiError::ServiceUnavailable(format!("failed to acquire account lifecycle lock: {e}"))
    })
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::io::Write;
    use std::sync::{Arc, Mutex};

    use crate::errors::ApiError;
    use crate::models::Customer;
    use crate::repos::{
        CustomerRepo, RepoError, ResendVerificationOutcome, ResendVerificationReservation,
    };
    use async_trait::async_trait;
    use chrono::Utc;
    use rust_decimal::Decimal;
    use tracing_subscriber::fmt::MakeWriter;
    use uuid::Uuid;

    use super::parse_limit;
    use super::parse_with_default;
    use super::require_active_customer;

    #[derive(Clone, Default)]
    struct TestLogSink {
        bytes: Arc<Mutex<Vec<u8>>>,
    }

    impl TestLogSink {
        fn as_string(&self) -> String {
            String::from_utf8(self.bytes.lock().expect("mutex poisoned").clone())
                .expect("valid utf-8 logs")
        }
    }

    struct TestLogWriter {
        bytes: Arc<Mutex<Vec<u8>>>,
    }

    impl Write for TestLogWriter {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.bytes.lock().expect("mutex poisoned").extend(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    impl<'a> MakeWriter<'a> for TestLogSink {
        type Writer = TestLogWriter;

        fn make_writer(&'a self) -> Self::Writer {
            TestLogWriter {
                bytes: Arc::clone(&self.bytes),
            }
        }
    }

    fn assert_bad_request(err: ApiError) {
        match err {
            ApiError::BadRequest(msg) => {
                assert_eq!(msg, "limit must be a positive integer");
            }
            other => panic!("expected BadRequest, got {other:?}"),
        }
    }

    #[test]
    fn parse_limit_none_returns_default() {
        let limit = parse_limit(None, 25, 100).expect("parse_limit should succeed");
        assert_eq!(limit, 25);
    }

    #[test]
    fn parse_limit_negative_returns_bad_request() {
        let err = parse_limit(Some(-5), 25, 100).expect_err("parse_limit should fail");
        assert_bad_request(err);
    }

    #[test]
    fn parse_limit_zero_returns_bad_request() {
        let err = parse_limit(Some(0), 25, 100).expect_err("parse_limit should fail");
        assert_bad_request(err);
    }

    #[test]
    fn parse_limit_valid_returns_exact_value() {
        let limit = parse_limit(Some(77), 25, 100).expect("parse_limit should succeed");
        assert_eq!(limit, 77);
    }

    #[test]
    fn parse_limit_over_max_clamps_to_max() {
        let limit = parse_limit(Some(350), 25, 100).expect("parse_limit should succeed");
        assert_eq!(limit, 100);
    }

    #[test]
    fn parse_with_default_parses_u64_when_value_present() {
        let values = HashMap::from([("FOO".to_string(), "42".to_string())]);
        let parsed = parse_with_default(&|key| values.get(key).cloned(), "FOO", 9_u64);
        assert_eq!(parsed, 42_u64);
    }

    #[test]
    fn parse_with_default_invalid_value_falls_back_and_logs_warning() {
        let values = HashMap::from([("FOO".to_string(), "abc".to_string())]);
        let logs = TestLogSink::default();
        let subscriber = tracing_subscriber::fmt()
            .with_ansi(false)
            .without_time()
            .with_writer(logs.clone())
            .finish();

        let parsed = tracing::subscriber::with_default(subscriber, || {
            parse_with_default(&|key| values.get(key).cloned(), "FOO", 15_u64)
        });
        assert_eq!(parsed, 15_u64);
        assert!(logs.as_string().contains("invalid env var; using default"));
    }

    #[test]
    fn parse_with_default_missing_value_returns_default() {
        let values: HashMap<String, String> = HashMap::new();
        let parsed = parse_with_default(&|key| values.get(key).cloned(), "FOO", 7_u64);
        assert_eq!(parsed, 7_u64);
    }

    #[test]
    fn parse_with_default_trims_whitespace() {
        let values = HashMap::from([("FOO".to_string(), "  31  ".to_string())]);
        let parsed = parse_with_default(&|key| values.get(key).cloned(), "FOO", 9_u64);
        assert_eq!(parsed, 31_u64);
    }

    #[test]
    fn parse_with_default_supports_u32() {
        let values = HashMap::from([("FOO".to_string(), "18".to_string())]);
        let parsed = parse_with_default(&|key| values.get(key).cloned(), "FOO", 5_u32);
        assert_eq!(parsed, 18_u32);
    }

    #[test]
    fn parse_with_default_supports_f64() {
        let values = HashMap::from([("FOO".to_string(), "0.75".to_string())]);
        let parsed = parse_with_default(&|key| values.get(key).cloned(), "FOO", 0.25_f64);
        assert_eq!(parsed, 0.75_f64);
    }

    struct MockCustomerRepo {
        customer: Option<Customer>,
        find_err: Option<String>,
    }

    #[async_trait]
    impl CustomerRepo for MockCustomerRepo {
        async fn list(&self) -> Result<Vec<Customer>, RepoError> {
            panic!("not used in this test");
        }

        async fn find_by_id(&self, _id: Uuid) -> Result<Option<Customer>, RepoError> {
            if let Some(err) = &self.find_err {
                return Err(RepoError::Other(err.clone()));
            }
            Ok(self.customer.clone())
        }

        async fn find_by_email(&self, _email: &str) -> Result<Option<Customer>, RepoError> {
            panic!("not used in this test");
        }

        async fn create(&self, _name: &str, _email: &str) -> Result<Customer, RepoError> {
            panic!("not used in this test");
        }

        async fn create_with_password(
            &self,
            _name: &str,
            _email: &str,
            _password_hash: &str,
        ) -> Result<Customer, RepoError> {
            panic!("not used in this test");
        }

        async fn update(
            &self,
            _id: Uuid,
            _name: Option<&str>,
            _email: Option<&str>,
        ) -> Result<Option<Customer>, RepoError> {
            panic!("not used in this test");
        }

        async fn soft_delete(&self, _id: Uuid) -> Result<bool, RepoError> {
            panic!("not used in this test");
        }

        async fn list_deleted_before_cutoff(
            &self,
            _cutoff: chrono::DateTime<Utc>,
        ) -> Result<Vec<Customer>, RepoError> {
            panic!("not used in this test");
        }

        async fn set_email_verify_token(
            &self,
            _id: Uuid,
            _token: &str,
            _expires_at: chrono::DateTime<Utc>,
        ) -> Result<bool, RepoError> {
            panic!("not used in this test");
        }

        async fn rotate_email_verification_token_with_resend_cooldown(
            &self,
            _id: Uuid,
            _token: &str,
            _expires_at: chrono::DateTime<Utc>,
        ) -> Result<ResendVerificationOutcome, RepoError> {
            panic!("not used in this test");
        }

        async fn rollback_resend_verification_token_rotation(
            &self,
            _id: Uuid,
            _reserved_token: &str,
            _reservation: &ResendVerificationReservation,
        ) -> Result<bool, RepoError> {
            panic!("not used in this test");
        }

        async fn verify_email(&self, _token: &str) -> Result<Option<Customer>, RepoError> {
            panic!("not used in this test");
        }

        async fn set_password_reset_token(
            &self,
            _id: Uuid,
            _token: &str,
            _expires_at: chrono::DateTime<Utc>,
        ) -> Result<bool, RepoError> {
            panic!("not used in this test");
        }

        async fn find_by_reset_token(&self, _token: &str) -> Result<Option<Customer>, RepoError> {
            panic!("not used in this test");
        }

        async fn reset_password(
            &self,
            _token: &str,
            _new_password_hash: &str,
        ) -> Result<bool, RepoError> {
            panic!("not used in this test");
        }

        async fn set_stripe_customer_id(
            &self,
            _id: Uuid,
            _stripe_customer_id: &str,
        ) -> Result<bool, RepoError> {
            panic!("not used in this test");
        }

        async fn find_by_stripe_customer_id(
            &self,
            _stripe_customer_id: &str,
        ) -> Result<Option<Customer>, RepoError> {
            panic!("not used in this test");
        }

        async fn set_quota_warning_sent_at(
            &self,
            _id: Uuid,
            _sent_at: chrono::DateTime<Utc>,
        ) -> Result<bool, RepoError> {
            panic!("not used in this test");
        }

        async fn change_password(
            &self,
            _id: Uuid,
            _new_password_hash: &str,
        ) -> Result<bool, RepoError> {
            panic!("not used in this test");
        }

        async fn set_billing_plan(&self, _id: Uuid, _plan: &str) -> Result<bool, RepoError> {
            panic!("not used in this test");
        }

        async fn suspend(&self, _id: Uuid) -> Result<bool, RepoError> {
            panic!("not used in this test");
        }

        async fn reactivate(&self, _id: Uuid) -> Result<bool, RepoError> {
            panic!("not used in this test");
        }

        async fn set_object_storage_egress_carryforward_cents(
            &self,
            _id: Uuid,
            _cents: Decimal,
        ) -> Result<bool, RepoError> {
            panic!("not used in this test");
        }
    }

    /// Test helper: creates a [`Customer`] with the given status and sensible
    /// defaults for all other fields.
    fn build_customer(status: &str) -> Customer {
        let updated_at = Utc::now();
        let created_at = if status == "deleted" {
            // Deleted fixtures represent retained rows with prior creation time.
            updated_at - chrono::Duration::minutes(5)
        } else {
            updated_at
        };

        Customer {
            id: Uuid::new_v4(),
            name: "test".to_string(),
            email: "test@example.com".to_string(),
            stripe_customer_id: Some("cus_123".to_string()),
            status: status.to_string(),
            deleted_at: (status == "deleted").then_some(updated_at),
            billing_plan: "free".to_string(),
            quota_warning_sent_at: None,
            created_at,
            updated_at,
            password_hash: None,
            email_verified_at: Some(Utc::now()),
            email_verify_token: None,
            email_verify_expires_at: None,
            resend_verification_sent_at: None,
            password_reset_token: None,
            password_reset_expires_at: None,
            last_accessed_at: None,
            overdue_invoice_count: 0,
            object_storage_egress_carryforward_cents: Decimal::ZERO,
        }
    }

    #[tokio::test]
    async fn require_active_customer_returns_active_customer() {
        let customer = build_customer("active");
        let repo = MockCustomerRepo {
            customer: Some(customer.clone()),
            find_err: None,
        };

        let result = require_active_customer(&repo, customer.id).await;
        assert_eq!(result.expect("expected active customer").id, customer.id);
    }

    #[tokio::test]
    async fn require_active_customer_returns_not_found_for_deleted_customer() {
        let customer = build_customer("deleted");
        let repo = MockCustomerRepo {
            customer: Some(customer),
            find_err: None,
        };

        let err = require_active_customer(&repo, Uuid::new_v4())
            .await
            .expect_err("expected not found");
        match err {
            ApiError::NotFound(msg) => assert_eq!(msg, "customer not found"),
            other => panic!("expected NotFound, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn require_active_customer_returns_not_found_when_missing() {
        let repo = MockCustomerRepo {
            customer: None,
            find_err: None,
        };

        let err = require_active_customer(&repo, Uuid::new_v4())
            .await
            .expect_err("expected not found");
        match err {
            ApiError::NotFound(msg) => assert_eq!(msg, "customer not found"),
            other => panic!("expected NotFound, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn require_active_customer_propagates_repo_error() {
        let repo = MockCustomerRepo {
            customer: None,
            find_err: Some("db unavailable".to_string()),
        };

        let err = require_active_customer(&repo, Uuid::new_v4())
            .await
            .expect_err("expected repo error");
        match err {
            ApiError::Internal(msg) => assert_eq!(msg, "db unavailable"),
            other => panic!("expected Internal, got {other:?}"),
        }
    }
}
