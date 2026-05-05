use super::*;
use crate::startup_env::StartupEnvSnapshot;
use std::sync::{Mutex, OnceLock};

fn env_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

fn snapshot_with(values: &[(&str, &str)]) -> StartupEnvSnapshot {
    StartupEnvSnapshot::from_reader(|key| {
        values
            .iter()
            .find(|(candidate, _)| *candidate == key)
            .map(|(_, value)| value.to_string())
    })
}

fn test_pool() -> sqlx::PgPool {
    sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .connect_lazy("postgres://postgres:postgres@127.0.0.1:5432/fjcloud_test")
        .expect("lazy postgres pool should construct")
}

fn env_snapshot() -> StartupEnvSnapshot {
    StartupEnvSnapshot::from_reader(|key| std::env::var(key).ok())
}

struct EnvVarGuard {
    key: &'static str,
    previous: Option<String>,
}

impl EnvVarGuard {
    fn set(key: &'static str, value: Option<&str>) -> Self {
        let previous = std::env::var(key).ok();
        // SAFETY: The env lock serializes these process-env mutations.
        unsafe {
            match value {
                Some(v) => std::env::set_var(key, v),
                None => std::env::remove_var(key),
            }
        }
        Self { key, previous }
    }
}

impl Drop for EnvVarGuard {
    fn drop(&mut self) {
        // SAFETY: The env lock serializes these process-env mutations.
        unsafe {
            match &self.previous {
                Some(value) => std::env::set_var(self.key, value),
                None => std::env::remove_var(self.key),
            }
        }
    }
}

#[test]
fn mailpit_from_name_falls_back_to_flapjack_cloud() {
    let _guard = env_lock().lock().expect("env lock poisoned");
    let _env = EnvVarGuard::set("EMAIL_FROM_NAME", None);

    assert_eq!(
        mailpit_from_name_from_env(&env_snapshot()),
        "Flapjack Cloud"
    );
}

#[test]
fn mailpit_from_name_respects_env_override() {
    let _guard = env_lock().lock().expect("env lock poisoned");
    let _env = EnvVarGuard::set("EMAIL_FROM_NAME", Some("  Custom Sender  "));

    assert_eq!(mailpit_from_name_from_env(&env_snapshot()), "Custom Sender");
}

#[test]
fn mailpit_from_name_falls_back_when_blank() {
    let _guard = env_lock().lock().expect("env lock poisoned");
    let _env = EnvVarGuard::set("EMAIL_FROM_NAME", Some("   "));

    assert_eq!(
        mailpit_from_name_from_env(&env_snapshot()),
        "Flapjack Cloud"
    );
}

#[tokio::test]
async fn init_alert_service_fails_closed_for_production_without_webhooks() {
    let pool = test_pool();
    let startup_env = snapshot_with(&[("ENVIRONMENT", "prod")]);

    let error = match init_alert_service(&pool, &startup_env) {
        Ok(_) => panic!("prod must require a webhook"),
        Err(error) => error,
    };
    assert!(
        error
            .to_string()
            .contains("production requires SLACK_WEBHOOK_URL or DISCORD_WEBHOOK_URL"),
        "unexpected error message: {error:#}"
    );
}

#[tokio::test]
async fn init_alert_service_uses_log_fallback_outside_production_when_webhooks_absent() {
    let pool = test_pool();
    let startup_env = snapshot_with(&[("ENVIRONMENT", "staging")]);

    init_alert_service(&pool, &startup_env).expect("non-production should allow log-only fallback");
}

#[tokio::test]
async fn init_alert_service_allows_production_when_any_webhook_is_configured() {
    let pool = test_pool();
    let startup_env = snapshot_with(&[
        ("ENVIRONMENT", "production"),
        (
            "SLACK_WEBHOOK_URL",
            "https://hooks.slack.com/services/T000/B000/XXX",
        ),
    ]);

    init_alert_service(&pool, &startup_env).expect("production webhook configuration must boot");
}
