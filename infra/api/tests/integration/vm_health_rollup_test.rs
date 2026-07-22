use api::services::vm_health_rollup::{vm_health_rollup, VmHealth};
use serde_json::json;

fn assert_rollup_serializes_to(deployment_healths: &[&str], expected: &str) {
    let health: VmHealth = vm_health_rollup(deployment_healths);

    assert_eq!(serde_json::to_value(health).unwrap(), json!(expected));
}

#[test]
fn all_healthy_rolls_up_to_healthy() {
    assert_rollup_serializes_to(&["healthy", "healthy"], "healthy");
}

#[test]
fn unhealthy_wins_over_healthy() {
    assert_rollup_serializes_to(&["healthy", "healthy", "unhealthy"], "unhealthy");
}

#[test]
fn zero_deployments_rolls_up_to_unknown() {
    assert_rollup_serializes_to(&[], "unknown");
}

#[test]
fn healthy_plus_unknown_rolls_up_to_unknown() {
    assert_rollup_serializes_to(&["healthy", "unknown"], "unknown");
}

#[test]
fn unhealthy_plus_unknown_rolls_up_to_unhealthy() {
    assert_rollup_serializes_to(&["unhealthy", "unknown"], "unhealthy");
}
