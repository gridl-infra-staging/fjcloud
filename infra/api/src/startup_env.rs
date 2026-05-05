#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RawEnvValueState {
    Absent,
    Blank,
    Present,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RawEnvFamilyState {
    AllAbsent,
    HasBlankValues,
    PartiallyExplicit,
    FullyExplicit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SesStartupMode {
    Noop,
    Ses,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColdStorageStartupMode {
    InMemory,
    S3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StorageKeyStartupMode {
    DevKey,
    Parse,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NodeSecretBackendMode {
    Memory,
    Disabled { normalized_backend: String },
    AutoLike { normalized_backend: String },
}

#[derive(Debug, Clone, Default)]
pub struct StartupEnvSnapshot {
    node_secret_backend: Option<String>,
    environment: Option<String>,
    slack_webhook_url: Option<String>,
    discord_webhook_url: Option<String>,
    ses_from_address: Option<String>,
    email_from_name: Option<String>,
    ses_region: Option<String>,
    ses_configuration_set: Option<String>,
    cold_storage_bucket: Option<String>,
    cold_storage_prefix: Option<String>,
    cold_storage_region: Option<String>,
    cold_storage_endpoint: Option<String>,
    cold_storage_regions: Option<String>,
    cold_storage_access_key: Option<String>,
    cold_storage_secret_key: Option<String>,
    storage_encryption_key: Option<String>,
    app_base_url: Option<String>,
}

impl StartupEnvSnapshot {
    /// Build a snapshot by reading each env var through the provided closure.
    pub fn from_reader<F>(read: F) -> Self
    where
        F: Fn(&str) -> Option<String>,
    {
        Self {
            node_secret_backend: read("NODE_SECRET_BACKEND"),
            environment: read("ENVIRONMENT"),
            slack_webhook_url: read("SLACK_WEBHOOK_URL"),
            discord_webhook_url: read("DISCORD_WEBHOOK_URL"),
            ses_from_address: read("SES_FROM_ADDRESS"),
            email_from_name: read("EMAIL_FROM_NAME"),
            ses_region: read("SES_REGION"),
            ses_configuration_set: read("SES_CONFIGURATION_SET"),
            cold_storage_bucket: read("COLD_STORAGE_BUCKET"),
            cold_storage_prefix: read("COLD_STORAGE_PREFIX"),
            cold_storage_region: read("COLD_STORAGE_REGION"),
            cold_storage_endpoint: read("COLD_STORAGE_ENDPOINT"),
            cold_storage_regions: read("COLD_STORAGE_REGIONS"),
            cold_storage_access_key: read("COLD_STORAGE_ACCESS_KEY"),
            cold_storage_secret_key: read("COLD_STORAGE_SECRET_KEY"),
            storage_encryption_key: read("STORAGE_ENCRYPTION_KEY"),
            app_base_url: read("APP_BASE_URL"),
        }
    }

    pub fn from_env() -> Self {
        Self::from_reader(|k| std::env::var(k).ok())
    }

    pub fn normalized_node_secret_backend(&self) -> String {
        self.node_secret_backend
            .as_deref()
            .unwrap_or("auto")
            .trim()
            .to_ascii_lowercase()
    }

    fn normalized_environment(&self) -> String {
        self.environment
            .as_deref()
            .unwrap_or("unknown")
            .trim()
            .to_ascii_lowercase()
    }

    pub fn is_production_environment(&self) -> bool {
        matches!(
            self.normalized_environment().as_str(),
            "prod" | "production"
        )
    }

    pub fn is_staging_or_production(&self) -> bool {
        matches!(
            self.normalized_environment().as_str(),
            "staging" | "prod" | "production"
        )
    }

    pub fn is_explicit_local_environment(&self) -> bool {
        matches!(
            self.normalized_environment().as_str(),
            "local" | "dev" | "development"
        )
    }

    pub fn classify_node_secret_backend(&self) -> NodeSecretBackendMode {
        let normalized_backend = self.normalized_node_secret_backend();
        match normalized_backend.as_str() {
            "memory" => NodeSecretBackendMode::Memory,
            "disabled" | "unconfigured" => NodeSecretBackendMode::Disabled { normalized_backend },
            _ => NodeSecretBackendMode::AutoLike { normalized_backend },
        }
    }

    pub fn is_local_zero_dependency_mode(&self) -> bool {
        self.is_explicit_local_environment()
            && matches!(
                self.classify_node_secret_backend(),
                NodeSecretBackendMode::Memory
            )
    }

    pub fn ses_family_state(&self) -> RawEnvFamilyState {
        Self::classify_family_state(&[
            &self.ses_from_address,
            &self.ses_region,
            &self.ses_configuration_set,
        ])
    }

    pub fn alert_webhook_family_state(&self) -> RawEnvFamilyState {
        Self::classify_family_state(&[&self.slack_webhook_url, &self.discord_webhook_url])
    }

    pub fn has_configured_alert_webhook(&self) -> bool {
        matches!(
            Self::classify_value_state(self.slack_webhook_url.as_deref()),
            RawEnvValueState::Present
        ) || matches!(
            Self::classify_value_state(self.discord_webhook_url.as_deref()),
            RawEnvValueState::Present
        )
    }

    pub fn ses_startup_mode(&self) -> SesStartupMode {
        if self.is_local_zero_dependency_mode()
            && self.ses_family_state() == RawEnvFamilyState::AllAbsent
        {
            SesStartupMode::Noop
        } else {
            SesStartupMode::Ses
        }
    }

    pub fn cold_storage_family_state(&self) -> RawEnvFamilyState {
        Self::classify_family_state(&[
            &self.cold_storage_bucket,
            &self.cold_storage_prefix,
            &self.cold_storage_region,
            &self.cold_storage_endpoint,
            &self.cold_storage_regions,
            &self.cold_storage_access_key,
            &self.cold_storage_secret_key,
        ])
    }

    pub fn cold_storage_startup_mode(&self) -> ColdStorageStartupMode {
        if self.is_local_zero_dependency_mode()
            && self.cold_storage_family_state() == RawEnvFamilyState::AllAbsent
        {
            ColdStorageStartupMode::InMemory
        } else {
            ColdStorageStartupMode::S3
        }
    }

    pub fn storage_key_startup_mode(&self) -> StorageKeyStartupMode {
        if self.is_local_zero_dependency_mode()
            && self.storage_encryption_key_state() == RawEnvValueState::Absent
        {
            StorageKeyStartupMode::DevKey
        } else {
            StorageKeyStartupMode::Parse
        }
    }

    pub fn storage_encryption_key_state(&self) -> RawEnvValueState {
        Self::classify_value_state(self.storage_encryption_key.as_deref())
    }

    pub fn cold_storage_regions_state(&self) -> RawEnvValueState {
        Self::classify_value_state(self.cold_storage_regions.as_deref())
    }

    pub fn storage_encryption_key_raw(&self) -> Option<&str> {
        self.storage_encryption_key.as_deref()
    }

    pub fn env_value(&self, key: &str) -> Option<&str> {
        match key {
            "NODE_SECRET_BACKEND" => self.node_secret_backend.as_deref(),
            "ENVIRONMENT" => self.environment.as_deref(),
            "SLACK_WEBHOOK_URL" => self.slack_webhook_url.as_deref(),
            "DISCORD_WEBHOOK_URL" => self.discord_webhook_url.as_deref(),
            "SES_FROM_ADDRESS" => self.ses_from_address.as_deref(),
            "EMAIL_FROM_NAME" => self.email_from_name.as_deref(),
            "SES_REGION" => self.ses_region.as_deref(),
            "SES_CONFIGURATION_SET" => self.ses_configuration_set.as_deref(),
            "COLD_STORAGE_BUCKET" => self.cold_storage_bucket.as_deref(),
            "COLD_STORAGE_PREFIX" => self.cold_storage_prefix.as_deref(),
            "COLD_STORAGE_REGION" => self.cold_storage_region.as_deref(),
            "COLD_STORAGE_ENDPOINT" => self.cold_storage_endpoint.as_deref(),
            "COLD_STORAGE_REGIONS" => self.cold_storage_regions.as_deref(),
            "COLD_STORAGE_ACCESS_KEY" => self.cold_storage_access_key.as_deref(),
            "COLD_STORAGE_SECRET_KEY" => self.cold_storage_secret_key.as_deref(),
            "STORAGE_ENCRYPTION_KEY" => self.storage_encryption_key.as_deref(),
            "APP_BASE_URL" => self.app_base_url.as_deref(),
            _ => None,
        }
    }

    /// Classify a group of related env vars as all-absent, has-blank, partially-explicit, or fully-explicit.
    fn classify_family_state(values: &[&Option<String>]) -> RawEnvFamilyState {
        let (mut has_present, mut has_absent, mut has_blank) = (false, false, false);
        for value in values {
            match Self::classify_value_state(value.as_deref()) {
                RawEnvValueState::Present => has_present = true,
                RawEnvValueState::Absent => has_absent = true,
                RawEnvValueState::Blank => has_blank = true,
            }
        }

        if !has_present && !has_blank {
            RawEnvFamilyState::AllAbsent
        } else if has_blank {
            RawEnvFamilyState::HasBlankValues
        } else if has_absent {
            RawEnvFamilyState::PartiallyExplicit
        } else {
            RawEnvFamilyState::FullyExplicit
        }
    }

    fn classify_value_state(value: Option<&str>) -> RawEnvValueState {
        match value {
            None => RawEnvValueState::Absent,
            Some(raw) if raw.trim().is_empty() => RawEnvValueState::Blank,
            Some(_) => RawEnvValueState::Present,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot_with(values: &[(&str, &str)]) -> StartupEnvSnapshot {
        StartupEnvSnapshot::from_reader(|key| {
            values
                .iter()
                .find(|(candidate, _)| *candidate == key)
                .map(|(_, value)| value.to_string())
        })
    }

    #[test]
    fn node_secret_backend_memory_is_local_mode() {
        let snapshot =
            snapshot_with(&[("ENVIRONMENT", "local"), ("NODE_SECRET_BACKEND", "memory")]);
        assert_eq!(snapshot.normalized_node_secret_backend(), "memory");
        assert!(snapshot.is_explicit_local_environment());
        assert!(snapshot.is_local_zero_dependency_mode());
        assert_eq!(
            snapshot.classify_node_secret_backend(),
            NodeSecretBackendMode::Memory
        );
    }

    #[test]
    fn captures_application_base_url_for_email_link_rendering() {
        let snapshot = snapshot_with(&[("APP_BASE_URL", "https://preview.example.test")]);

        assert_eq!(
            snapshot.env_value("APP_BASE_URL"),
            Some("https://preview.example.test")
        );
    }

    #[test]
    fn node_secret_backend_whitespace_and_case_are_normalized() {
        let snapshot = snapshot_with(&[
            ("ENVIRONMENT", "  DeVeLoPmEnT  "),
            ("NODE_SECRET_BACKEND", "  MeMoRy  "),
        ]);
        assert_eq!(snapshot.normalized_node_secret_backend(), "memory");
        assert!(snapshot.is_explicit_local_environment());
        assert!(snapshot.is_local_zero_dependency_mode());
        assert_eq!(
            snapshot.classify_node_secret_backend(),
            NodeSecretBackendMode::Memory
        );
    }

    #[test]
    fn node_secret_backend_non_local_values_do_not_enable_local_mode() {
        let snapshot = snapshot_with(&[("ENVIRONMENT", "local"), ("NODE_SECRET_BACKEND", "ssm")]);
        assert_eq!(snapshot.normalized_node_secret_backend(), "ssm");
        assert!(!snapshot.is_local_zero_dependency_mode());
        assert_eq!(
            snapshot.classify_node_secret_backend(),
            NodeSecretBackendMode::AutoLike {
                normalized_backend: "ssm".to_string()
            }
        );
    }

    /// SES family (FROM_ADDRESS + REGION) returns correct state for absent, blank, and partial configs.
    #[test]
    fn ses_family_classification_distinguishes_absent_blank_and_partial() {
        let absent = snapshot_with(&[]);
        assert_eq!(absent.ses_family_state(), RawEnvFamilyState::AllAbsent);

        let blank = snapshot_with(&[("SES_FROM_ADDRESS", "   ")]);
        assert_eq!(blank.ses_family_state(), RawEnvFamilyState::HasBlankValues);

        let partial = snapshot_with(&[("SES_FROM_ADDRESS", "ops@example.com")]);
        assert_eq!(
            partial.ses_family_state(),
            RawEnvFamilyState::PartiallyExplicit
        );

        let full = snapshot_with(&[
            ("SES_FROM_ADDRESS", "ops@example.com"),
            ("SES_REGION", "us-east-1"),
            ("SES_CONFIGURATION_SET", "ses-feedback"),
        ]);
        assert_eq!(full.ses_family_state(), RawEnvFamilyState::FullyExplicit);
    }

    #[test]
    fn node_secret_backend_memory_requires_explicit_local_environment() {
        let memory_only = snapshot_with(&[("NODE_SECRET_BACKEND", "memory")]);
        assert!(!memory_only.is_explicit_local_environment());
        assert!(!memory_only.is_local_zero_dependency_mode());

        let prod_memory = snapshot_with(&[
            ("ENVIRONMENT", "production"),
            ("NODE_SECRET_BACKEND", "memory"),
        ]);
        assert!(!prod_memory.is_explicit_local_environment());
        assert!(!prod_memory.is_local_zero_dependency_mode());
    }

    #[test]
    fn production_environment_detection_normalizes_prod_aliases() {
        let prod = snapshot_with(&[("ENVIRONMENT", "  PROD  ")]);
        assert!(prod.is_production_environment());

        let production = snapshot_with(&[("ENVIRONMENT", "  Production ")]);
        assert!(production.is_production_environment());

        let non_prod = snapshot_with(&[("ENVIRONMENT", "staging")]);
        assert!(!non_prod.is_production_environment());
    }

    #[test]
    fn staging_or_production_detection_normalizes_environment_aliases() {
        let staging = snapshot_with(&[("ENVIRONMENT", "  staging  ")]);
        assert!(staging.is_staging_or_production());

        let prod = snapshot_with(&[("ENVIRONMENT", "PROD")]);
        assert!(prod.is_staging_or_production());

        let production = snapshot_with(&[("ENVIRONMENT", "production")]);
        assert!(production.is_staging_or_production());

        let local = snapshot_with(&[("ENVIRONMENT", "local")]);
        assert!(!local.is_staging_or_production());
    }

    #[test]
    fn alert_webhook_family_classifies_absent_blank_and_present_values() {
        let absent = snapshot_with(&[]);
        assert_eq!(
            absent.alert_webhook_family_state(),
            RawEnvFamilyState::AllAbsent
        );
        assert!(!absent.has_configured_alert_webhook());

        let blank = snapshot_with(&[("SLACK_WEBHOOK_URL", "   ")]);
        assert_eq!(
            blank.alert_webhook_family_state(),
            RawEnvFamilyState::HasBlankValues
        );
        assert!(!blank.has_configured_alert_webhook());

        let single = snapshot_with(&[("DISCORD_WEBHOOK_URL", "https://discord.test/hook")]);
        assert_eq!(
            single.alert_webhook_family_state(),
            RawEnvFamilyState::PartiallyExplicit
        );
        assert!(single.has_configured_alert_webhook());

        let mixed = snapshot_with(&[
            ("SLACK_WEBHOOK_URL", "https://slack.test/hook"),
            ("DISCORD_WEBHOOK_URL", "   "),
        ]);
        assert_eq!(
            mixed.alert_webhook_family_state(),
            RawEnvFamilyState::HasBlankValues
        );
        assert!(mixed.has_configured_alert_webhook());

        let full = snapshot_with(&[
            ("SLACK_WEBHOOK_URL", "https://slack.test/hook"),
            ("DISCORD_WEBHOOK_URL", "https://discord.test/hook"),
        ]);
        assert_eq!(
            full.alert_webhook_family_state(),
            RawEnvFamilyState::FullyExplicit
        );
        assert!(full.has_configured_alert_webhook());
    }

    /// Noop email only activates in local zero-dep mode with all SES vars absent.
    #[test]
    fn ses_startup_mode_only_noops_for_local_mode_with_absent_ses_env() {
        let local_absent =
            snapshot_with(&[("ENVIRONMENT", "local"), ("NODE_SECRET_BACKEND", "memory")]);
        assert_eq!(local_absent.ses_startup_mode(), SesStartupMode::Noop);

        let local_full = snapshot_with(&[
            ("ENVIRONMENT", "local"),
            ("NODE_SECRET_BACKEND", "memory"),
            ("SES_FROM_ADDRESS", "ops@example.com"),
            ("SES_REGION", "us-east-1"),
            ("SES_CONFIGURATION_SET", "ses-feedback"),
        ]);
        assert_eq!(local_full.ses_startup_mode(), SesStartupMode::Ses);

        let non_local_absent = snapshot_with(&[]);
        assert_eq!(non_local_absent.ses_startup_mode(), SesStartupMode::Ses);
    }

    /// InMemory cold storage only activates in local zero-dep mode with all cold storage vars absent.
    #[test]
    fn cold_storage_startup_mode_uses_in_memory_only_for_local_mode_with_absent_cold_storage_env() {
        let local_absent =
            snapshot_with(&[("ENVIRONMENT", "local"), ("NODE_SECRET_BACKEND", "memory")]);
        assert_eq!(
            local_absent.cold_storage_startup_mode(),
            ColdStorageStartupMode::InMemory
        );

        let local_explicit = snapshot_with(&[
            ("ENVIRONMENT", "local"),
            ("NODE_SECRET_BACKEND", "memory"),
            ("COLD_STORAGE_BUCKET", "fjcloud-cold"),
            ("COLD_STORAGE_PREFIX", "snapshots"),
            ("COLD_STORAGE_REGION", "us-east-1"),
            ("COLD_STORAGE_ENDPOINT", "https://s3.example.com"),
            ("COLD_STORAGE_REGIONS", "{}"),
            ("COLD_STORAGE_ACCESS_KEY", "access-a"),
            ("COLD_STORAGE_SECRET_KEY", "secret-a"),
        ]);
        assert_eq!(
            local_explicit.cold_storage_startup_mode(),
            ColdStorageStartupMode::S3
        );

        let local_partial = snapshot_with(&[
            ("ENVIRONMENT", "local"),
            ("NODE_SECRET_BACKEND", "memory"),
            ("COLD_STORAGE_BUCKET", "fjcloud-cold"),
        ]);
        assert_eq!(
            local_partial.cold_storage_startup_mode(),
            ColdStorageStartupMode::S3
        );

        let local_blank = snapshot_with(&[
            ("ENVIRONMENT", "local"),
            ("NODE_SECRET_BACKEND", "memory"),
            ("COLD_STORAGE_BUCKET", "   "),
        ]);
        assert_eq!(
            local_blank.cold_storage_startup_mode(),
            ColdStorageStartupMode::S3
        );

        let non_local_absent = snapshot_with(&[]);
        assert_eq!(
            non_local_absent.cold_storage_startup_mode(),
            ColdStorageStartupMode::S3
        );
    }

    /// Cold storage family returns correct state for absent, blank, partial, and fully-explicit configs.
    #[test]
    fn cold_storage_family_classification_distinguishes_absent_blank_and_partial() {
        let absent = snapshot_with(&[]);
        assert_eq!(
            absent.cold_storage_family_state(),
            RawEnvFamilyState::AllAbsent
        );

        let blank = snapshot_with(&[("COLD_STORAGE_BUCKET", " ")]);
        assert_eq!(
            blank.cold_storage_family_state(),
            RawEnvFamilyState::HasBlankValues
        );

        let partial = snapshot_with(&[("COLD_STORAGE_BUCKET", "fjcloud-cold")]);
        assert_eq!(
            partial.cold_storage_family_state(),
            RawEnvFamilyState::PartiallyExplicit
        );

        let full = snapshot_with(&[
            ("COLD_STORAGE_BUCKET", "bucket-a"),
            ("COLD_STORAGE_PREFIX", "prefix-a"),
            ("COLD_STORAGE_REGION", "us-east-1"),
            ("COLD_STORAGE_ENDPOINT", "https://s3.example.com"),
            ("COLD_STORAGE_REGIONS", "{}"),
            ("COLD_STORAGE_ACCESS_KEY", "access-a"),
            ("COLD_STORAGE_SECRET_KEY", "secret-a"),
        ]);
        assert_eq!(
            full.cold_storage_family_state(),
            RawEnvFamilyState::FullyExplicit
        );
    }

    /// STORAGE_ENCRYPTION_KEY returns correct value state for absent, blank, and present.
    #[test]
    fn storage_key_state_distinguishes_absent_blank_and_present() {
        let absent = snapshot_with(&[]);
        assert_eq!(
            absent.storage_encryption_key_state(),
            RawEnvValueState::Absent
        );

        let blank = snapshot_with(&[("STORAGE_ENCRYPTION_KEY", "   ")]);
        assert_eq!(
            blank.storage_encryption_key_state(),
            RawEnvValueState::Blank
        );

        let present = snapshot_with(&[("STORAGE_ENCRYPTION_KEY", "abcd")]);
        assert_eq!(
            present.storage_encryption_key_state(),
            RawEnvValueState::Present
        );
        assert_eq!(present.storage_encryption_key_raw(), Some("abcd"));
    }

    #[test]
    fn env_value_returns_snapshot_values_by_name() {
        let snapshot = snapshot_with(&[
            ("SES_REGION", "us-east-1"),
            ("SES_CONFIGURATION_SET", "ses-feedback"),
            ("EMAIL_FROM_NAME", "Billing Team"),
            ("COLD_STORAGE_BUCKET", "fjcloud-cold"),
            ("COLD_STORAGE_ACCESS_KEY", "access-a"),
            ("SLACK_WEBHOOK_URL", "https://slack.test/hook"),
            ("DISCORD_WEBHOOK_URL", "https://discord.test/hook"),
        ]);

        assert_eq!(snapshot.env_value("SES_REGION"), Some("us-east-1"));
        assert_eq!(
            snapshot.env_value("SES_CONFIGURATION_SET"),
            Some("ses-feedback")
        );
        assert_eq!(snapshot.env_value("EMAIL_FROM_NAME"), Some("Billing Team"));
        assert_eq!(
            snapshot.env_value("COLD_STORAGE_BUCKET"),
            Some("fjcloud-cold")
        );
        assert_eq!(
            snapshot.env_value("COLD_STORAGE_ACCESS_KEY"),
            Some("access-a")
        );
        assert_eq!(
            snapshot.env_value("SLACK_WEBHOOK_URL"),
            Some("https://slack.test/hook")
        );
        assert_eq!(
            snapshot.env_value("DISCORD_WEBHOOK_URL"),
            Some("https://discord.test/hook")
        );
        assert_eq!(snapshot.env_value("MISSING_KEY"), None);
    }

    /// COLD_STORAGE_REGIONS returns correct value state for absent, blank, and present.
    #[test]
    fn cold_storage_regions_state_distinguishes_absent_blank_and_present() {
        let absent = snapshot_with(&[]);
        assert_eq!(
            absent.cold_storage_regions_state(),
            RawEnvValueState::Absent
        );

        let blank = snapshot_with(&[("COLD_STORAGE_REGIONS", "   ")]);
        assert_eq!(blank.cold_storage_regions_state(), RawEnvValueState::Blank);

        let present = snapshot_with(&[("COLD_STORAGE_REGIONS", "{}")]);
        assert_eq!(
            present.cold_storage_regions_state(),
            RawEnvValueState::Present
        );
    }

    /// Deterministic dev key only activates in local zero-dep mode with STORAGE_ENCRYPTION_KEY absent.
    #[test]
    fn storage_key_startup_mode_dev_key_only_for_local_mode_with_absent_key() {
        // memory + absent → DevKey
        let local_absent =
            snapshot_with(&[("ENVIRONMENT", "local"), ("NODE_SECRET_BACKEND", "memory")]);
        assert_eq!(
            local_absent.storage_key_startup_mode(),
            StorageKeyStartupMode::DevKey
        );

        // memory + blank → Parse (blank is explicit operator input)
        let local_blank = snapshot_with(&[
            ("ENVIRONMENT", "local"),
            ("NODE_SECRET_BACKEND", "memory"),
            ("STORAGE_ENCRYPTION_KEY", "   "),
        ]);
        assert_eq!(
            local_blank.storage_key_startup_mode(),
            StorageKeyStartupMode::Parse
        );

        // memory + present → Parse
        let local_present = snapshot_with(&[
            ("ENVIRONMENT", "local"),
            ("NODE_SECRET_BACKEND", "memory"),
            ("STORAGE_ENCRYPTION_KEY", "abcd1234"),
        ]);
        assert_eq!(
            local_present.storage_key_startup_mode(),
            StorageKeyStartupMode::Parse
        );

        // non-memory + absent → Parse
        let non_local_absent = snapshot_with(&[]);
        assert_eq!(
            non_local_absent.storage_key_startup_mode(),
            StorageKeyStartupMode::Parse
        );

        // non-memory + present → Parse
        let non_local_present = snapshot_with(&[("STORAGE_ENCRYPTION_KEY", "abcd1234")]);
        assert_eq!(
            non_local_present.storage_key_startup_mode(),
            StorageKeyStartupMode::Parse
        );
    }
}
