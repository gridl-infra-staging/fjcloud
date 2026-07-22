use async_trait::async_trait;
use uuid::Uuid;

use crate::models::{NewVmHostMetrics, VmHostMetrics};
use crate::repos::RepoError;

#[async_trait]
pub trait VmHostMetricsRepo {
    async fn insert(&self, metrics: &NewVmHostMetrics) -> Result<VmHostMetrics, RepoError>;

    async fn latest_for_vm(&self, vm_id: Uuid) -> Result<Option<VmHostMetrics>, RepoError>;
}
