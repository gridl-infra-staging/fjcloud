use async_trait::async_trait;
use chrono::{DateTime, Duration, Utc};
use std::collections::HashMap;
use uuid::Uuid;

use crate::models::{NewVmLifecycleEvent, VmLifecycleEvent, VmLifecycleEventType};
use crate::repos::advisory_lock::{in_process_advisory_lock, AdvisoryLockGuard};
use crate::repos::RepoError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplacementAdmissionDraft {
    pub attempt_id: Uuid,
    pub dead_vm_id: Uuid,
    pub dead_hostname: String,
    pub planned_replacement_hostname: String,
    pub planned_replacement_node_id: String,
    pub provider: String,
    pub region: String,
    pub planned_spend_cents: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ReplacementAdmission {
    pub event: VmLifecycleEvent,
    pub attempt_id: Uuid,
    pub planned_replacement_hostname: String,
    pub planned_replacement_node_id: String,
    pub appended: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutorepairGuardrailQuery {
    pub region: String,
    pub observed_at: DateTime<Utc>,
    pub replacement_cooldown: Duration,
    pub region_death_window: Duration,
    pub spend_window: Duration,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutorepairGuardrailHistory {
    pub replacement_cooldown_until: Option<DateTime<Utc>>,
    pub region_deaths_in_window: u32,
    pub concurrent_replacements: u32,
    pub committed_spend_cents: u64,
}

#[async_trait]
pub trait VmLifecycleEventRepo {
    /// Serialize fleet-wide guardrail evaluation with replacement admission.
    async fn lock_autorepair_admission(&self) -> Result<AdvisoryLockGuard<'_>, RepoError> {
        Ok(in_process_advisory_lock("vm_autorepair_admission").await)
    }

    /// Serialize one dead VM's replacement advancement across API processes.
    async fn lock_replacement_execution(
        &self,
        vm_id: Uuid,
    ) -> Result<AdvisoryLockGuard<'_>, RepoError> {
        Ok(in_process_advisory_lock(&format!("vm_replacement_{vm_id}")).await)
    }

    async fn append(&self, event: NewVmLifecycleEvent) -> Result<VmLifecycleEvent, RepoError>;

    async fn list_for_vm(&self, vm_id: Uuid) -> Result<Vec<VmLifecycleEvent>, RepoError>;

    async fn latest_for_vm(&self, vm_id: Uuid) -> Result<Option<VmLifecycleEvent>, RepoError>;

    async fn admit_replacement(
        &self,
        draft: ReplacementAdmissionDraft,
    ) -> Result<ReplacementAdmission, RepoError>;

    async fn guardrail_history(
        &self,
        query: AutorepairGuardrailQuery,
    ) -> Result<AutorepairGuardrailHistory, RepoError>;

    async fn unfinished_replacements(&self) -> Result<Vec<VmLifecycleEvent>, RepoError>;
}

pub fn replacement_provisioning_event(draft: &ReplacementAdmissionDraft) -> NewVmLifecycleEvent {
    NewVmLifecycleEvent {
        vm_id: draft.dead_vm_id,
        event_type: VmLifecycleEventType::ReplacementProvisioning,
        detail: serde_json::json!({
            "attempt_id": draft.attempt_id,
            "dead_vm_id": draft.dead_vm_id,
            "dead_hostname": draft.dead_hostname,
            "planned_replacement_hostname": draft.planned_replacement_hostname,
            "planned_replacement_node_id": draft.planned_replacement_node_id,
            "provider": draft.provider,
            "region": draft.region,
            "planned_spend_cents": draft.planned_spend_cents,
        }),
    }
}

pub fn summarize_guardrail_history(
    events: &[VmLifecycleEvent],
    query: &AutorepairGuardrailQuery,
) -> Result<AutorepairGuardrailHistory, RepoError> {
    let region_window_start = query.observed_at - query.region_death_window;
    let spend_window_start = query.observed_at - query.spend_window;
    let mut latest_booted_at = None;
    let mut region_deaths_in_window = 0_u32;
    let mut committed_spend_cents = 0_u64;

    for event in events
        .iter()
        .filter(|event| event.created_at <= query.observed_at)
    {
        if event.event_type == VmLifecycleEventType::ReplacementBooted {
            latest_booted_at = Some(
                latest_booted_at.map_or(event.created_at, |latest: DateTime<Utc>| {
                    latest.max(event.created_at)
                }),
            );
        }
        if event.event_type == VmLifecycleEventType::DetectedDead
            && event.created_at > region_window_start
            && event_region(event) == Some(query.region.as_str())
        {
            region_deaths_in_window = region_deaths_in_window.saturating_add(1);
        }
        if event.event_type == VmLifecycleEventType::ReplacementProvisioning
            && event.created_at > spend_window_start
        {
            committed_spend_cents = committed_spend_cents
                .checked_add(detail_u64_or_zero(&event.detail, "planned_spend_cents")?)
                .ok_or_else(|| RepoError::Other("autorepair spend history overflow".to_string()))?;
        }
    }

    let concurrent_replacements = active_replacement_events(events)?
        .len()
        .try_into()
        .map_err(|_| RepoError::Other("autorepair concurrent history overflow".to_string()))?;

    Ok(AutorepairGuardrailHistory {
        replacement_cooldown_until: latest_booted_at
            .map(|booted_at| booted_at + query.replacement_cooldown),
        region_deaths_in_window,
        concurrent_replacements,
        committed_spend_cents,
    })
}

pub fn latest_unfinished_replacements(
    events: &[VmLifecycleEvent],
) -> Result<Vec<VmLifecycleEvent>, RepoError> {
    let mut unfinished = active_replacement_events(events)?
        .into_iter()
        .cloned()
        .collect::<Vec<_>>();
    unfinished.sort_by_key(|event| (event.created_at, event.id));
    Ok(unfinished)
}

fn event_region(event: &VmLifecycleEvent) -> Option<&str> {
    event
        .detail
        .get("inventory_region")
        .or_else(|| event.detail.get("region"))
        .and_then(serde_json::Value::as_str)
}

fn detail_u64_or_zero(detail: &serde_json::Value, key: &str) -> Result<u64, RepoError> {
    match detail.get(key) {
        None => Ok(0),
        Some(value) => value
            .as_u64()
            .ok_or_else(|| RepoError::Other(format!("replacement event invalid {key}"))),
    }
}

pub fn active_replacement_admission(
    events: &[VmLifecycleEvent],
) -> Result<Option<ReplacementAdmission>, RepoError> {
    let active = active_replacement_events(events)?.into_iter().last();
    active
        .map(|event| admission_from_event(event, false))
        .transpose()
}

fn active_replacement_events(
    events: &[VmLifecycleEvent],
) -> Result<Vec<&VmLifecycleEvent>, RepoError> {
    let mut sorted_events = events.iter().collect::<Vec<_>>();
    sorted_events.sort_by_key(|event| (event.created_at, event.id));
    let mut active_by_vm = HashMap::<Uuid, &VmLifecycleEvent>::new();

    for event in sorted_events {
        apply_active_replacement_event(&mut active_by_vm, event)?;
    }

    Ok(active_by_vm.into_values().collect())
}

fn apply_active_replacement_event<'a>(
    active_by_vm: &mut HashMap<Uuid, &'a VmLifecycleEvent>,
    event: &'a VmLifecycleEvent,
) -> Result<(), RepoError> {
    match event.event_type {
        VmLifecycleEventType::ReplacementProvisioning
        | VmLifecycleEventType::ReplacementBooted
        | VmLifecycleEventType::TenantsReplaced => {
            active_by_vm.insert(event.vm_id, event);
        }
        VmLifecycleEventType::ReplacementFailed => {
            if !is_retryable_replacement_failure(event)? {
                active_by_vm.remove(&event.vm_id);
            }
        }
        VmLifecycleEventType::ReplacementCompleted | VmLifecycleEventType::ReplacementRefused => {
            active_by_vm.remove(&event.vm_id);
        }
        VmLifecycleEventType::DetectedDead => {}
    }
    Ok(())
}

fn is_retryable_replacement_failure(event: &VmLifecycleEvent) -> Result<bool, RepoError> {
    let Some(phase) = event
        .detail
        .get("failure_phase")
        .and_then(serde_json::Value::as_str)
    else {
        return Ok(false);
    };

    Ok(matches!(
        phase,
        "provisioning" | "placement" | "retirement" | "teardown" | "lifecycle_append"
    ))
}

pub fn admission_from_event(
    event: &VmLifecycleEvent,
    appended: bool,
) -> Result<ReplacementAdmission, RepoError> {
    let attempt_id = detail_uuid(&event.detail, "attempt_id")?;
    let planned_replacement_hostname =
        detail_string(&event.detail, "planned_replacement_hostname")?;
    let planned_replacement_node_id = detail_string(&event.detail, "planned_replacement_node_id")?;
    Ok(ReplacementAdmission {
        event: event.clone(),
        attempt_id,
        planned_replacement_hostname,
        planned_replacement_node_id,
        appended,
    })
}

fn detail_uuid(detail: &serde_json::Value, key: &str) -> Result<Uuid, RepoError> {
    let raw = detail
        .get(key)
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| RepoError::Other(format!("replacement event missing {key}")))?;
    Uuid::parse_str(raw).map_err(|e| RepoError::Other(format!("invalid {key}: {e}")))
}

fn detail_string(detail: &serde_json::Value, key: &str) -> Result<String, RepoError> {
    detail
        .get(key)
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .ok_or_else(|| RepoError::Other(format!("replacement event missing {key}")))
}
