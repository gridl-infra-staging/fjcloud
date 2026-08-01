use anyhow::Result;
use sqlx::postgres::PgPool;

pub async fn create_pool(database_url: &str) -> Result<PgPool> {
    database_url::validate_database_url_tls(database_url).map_err(anyhow::Error::msg)?;
    let pool = PgPool::connect(database_url).await?;
    Ok(pool)
}
