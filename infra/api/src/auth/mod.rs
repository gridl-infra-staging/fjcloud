pub mod admin;
pub mod api_key;
pub mod claims;
pub mod error;
pub mod storage;
pub mod tenant;

use std::collections::HashSet;
use std::sync::OnceLock;

pub use crate::services::storage::s3_auth::S3AuthContext;
pub use admin::AdminAuth;
pub use api_key::ApiKeyAuth;
pub use claims::Claims;
pub use error::AuthError;
pub use tenant::AuthenticatedTenant;

static DISPOSABLE_EMAIL_DOMAINS: OnceLock<HashSet<&'static str>> = OnceLock::new();

pub fn is_disposable_email_domain(domain: &str) -> bool {
    DISPOSABLE_EMAIL_DOMAINS
        .get_or_init(load_disposable_email_domains)
        .contains(domain)
}

fn load_disposable_email_domains() -> HashSet<&'static str> {
    include_str!("disposable_email_domains.txt")
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .collect()
}
