use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::str::FromStr;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VmLifecycleEventType {
    DetectedDead,
    ReplacementProvisioning,
    ReplacementBooted,
    TenantsReplaced,
    ReplacementCompleted,
    ReplacementFailed,
    ReplacementRefused,
}

impl VmLifecycleEventType {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::DetectedDead => "detected_dead",
            Self::ReplacementProvisioning => "replacement_provisioning",
            Self::ReplacementBooted => "replacement_booted",
            Self::TenantsReplaced => "tenants_replaced",
            Self::ReplacementCompleted => "replacement_completed",
            Self::ReplacementFailed => "replacement_failed",
            Self::ReplacementRefused => "replacement_refused",
        }
    }
}

impl FromStr for VmLifecycleEventType {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "detected_dead" => Ok(Self::DetectedDead),
            "replacement_provisioning" => Ok(Self::ReplacementProvisioning),
            "replacement_booted" => Ok(Self::ReplacementBooted),
            "tenants_replaced" => Ok(Self::TenantsReplaced),
            "replacement_completed" => Ok(Self::ReplacementCompleted),
            "replacement_failed" => Ok(Self::ReplacementFailed),
            "replacement_refused" => Ok(Self::ReplacementRefused),
            other => Err(format!("unknown VM lifecycle event type: {other}")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct VmLifecycleEvent {
    pub id: Uuid,
    pub vm_id: Uuid,
    pub event_type: VmLifecycleEventType,
    pub detail: serde_json::Value,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct NewVmLifecycleEvent {
    pub vm_id: Uuid,
    pub event_type: VmLifecycleEventType,
    pub detail: serde_json::Value,
}
