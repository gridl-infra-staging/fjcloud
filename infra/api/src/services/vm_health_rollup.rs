use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

use crate::models::CustomerTenant;
use crate::repos::{DeploymentRepo, RepoError};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum VmHealth {
    Healthy,
    Unhealthy,
    Unknown,
}

pub fn vm_health_rollup(deployment_healths: &[&str]) -> VmHealth {
    if deployment_healths.contains(&"unhealthy") {
        return VmHealth::Unhealthy;
    }

    // A VM with no deployments has no health evidence, so shared capacity must not appear healthy.
    if deployment_healths.is_empty() {
        return VmHealth::Unknown;
    }

    if deployment_healths.iter().all(|health| *health == "healthy") {
        VmHealth::Healthy
    } else {
        VmHealth::Unknown
    }
}

pub async fn health_rollup_for_tenants(
    tenants: &[CustomerTenant],
    deployment_repo: &(dyn DeploymentRepo + Send + Sync),
) -> Result<VmHealth, RepoError> {
    let deployment_ids: BTreeSet<_> = tenants.iter().map(|tenant| tenant.deployment_id).collect();
    let mut deployment_healths = Vec::with_capacity(deployment_ids.len());
    for deployment_id in deployment_ids {
        if let Some(deployment) = deployment_repo.find_by_id(deployment_id).await? {
            deployment_healths.push(deployment.health_status);
        }
    }
    let deployment_health_refs: Vec<_> = deployment_healths.iter().map(String::as_str).collect();
    Ok(vm_health_rollup(&deployment_health_refs))
}

pub fn health_rollup_from_deployment_healths(
    tenants: &[CustomerTenant],
    deployment_healths_by_id: &BTreeMap<uuid::Uuid, String>,
) -> VmHealth {
    let deployment_ids: BTreeSet<_> = tenants.iter().map(|tenant| tenant.deployment_id).collect();
    let deployment_healths = deployment_ids
        .iter()
        .filter_map(|deployment_id| deployment_healths_by_id.get(deployment_id))
        .map(String::as_str)
        .collect::<Vec<_>>();

    // Delegate classification so `vm_health_rollup` remains the single health-rule owner.
    vm_health_rollup(&deployment_healths)
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, HashMap};
    use std::sync::Mutex;

    use async_trait::async_trait;
    use chrono::{DateTime, Utc};
    use uuid::Uuid;

    use super::*;
    use crate::models::{CustomerTenant, Deployment};
    use crate::repos::{DeploymentRepo, RepoError};

    struct FakeDeploymentRepo {
        deployments: Mutex<HashMap<Uuid, Deployment>>,
        find_calls: Mutex<Vec<Uuid>>,
    }

    impl FakeDeploymentRepo {
        fn new(deployments: Vec<Deployment>) -> Self {
            Self {
                deployments: Mutex::new(
                    deployments
                        .into_iter()
                        .map(|deployment| (deployment.id, deployment))
                        .collect(),
                ),
                find_calls: Mutex::new(Vec::new()),
            }
        }

        fn find_calls(&self) -> Vec<Uuid> {
            self.find_calls.lock().unwrap().clone()
        }
    }

    #[async_trait]
    impl DeploymentRepo for FakeDeploymentRepo {
        async fn list_by_customer(
            &self,
            _customer_id: Uuid,
            _include_terminated: bool,
        ) -> Result<Vec<Deployment>, RepoError> {
            unimplemented!("not needed by vm health rollup tests")
        }

        async fn find_by_id(&self, id: Uuid) -> Result<Option<Deployment>, RepoError> {
            self.find_calls.lock().unwrap().push(id);
            Ok(self.deployments.lock().unwrap().get(&id).cloned())
        }

        async fn find_by_ids(&self, ids: &[Uuid]) -> Result<Vec<Deployment>, RepoError> {
            let deployments = self.deployments.lock().unwrap();
            Ok(ids
                .iter()
                .filter_map(|id| deployments.get(id).cloned())
                .collect())
        }

        async fn create(
            &self,
            _customer_id: Uuid,
            _node_id: &str,
            _region: &str,
            _vm_type: &str,
            _vm_provider: &str,
            _ip_address: Option<&str>,
        ) -> Result<Deployment, RepoError> {
            unimplemented!("not needed by vm health rollup tests")
        }

        async fn update(
            &self,
            _id: Uuid,
            _ip_address: Option<&str>,
            _status: Option<&str>,
        ) -> Result<Option<Deployment>, RepoError> {
            unimplemented!("not needed by vm health rollup tests")
        }

        async fn terminate(&self, _id: Uuid) -> Result<bool, RepoError> {
            unimplemented!("not needed by vm health rollup tests")
        }

        async fn list_active(&self) -> Result<Vec<Deployment>, RepoError> {
            unimplemented!("not needed by vm health rollup tests")
        }

        async fn update_health(
            &self,
            _id: Uuid,
            _health_status: &str,
            _last_health_check_at: DateTime<Utc>,
        ) -> Result<(), RepoError> {
            unimplemented!("not needed by vm health rollup tests")
        }

        async fn claim_provisioning(&self, _id: Uuid) -> Result<bool, RepoError> {
            unimplemented!("not needed by vm health rollup tests")
        }

        async fn mark_failed_provisioning(
            &self,
            _id: Uuid,
            _failure_reason: Option<&str>,
        ) -> Result<bool, RepoError> {
            unimplemented!("not needed by vm health rollup tests")
        }

        async fn update_provisioning(
            &self,
            _id: Uuid,
            _provider_vm_id: &str,
            _ip_address: &str,
            _hostname: &str,
            _flapjack_url: &str,
        ) -> Result<Option<Deployment>, RepoError> {
            unimplemented!("not needed by vm health rollup tests")
        }
    }

    fn deployment(id: Uuid, health_status: &str) -> Deployment {
        Deployment {
            id,
            customer_id: Uuid::new_v4(),
            node_id: format!("node-{id}"),
            region: "us-east-1".to_string(),
            vm_type: "shared".to_string(),
            vm_provider: "aws".to_string(),
            ip_address: None,
            status: "running".to_string(),
            failure_reason: None,
            created_at: Utc::now(),
            terminated_at: None,
            provider_vm_id: None,
            hostname: None,
            flapjack_url: Some("http://vm.test:7700".to_string()),
            last_health_check_at: None,
            health_status: health_status.to_string(),
        }
    }

    fn tenant(customer_id: Uuid, tenant_id: &str, deployment_id: Uuid) -> CustomerTenant {
        CustomerTenant {
            customer_id,
            tenant_id: tenant_id.to_string(),
            deployment_id,
            created_at: Utc::now(),
            vm_id: Some(Uuid::new_v4()),
            tier: "active".to_string(),
            last_accessed_at: None,
            cold_snapshot_id: None,
            resource_quota: serde_json::json!({}),
            service_type: "flapjack".to_string(),
        }
    }

    #[tokio::test]
    async fn health_rollup_for_tenants_deduplicates_deployments_before_classifying() {
        let healthy_id = Uuid::new_v4();
        let unhealthy_id = Uuid::new_v4();
        let repo = FakeDeploymentRepo::new(vec![
            deployment(healthy_id, "healthy"),
            deployment(unhealthy_id, "unhealthy"),
        ]);
        let customer_id = Uuid::new_v4();
        let tenants = vec![
            tenant(customer_id, "products", healthy_id),
            tenant(customer_id, "orders", healthy_id),
            tenant(customer_id, "logs", unhealthy_id),
        ];

        let health = health_rollup_for_tenants(&tenants, &repo).await.unwrap();
        let mut find_calls = repo.find_calls();
        find_calls.sort();

        assert_eq!(health, VmHealth::Unhealthy);
        let mut expected_calls = vec![healthy_id, unhealthy_id];
        expected_calls.sort();
        assert_eq!(find_calls, expected_calls);
    }

    #[test]
    fn health_rollup_from_deployment_healths_deduplicates_and_ignores_missing_ids() {
        let healthy_id = Uuid::new_v4();
        let missing_id = Uuid::new_v4();
        let customer_id = Uuid::new_v4();
        let tenants = vec![
            tenant(customer_id, "products", healthy_id),
            tenant(customer_id, "orders", healthy_id),
            tenant(customer_id, "logs", missing_id),
        ];
        let deployment_healths = BTreeMap::from([(healthy_id, "healthy".to_string())]);

        let health = health_rollup_from_deployment_healths(&tenants, &deployment_healths);

        assert_eq!(health, VmHealth::Healthy);
    }

    #[test]
    fn health_rollup_from_deployment_healths_classifies_mixed_values() {
        let healthy_id = Uuid::new_v4();
        let unhealthy_id = Uuid::new_v4();
        let unknown_id = Uuid::new_v4();
        let customer_id = Uuid::new_v4();
        let tenants = vec![
            tenant(customer_id, "products", healthy_id),
            tenant(customer_id, "orders", unhealthy_id),
            tenant(customer_id, "logs", unknown_id),
        ];
        let deployment_healths = BTreeMap::from([
            (healthy_id, "healthy".to_string()),
            (unhealthy_id, "unhealthy".to_string()),
            (unknown_id, "unknown".to_string()),
        ]);

        let health = health_rollup_from_deployment_healths(&tenants, &deployment_healths);

        assert_eq!(health, VmHealth::Unhealthy);
    }

    #[test]
    fn health_rollup_from_deployment_healths_returns_unknown_without_evidence() {
        let customer_id = Uuid::new_v4();
        let tenants = vec![tenant(customer_id, "products", Uuid::new_v4())];
        let deployment_healths = BTreeMap::new();

        let health = health_rollup_from_deployment_healths(&tenants, &deployment_healths);

        assert_eq!(health, VmHealth::Unknown);
    }
}
