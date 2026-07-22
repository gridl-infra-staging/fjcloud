pub mod cloudflare;
pub mod mock;
pub mod route53;

use async_trait::async_trait;
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DnsARecord {
    pub hostname: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, thiserror::Error)]
pub enum DnsError {
    #[error("DNS API error: {0}")]
    Api(String),

    #[error("DNS manager not configured")]
    NotConfigured,

    #[error("DNS record not found: {0}")]
    RecordNotFound(String),

    #[error("DNS record listing is not supported")]
    ListingUnsupported,
}

#[async_trait]
pub trait DnsManager: Send + Sync {
    /// Create or upsert an A record for the given hostname pointing to the given IP.
    async fn create_record(&self, hostname: &str, ip: &str) -> Result<(), DnsError>;

    /// Delete the A record for the given hostname. Idempotent — returns Ok if not found.
    async fn delete_record(&self, hostname: &str) -> Result<(), DnsError>;

    /// Enumerate every A record owned by this manager. Implementations that do
    /// not provide a complete read-only listing must fail closed.
    async fn list_a_records(&self) -> Result<Vec<DnsARecord>, DnsError> {
        Err(DnsError::ListingUnsupported)
    }
}

/// Returns `DnsError::NotConfigured` for all methods.
/// Used in dev mode when `DNS_HOSTED_ZONE_ID` is not set.
pub struct UnconfiguredDnsManager;

#[async_trait]
impl DnsManager for UnconfiguredDnsManager {
    async fn create_record(&self, _hostname: &str, _ip: &str) -> Result<(), DnsError> {
        Err(DnsError::NotConfigured)
    }

    async fn delete_record(&self, _hostname: &str) -> Result<(), DnsError> {
        Err(DnsError::NotConfigured)
    }
}

fn hostname_for_domain(domain: &str, hostname: &str) -> String {
    let trimmed = hostname.trim_end_matches('.');
    if trimmed == domain || trimmed.ends_with(&format!(".{domain}")) {
        trimmed.to_string()
    } else {
        format!("{trimmed}.{domain}")
    }
}
