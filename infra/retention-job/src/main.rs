use anyhow::Result;
use retention_job::{config::Config, job};
use tracing::info;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("retention_job=info".parse().unwrap()),
        )
        .init();

    let cfg = Config::from_env().map_err(|err| anyhow::anyhow!("{err}"))?;
    info!(
        retention_days = cfg.retention_days,
        dry_run = cfg.dry_run,
        max_erase_per_run = cfg.max_erase_per_run,
        "retention job starting"
    );

    database_url::validate_database_url_tls(&cfg.database_url).map_err(anyhow::Error::msg)?;
    let pool = sqlx::PgPool::connect(&cfg.database_url).await?;
    let summary = job::run_from_config(&cfg, pool.clone()).await?;
    pool.close().await;

    println!("{}", summary.json_line());
    Ok(())
}
