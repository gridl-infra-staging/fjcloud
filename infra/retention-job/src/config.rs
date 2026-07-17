use thiserror::Error;

pub const DEFAULT_RETENTION_DAYS: i64 = 30;
pub const DEFAULT_DRY_RUN: bool = true;
pub const DEFAULT_MAX_ERASE_PER_RUN: usize = 25;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub database_url: String,
    pub admin_key: String,
    pub api_url: String,
    pub retention_days: i64,
    pub dry_run: bool,
    pub max_erase_per_run: usize,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ConfigError {
    #[error("missing required env var: {0}")]
    Missing(String),
    #[error("invalid value for {var}: {reason}")]
    Invalid { var: String, reason: String },
}

impl Config {
    pub fn from_reader<F>(read: F) -> Result<Self, ConfigError>
    where
        F: Fn(&str) -> Result<String, std::env::VarError>,
    {
        let require = |key: &str| read(key).map_err(|_| ConfigError::Missing(key.to_string()));

        Ok(Self {
            database_url: require("DATABASE_URL")?,
            admin_key: require("ADMIN_KEY")?,
            api_url: validate_api_url(&require("API_URL")?)?,
            retention_days: parse_optional_non_negative_i64(
                &read,
                "RETENTION_DAYS",
                DEFAULT_RETENTION_DAYS,
            )?,
            dry_run: parse_optional_bool(&read, "RETENTION_DRY_RUN", DEFAULT_DRY_RUN)?,
            max_erase_per_run: parse_optional_usize(
                &read,
                "RETENTION_MAX_ERASE_PER_RUN",
                DEFAULT_MAX_ERASE_PER_RUN,
            )?,
        })
    }

    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_reader(|key| std::env::var(key))
    }
}

fn parse_optional_i64<F>(read: &F, key: &str, default: i64) -> Result<i64, ConfigError>
where
    F: Fn(&str) -> Result<String, std::env::VarError>,
{
    match read(key) {
        Ok(value) => value
            .trim()
            .parse::<i64>()
            .map_err(|err| ConfigError::Invalid {
                var: key.to_string(),
                reason: err.to_string(),
            }),
        Err(_) => Ok(default),
    }
}

fn parse_optional_non_negative_i64<F>(read: &F, key: &str, default: i64) -> Result<i64, ConfigError>
where
    F: Fn(&str) -> Result<String, std::env::VarError>,
{
    let value = parse_optional_i64(read, key, default)?;
    if value < 0 {
        return Err(ConfigError::Invalid {
            var: key.to_string(),
            reason: "must be non-negative".to_string(),
        });
    }
    Ok(value)
}

fn parse_optional_usize<F>(read: &F, key: &str, default: usize) -> Result<usize, ConfigError>
where
    F: Fn(&str) -> Result<String, std::env::VarError>,
{
    match read(key) {
        Ok(value) => value
            .trim()
            .parse::<usize>()
            .map_err(|err| ConfigError::Invalid {
                var: key.to_string(),
                reason: err.to_string(),
            }),
        Err(_) => Ok(default),
    }
}

fn parse_optional_bool<F>(read: &F, key: &str, default: bool) -> Result<bool, ConfigError>
where
    F: Fn(&str) -> Result<String, std::env::VarError>,
{
    match read(key) {
        Ok(value) => match value.trim() {
            "true" | "1" => Ok(true),
            "false" | "0" => Ok(false),
            _ => Err(ConfigError::Invalid {
                var: key.to_string(),
                reason: "must be true, false, 1, or 0".to_string(),
            }),
        },
        Err(_) => Ok(default),
    }
}

fn validate_api_url(raw: &str) -> Result<String, ConfigError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(ConfigError::Invalid {
            var: "API_URL".to_string(),
            reason: "must not be empty".to_string(),
        });
    }

    let url = reqwest::Url::parse(trimmed).map_err(|err| ConfigError::Invalid {
        var: "API_URL".to_string(),
        reason: err.to_string(),
    })?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err(ConfigError::Invalid {
            var: "API_URL".to_string(),
            reason: "must use http or https".to_string(),
        });
    }
    let Some(host) = url.host_str() else {
        return Err(ConfigError::Invalid {
            var: "API_URL".to_string(),
            reason: "must include a host".to_string(),
        });
    };
    if url.scheme() == "http" && !matches!(host, "localhost" | "127.0.0.1" | "::1") {
        return Err(ConfigError::Invalid {
            var: "API_URL".to_string(),
            reason: "must use https unless targeting localhost".to_string(),
        });
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(ConfigError::Invalid {
            var: "API_URL".to_string(),
            reason: "must not include embedded credentials".to_string(),
        });
    }

    Ok(url.as_str().trim_end_matches('/').to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_env(key: &str) -> Result<String, std::env::VarError> {
        match key {
            "DATABASE_URL" => Ok("postgres://localhost/fjcloud".into()),
            "ADMIN_KEY" => Ok("admin-secret".into()),
            "API_URL" => Ok("https://api.example.test".into()),
            _ => Err(std::env::VarError::NotPresent),
        }
    }

    #[test]
    fn missing_required_var_is_error() {
        let err = Config::from_reader(|key| match key {
            "ADMIN_KEY" => Err(std::env::VarError::NotPresent),
            other => valid_env(other),
        })
        .unwrap_err();

        assert_eq!(err, ConfigError::Missing("ADMIN_KEY".into()));
    }

    #[test]
    fn invalid_numeric_input_is_error() {
        let err = Config::from_reader(|key| match key {
            "RETENTION_DAYS" => Ok("thirty".into()),
            other => valid_env(other),
        })
        .unwrap_err();

        assert!(matches!(err, ConfigError::Invalid { ref var, .. } if var == "RETENTION_DAYS"));
    }

    #[test]
    fn negative_retention_days_is_error() {
        let err = Config::from_reader(|key| match key {
            "RETENTION_DAYS" => Ok("-1".into()),
            other => valid_env(other),
        })
        .unwrap_err();

        assert!(matches!(
            err,
            ConfigError::Invalid {
                ref var,
                ref reason,
            } if var == "RETENTION_DAYS" && reason == "must be non-negative"
        ));
    }

    #[test]
    fn invalid_bool_input_is_error() {
        let err = Config::from_reader(|key| match key {
            "RETENTION_DRY_RUN" => Ok("sometimes".into()),
            other => valid_env(other),
        })
        .unwrap_err();

        assert!(matches!(err, ConfigError::Invalid { ref var, .. } if var == "RETENTION_DRY_RUN"));
    }

    #[test]
    fn defaults_dry_run_and_max_erasure_bound() {
        let cfg = Config::from_reader(valid_env).unwrap();

        assert_eq!(cfg.retention_days, DEFAULT_RETENTION_DAYS);
        assert_eq!(cfg.dry_run, DEFAULT_DRY_RUN);
        assert_eq!(cfg.max_erase_per_run, DEFAULT_MAX_ERASE_PER_RUN);
    }

    #[test]
    fn accepts_systemd_binary_dry_run_flag() {
        let cfg = Config::from_reader(|key| match key {
            "RETENTION_DRY_RUN" => Ok("0".into()),
            other => valid_env(other),
        })
        .unwrap();

        assert!(!cfg.dry_run);
    }

    #[test]
    fn normalizes_api_url_trailing_slash_once() {
        let cfg = Config::from_reader(|key| match key {
            "API_URL" => Ok("https://api.example.test///".into()),
            other => valid_env(other),
        })
        .unwrap();

        assert_eq!(cfg.api_url, "https://api.example.test");
    }

    #[test]
    fn rejects_plaintext_non_local_api_url() {
        let err = Config::from_reader(|key| match key {
            "API_URL" => Ok("http://api.example.test".into()),
            other => valid_env(other),
        })
        .unwrap_err();

        assert!(matches!(
            err,
            ConfigError::Invalid {
                ref var,
                ref reason,
            } if var == "API_URL" && reason == "must use https unless targeting localhost"
        ));
    }

    #[test]
    fn allows_plaintext_loopback_api_url_for_local_runs() {
        let cfg = Config::from_reader(|key| match key {
            "API_URL" => Ok("http://127.0.0.1:3001".into()),
            other => valid_env(other),
        })
        .unwrap();

        assert_eq!(cfg.api_url, "http://127.0.0.1:3001");
    }
}
