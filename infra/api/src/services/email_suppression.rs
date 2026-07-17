use async_trait::async_trait;
use sqlx::PgPool;
use std::collections::HashSet;
use std::sync::Mutex;

/// Normalize an email address to the canonical suppression lookup key.
///
/// Stage 2 contract: suppression state uses one lowercase+trimmed key shape,
/// shared by outbound checks and webhook ingestion upserts.
pub fn normalize_recipient_email(recipient_email: &str) -> String {
    recipient_email.trim().to_ascii_lowercase()
}

#[async_trait]
pub trait EmailSuppressionStore: Send + Sync {
    async fn is_suppressed(&self, recipient_email: &str) -> Result<bool, String>;

    async fn upsert_suppressed_recipient(
        &self,
        recipient_email: &str,
        suppression_reason: &str,
        source: &str,
    ) -> Result<(), String>;
}

pub struct PgEmailSuppressionStore {
    pool: PgPool,
}

impl PgEmailSuppressionStore {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl EmailSuppressionStore for PgEmailSuppressionStore {
    async fn is_suppressed(&self, recipient_email: &str) -> Result<bool, String> {
        let normalized = normalize_recipient_email(recipient_email);
        if normalized.is_empty() {
            return Ok(false);
        }

        sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(SELECT 1 FROM email_suppression WHERE recipient_email = $1)",
        )
        .bind(normalized)
        .fetch_one(&self.pool)
        .await
        .map_err(|error| format!("email suppression lookup failed: {error}"))
    }

    async fn upsert_suppressed_recipient(
        &self,
        recipient_email: &str,
        suppression_reason: &str,
        source: &str,
    ) -> Result<(), String> {
        let normalized = normalize_recipient_email(recipient_email);
        if normalized.is_empty() {
            return Err("suppression recipient email must not normalize to empty".to_string());
        }

        sqlx::query(
            "INSERT INTO email_suppression (recipient_email, suppression_reason, source) \
             VALUES ($1, $2, $3) \
             ON CONFLICT (recipient_email) DO UPDATE SET \
                 suppression_reason = EXCLUDED.suppression_reason, \
                 source = EXCLUDED.source, \
                 updated_at = NOW()",
        )
        .bind(normalized)
        .bind(suppression_reason)
        .bind(source)
        .execute(&self.pool)
        .await
        .map_err(|error| format!("email suppression upsert failed: {error}"))?;

        Ok(())
    }
}

#[derive(Default)]
pub struct InMemoryEmailSuppressionStore {
    recipients: Mutex<HashSet<String>>,
}

impl InMemoryEmailSuppressionStore {
    pub fn new_with_recipients<I, S>(recipients: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let normalized_recipients = recipients
            .into_iter()
            .map(|value| normalize_recipient_email(value.as_ref()))
            .filter(|value| !value.is_empty())
            .collect::<HashSet<String>>();
        Self {
            recipients: Mutex::new(normalized_recipients),
        }
    }

    pub fn insert_recipient(&self, recipient_email: &str) {
        let normalized = normalize_recipient_email(recipient_email);
        if normalized.is_empty() {
            return;
        }
        self.recipients.lock().unwrap().insert(normalized);
    }
}

#[async_trait]
impl EmailSuppressionStore for InMemoryEmailSuppressionStore {
    async fn is_suppressed(&self, recipient_email: &str) -> Result<bool, String> {
        let normalized = normalize_recipient_email(recipient_email);
        Ok(!normalized.is_empty() && self.recipients.lock().unwrap().contains(&normalized))
    }

    async fn upsert_suppressed_recipient(
        &self,
        recipient_email: &str,
        _suppression_reason: &str,
        _source: &str,
    ) -> Result<(), String> {
        self.insert_recipient(recipient_email);
        Ok(())
    }
}
