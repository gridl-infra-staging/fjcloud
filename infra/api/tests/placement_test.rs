use api::models::resource_vector::ResourceVector;
use api::services::placement::{place_batch, place_index, VmWithLoad};
use chrono::{Duration, Utc};
use uuid::Uuid;

mod common;

fn vm(
    cpu_load: f64,
    mem_load: u64,
    disk_load: u64,
    query_load: f64,
    indexing_load: f64,
) -> VmWithLoad {
    VmWithLoad {
        vm_id: Uuid::new_v4(),
        capacity: common::capacity_profiles::VM_CAPACITY.clone(),
        current_load: ResourceVector {
            cpu_weight: cpu_load,
            mem_rss_bytes: mem_load,
            disk_bytes: disk_load,
            query_rps: query_load,
            indexing_rps: indexing_load,
        },
        status: "active".to_string(),
        load_scraped_at: Some(Utc::now()),
    }
}

#[test]
fn resource_vector_dot_product_basic() {
    let a = ResourceVector {
        cpu_weight: 2.0,
        mem_rss_bytes: 1000,
        disk_bytes: 500,
        query_rps: 10.0,
        indexing_rps: 5.0,
    };
    let b = ResourceVector {
        cpu_weight: 3.0,
        mem_rss_bytes: 2000,
        disk_bytes: 1000,
        query_rps: 20.0,
        indexing_rps: 10.0,
    };
    // 2*3 + 1000*2000 + 500*1000 + 10*20 + 5*10
    let expected = 6.0 + 2_000_000.0 + 500_000.0 + 200.0 + 50.0;
    assert!((a.dot(&b) - expected).abs() < 1e-6);
}

#[test]
fn resource_vector_exceeds_capacity() {
    let capacity = ResourceVector {
        cpu_weight: 4.0,
        mem_rss_bytes: 8000,
        disk_bytes: 100000,
        query_rps: 500.0,
        indexing_rps: 200.0,
    };

    // Within capacity
    let within = ResourceVector {
        cpu_weight: 3.0,
        mem_rss_bytes: 7000,
        disk_bytes: 90000,
        query_rps: 400.0,
        indexing_rps: 100.0,
    };
    assert!(!within.exceeds_capacity(&capacity));

    // Exceeds in one dimension (CPU)
    let exceeds = ResourceVector {
        cpu_weight: 5.0,
        mem_rss_bytes: 7000,
        disk_bytes: 90000,
        query_rps: 400.0,
        indexing_rps: 100.0,
    };
    assert!(exceeds.exceeds_capacity(&capacity));

    // Exactly at capacity — should NOT exceed (uses > not >=)
    let at_capacity = ResourceVector {
        cpu_weight: 4.0,
        mem_rss_bytes: 8000,
        disk_bytes: 100000,
        query_rps: 500.0,
        indexing_rps: 200.0,
    };
    assert!(
        !at_capacity.exceeds_capacity(&capacity),
        "at-capacity load must not be treated as exceeding"
    );
}

#[test]
fn placement_scores_complementary_workloads_higher() {
    // Both VMs have enough capacity for the index (no exceeds_capacity exclusion).
    // They differ in load profile: VM A is CPU-heavy, VM B is disk-heavy.
    // A CPU-heavy index should be placed on VM B (more remaining CPU = complementary).

    // VM A: high CPU load (2.5 of 4.0), low disk load (20 GB of 100 GB)
    // Remaining: cpu=1.5, disk=80GB
    let vm_cpu_heavy = vm(2.5, 2_000_000_000, 20_000_000_000, 200.0, 80.0);

    // VM B: low CPU load (0.5 of 4.0), high disk load (70 GB of 100 GB)
    // Remaining: cpu=3.5, disk=30GB
    let vm_disk_heavy = vm(0.5, 2_000_000_000, 70_000_000_000, 200.0, 80.0);

    let cpu_heavy_id = vm_cpu_heavy.vm_id;
    let disk_heavy_id = vm_disk_heavy.vm_id;

    // CPU-heavy index: high CPU demand, modest disk demand
    let cpu_heavy_index = ResourceVector {
        cpu_weight: 1.0,
        mem_rss_bytes: 500_000_000,
        disk_bytes: 1_000_000_000,
        query_rps: 50.0,
        indexing_rps: 20.0,
    };

    let vms = vec![vm_cpu_heavy.clone(), vm_disk_heavy.clone()];
    let chosen = place_index(&cpu_heavy_index, &vms).unwrap();

    // Normalized dot product: CPU-heavy index gets higher score on VM B
    // (which has more remaining CPU as a fraction of capacity).
    assert_eq!(
        chosen, disk_heavy_id,
        "CPU-heavy index should be placed on disk-heavy VM (complementary)"
    );

    // Conversely, a disk-heavy index should go on the CPU-heavy VM
    let disk_heavy_index = ResourceVector {
        cpu_weight: 0.1,
        mem_rss_bytes: 500_000_000,
        disk_bytes: 15_000_000_000,
        query_rps: 10.0,
        indexing_rps: 5.0,
    };

    let vms2 = vec![vm_cpu_heavy, vm_disk_heavy];
    let chosen2 = place_index(&disk_heavy_index, &vms2).unwrap();

    assert_eq!(
        chosen2, cpu_heavy_id,
        "disk-heavy index should be placed on CPU-heavy VM (complementary)"
    );
}

#[test]
fn placement_excludes_full_vms() {
    // VM at CPU capacity
    let full_vm = vm(4.0, 1_000_000_000, 10_000_000_000, 100.0, 50.0);
    let available_vm = vm(1.0, 1_000_000_000, 10_000_000_000, 100.0, 50.0);
    let available_id = available_vm.vm_id;

    let index = ResourceVector {
        cpu_weight: 0.5,
        mem_rss_bytes: 100_000_000,
        disk_bytes: 1_000_000_000,
        query_rps: 10.0,
        indexing_rps: 5.0,
    };

    let vms = vec![full_vm, available_vm];
    let chosen = place_index(&index, &vms).unwrap();
    assert_eq!(chosen, available_id, "full VM should be excluded");
}

#[test]
fn placement_rejects_index_exceeding_any_single_dimension() {
    let candidate = VmWithLoad {
        vm_id: Uuid::new_v4(),
        capacity: ResourceVector {
            cpu_weight: 4.0,
            mem_rss_bytes: 8_000_000_000,
            disk_bytes: 100_000_000_000,
            query_rps: 500.0,
            indexing_rps: 200.0,
        },
        current_load: ResourceVector {
            cpu_weight: 3.0,
            mem_rss_bytes: 1_000_000_000,
            disk_bytes: 10_000_000_000,
            query_rps: 100.0,
            indexing_rps: 50.0,
        },
        status: "active".to_string(),
        load_scraped_at: Some(Utc::now()),
    };

    let cpu_only_index = ResourceVector {
        cpu_weight: 2.0,
        mem_rss_bytes: 0,
        disk_bytes: 0,
        query_rps: 0.0,
        indexing_rps: 0.0,
    };

    assert!(
        place_index(&cpu_only_index, &[candidate]).is_none(),
        "placement must reject when any one dimension exceeds capacity"
    );
}

#[test]
fn placement_excludes_draining_vms() {
    let mut draining = vm(0.5, 1_000_000_000, 10_000_000_000, 50.0, 20.0);
    draining.status = "draining".to_string();

    let active = vm(1.0, 2_000_000_000, 20_000_000_000, 100.0, 50.0);
    let active_id = active.vm_id;

    let index = ResourceVector {
        cpu_weight: 0.5,
        mem_rss_bytes: 100_000_000,
        disk_bytes: 1_000_000_000,
        query_rps: 10.0,
        indexing_rps: 5.0,
    };

    let vms = vec![draining, active];
    let chosen = place_index(&index, &vms).unwrap();
    assert_eq!(chosen, active_id, "draining VM should be excluded");
}

#[test]
fn placement_returns_none_when_no_capacity() {
    // Both VMs at capacity
    let full_a = vm(3.8, 7_500_000_000, 95_000_000_000, 450.0, 180.0);
    let full_b = vm(3.9, 7_800_000_000, 98_000_000_000, 480.0, 190.0);

    let heavy_index = ResourceVector {
        cpu_weight: 1.0,
        mem_rss_bytes: 1_000_000_000,
        disk_bytes: 10_000_000_000,
        query_rps: 100.0,
        indexing_rps: 50.0,
    };

    let vms = vec![full_a, full_b];
    let chosen = place_index(&heavy_index, &vms);
    assert!(chosen.is_none(), "no VM should have capacity");
}

#[test]
fn placement_batch_decreasing_order() {
    let vm_a = vm(0.0, 0, 0, 0.0, 0.0);
    let _vm_a_id = vm_a.vm_id;

    let mut indexes = vec![
        (
            "small".to_string(),
            ResourceVector {
                cpu_weight: 0.1,
                mem_rss_bytes: 100_000_000,
                disk_bytes: 1_000_000_000,
                query_rps: 5.0,
                indexing_rps: 2.0,
            },
        ),
        (
            "large".to_string(),
            ResourceVector {
                cpu_weight: 2.0,
                mem_rss_bytes: 4_000_000_000,
                disk_bytes: 50_000_000_000,
                query_rps: 200.0,
                indexing_rps: 100.0,
            },
        ),
    ];

    let mut vms = vec![vm_a];
    let assignments = place_batch(&mut indexes, &mut vms);

    // Both should be placed (single VM has enough capacity)
    assert_eq!(assignments.len(), 2);
    // The "large" index should be placed first (decreasing order)
    assert_eq!(assignments[0].0, "large");
    assert_eq!(assignments[1].0, "small");
}

#[test]
fn placement_empty_vm_chosen_for_first_index() {
    // An empty VM should be a valid placement target
    let empty = vm(0.0, 0, 0, 0.0, 0.0);
    let empty_id = empty.vm_id;

    let index = ResourceVector {
        cpu_weight: 1.0,
        mem_rss_bytes: 1_000_000_000,
        disk_bytes: 5_000_000_000,
        query_rps: 50.0,
        indexing_rps: 20.0,
    };

    let vms = vec![empty];
    let chosen = place_index(&index, &vms).unwrap();
    assert_eq!(chosen, empty_id);
}

#[test]
fn placement_excludes_stale_vm() {
    let mut stale = vm(0.1, 100_000_000, 1_000_000_000, 5.0, 2.0);
    stale.load_scraped_at = Some(Utc::now() - Duration::minutes(6));

    let index = ResourceVector {
        cpu_weight: 0.1,
        mem_rss_bytes: 10_000_000,
        disk_bytes: 10_000_000,
        query_rps: 1.0,
        indexing_rps: 1.0,
    };

    assert!(
        place_index(&index, &[stale]).is_none(),
        "stale-only candidate list should be unplaceable"
    );
}

#[test]
fn placement_allows_fresh_vm() {
    let mut fresh = vm(0.1, 100_000_000, 1_000_000_000, 5.0, 2.0);
    fresh.load_scraped_at = Some(Utc::now() - Duration::minutes(2));
    let fresh_id = fresh.vm_id;

    let index = ResourceVector {
        cpu_weight: 0.1,
        mem_rss_bytes: 10_000_000,
        disk_bytes: 10_000_000,
        query_rps: 1.0,
        indexing_rps: 1.0,
    };

    assert_eq!(place_index(&index, &[fresh]), Some(fresh_id));
}

#[test]
fn placement_prefers_fresh_vm_over_stale_even_if_stale_has_more_capacity() {
    let stale_id = Uuid::new_v4();
    let stale = VmWithLoad {
        vm_id: stale_id,
        capacity: ResourceVector {
            cpu_weight: 8.0,
            mem_rss_bytes: 16_000_000_000,
            disk_bytes: 200_000_000_000,
            query_rps: 1_000.0,
            indexing_rps: 400.0,
        },
        current_load: ResourceVector::zero(),
        status: "active".to_string(),
        load_scraped_at: Some(Utc::now() - Duration::minutes(10)),
    };

    let fresh = vm(1.0, 1_000_000_000, 10_000_000_000, 20.0, 10.0);
    let fresh_id = fresh.vm_id;

    let index = ResourceVector {
        cpu_weight: 0.2,
        mem_rss_bytes: 100_000_000,
        disk_bytes: 100_000_000,
        query_rps: 2.0,
        indexing_rps: 1.0,
    };

    let chosen = place_index(&index, &[stale, fresh]);
    assert_eq!(chosen, Some(fresh_id));
}

#[test]
fn placement_excludes_vm_with_null_load_scraped_at() {
    let mut never_scraped = vm(0.1, 100_000_000, 1_000_000_000, 5.0, 2.0);
    never_scraped.load_scraped_at = None;

    let index = ResourceVector {
        cpu_weight: 0.1,
        mem_rss_bytes: 10_000_000,
        disk_bytes: 10_000_000,
        query_rps: 1.0,
        indexing_rps: 1.0,
    };

    assert!(
        place_index(&index, &[never_scraped]).is_none(),
        "VM with NULL load_scraped_at should be excluded"
    );
}

// ---- ResourceVector unit tests ----

#[test]
fn resource_vector_json_round_trip() {
    let rv = ResourceVector {
        cpu_weight: 2.5,
        mem_rss_bytes: 4_294_967_296,
        disk_bytes: 50_000_000_000,
        query_rps: 120.0,
        indexing_rps: 45.0,
    };

    let json: serde_json::Value = rv.clone().into();
    assert_eq!(json["cpu_weight"], 2.5);
    assert_eq!(json["mem_rss_bytes"], 4_294_967_296_u64);
    assert_eq!(json["disk_bytes"], 50_000_000_000_u64);
    assert_eq!(json["query_rps"], 120.0);
    assert_eq!(json["indexing_rps"], 45.0);

    let back: ResourceVector = json.into();
    assert_eq!(back, rv);
}

#[test]
fn resource_vector_from_json_missing_fields_default_to_zero() {
    let partial = serde_json::json!({ "cpu_weight": 1.5 });
    let rv: ResourceVector = partial.into();
    assert_eq!(rv.cpu_weight, 1.5);
    assert_eq!(rv.mem_rss_bytes, 0);
    assert_eq!(rv.disk_bytes, 0);
    assert_eq!(rv.query_rps, 0.0);
    assert_eq!(rv.indexing_rps, 0.0);
}

#[test]
fn resource_vector_from_empty_json() {
    let empty = serde_json::json!({});
    let rv: ResourceVector = empty.into();
    assert_eq!(rv, ResourceVector::zero());
}

#[test]
fn resource_vector_add() {
    let a = ResourceVector {
        cpu_weight: 1.0,
        mem_rss_bytes: 1000,
        disk_bytes: 2000,
        query_rps: 10.0,
        indexing_rps: 5.0,
    };
    let b = ResourceVector {
        cpu_weight: 0.5,
        mem_rss_bytes: 500,
        disk_bytes: 1000,
        query_rps: 3.0,
        indexing_rps: 2.0,
    };
    let sum = a.add(&b);
    assert_eq!(sum.cpu_weight, 1.5);
    assert_eq!(sum.mem_rss_bytes, 1500);
    assert_eq!(sum.disk_bytes, 3000);
    assert_eq!(sum.query_rps, 13.0);
    assert_eq!(sum.indexing_rps, 7.0);
}

#[test]
fn resource_vector_dot_normalized_equal_weights() {
    // When all dimensions are at 50% of capacity, the normalized dot product of
    // the load with itself should be 5 * (0.5 * 0.5) = 1.25
    let capacity = ResourceVector {
        cpu_weight: 4.0,
        mem_rss_bytes: 8_000_000_000,
        disk_bytes: 100_000_000_000,
        query_rps: 500.0,
        indexing_rps: 200.0,
    };
    let half = ResourceVector {
        cpu_weight: 2.0,
        mem_rss_bytes: 4_000_000_000,
        disk_bytes: 50_000_000_000,
        query_rps: 250.0,
        indexing_rps: 100.0,
    };
    let score = half.dot_normalized(&half, &capacity);
    assert!((score - 1.25).abs() < 1e-9, "expected 1.25, got {score}");
}

#[test]
fn resource_vector_dot_normalized_zero_capacity_safe() {
    // Zero capacity in some dimension should not panic or produce NaN
    let capacity = ResourceVector {
        cpu_weight: 0.0,
        mem_rss_bytes: 0,
        disk_bytes: 100_000_000_000,
        query_rps: 500.0,
        indexing_rps: 0.0,
    };
    let load = ResourceVector {
        cpu_weight: 1.0,
        mem_rss_bytes: 1000,
        disk_bytes: 50_000_000_000,
        query_rps: 250.0,
        indexing_rps: 10.0,
    };
    let score = load.dot_normalized(&load, &capacity);
    assert!(score.is_finite(), "score must be finite, got {score}");
    // Only disk and query dimensions contribute (cpu, mem, indexing have 0 capacity)
    // disk: (50B/100B)^2 = 0.25, query: (250/500)^2 = 0.25 → total 0.5
    assert!((score - 0.5).abs() < 1e-9, "expected 0.5, got {score}");
}

#[test]
fn resource_vector_total_weight_ordering() {
    let heavy = ResourceVector {
        cpu_weight: 3.0,
        mem_rss_bytes: 4_000_000_000,
        disk_bytes: 80_000_000_000,
        query_rps: 300.0,
        indexing_rps: 100.0,
    };
    let light = ResourceVector {
        cpu_weight: 0.1,
        mem_rss_bytes: 100_000_000,
        disk_bytes: 1_000_000_000,
        query_rps: 5.0,
        indexing_rps: 2.0,
    };
    assert!(
        heavy.total_weight() > light.total_weight(),
        "heavy ({}) should outweigh light ({})",
        heavy.total_weight(),
        light.total_weight()
    );
}
