//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/in_memory_index_replica_repo.rs.
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use std::sync::Mutex;
use uuid::Uuid;

use crate::models::index_replica::IndexReplica;
use crate::repos::error::RepoError;
use crate::repos::index_replica_repo::IndexReplicaRepo;

pub struct InMemoryIndexReplicaRepo {
    replicas: Mutex<Vec<IndexReplica>>,
}

impl InMemoryIndexReplicaRepo {
    pub fn new() -> Self {
        Self {
            replicas: Mutex::new(Vec::new()),
        }
    }

    /// Test helper: set `updated_at` on a replica to simulate stale timestamps.
    pub fn set_updated_at(&self, id: Uuid, ts: DateTime<Utc>) {
        let mut replicas = self.replicas.lock().unwrap();
        if let Some(r) = replicas.iter_mut().find(|r| r.id == id) {
            r.updated_at = ts;
        }
    }
}

impl Default for InMemoryIndexReplicaRepo {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl IndexReplicaRepo for InMemoryIndexReplicaRepo {
    /// In-memory replica creation for tests/local dev. Enforces unique
    /// constraint on (customer_id, tenant_id, replica_vm_id) via Vec scan.
    /// Initial status is "provisioning".
    async fn create(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        primary_vm_id: Uuid,
        replica_vm_id: Uuid,
        replica_region: &str,
    ) -> Result<IndexReplica, RepoError> {
        let mut replicas = self.replicas.lock().unwrap();

        // Enforce unique constraint: (customer_id, tenant_id, replica_vm_id)
        if replicas.iter().any(|r| {
            r.customer_id == customer_id
                && r.tenant_id == tenant_id
                && r.replica_vm_id == replica_vm_id
        }) {
            return Err(RepoError::Conflict(
                "replica already exists on this VM".into(),
            ));
        }

        let now = Utc::now();
        let replica = IndexReplica {
            id: Uuid::new_v4(),
            customer_id,
            tenant_id: tenant_id.to_string(),
            primary_vm_id,
            replica_vm_id,
            replica_region: replica_region.to_string(),
            status: "provisioning".to_string(),
            lag_ops: 0,
            created_at: now,
            updated_at: now,
        };

        replicas.push(replica.clone());
        Ok(replica)
    }

    async fn get(&self, id: Uuid) -> Result<Option<IndexReplica>, RepoError> {
        let replicas = self.replicas.lock().unwrap();
        Ok(replicas.iter().find(|r| r.id == id).cloned())
    }

    async fn list_by_index(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Vec<IndexReplica>, RepoError> {
        let replicas = self.replicas.lock().unwrap();
        Ok(replicas
            .iter()
            .filter(|r| r.customer_id == customer_id && r.tenant_id == tenant_id)
            .cloned()
            .collect())
    }

    async fn list_healthy_by_index(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Vec<IndexReplica>, RepoError> {
        let replicas = self.replicas.lock().unwrap();
        Ok(replicas
            .iter()
            .filter(|r| {
                r.customer_id == customer_id && r.tenant_id == tenant_id && r.status == "active"
            })
            .cloned()
            .collect())
    }

    async fn set_status(&self, id: Uuid, status: &str) -> Result<(), RepoError> {
        let mut replicas = self.replicas.lock().unwrap();
        if let Some(r) = replicas.iter_mut().find(|r| r.id == id) {
            r.status = status.to_string();
            r.updated_at = Utc::now();
            Ok(())
        } else {
            Err(RepoError::NotFound)
        }
    }

    async fn set_lag(&self, id: Uuid, lag_ops: i64) -> Result<(), RepoError> {
        let mut replicas = self.replicas.lock().unwrap();
        if let Some(r) = replicas.iter_mut().find(|r| r.id == id) {
            r.lag_ops = lag_ops;
            Ok(())
        } else {
            Err(RepoError::NotFound)
        }
    }

    async fn delete(&self, id: Uuid) -> Result<bool, RepoError> {
        let mut replicas = self.replicas.lock().unwrap();
        let len_before = replicas.len();
        replicas.retain(|r| r.id != id);
        Ok(replicas.len() < len_before)
    }

    async fn count_by_index(&self, customer_id: Uuid, tenant_id: &str) -> Result<i64, RepoError> {
        let replicas = self.replicas.lock().unwrap();
        Ok(replicas
            .iter()
            .filter(|r| r.customer_id == customer_id && r.tenant_id == tenant_id)
            .count() as i64)
    }

    async fn list_actionable(&self) -> Result<Vec<IndexReplica>, RepoError> {
        let replicas = self.replicas.lock().unwrap();
        Ok(replicas
            .iter()
            .filter(|r| r.status != "failed" && r.status != "removing" && r.status != "suspended")
            .cloned()
            .collect())
    }

    async fn list_all(&self) -> Result<Vec<IndexReplica>, RepoError> {
        let replicas = self.replicas.lock().unwrap();
        Ok(replicas.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cid() -> Uuid {
        Uuid::parse_str("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa").unwrap()
    }
    fn vm1() -> Uuid {
        Uuid::parse_str("11111111-1111-1111-1111-111111111111").unwrap()
    }
    fn vm2() -> Uuid {
        Uuid::parse_str("22222222-2222-2222-2222-222222222222").unwrap()
    }
    fn vm3() -> Uuid {
        Uuid::parse_str("33333333-3333-3333-3333-333333333333").unwrap()
    }

    #[tokio::test]
    async fn create_and_get_roundtrip() {
        let repo = InMemoryIndexReplicaRepo::new();
        let r = repo
            .create(cid(), "idx", vm1(), vm2(), "us-east-1")
            .await
            .unwrap();
        assert_eq!(r.status, "provisioning");
        assert_eq!(r.lag_ops, 0);
        let fetched = repo.get(r.id).await.unwrap().unwrap();
        assert_eq!(fetched.tenant_id, "idx");
    }

    #[tokio::test]
    async fn get_missing_returns_none() {
        let repo = InMemoryIndexReplicaRepo::new();
        assert!(repo.get(Uuid::new_v4()).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn unique_constraint_on_customer_tenant_vm() {
        let repo = InMemoryIndexReplicaRepo::new();
        repo.create(cid(), "idx", vm1(), vm2(), "us-east-1")
            .await
            .unwrap();
        let err = repo
            .create(cid(), "idx", vm1(), vm2(), "us-east-1")
            .await
            .unwrap_err();
        assert!(matches!(err, RepoError::Conflict(_)));
    }

    #[tokio::test]
    async fn same_tenant_different_replica_vm_allowed() {
        let repo = InMemoryIndexReplicaRepo::new();
        repo.create(cid(), "idx", vm1(), vm2(), "us-east-1")
            .await
            .unwrap();
        repo.create(cid(), "idx", vm1(), vm3(), "eu-west-1")
            .await
            .unwrap();
        assert_eq!(repo.count_by_index(cid(), "idx").await.unwrap(), 2);
    }

    #[tokio::test]
    async fn list_by_index_filters_correctly() {
        let repo = InMemoryIndexReplicaRepo::new();
        repo.create(cid(), "a", vm1(), vm2(), "r").await.unwrap();
        repo.create(cid(), "b", vm1(), vm2(), "r").await.unwrap();
        assert_eq!(repo.list_by_index(cid(), "a").await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn list_healthy_filters_by_active_status() {
        let repo = InMemoryIndexReplicaRepo::new();
        let r1 = repo.create(cid(), "idx", vm1(), vm2(), "r").await.unwrap();
        let r2 = repo.create(cid(), "idx", vm1(), vm3(), "r").await.unwrap();
        repo.set_status(r1.id, "active").await.unwrap();
        repo.set_status(r2.id, "failed").await.unwrap();
        let healthy = repo.list_healthy_by_index(cid(), "idx").await.unwrap();
        assert_eq!(healthy.len(), 1);
        assert_eq!(healthy[0].id, r1.id);
    }

    #[tokio::test]
    async fn set_status_missing_returns_not_found() {
        let repo = InMemoryIndexReplicaRepo::new();
        assert!(matches!(
            repo.set_status(Uuid::new_v4(), "active").await,
            Err(RepoError::NotFound)
        ));
    }

    #[tokio::test]
    async fn set_lag_updates_value() {
        let repo = InMemoryIndexReplicaRepo::new();
        let r = repo.create(cid(), "idx", vm1(), vm2(), "r").await.unwrap();
        repo.set_lag(r.id, 42).await.unwrap();
        assert_eq!(repo.get(r.id).await.unwrap().unwrap().lag_ops, 42);
    }

    #[tokio::test]
    async fn delete_removes_and_returns_true() {
        let repo = InMemoryIndexReplicaRepo::new();
        let r = repo.create(cid(), "idx", vm1(), vm2(), "r").await.unwrap();
        assert!(repo.delete(r.id).await.unwrap());
        assert!(repo.get(r.id).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn delete_missing_returns_false() {
        let repo = InMemoryIndexReplicaRepo::new();
        assert!(!repo.delete(Uuid::new_v4()).await.unwrap());
    }

    #[tokio::test]
    async fn list_actionable_excludes_failed_and_removing() {
        let repo = InMemoryIndexReplicaRepo::new();
        let r1 = repo.create(cid(), "a", vm1(), vm2(), "r").await.unwrap();
        let r2 = repo.create(cid(), "b", vm1(), vm2(), "r").await.unwrap();
        let r3 = repo.create(cid(), "c", vm1(), vm2(), "r").await.unwrap();
        repo.set_status(r1.id, "active").await.unwrap();
        repo.set_status(r2.id, "failed").await.unwrap();
        repo.set_status(r3.id, "removing").await.unwrap();
        let actionable = repo.list_actionable().await.unwrap();
        assert_eq!(actionable.len(), 1);
        assert_eq!(actionable[0].id, r1.id);
    }

    #[tokio::test]
    async fn list_actionable_excludes_suspended() {
        let repo = InMemoryIndexReplicaRepo::new();
        let r1 = repo.create(cid(), "a", vm1(), vm2(), "r").await.unwrap();
        let r2 = repo.create(cid(), "b", vm1(), vm3(), "r").await.unwrap();
        repo.set_status(r1.id, "active").await.unwrap();
        repo.set_status(r2.id, "suspended").await.unwrap();
        let actionable = repo.list_actionable().await.unwrap();
        assert_eq!(actionable.len(), 1);
        assert_eq!(actionable[0].id, r1.id);
    }

    #[tokio::test]
    async fn default_trait() {
        let repo = InMemoryIndexReplicaRepo::default();
        assert_eq!(repo.list_all().await.unwrap().len(), 0);
    }
}
