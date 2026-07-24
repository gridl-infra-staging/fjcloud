use chrono::{NaiveDate, Utc};
use thiserror::Error;

#[derive(Debug, PartialEq)]
pub struct Config {
    pub database_url: String,
    /// The calendar day (UTC) to aggregate. Defaults to yesterday.
    pub target_date: NaiveDate,
    pub rollup_metric_environment: Option<String>,
}

#[derive(Debug, Error, PartialEq)]
pub enum ConfigError {
    #[error("missing required env var: {0}")]
    Missing(String),
    #[error("invalid TARGET_DATE format (expected YYYY-MM-DD): {0}")]
    InvalidDate(String),
}

impl Config {
    /// Construct from an injected env reader — keeps tests hermetic (no shared
    /// process env, no race conditions between parallel test threads).
    pub fn from_reader<F>(read: F) -> Result<Self, ConfigError>
    where
        F: Fn(&str) -> Option<String>,
    {
        let database_url =
            read("DATABASE_URL").ok_or_else(|| ConfigError::Missing("DATABASE_URL".into()))?;

        let target_date = match read("TARGET_DATE") {
            Some(s) => NaiveDate::parse_from_str(&s, "%Y-%m-%d")
                .map_err(|_| ConfigError::InvalidDate(s))?,
            None => Utc::now().date_naive() - chrono::Duration::days(1),
        };
        let rollup_metric_environment = read("ENVIRONMENT")
            .and_then(|env| matches!(env.as_str(), "staging" | "prod").then_some(env));

        Ok(Config {
            database_url,
            target_date,
            rollup_metric_environment,
        })
    }

    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_reader(|k| std::env::var(k).ok())
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;
    use std::collections::HashMap;

    fn reader(vars: HashMap<&'static str, &'static str>) -> impl Fn(&str) -> Option<String> {
        move |k| vars.get(k).map(|v| v.to_string())
    }

    fn db_only() -> impl Fn(&str) -> Option<String> {
        reader(HashMap::from([(
            "DATABASE_URL",
            "postgres://localhost/test",
        )]))
    }

    #[test]
    fn reads_database_url() {
        let cfg = Config::from_reader(db_only()).unwrap();
        assert_eq!(cfg.database_url, "postgres://localhost/test");
    }

    #[test]
    fn missing_database_url_is_error() {
        let err = Config::from_reader(reader(HashMap::new())).unwrap_err();
        assert_eq!(err, ConfigError::Missing("DATABASE_URL".into()));
    }

    #[test]
    fn parses_target_date_from_env() {
        let cfg = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/test"),
            ("TARGET_DATE", "2026-02-15"),
        ])))
        .unwrap();

        assert_eq!(
            cfg.target_date,
            NaiveDate::from_ymd_opt(2026, 2, 15).unwrap()
        );
    }

    #[test]
    fn invalid_target_date_format_is_error() {
        let err = Config::from_reader(reader(HashMap::from([
            ("DATABASE_URL", "postgres://localhost/test"),
            ("TARGET_DATE", "15-02-2026"),
        ])))
        .unwrap_err();

        assert_eq!(err, ConfigError::InvalidDate("15-02-2026".into()));
    }

    #[test]
    fn missing_target_date_defaults_to_yesterday() {
        let cfg = Config::from_reader(db_only()).unwrap();
        let yesterday = Utc::now().date_naive() - chrono::Duration::days(1);
        assert_eq!(cfg.target_date, yesterday);
    }

    #[test]
    fn accepts_only_staging_and_prod_for_rollup_metric_publication() {
        for (raw_env, expected) in [("staging", Some("staging")), ("prod", Some("prod"))] {
            let cfg = Config::from_reader(reader(HashMap::from([
                ("DATABASE_URL", "postgres://localhost/test"),
                ("ENVIRONMENT", raw_env),
            ])))
            .unwrap();

            assert_eq!(cfg.rollup_metric_environment.as_deref(), expected);
        }
    }

    #[test]
    fn rejects_non_canonical_rollup_metric_publication_environments() {
        for raw_env in ["", "local", "dev", "production", "qa", " staging "] {
            let cfg = Config::from_reader(reader(HashMap::from([
                ("DATABASE_URL", "postgres://localhost/test"),
                ("ENVIRONMENT", raw_env),
            ])))
            .unwrap();

            assert_eq!(cfg.rollup_metric_environment, None, "raw env: {raw_env:?}");
        }
    }

    #[test]
    fn missing_environment_skips_rollup_metric_publication() {
        let cfg = Config::from_reader(db_only()).unwrap();
        assert_eq!(cfg.rollup_metric_environment, None);
    }
}
