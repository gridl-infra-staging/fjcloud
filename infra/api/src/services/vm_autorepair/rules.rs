use chrono::{DateTime, Duration, Utc};

use crate::provisioner::{VmProvisioner, VmProvisionerError, VmStatus};
use crate::services::health_monitor::{HealthCheckClient, HealthCheckResult};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VmLiveness {
    Live,
    EngineDown,
    HostDead,
    Indeterminate,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LivenessCheck {
    pub provider_vm_id: Option<String>,
    pub flapjack_url: Option<String>,
    pub observed_at: DateTime<Utc>,
    pub dead_since: Option<DateTime<Utc>>,
    pub host_dead_after: Duration,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AutorepairRefusal {
    KillSwitchDisabled,
    ReplacementCooldown,
    RegionDampening,
    ConcurrentReplacementCap,
    SpendCeiling,
}

impl AutorepairRefusal {
    pub(super) fn guardrail(self) -> &'static str {
        match self {
            Self::KillSwitchDisabled => "kill_switch_disabled",
            Self::ReplacementCooldown => "replacement_cooldown",
            Self::RegionDampening => "region_dampening",
            Self::ConcurrentReplacementCap => "concurrent_replacement_cap",
            Self::SpendCeiling => "spend_ceiling",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AutorepairDecision {
    ReplacementAllowed,
    NoReplacement(VmLiveness),
    Refused(AutorepairRefusal),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AutorepairPolicy {
    pub kill_switch_enabled: bool,
    pub observed_at: DateTime<Utc>,
    pub replacement_cooldown_until: Option<DateTime<Utc>>,
    pub region_deaths_in_window: u32,
    pub region_death_limit: u32,
    pub concurrent_replacements: u32,
    pub concurrent_replacement_cap: u32,
    pub projected_spend_cents: u64,
    pub spend_ceiling_cents: u64,
}

pub async fn classify_vm_liveness<P, H>(
    provisioner: &P,
    health_client: &H,
    check: LivenessCheck,
) -> VmLiveness
where
    P: VmProvisioner + ?Sized,
    H: HealthCheckClient + ?Sized,
{
    classify_vm_liveness_observation(provisioner, health_client, check)
        .await
        .liveness
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct LivenessObservation {
    pub(super) liveness: VmLiveness,
    pub(super) concrete_dead_evidence: bool,
}

pub(super) async fn classify_vm_liveness_observation<P, H>(
    provisioner: &P,
    health_client: &H,
    check: LivenessCheck,
) -> LivenessObservation
where
    P: VmProvisioner + ?Sized,
    H: HealthCheckClient + ?Sized,
{
    let engine_health = health_client.check(check.flapjack_url.clone()).await;

    let Some(provider_vm_id) = check.provider_vm_id.as_deref() else {
        return liveness_observation(VmLiveness::Indeterminate, false);
    };

    let instance_status = match provisioner.get_vm_status(provider_vm_id).await {
        Ok(status) => status,
        Err(VmProvisionerError::VmNotFound(_)) => {
            return classify_dead_state_vm(engine_health, &check);
        }
        Err(_) => return liveness_observation(VmLiveness::Indeterminate, false),
    };

    classify_observed_liveness(instance_status, engine_health, &check)
}

pub fn decide_autorepair(liveness: VmLiveness, policy: &AutorepairPolicy) -> AutorepairDecision {
    if liveness != VmLiveness::HostDead {
        return AutorepairDecision::NoReplacement(liveness);
    }

    if !policy.kill_switch_enabled {
        return AutorepairDecision::Refused(AutorepairRefusal::KillSwitchDisabled);
    }

    if policy.region_deaths_in_window > policy.region_death_limit {
        return AutorepairDecision::Refused(AutorepairRefusal::RegionDampening);
    }

    if policy.concurrent_replacements >= policy.concurrent_replacement_cap {
        return AutorepairDecision::Refused(AutorepairRefusal::ConcurrentReplacementCap);
    }

    if policy.projected_spend_cents > policy.spend_ceiling_cents {
        return AutorepairDecision::Refused(AutorepairRefusal::SpendCeiling);
    }

    if policy
        .replacement_cooldown_until
        .is_some_and(|cooldown_until| cooldown_until > policy.observed_at)
    {
        return AutorepairDecision::Refused(AutorepairRefusal::ReplacementCooldown);
    }

    AutorepairDecision::ReplacementAllowed
}

fn classify_observed_liveness(
    instance_status: VmStatus,
    engine_health: HealthCheckResult,
    check: &LivenessCheck,
) -> LivenessObservation {
    match instance_status {
        VmStatus::Running => classify_running_vm(engine_health),
        VmStatus::Stopped | VmStatus::Terminated => classify_dead_state_vm(engine_health, check),
        VmStatus::Pending | VmStatus::Unknown => {
            liveness_observation(VmLiveness::Indeterminate, false)
        }
    }
}

fn classify_running_vm(engine_health: HealthCheckResult) -> LivenessObservation {
    let liveness = match engine_health {
        HealthCheckResult::Healthy => VmLiveness::Live,
        HealthCheckResult::Unhealthy(_) | HealthCheckResult::Unreachable(_) => {
            VmLiveness::EngineDown
        }
    };
    liveness_observation(liveness, false)
}

fn classify_dead_state_vm(
    engine_health: HealthCheckResult,
    check: &LivenessCheck,
) -> LivenessObservation {
    if matches!(engine_health, HealthCheckResult::Healthy) {
        return liveness_observation(VmLiveness::Indeterminate, false);
    }

    let liveness = if has_elapsed_dead_window(check) {
        VmLiveness::HostDead
    } else {
        VmLiveness::Indeterminate
    };
    liveness_observation(liveness, true)
}

fn liveness_observation(liveness: VmLiveness, concrete_dead_evidence: bool) -> LivenessObservation {
    LivenessObservation {
        liveness,
        concrete_dead_evidence,
    }
}

fn has_elapsed_dead_window(check: &LivenessCheck) -> bool {
    check
        .dead_since
        .is_some_and(|dead_since| check.observed_at - dead_since >= check.host_dead_after)
}
