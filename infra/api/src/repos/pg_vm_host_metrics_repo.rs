use async_trait::async_trait;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::{NewVmHostMetrics, VmHostMetrics};
use crate::repos::{RepoError, VmHostMetricsRepo};

pub struct PgVmHostMetricsRepo {
    pool: PgPool,
}

impl PgVmHostMetricsRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl VmHostMetricsRepo for PgVmHostMetricsRepo {
    async fn insert(&self, metrics: &NewVmHostMetrics) -> Result<VmHostMetrics, RepoError> {
        sqlx::query_as::<_, VmHostMetrics>(
            "INSERT INTO vm_host_metrics
             (vm_id, collected_at, cpu_pct, mem_used_bytes, mem_total_bytes,
              disk_used_bytes, disk_total_bytes, net_rx_bytes, net_tx_bytes)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
             RETURNING *",
        )
        .bind(metrics.vm_id)
        .bind(metrics.collected_at)
        .bind(metrics.cpu_pct)
        .bind(metrics.mem_used_bytes)
        .bind(metrics.mem_total_bytes)
        .bind(metrics.disk_used_bytes)
        .bind(metrics.disk_total_bytes)
        .bind(metrics.net_rx_bytes)
        .bind(metrics.net_tx_bytes)
        .fetch_one(&self.pool)
        .await
        .map_err(|error| RepoError::Other(error.to_string()))
    }

    async fn latest_for_vm(&self, vm_id: Uuid) -> Result<Option<VmHostMetrics>, RepoError> {
        sqlx::query_as::<_, VmHostMetrics>(
            "SELECT *
             FROM vm_host_metrics
             WHERE vm_id = $1
             ORDER BY collected_at DESC
             LIMIT 1",
        )
        .bind(vm_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|error| RepoError::Other(error.to_string()))
    }
}
