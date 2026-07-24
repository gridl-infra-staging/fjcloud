use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration as StdDuration;

use chrono::{DateTime, Duration, Utc};
use tokio::sync::watch;
use tracing::error;
use uuid::Uuid;

use crate::config::ConfigError;
use crate::models::{VmInventory, VmLifecycleEventType};
use crate::repos::vm_lifecycle_event_repo::{
    active_replacement_admission, admission_from_event, AutorepairGuardrailQuery,
    ReplacementAdmission,
};
use crate::repos::{
    RepoError, TenantRepo, VmDecommissionResult, VmInventoryRepo, VmLifecycleEventRepo,
};
use crate::services::health_monitor::HealthCheckClient;
use crate::services::provisioning::{
    DurableSharedVmDraft, ProvisioningService, SharedVmProvisioningMode,
};

mod lifecycle;
mod rules;

use lifecycle::{dead_vm_event, event_uuid, replacement_draft, replacement_event};
use rules::classify_vm_liveness_observation;
pub use rules::{
    classify_vm_liveness, decide_autorepair, AutorepairDecision, AutorepairPolicy,
    AutorepairRefusal, LivenessCheck, VmLiveness,
};

pub struct VmAutorepairDeps {
    pub vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
    pub tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
    pub lifecycle_event_repo: Arc<dyn VmLifecycleEventRepo + Send + Sync>,
    pub provisioning_service: Arc<ProvisioningService>,
    pub health_client: Arc<dyn HealthCheckClient>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VmAutorepairSettings {
    pub check_interval: StdDuration,
    pub host_dead_after: Duration,
    pub replacement_cooldown: Duration,
    pub region_death_window: Duration,
    pub region_death_limit: u32,
    pub concurrent_replacement_cap: u32,
    pub spend_window: Duration,
    pub replacement_cost_cents: u64,
    pub spend_ceiling_cents: u64,
}

impl Default for VmAutorepairSettings {
    fn default() -> Self {
        Self {
            check_interval: StdDuration::from_secs(60),
            host_dead_after: Duration::minutes(15),
            replacement_cooldown: Duration::minutes(30),
            region_death_window: Duration::minutes(15),
            region_death_limit: 2,
            concurrent_replacement_cap: 1,
            spend_window: Duration::hours(24),
            replacement_cost_cents: 1_000,
            spend_ceiling_cents: 0,
        }
    }
}

impl VmAutorepairSettings {
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_reader(|key| std::env::var(key).ok())
    }

    pub fn from_reader<F>(read: F) -> Result<Self, ConfigError>
    where
        F: Fn(&str) -> Option<String>,
    {
        let defaults = Self::default();
        Ok(Self {
            check_interval: read_duration_seconds(
                &read,
                "FJCLOUD_VM_AUTOREPAIR_CHECK_INTERVAL_SECONDS",
                defaults.check_interval,
            )?,
            host_dead_after: read_chrono_seconds(
                &read,
                "FJCLOUD_VM_AUTOREPAIR_HOST_DEAD_AFTER_SECONDS",
                defaults.host_dead_after,
            )?,
            replacement_cooldown: read_chrono_seconds(
                &read,
                "FJCLOUD_VM_AUTOREPAIR_REPLACEMENT_COOLDOWN_SECONDS",
                defaults.replacement_cooldown,
            )?,
            region_death_window: read_chrono_seconds(
                &read,
                "FJCLOUD_VM_AUTOREPAIR_REGION_DEATH_WINDOW_SECONDS",
                defaults.region_death_window,
            )?,
            region_death_limit: read_u32(
                &read,
                "FJCLOUD_VM_AUTOREPAIR_REGION_DEATH_LIMIT",
                defaults.region_death_limit,
            )?,
            concurrent_replacement_cap: read_u32(
                &read,
                "FJCLOUD_VM_AUTOREPAIR_CONCURRENT_REPLACEMENT_CAP",
                defaults.concurrent_replacement_cap,
            )?,
            spend_window: read_chrono_seconds(
                &read,
                "FJCLOUD_VM_AUTOREPAIR_SPEND_WINDOW_SECONDS",
                defaults.spend_window,
            )?,
            replacement_cost_cents: read_u64(
                &read,
                "FJCLOUD_VM_AUTOREPAIR_REPLACEMENT_COST_CENTS",
                defaults.replacement_cost_cents,
            )?,
            spend_ceiling_cents: read_u64(
                &read,
                "FJCLOUD_VM_AUTOREPAIR_SPEND_CEILING_CENTS",
                defaults.spend_ceiling_cents,
            )?,
        })
    }
}

type EnabledReader = dyn Fn() -> Result<bool, ConfigError> + Send + Sync;

pub struct VmAutorepairReconciler {
    deps: VmAutorepairDeps,
    settings: VmAutorepairSettings,
    enabled_reader: Arc<EnabledReader>,
    dead_observations: Mutex<HashMap<Uuid, DeadObservationState>>,
}

#[derive(Debug, Clone, Copy)]
struct DeadObservationState {
    since: DateTime<Utc>,
    incident_recorded: bool,
}

impl VmAutorepairReconciler {
    pub fn new_with_enabled_reader(
        deps: VmAutorepairDeps,
        settings: VmAutorepairSettings,
        enabled_reader: Arc<EnabledReader>,
    ) -> Self {
        Self {
            deps,
            settings,
            enabled_reader,
            dead_observations: Mutex::new(HashMap::new()),
        }
    }

    pub async fn run(&self, mut shutdown_rx: watch::Receiver<bool>) {
        let mut interval = tokio::time::interval(self.settings.check_interval);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

        loop {
            tokio::select! {
                _ = interval.tick() => {
                    if let Err(error) = self.observe_once_at(Utc::now()).await {
                        error!(%error, "VM autorepair reconciliation pass failed");
                    }
                }
                changed = shutdown_rx.changed() => {
                    match changed {
                        Ok(()) if *shutdown_rx.borrow() => break,
                        Ok(()) => {}
                        Err(_) => break,
                    }
                }
            }
        }
    }

    pub async fn observe_once_at(&self, observed_at: DateTime<Utc>) -> Result<(), RepoError> {
        let (resuming_vm_ids, mut first_error) = self
            .reconcile_unfinished_replacements(self.replacement_enabled())
            .await?;
        let vms = self
            .deps
            .vm_inventory_repo
            .list_non_decommissioned()
            .await?;
        for vm in vms
            .into_iter()
            .filter(|vm| !resuming_vm_ids.contains(&vm.id))
        {
            if let Err(error) = self.observe_vm(&vm, observed_at).await {
                error!(vm_id = %vm.id, hostname = %vm.hostname, %error, "VM autorepair observation failed");
                if first_error.is_none() {
                    first_error = Some(error);
                }
            }
        }
        first_error.map_or(Ok(()), Err)
    }

    async fn reconcile_unfinished_replacements(
        &self,
        replacement_enabled: bool,
    ) -> Result<(HashSet<Uuid>, Option<RepoError>), RepoError> {
        let unfinished = self
            .deps
            .lifecycle_event_repo
            .unfinished_replacements()
            .await?;
        let mut vm_ids = HashSet::with_capacity(unfinished.len());
        vm_ids.extend(unfinished.iter().map(|event| event.vm_id));
        if !replacement_enabled {
            return Ok((vm_ids, None));
        }

        let mut first_error = None;
        for event in unfinished {
            let result = async {
                let dead_vm = self
                    .deps
                    .vm_inventory_repo
                    .get(event.vm_id)
                    .await?
                    .ok_or(RepoError::NotFound)?;
                let admission = admission_from_event(&event, false)?;
                self.resume_replacement(&dead_vm, admission).await
            }
            .await;
            if let Err(error) = result {
                tracing::error!(
                    vm_id = %event.vm_id,
                    phase = event.event_type.as_str(),
                    %error,
                    "VM autorepair recovery failed"
                );
                if first_error.is_none() {
                    first_error = Some(error);
                }
            }
        }
        Ok((vm_ids, first_error))
    }

    async fn observe_vm(
        &self,
        vm: &VmInventory,
        observed_at: DateTime<Utc>,
    ) -> Result<(), RepoError> {
        let provider_instance = self
            .deps
            .provisioning_service
            .vm_provisioner
            .find_managed_vm_by_hostname(&vm.provider, &vm.region, &vm.hostname)
            .await
            .map_err(|error| RepoError::Other(error.to_string()))?;
        let provider_vm_id = provider_instance
            .as_ref()
            .map(|instance| instance.provider_vm_id.clone());
        let dead_since = self
            .dead_observations
            .lock()
            .unwrap()
            .get(&vm.id)
            .map(|state| state.since);
        let observation = classify_vm_liveness_observation(
            self.deps.provisioning_service.vm_provisioner.as_ref(),
            self.deps.health_client.as_ref(),
            LivenessCheck {
                provider_vm_id: provider_vm_id.clone(),
                flapjack_url: Some(vm.flapjack_url.clone()),
                observed_at,
                dead_since,
                host_dead_after: self.settings.host_dead_after,
            },
        )
        .await;

        tracing::info!(
            vm_id = %vm.id,
            hostname = %vm.hostname,
            provider = %vm.provider,
            region = %vm.region,
            provider_vm_id = provider_vm_id.as_deref().unwrap_or("unresolved"),
            liveness = ?observation.liveness,
            concrete_dead_evidence = observation.concrete_dead_evidence,
            "VM autorepair liveness observed"
        );

        match observation.liveness {
            VmLiveness::Live | VmLiveness::EngineDown => {
                self.dead_observations.lock().unwrap().remove(&vm.id);
                Ok(())
            }
            VmLiveness::Indeterminate => {
                if observation.concrete_dead_evidence {
                    self.dead_observations
                        .lock()
                        .unwrap()
                        .entry(vm.id)
                        .or_insert(DeadObservationState {
                            since: observed_at,
                            incident_recorded: false,
                        });
                }
                Ok(())
            }
            VmLiveness::HostDead => {
                self.handle_host_dead(vm, provider_vm_id.as_deref(), observed_at)
                    .await
            }
        }
    }

    async fn handle_host_dead(
        &self,
        vm: &VmInventory,
        provider_vm_id: Option<&str>,
        observed_at: DateTime<Utc>,
    ) -> Result<(), RepoError> {
        let enabled = self.replacement_enabled();
        let latest = self.deps.lifecycle_event_repo.latest_for_vm(vm.id).await?;
        let fresh_incident = !self.dead_incident_recorded(vm.id);
        if fresh_incident {
            self.deps
                .lifecycle_event_repo
                .append(dead_vm_event(
                    vm,
                    provider_vm_id,
                    VmLifecycleEventType::DetectedDead,
                    None,
                ))
                .await?;
            self.mark_dead_incident_recorded(vm.id);
        }
        if !enabled {
            return self
                .record_refusal_once(
                    vm,
                    provider_vm_id,
                    latest.as_ref(),
                    "kill_switch_disabled",
                    fresh_incident,
                )
                .await;
        }

        let admission_guard = self
            .deps
            .lifecycle_event_repo
            .lock_autorepair_admission()
            .await?;
        let current_events = self.deps.lifecycle_event_repo.list_for_vm(vm.id).await?;
        if let Some(admission) = active_replacement_admission(&current_events)? {
            drop(admission_guard);
            return self.resume_replacement(vm, admission).await;
        }

        let decision_at = observed_at.max(Utc::now());
        let history = self
            .deps
            .lifecycle_event_repo
            .guardrail_history(AutorepairGuardrailQuery {
                region: vm.region.clone(),
                observed_at: decision_at,
                replacement_cooldown: self.settings.replacement_cooldown,
                region_death_window: self.settings.region_death_window,
                spend_window: self.settings.spend_window,
            })
            .await?;
        let policy = AutorepairPolicy {
            kill_switch_enabled: true,
            observed_at: decision_at,
            replacement_cooldown_until: history.replacement_cooldown_until,
            region_deaths_in_window: history.region_deaths_in_window,
            region_death_limit: self.settings.region_death_limit,
            concurrent_replacements: history.concurrent_replacements,
            concurrent_replacement_cap: self.settings.concurrent_replacement_cap,
            projected_spend_cents: history
                .committed_spend_cents
                .saturating_add(self.settings.replacement_cost_cents),
            spend_ceiling_cents: self.settings.spend_ceiling_cents,
        };
        match decide_autorepair(VmLiveness::HostDead, &policy) {
            AutorepairDecision::ReplacementAllowed => {
                let admission = self.admit_dead_vm(vm).await?;
                drop(admission_guard);
                self.resume_replacement(vm, admission).await
            }
            AutorepairDecision::Refused(refusal) => {
                self.record_refusal_once(
                    vm,
                    provider_vm_id,
                    latest.as_ref(),
                    refusal.guardrail(),
                    fresh_incident,
                )
                .await
            }
            AutorepairDecision::NoReplacement(_) => Ok(()),
        }
    }

    async fn record_refusal_once(
        &self,
        vm: &VmInventory,
        provider_vm_id: Option<&str>,
        latest: Option<&crate::models::VmLifecycleEvent>,
        guardrail: &str,
        force_append: bool,
    ) -> Result<(), RepoError> {
        let unchanged = !force_append
            && latest.is_some_and(|event| {
                event.event_type == VmLifecycleEventType::ReplacementRefused
                    && event
                        .detail
                        .get("guardrail")
                        .and_then(|value| value.as_str())
                        == Some(guardrail)
            });
        if !unchanged {
            self.deps
                .lifecycle_event_repo
                .append(dead_vm_event(
                    vm,
                    provider_vm_id,
                    VmLifecycleEventType::ReplacementRefused,
                    Some(("guardrail", guardrail)),
                ))
                .await?;
        }
        Ok(())
    }

    fn dead_incident_recorded(&self, vm_id: Uuid) -> bool {
        self.dead_observations
            .lock()
            .unwrap()
            .get(&vm_id)
            .is_some_and(|state| state.incident_recorded)
    }

    fn mark_dead_incident_recorded(&self, vm_id: Uuid) {
        self.dead_observations
            .lock()
            .unwrap()
            .entry(vm_id)
            .and_modify(|state| state.incident_recorded = true)
            .or_insert_with(|| DeadObservationState {
                since: Utc::now(),
                incident_recorded: true,
            });
    }

    fn replacement_enabled(&self) -> bool {
        (self.enabled_reader)().unwrap_or_else(|error| {
            error!(%error, "VM autorepair kill switch is invalid; refusing replacement");
            false
        })
    }

    async fn admit_dead_vm(
        &self,
        dead_vm: &VmInventory,
    ) -> Result<ReplacementAdmission, RepoError> {
        let draft = replacement_draft(
            dead_vm,
            &self.deps.provisioning_service.dns_domain,
            self.settings.replacement_cost_cents,
        );
        self.deps
            .lifecycle_event_repo
            .admit_replacement(draft)
            .await
    }

    async fn resume_replacement(
        &self,
        dead_vm: &VmInventory,
        admission: ReplacementAdmission,
    ) -> Result<(), RepoError> {
        let _execution_guard = self
            .deps
            .lifecycle_event_repo
            .lock_replacement_execution(dead_vm.id)
            .await?;
        let events = self
            .deps
            .lifecycle_event_repo
            .list_for_vm(dead_vm.id)
            .await?;
        let Some(current_admission) = active_replacement_admission(&events)? else {
            return Ok(());
        };
        if current_admission.attempt_id != admission.attempt_id {
            return Err(RepoError::Conflict(format!(
                "replacement attempt changed while waiting for execution lock: expected {}, found {}",
                admission.attempt_id, current_admission.attempt_id
            )));
        }

        if let Err(failure) = self.advance_replacement(dead_vm, &current_admission).await {
            let reason = failure.error.to_string();
            if let Err(append_error) = self
                .append_attempt_event(
                    dead_vm,
                    &current_admission,
                    None,
                    VmLifecycleEventType::ReplacementFailed,
                    Some((failure.phase, &reason)),
                )
                .await
            {
                error!(
                    vm_id = %dead_vm.id,
                    phase = failure.phase,
                    %append_error,
                    "failed to persist VM autorepair failure"
                );
            }
            return Err(failure.error);
        }
        Ok(())
    }

    async fn advance_replacement(
        &self,
        dead_vm: &VmInventory,
        admission: &ReplacementAdmission,
    ) -> Result<(), ReplacementFailure> {
        let replacement_vm = match admission.event.event_type {
            VmLifecycleEventType::ReplacementProvisioning => self
                .provision_replacement(dead_vm, admission)
                .await
                .map_err(|error| ReplacementFailure::new("provisioning", error))?,
            VmLifecycleEventType::ReplacementBooted | VmLifecycleEventType::TenantsReplaced => self
                .replacement_vm_from_event(admission)
                .await
                .map_err(|error| ReplacementFailure::new("recovery", error))?,
            phase => {
                return Err(ReplacementFailure::new(
                    "recovery",
                    RepoError::Other(format!(
                        "cannot resume replacement from phase {}",
                        phase.as_str()
                    )),
                ));
            }
        };
        let known_tenants = self
            .deps
            .tenant_repo
            .list_by_vm(dead_vm.id)
            .await
            .map_err(|error| ReplacementFailure::new("placement", error))?;
        if admission.event.event_type != VmLifecycleEventType::TenantsReplaced {
            self.place_tenants(dead_vm, &replacement_vm, &known_tenants)
                .await
                .map_err(|error| ReplacementFailure::new("placement", error))?;
            self.append_attempt_event(
                dead_vm,
                admission,
                Some(&replacement_vm),
                VmLifecycleEventType::TenantsReplaced,
                None,
            )
            .await
            .map_err(|error| ReplacementFailure::new("lifecycle_append", error))?;
        }
        self.decommission_source(dead_vm)
            .await
            .map_err(|error| ReplacementFailure::new("retirement", error))?;
        self.teardown_source(dead_vm, &known_tenants)
            .await
            .map_err(|error| ReplacementFailure::new("teardown", error))?;
        self.append_attempt_event(
            dead_vm,
            admission,
            Some(&replacement_vm),
            VmLifecycleEventType::ReplacementCompleted,
            None,
        )
        .await
        .map_err(|error| ReplacementFailure::new("lifecycle_append", error))?;
        self.dead_observations.lock().unwrap().remove(&dead_vm.id);
        Ok(())
    }

    async fn provision_replacement(
        &self,
        dead_vm: &VmInventory,
        admission: &ReplacementAdmission,
    ) -> Result<VmInventory, RepoError> {
        let replacement = self
            .deps
            .provisioning_service
            .auto_provision_shared_vm_with_draft(
                self.deps.vm_inventory_repo.as_ref(),
                &dead_vm.region,
                &dead_vm.provider,
                SharedVmProvisioningMode::RequireManagedVm,
                Some(DurableSharedVmDraft {
                    hostname: admission.planned_replacement_hostname.clone(),
                    node_id: admission.planned_replacement_node_id.clone(),
                }),
            )
            .await
            .map_err(|error| RepoError::Other(error.to_string()))?;
        self.append_attempt_event(
            dead_vm,
            admission,
            Some(&replacement),
            VmLifecycleEventType::ReplacementBooted,
            None,
        )
        .await?;
        Ok(replacement)
    }

    async fn replacement_vm_from_event(
        &self,
        admission: &ReplacementAdmission,
    ) -> Result<VmInventory, RepoError> {
        let replacement_vm_id = event_uuid(&admission.event.detail, "replacement_vm_id")?;
        self.deps
            .vm_inventory_repo
            .get(replacement_vm_id)
            .await?
            .ok_or(RepoError::NotFound)
    }

    async fn place_tenants(
        &self,
        dead_vm: &VmInventory,
        replacement_vm: &VmInventory,
        tenants: &[crate::models::CustomerTenant],
    ) -> Result<(), RepoError> {
        for tenant in tenants {
            self.deps
                .tenant_repo
                .replace_vm_if_current(
                    tenant.customer_id,
                    &tenant.tenant_id,
                    dead_vm.id,
                    replacement_vm.id,
                )
                .await?;
        }
        Ok(())
    }

    async fn decommission_source(&self, dead_vm: &VmInventory) -> Result<(), RepoError> {
        match self
            .deps
            .vm_inventory_repo
            .decommission_if_unreferenced(dead_vm.id, &dead_vm.hostname)
            .await?
        {
            VmDecommissionResult::Decommissioned | VmDecommissionResult::AlreadyDecommissioned => {}
            result => {
                return Err(RepoError::Conflict(format!(
                    "autorepair retirement refused: {result:?}"
                )));
            }
        }
        Ok(())
    }

    async fn teardown_source(
        &self,
        dead_vm: &VmInventory,
        known_tenants: &[crate::models::CustomerTenant],
    ) -> Result<(), RepoError> {
        let teardown = self
            .deps
            .provisioning_service
            .teardown_retired_vm_resources(dead_vm, known_tenants)
            .await
            .map_err(|error| RepoError::Other(error.to_string()))?;
        if teardown.is_clean() {
            Ok(())
        } else {
            Err(RepoError::Other(format!(
                "autorepair teardown incomplete: {teardown:?}"
            )))
        }
    }

    async fn append_attempt_event(
        &self,
        dead_vm: &VmInventory,
        admission: &ReplacementAdmission,
        replacement_vm: Option<&VmInventory>,
        event_type: VmLifecycleEventType,
        failure: Option<(&str, &str)>,
    ) -> Result<(), RepoError> {
        self.deps
            .lifecycle_event_repo
            .append(replacement_event(
                dead_vm,
                admission,
                replacement_vm,
                event_type,
                failure,
            ))
            .await?;
        Ok(())
    }
}

struct ReplacementFailure {
    phase: &'static str,
    error: RepoError,
}

impl ReplacementFailure {
    fn new(phase: &'static str, error: RepoError) -> Self {
        Self { phase, error }
    }
}

fn read_duration_seconds<F>(
    read: &F,
    key: &str,
    default_value: StdDuration,
) -> Result<StdDuration, ConfigError>
where
    F: Fn(&str) -> Option<String>,
{
    let seconds = read_u64(read, key, default_value.as_secs())?;
    if seconds == 0 {
        return Err(ConfigError::Invalid(key.to_string()));
    }
    Ok(StdDuration::from_secs(seconds))
}

fn read_chrono_seconds<F>(
    read: &F,
    key: &str,
    default_value: Duration,
) -> Result<Duration, ConfigError>
where
    F: Fn(&str) -> Option<String>,
{
    let default_seconds = default_value
        .num_seconds()
        .try_into()
        .map_err(|_| ConfigError::Invalid(key.to_string()))?;
    let seconds = read_u64(read, key, default_seconds)?;
    if seconds == 0 || seconds > i64::MAX as u64 {
        return Err(ConfigError::Invalid(key.to_string()));
    }
    Ok(Duration::seconds(seconds as i64))
}

fn read_u32<F>(read: &F, key: &str, default_value: u32) -> Result<u32, ConfigError>
where
    F: Fn(&str) -> Option<String>,
{
    let value = read_u64(read, key, u64::from(default_value))?;
    value
        .try_into()
        .map_err(|_| ConfigError::Invalid(key.to_string()))
}

fn read_u64<F>(read: &F, key: &str, default_value: u64) -> Result<u64, ConfigError>
where
    F: Fn(&str) -> Option<String>,
{
    let Some(raw) = read(key) else {
        return Ok(default_value);
    };
    raw.trim()
        .parse::<u64>()
        .map_err(|_| ConfigError::Invalid(key.to_string()))
}
