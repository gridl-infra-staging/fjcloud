use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use chrono::{DateTime, Duration, Utc};
use serde::Serialize;
use uuid::Uuid;

use crate::dns::{DnsARecord, DnsError, DnsManager};
use crate::models::vm_inventory::VmInventory;
use crate::provisioner::{VmInstance, VmProvisioner};
use crate::repos::vm_inventory_repo::VmInventoryRepo;
use crate::secrets::{NodeSecretError, NodeSecretManager, NodeSecretRecord};
use crate::services::provisioning::is_canonical_shared_vm_hostname_for_domain;

const ORPHAN_AGE_GRACE: Duration = Duration::hours(1);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum OrphanReportStatus {
    Clean,
    OrphansFound,
    Indeterminate,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceStatus {
    Scanned,
    Unsupported,
    Error,
}

#[derive(Debug, Clone, Serialize)]
pub struct DnsSourceReport {
    pub status: SourceStatus,
    pub enumeration_incomplete: bool,
    pub records_scanned: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SsmSourceReport {
    pub status: SourceStatus,
    pub enumeration_incomplete: bool,
    pub keys_scanned: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct InventorySourceReport {
    pub status: SourceStatus,
    pub enumeration_incomplete: bool,
    pub inventory_scanned: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct InstanceSourceReport {
    pub status: SourceStatus,
    pub enumeration_incomplete: bool,
    pub inventory_checked: usize,
    pub instances_found: usize,
    pub instances_missing: usize,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub errors: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct OrphanReportSources {
    pub dns: DnsSourceReport,
    pub ssm: SsmSourceReport,
    pub inventory: InventorySourceReport,
    pub instances: InstanceSourceReport,
}

#[derive(Debug, Clone, Serialize)]
pub struct RetiredInventoryContext {
    pub id: Uuid,
    pub status: String,
    pub updated_at: DateTime<Utc>,
}

impl From<VmInventory> for RetiredInventoryContext {
    fn from(inventory: VmInventory) -> Self {
        Self {
            id: inventory.id,
            status: inventory.status,
            updated_at: inventory.updated_at,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct DnsOrphan {
    pub hostname: String,
    pub created_at: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retired_inventory: Option<RetiredInventoryContext>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SsmKeyOrphan {
    pub node_id: String,
    pub path: String,
    pub last_modified_at: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retired_inventory: Option<RetiredInventoryContext>,
}

#[derive(Debug, Clone, Serialize)]
pub struct NonOrphanMatch {
    pub hostname: String,
    pub inventory_id: Uuid,
    pub provider_vm_id: String,
    pub instance_status: String,
    pub dns_record_matched: bool,
    pub ssm_paths_matched: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct VmOrphanReport {
    pub generated_at: DateTime<Utc>,
    pub status: OrphanReportStatus,
    pub enumeration_incomplete: bool,
    pub sources: OrphanReportSources,
    pub orphans_found: usize,
    pub dns_orphans: Vec<DnsOrphan>,
    pub ssm_key_orphans: Vec<SsmKeyOrphan>,
    pub non_orphans: Vec<NonOrphanMatch>,
}

pub struct VmOrphanDependencies {
    pub inventory: Arc<dyn VmInventoryRepo + Send + Sync>,
    pub dns: Arc<dyn DnsManager>,
    pub secrets: Arc<dyn NodeSecretManager>,
    pub provisioner: Arc<dyn VmProvisioner>,
}

pub struct VmOrphanReconciler {
    dependencies: VmOrphanDependencies,
    dns_domain: String,
}

struct InventoryFacts {
    rows: Vec<VmInventory>,
    source: InventorySourceReport,
}

struct DnsFacts {
    records: Vec<DnsARecord>,
    source: DnsSourceReport,
}

struct SsmFacts {
    records: Vec<NodeSecretRecord>,
    source: SsmSourceReport,
}

struct InstanceFacts {
    protected_node_ids: HashSet<String>,
    matches: Vec<(VmInventory, VmInstance)>,
    source: InstanceSourceReport,
}

impl VmOrphanReconciler {
    pub fn new(dependencies: VmOrphanDependencies, dns_domain: String) -> Self {
        Self {
            dependencies,
            dns_domain,
        }
    }

    pub async fn reconcile(&self) -> VmOrphanReport {
        self.reconcile_at(Utc::now()).await
    }

    async fn reconcile_at(&self, now: DateTime<Utc>) -> VmOrphanReport {
        let inventory = self.load_inventory().await;
        let dns = self.load_dns().await;
        let ssm = self.load_ssm().await;
        let instances = self.resolve_instances(&inventory.rows).await;
        let classification_allowed = inventory.source.status == SourceStatus::Scanned;

        let dns_orphans = self
            .classify_dns_orphans(
                &dns.records,
                &instances.protected_node_ids,
                now,
                classification_allowed,
            )
            .await;
        let ssm_key_orphans = self
            .classify_ssm_orphans(
                &ssm.records,
                &instances.protected_node_ids,
                now,
                classification_allowed,
            )
            .await;
        let non_orphans = build_non_orphan_matches(&instances.matches, &dns.records, &ssm.records);
        let sources = OrphanReportSources {
            dns: dns.source,
            ssm: ssm.source,
            inventory: inventory.source,
            instances: instances.source,
        };
        let enumeration_incomplete = source_enumeration_incomplete(&sources);
        let orphans_found = dns_orphans.len() + ssm_key_orphans.len();
        let status = report_status(enumeration_incomplete, orphans_found);

        VmOrphanReport {
            generated_at: now,
            status,
            enumeration_incomplete,
            sources,
            orphans_found,
            dns_orphans,
            ssm_key_orphans,
            non_orphans,
        }
    }

    async fn load_inventory(&self) -> InventoryFacts {
        match self.dependencies.inventory.list_non_decommissioned().await {
            Ok(rows) => {
                let rows = rows
                    .into_iter()
                    .filter(|row| {
                        is_canonical_shared_vm_hostname_for_domain(&row.hostname, &self.dns_domain)
                    })
                    .collect::<Vec<_>>();
                InventoryFacts {
                    source: InventorySourceReport {
                        status: SourceStatus::Scanned,
                        enumeration_incomplete: false,
                        inventory_scanned: rows.len(),
                        error: None,
                    },
                    rows,
                }
            }
            Err(error) => InventoryFacts {
                rows: Vec::new(),
                source: InventorySourceReport {
                    status: SourceStatus::Error,
                    enumeration_incomplete: true,
                    inventory_scanned: 0,
                    error: Some(error.to_string()),
                },
            },
        }
    }

    async fn load_dns(&self) -> DnsFacts {
        match self.dependencies.dns.list_a_records().await {
            Ok(records) => DnsFacts {
                source: DnsSourceReport {
                    status: SourceStatus::Scanned,
                    enumeration_incomplete: false,
                    records_scanned: records.len(),
                    error: None,
                },
                records,
            },
            Err(error) => DnsFacts {
                records: Vec::new(),
                source: DnsSourceReport {
                    status: source_status_for_dns_error(&error),
                    enumeration_incomplete: true,
                    records_scanned: 0,
                    error: Some(error.to_string()),
                },
            },
        }
    }

    async fn load_ssm(&self) -> SsmFacts {
        match self.dependencies.secrets.list_node_api_keys().await {
            Ok(records) => SsmFacts {
                source: SsmSourceReport {
                    status: SourceStatus::Scanned,
                    enumeration_incomplete: false,
                    keys_scanned: records.len(),
                    error: None,
                },
                records,
            },
            Err(error) => SsmFacts {
                records: Vec::new(),
                source: SsmSourceReport {
                    status: source_status_for_secret_error(&error),
                    enumeration_incomplete: true,
                    keys_scanned: 0,
                    error: Some(error.to_string()),
                },
            },
        }
    }

    async fn resolve_instances(&self, inventory: &[VmInventory]) -> InstanceFacts {
        let mut protected_node_ids = HashSet::new();
        let mut matches = Vec::new();
        let mut errors = Vec::new();
        let mut missing = 0;
        for row in inventory {
            // This state-agnostic oracle is required because the 2026-07-21
            // previous-AMI incident left managed stopped/pending VMs that the
            // running-only lookup would have falsely reported as absent.
            match self
                .dependencies
                .provisioner
                .find_managed_vm_by_hostname(&row.provider, &row.region, &row.hostname)
                .await
            {
                Ok(Some(instance)) => {
                    protected_node_ids.insert(row.node_secret_id().to_string());
                    matches.push((row.clone(), instance));
                }
                Ok(None) => missing += 1,
                Err(error) => {
                    protected_node_ids.insert(row.node_secret_id().to_string());
                    errors.push(format!("{}: {error}", row.hostname));
                }
            }
        }
        InstanceFacts {
            protected_node_ids,
            source: InstanceSourceReport {
                status: if errors.is_empty() {
                    SourceStatus::Scanned
                } else {
                    SourceStatus::Error
                },
                enumeration_incomplete: !errors.is_empty(),
                inventory_checked: inventory.len(),
                instances_found: matches.len(),
                instances_missing: missing,
                errors,
            },
            matches,
        }
    }

    async fn classify_dns_orphans(
        &self,
        records: &[DnsARecord],
        protected_node_ids: &HashSet<String>,
        now: DateTime<Utc>,
        classification_allowed: bool,
    ) -> Vec<DnsOrphan> {
        let mut orphans = Vec::new();
        for record in records {
            if !classification_allowed
                || !is_canonical_shared_vm_hostname_for_domain(&record.hostname, &self.dns_domain)
                || protected_node_ids.contains(&record.hostname)
                || resource_is_in_grace(record.created_at, now)
            {
                continue;
            }
            orphans.push(DnsOrphan {
                hostname: record.hostname.clone(),
                created_at: record.created_at,
                retired_inventory: self.retired_context(&record.hostname).await,
            });
        }
        orphans
    }

    async fn classify_ssm_orphans(
        &self,
        records: &[NodeSecretRecord],
        protected_node_ids: &HashSet<String>,
        now: DateTime<Utc>,
        classification_allowed: bool,
    ) -> Vec<SsmKeyOrphan> {
        let mut orphans = Vec::new();
        for record in records {
            if !classification_allowed
                || !is_canonical_shared_vm_hostname_for_domain(&record.node_id, &self.dns_domain)
                || protected_node_ids.contains(&record.node_id)
                || resource_is_in_grace(record.last_modified_at, now)
            {
                continue;
            }
            orphans.push(SsmKeyOrphan {
                node_id: record.node_id.clone(),
                path: record.path.clone(),
                last_modified_at: record.last_modified_at,
                retired_inventory: self.retired_context(&record.node_id).await,
            });
        }
        orphans
    }

    async fn retired_context(&self, hostname: &str) -> Option<RetiredInventoryContext> {
        self.dependencies
            .inventory
            .find_by_hostname(hostname)
            .await
            .ok()
            .flatten()
            .filter(|row| row.status == "decommissioned")
            .map(Into::into)
    }
}

fn build_non_orphan_matches(
    matches: &[(VmInventory, VmInstance)],
    dns_records: &[DnsARecord],
    ssm_records: &[NodeSecretRecord],
) -> Vec<NonOrphanMatch> {
    let dns_hostnames = dns_records
        .iter()
        .map(|record| record.hostname.as_str())
        .collect::<HashSet<_>>();
    let mut ssm_paths = HashMap::<&str, Vec<String>>::new();
    for record in ssm_records {
        ssm_paths
            .entry(record.node_id.as_str())
            .or_default()
            .push(record.path.clone());
    }
    matches
        .iter()
        .map(|(inventory, instance)| NonOrphanMatch {
            hostname: inventory.hostname.clone(),
            inventory_id: inventory.id,
            provider_vm_id: instance.provider_vm_id.clone(),
            instance_status: format!("{:?}", instance.status).to_lowercase(),
            dns_record_matched: dns_hostnames.contains(inventory.hostname.as_str()),
            ssm_paths_matched: ssm_paths
                .remove(inventory.node_secret_id())
                .unwrap_or_default(),
        })
        .collect()
}

fn source_status_for_dns_error(error: &DnsError) -> SourceStatus {
    match error {
        DnsError::ListingUnsupported => SourceStatus::Unsupported,
        _ => SourceStatus::Error,
    }
}

fn source_status_for_secret_error(error: &NodeSecretError) -> SourceStatus {
    match error {
        NodeSecretError::ListingUnsupported => SourceStatus::Unsupported,
        _ => SourceStatus::Error,
    }
}

fn source_enumeration_incomplete(sources: &OrphanReportSources) -> bool {
    sources.dns.enumeration_incomplete
        || sources.ssm.enumeration_incomplete
        || sources.inventory.enumeration_incomplete
        || sources.instances.enumeration_incomplete
}

fn report_status(enumeration_incomplete: bool, orphans_found: usize) -> OrphanReportStatus {
    if enumeration_incomplete {
        OrphanReportStatus::Indeterminate
    } else if orphans_found > 0 {
        OrphanReportStatus::OrphansFound
    } else {
        OrphanReportStatus::Clean
    }
}

fn resource_is_in_grace(resource_timestamp: DateTime<Utc>, now: DateTime<Utc>) -> bool {
    // Resources younger than one hour are suppressed to avoid flagging in-flight
    // provisioning/rollback fallout from the 2026-07-21 incident pattern, but
    // the source denominator still counts them.
    now.signed_duration_since(resource_timestamp) < ORPHAN_AGE_GRACE
}

#[cfg(test)]
mod tests;
