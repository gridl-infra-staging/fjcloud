//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/aggregation-job/src/main.rs.
mod config;
mod rollup;

use anyhow::Result;
use config::Config;
use tracing::info;

/// Program entry point for the daily rollup job: initialize structured logging, load env config, open PostgreSQL, execute run, and report affected rows.
#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("aggregation_job=info".parse().unwrap()),
        )
        .init();

    let cfg = Config::from_env().map_err(|e| anyhow::anyhow!("{}", e))?;

    info!(
        target_date = %cfg.target_date,
        "aggregation job starting"
    );

    let pool = sqlx::PgPool::connect(&cfg.database_url).await?;
    let rows_affected = run(&cfg, &pool).await?;
    pool.close().await;

    info!(
        target_date = %cfg.target_date,
        rows_affected,
        "aggregation complete"
    );

    Ok(())
}

async fn run(cfg: &Config, pool: &sqlx::PgPool) -> Result<u64> {
    let (window_start, window_end) = rollup::day_window(cfg.target_date);

    let result = sqlx::query(rollup::ROLLUP_SQL)
        .bind(window_start)
        .bind(window_end)
        .bind(cfg.target_date)
        .execute(pool)
        .await?;

    Ok(result.rows_affected())
}
