//! Local-dev shared VM provisioning tests.

use super::tests::{clear_local_dev_topology_env, EnvVarGuard, InMemoryVmRepo, LOCAL_DEV_ENV_LOCK};
use super::*;

#[tokio::test]
async fn try_local_dev_provision_reuses_existing_vm() {
    let _lock = LOCAL_DEV_ENV_LOCK.lock().unwrap();
    let (_regions_guard, _single_instance_guard) = clear_local_dev_topology_env();
    let _guard = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", Some("http://127.0.0.1:6333"));
    let existing = InMemoryVmRepo::make_vm("local-dev-us-east-1", "us-east-1");
    let expected_id = existing.id;
    let repo = InMemoryVmRepo::with_vm(existing);

    let result = try_local_dev_provision(&repo, "us-east-1", "aws")
        .await
        .expect("should succeed");

    let vm = result.expect("should return Some(vm)");
    assert_eq!(vm.id, expected_id, "should reuse the existing VM");
    assert_eq!(vm.hostname, "local-dev-us-east-1");
}

#[tokio::test]
async fn try_local_dev_provision_creates_new_vm() {
    let _lock = LOCAL_DEV_ENV_LOCK.lock().unwrap();
    let (_regions_guard, _single_instance_guard) = clear_local_dev_topology_env();
    let _guard = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", Some("http://127.0.0.1:6333"));
    let repo = InMemoryVmRepo::new();

    let result = try_local_dev_provision(&repo, "eu-west-1", "hetzner")
        .await
        .expect("should succeed");

    let vm = result.expect("should return Some(vm)");
    assert_eq!(vm.hostname, "local-dev-eu-west-1");
    assert_eq!(vm.provider, "local");
    assert_eq!(vm.flapjack_url, "http://127.0.0.1:6333");
    assert_eq!(repo.vms.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn try_local_dev_provision_prefers_region_specific_url_from_flapjack_regions() {
    let _lock = LOCAL_DEV_ENV_LOCK.lock().unwrap();
    let _single_instance_guard = EnvVarGuard::set("FLAPJACK_SINGLE_INSTANCE", None);
    let _local_guard = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", Some("http://127.0.0.1:6333"));
    let _regions_guard = EnvVarGuard::set(
        "FLAPJACK_REGIONS",
        Some("us-east-1:7700 eu-west-1:7701 eu-central-1:7702"),
    );
    let repo = InMemoryVmRepo::new();

    let result = try_local_dev_provision(&repo, "eu-west-1", "hetzner")
        .await
        .expect("should succeed");

    let vm = result.expect("should return Some(vm)");
    assert_eq!(vm.hostname, "local-dev-eu-west-1");
    assert_eq!(
        vm.flapjack_url, "http://127.0.0.1:7701",
        "should use the target region port instead of the shared LOCAL_DEV_FLAPJACK_URL"
    );
}

#[tokio::test]
async fn try_local_dev_provision_ignores_region_specific_urls_when_single_instance_is_forced() {
    let _lock = LOCAL_DEV_ENV_LOCK.lock().unwrap();
    let _local_guard = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", Some("http://127.0.0.1:6333"));
    let _regions_guard = EnvVarGuard::set(
        "FLAPJACK_REGIONS",
        Some("us-east-1:7700 eu-west-1:7701 eu-central-1:7702"),
    );
    let _single_instance_guard = EnvVarGuard::set("FLAPJACK_SINGLE_INSTANCE", Some("1"));
    let repo = InMemoryVmRepo::new();

    let result = try_local_dev_provision(&repo, "eu-west-1", "hetzner")
        .await
        .expect("should succeed");

    let vm = result.expect("should return Some(vm)");
    assert_eq!(vm.hostname, "local-dev-eu-west-1");
    assert_eq!(
        vm.flapjack_url, "http://127.0.0.1:6333",
        "single-instance mode should keep using LOCAL_DEV_FLAPJACK_URL"
    );
}

#[tokio::test]
async fn try_local_dev_provision_returns_none_without_env_var() {
    let _lock = LOCAL_DEV_ENV_LOCK.lock().unwrap();
    let (_regions_guard, _single_instance_guard) = clear_local_dev_topology_env();
    let _guard = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", None);
    let repo = InMemoryVmRepo::new();

    let result = try_local_dev_provision(&repo, "us-east-1", "aws")
        .await
        .expect("should succeed");

    assert!(result.is_none(), "should return None when env var is unset");
}

#[tokio::test]
async fn try_local_dev_provision_ignores_invalid_local_dev_url() {
    let _lock = LOCAL_DEV_ENV_LOCK.lock().unwrap();
    let (_regions_guard, _single_instance_guard) = clear_local_dev_topology_env();
    let _guard = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", Some("https://example.com"));
    let repo = InMemoryVmRepo::new();

    let result = try_local_dev_provision(&repo, "us-east-1", "aws")
        .await
        .expect("invalid fallback URL should leave the real provisioner path in charge");

    assert!(
        result.is_none(),
        "invalid fallback URL must not activate the local-dev bypass"
    );
}

#[tokio::test]
async fn try_local_dev_provision_errors_on_invalid_region_specific_port() {
    let _lock = LOCAL_DEV_ENV_LOCK.lock().unwrap();
    let _local_guard = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", Some("http://127.0.0.1:6333"));
    let _regions_guard = EnvVarGuard::set(
        "FLAPJACK_REGIONS",
        Some("us-east-1:7700 eu-west-1:7701@evil.test"),
    );
    let _single_instance_guard = EnvVarGuard::set("FLAPJACK_SINGLE_INSTANCE", None);
    let repo = InMemoryVmRepo::new();

    let err = try_local_dev_provision(&repo, "eu-west-1", "hetzner")
        .await
        .expect_err("should reject non-numeric FLAPJACK_REGIONS ports");

    assert!(
        err.to_string().contains("FLAPJACK_REGIONS"),
        "error should explain the invalid region-specific flapjack contract"
    );
}
