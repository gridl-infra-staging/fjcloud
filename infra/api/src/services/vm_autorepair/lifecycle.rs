use uuid::Uuid;

use crate::models::{NewVmLifecycleEvent, VmInventory, VmLifecycleEventType};
use crate::repos::vm_lifecycle_event_repo::{ReplacementAdmission, ReplacementAdmissionDraft};
use crate::repos::RepoError;

pub(super) fn replacement_draft(
    dead_vm: &VmInventory,
    dns_domain: &str,
    planned_spend_cents: u64,
) -> ReplacementAdmissionDraft {
    let attempt_id = Uuid::new_v4();
    let attempt = attempt_id.simple().to_string();
    let hostname = format!("vm-shared-autorepair-{}.{dns_domain}", &attempt[..12]);
    ReplacementAdmissionDraft {
        attempt_id,
        dead_vm_id: dead_vm.id,
        dead_hostname: dead_vm.hostname.clone(),
        planned_replacement_hostname: hostname.clone(),
        planned_replacement_node_id: hostname,
        provider: dead_vm.provider.clone(),
        region: dead_vm.region.clone(),
        planned_spend_cents,
    }
}

pub(super) fn replacement_event(
    dead_vm: &VmInventory,
    admission: &ReplacementAdmission,
    replacement_vm: Option<&VmInventory>,
    event_type: VmLifecycleEventType,
    failure: Option<(&str, &str)>,
) -> NewVmLifecycleEvent {
    let mut detail = admission.event.detail.clone();
    let detail_object = detail
        .as_object_mut()
        .expect("admitted replacement detail is an object");
    detail_object.insert(
        "dead_vm_id".to_string(),
        serde_json::Value::String(dead_vm.id.to_string()),
    );
    if let Some(replacement_vm) = replacement_vm {
        detail_object.insert(
            "replacement_vm_id".to_string(),
            serde_json::Value::String(replacement_vm.id.to_string()),
        );
        detail_object.insert(
            "replacement_hostname".to_string(),
            serde_json::Value::String(replacement_vm.hostname.clone()),
        );
    }
    if let Some((phase, reason)) = failure {
        detail_object.insert(
            "failure_phase".to_string(),
            serde_json::Value::String(phase.to_string()),
        );
        detail_object.insert(
            "failure_reason".to_string(),
            serde_json::Value::String(reason.to_string()),
        );
    }
    NewVmLifecycleEvent {
        vm_id: dead_vm.id,
        event_type,
        detail,
    }
}

pub(super) fn event_uuid(detail: &serde_json::Value, key: &str) -> Result<Uuid, RepoError> {
    let value = detail
        .get(key)
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| RepoError::Other(format!("replacement event missing {key}")))?;
    Uuid::parse_str(value)
        .map_err(|error| RepoError::Other(format!("replacement event invalid {key}: {error}")))
}

pub(super) fn dead_vm_event(
    vm: &VmInventory,
    provider_vm_id: Option<&str>,
    event_type: VmLifecycleEventType,
    extra: Option<(&str, &str)>,
) -> NewVmLifecycleEvent {
    let mut detail = serde_json::json!({
        "dead_vm_id": vm.id,
        "dead_hostname": vm.hostname,
        "provider": vm.provider,
        "provider_vm_id": provider_vm_id,
        "region": vm.region,
    });
    if let Some((key, value)) = extra {
        detail
            .as_object_mut()
            .expect("lifecycle detail is an object")
            .insert(
                key.to_string(),
                serde_json::Value::String(value.to_string()),
            );
    }
    NewVmLifecycleEvent {
        vm_id: vm.id,
        event_type,
        detail,
    }
}
