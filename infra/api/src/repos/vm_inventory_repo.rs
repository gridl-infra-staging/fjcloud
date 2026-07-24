use async_trait::async_trait;
use uuid::Uuid;

use crate::models::vm_inventory::{NewVmInventory, VmInventory};
use crate::repos::advisory_lock::{in_process_advisory_lock, AdvisoryLockGuard};
use crate::repos::error::RepoError;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, sqlx::FromRow)]
pub struct VmRetirementBlocker {
    pub owner: String,
    pub reference_column: String,
    pub count: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum VmRetirementConflict {
    UnknownVm {
        vm_id: Uuid,
    },
    HostnameMismatch {
        expected_hostname: String,
        actual_hostname: String,
    },
    InvalidStatus {
        actual_status: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "status", content = "details", rename_all = "snake_case")]
pub enum VmRetirementAssessment {
    Eligible,
    Blocked(Vec<VmRetirementBlocker>),
    Conflict(VmRetirementConflict),
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "status", content = "details", rename_all = "snake_case")]
pub enum VmDecommissionResult {
    Decommissioned,
    AlreadyDecommissioned,
    Blocked(Vec<VmRetirementBlocker>),
    Conflict(VmRetirementConflict),
}

#[doc(hidden)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VmRetirementCandidateStatus {
    Active,
    Decommissioned,
}

impl VmRetirementCandidateStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Decommissioned => "decommissioned",
        }
    }
}

/// Shared identity/status validation for repository implementations and test doubles.
#[doc(hidden)]
pub fn validate_vm_retirement_candidate(
    id: Uuid,
    expected_hostname: &str,
    candidate: Option<(&str, &str)>,
) -> Result<VmRetirementCandidateStatus, VmRetirementConflict> {
    let Some((actual_hostname, actual_status)) = candidate else {
        return Err(VmRetirementConflict::UnknownVm { vm_id: id });
    };
    if actual_hostname != expected_hostname {
        return Err(VmRetirementConflict::HostnameMismatch {
            expected_hostname: expected_hostname.to_string(),
            actual_hostname: actual_hostname.to_string(),
        });
    }
    match actual_status {
        "active" => Ok(VmRetirementCandidateStatus::Active),
        "decommissioned" => Ok(VmRetirementCandidateStatus::Decommissioned),
        _ => Err(VmRetirementConflict::InvalidStatus {
            actual_status: actual_status.to_string(),
        }),
    }
}

/// VM inventory repository: physical VM fleet tracking with creation,
/// load-metric JSONB updates, status transitions (active → draining →
/// decommissioned), and region-filtered active-VM queries.
#[async_trait]
pub trait VmInventoryRepo {
    /// Serialize recovery and provider creation for one durable hostname.
    ///
    /// Production implementations must coordinate across API processes. The
    /// default keeps non-Postgres test repositories faithful to that contract.
    async fn lock_provisioning_hostname(
        &self,
        hostname: &str,
    ) -> Result<AdvisoryLockGuard<'_>, RepoError> {
        Ok(in_process_advisory_lock(&format!("vm_provisioning_{hostname}")).await)
    }

    /// All VMs with status=active, optionally filtered by region.
    async fn list_active(&self, region: Option<&str>) -> Result<Vec<VmInventory>, RepoError>;

    /// All VMs that still participate in fleet liveness, including draining VMs.
    async fn list_non_decommissioned(&self) -> Result<Vec<VmInventory>, RepoError>;

    /// Get a single VM by id.
    async fn get(&self, id: Uuid) -> Result<Option<VmInventory>, RepoError>;

    /// Insert a new VM into the inventory.
    async fn create(&self, vm: NewVmInventory) -> Result<VmInventory, RepoError>;

    /// Update the current_load JSONB for a VM (called by scheduler after scraping metrics).
    async fn update_load(&self, id: Uuid, load: serde_json::Value) -> Result<(), RepoError>;

    /// Existing lifecycle transition seam; production retirement must use
    /// `decommission_if_unreferenced` so identity and reference checks stay atomic.
    async fn set_status(&self, id: Uuid, status: &str) -> Result<(), RepoError>;

    /// Inspect the migration-owned blocker facts for an identity-checked active VM.
    async fn retirement_blockers(
        &self,
        id: Uuid,
        expected_hostname: &str,
    ) -> Result<VmRetirementAssessment, RepoError>;

    /// Atomically decommission an identity-checked active VM with no live references.
    async fn decommission_if_unreferenced(
        &self,
        id: Uuid,
        expected_hostname: &str,
    ) -> Result<VmDecommissionResult, RepoError>;

    /// Look up a VM by its hostname.
    async fn find_by_hostname(&self, hostname: &str) -> Result<Option<VmInventory>, RepoError>;
}
