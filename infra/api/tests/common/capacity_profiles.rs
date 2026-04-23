//! Shared capacity profile fixtures for scheduler and placement tests.
//!
//! These constants represent local measured resource envelopes for three
//! document tiers.
//! Memory and disk values were refreshed from
//! `scripts/reliability/profiles/` on 2026-03-24 after a real profiling run.
//! CPU weight and RPS fields still use provisional test-calibration defaults
//! because the current harness does not emit them directly.
//!
//! Downstream stages consume these profiles to calibrate overload thresholds,
//! migration triggers, and placement scoring.

use api::models::resource_vector::ResourceVector;

/// Default VM capacity envelope — the upper bound of resources a single VM provides.
/// This matches the capacity values previously hardcoded in placement_test.rs::vm().
pub const VM_CAPACITY: ResourceVector = ResourceVector {
    cpu_weight: 4.0,
    mem_rss_bytes: 8_000_000_000,
    disk_bytes: 100_000_000_000,
    query_rps: 500.0,
    indexing_rps: 200.0,
};

/// Capacity profile for a 1K document workload.
/// Represents the resource footprint of a single index holding ~1,000 documents.
///
pub const PROFILE_1K: ResourceVector = ResourceVector {
    cpu_weight: 0.1,
    mem_rss_bytes: 27_999_968,
    disk_bytes: 1_424_118,
    query_rps: 10.0,
    indexing_rps: 5.0,
};

/// Capacity profile for a 10K document workload.
///
pub const PROFILE_10K: ResourceVector = ResourceVector {
    cpu_weight: 0.5,
    mem_rss_bytes: 28_814_984,
    disk_bytes: 11_823_627,
    query_rps: 50.0,
    indexing_rps: 20.0,
};

/// Capacity profile for a 100K document workload.
///
pub const PROFILE_100K: ResourceVector = ResourceVector {
    cpu_weight: 2.0,
    mem_rss_bytes: 52_113_872,
    disk_bytes: 61_284_050,
    query_rps: 200.0,
    indexing_rps: 80.0,
};

/// Look up the constant profile for a given tier.
/// Returns None for unknown tier strings.
pub fn constant_profile_for_tier(tier: &str) -> Option<ResourceVector> {
    match tier {
        "1k" => Some(PROFILE_1K),
        "10k" => Some(PROFILE_10K),
        "100k" => Some(PROFILE_100K),
        _ => None,
    }
}

/// Convert a `ResourceVector` to a serde_json::Value.
pub fn resource_vector_to_json(rv: &ResourceVector) -> serde_json::Value {
    serde_json::json!({
        "cpu_weight": rv.cpu_weight,
        "mem_rss_bytes": rv.mem_rss_bytes,
        "disk_bytes": rv.disk_bytes,
        "query_rps": rv.query_rps,
        "indexing_rps": rv.indexing_rps,
    })
}

/// Build a VM capacity JSON value suitable for `NewVmInventory.capacity`.
/// Uses the standard VM_CAPACITY constants.
pub fn vm_capacity_json() -> serde_json::Value {
    resource_vector_to_json(&VM_CAPACITY)
}

// ============================================================================
// Profile artifact loading utilities
// ============================================================================

/// Load a capacity profile from generated artifacts under scripts/reliability/profiles/.
///
/// Reads mem and disk from the tier-specific JSON artifacts and returns a ResourceVector.
/// CPU weight and RPS values are derived from the constants (not yet in artifacts).
///
/// Returns None if artifacts don't exist or are malformed.
pub fn load_profile_from_artifacts(tier: &str) -> Option<ResourceVector> {
    let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let repo_root = manifest_dir.parent()?.parent()?;

    let profiles_dir = repo_root
        .join("scripts")
        .join("reliability")
        .join("profiles");

    // Load mem profile
    let mem_path = profiles_dir.join(format!("{}_mem.json", tier));
    let mem_json: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&mem_path).ok()?).ok()?;
    let mem_bytes = mem_json
        .pointer("/envelope/query_load/rss_bytes")
        .and_then(|v| v.as_u64())?;

    // Load disk profile
    let disk_path = profiles_dir.join(format!("{}_disk.json", tier));
    let disk_json: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&disk_path).ok()?).ok()?;
    let disk_bytes = disk_json
        .pointer("/envelope/post_seed/disk_bytes")
        .and_then(|v| v.as_u64())?;

    // Use constants for cpu_weight and rps (not in artifacts yet)
    let base = constant_profile_for_tier(tier)?;

    Some(ResourceVector {
        cpu_weight: base.cpu_weight,
        mem_rss_bytes: mem_bytes,
        disk_bytes,
        query_rps: base.query_rps,
        indexing_rps: base.indexing_rps,
    })
}

/// Build a capacity JSON value from profile artifacts for a given tier.
///
/// Falls back to the constant profile if artifacts don't exist.
pub fn profile_capacity_json_from_artifacts(tier: &str) -> serde_json::Value {
    let rv = load_profile_from_artifacts(tier).or_else(|| constant_profile_for_tier(tier));
    match rv {
        Some(ref v) => resource_vector_to_json(v),
        None => serde_json::json!({}),
    }
}
