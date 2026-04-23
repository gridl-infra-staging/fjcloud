pub mod mock;
pub mod route53;

use async_trait::async_trait;

#[derive(Debug, thiserror::Error)]
pub enum DnsError {
    #[error("DNS API error: {0}")]
    Api(String),

    #[error("DNS manager not configured")]
    NotConfigured,

    #[error("DNS record not found: {0}")]
    RecordNotFound(String),
}

#[async_trait]
pub trait DnsManager: Send + Sync {
    /// Create or upsert an A record for the given hostname pointing to the given IP.
    async fn create_record(&self, hostname: &str, ip: &str) -> Result<(), DnsError>;

    /// Delete the A record for the given hostname. Idempotent — returns Ok if not found.
    async fn delete_record(&self, hostname: &str) -> Result<(), DnsError>;
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
