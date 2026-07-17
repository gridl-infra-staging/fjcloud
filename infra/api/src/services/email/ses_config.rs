use super::{normalize_from_name, DEFAULT_EMAIL_FROM_NAME};

/// Configuration required to wire `SesEmailService` in production.
/// Loaded from environment variables; startup fails fast if missing or invalid.
#[derive(Debug, Clone)]
pub struct SesConfig {
    pub from_address: String,
    pub from_name: String,
    pub region: String,
    pub configuration_set: String,
}

impl SesConfig {
    pub fn from_name_from_reader<F>(read: F) -> String
    where
        F: Fn(&str) -> Option<String>,
    {
        read("EMAIL_FROM_NAME")
            .map(normalize_from_name)
            .unwrap_or_else(|| DEFAULT_EMAIL_FROM_NAME.to_string())
    }

    pub fn from_name_from_env() -> String {
        Self::from_name_from_reader(|k| std::env::var(k).ok())
    }

    /// Testable constructor that reads values via a closure.
    pub fn from_reader<F>(read: F) -> Result<Self, String>
    where
        F: Fn(&str) -> Option<String>,
    {
        let from_address = read("SES_FROM_ADDRESS")
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
            .ok_or("SES_FROM_ADDRESS is required but missing or empty")?;

        let from_name = Self::from_name_from_reader(&read);

        let region = read("SES_REGION")
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
            .ok_or("SES_REGION is required but missing or empty")?;

        let configuration_set = read("SES_CONFIGURATION_SET")
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
            .ok_or("SES_CONFIGURATION_SET is required but missing or empty")?;

        Ok(Self {
            from_address,
            from_name,
            region,
            configuration_set,
        })
    }

    /// Load from real environment variables.
    pub fn from_env() -> Result<Self, String> {
        Self::from_reader(|k| std::env::var(k).ok())
    }
}
