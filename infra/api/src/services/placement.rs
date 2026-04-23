//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/placement.rs.
use chrono::{DateTime, Utc};
use std::time::Duration;
use uuid::Uuid;

use crate::models::resource_vector::ResourceVector;

const DEFAULT_LOAD_STALENESS_THRESHOLD: Duration = Duration::from_secs(300);

/// A VM with its current aggregate load, used as input to placement decisions.
#[derive(Debug, Clone)]
pub struct VmWithLoad {
    pub vm_id: Uuid,
    pub capacity: ResourceVector,
    pub current_load: ResourceVector,
    pub status: String,
    pub load_scraped_at: Option<DateTime<Utc>>,
}

impl VmWithLoad {
    /// Remaining capacity (capacity - current_load) per dimension.
    pub fn remaining(&self) -> ResourceVector {
        ResourceVector {
            cpu_weight: (self.capacity.cpu_weight - self.current_load.cpu_weight).max(0.0),
            mem_rss_bytes: self
                .capacity
                .mem_rss_bytes
                .saturating_sub(self.current_load.mem_rss_bytes),
            disk_bytes: self
                .capacity
                .disk_bytes
                .saturating_sub(self.current_load.disk_bytes),
            query_rps: (self.capacity.query_rps - self.current_load.query_rps).max(0.0),
            indexing_rps: (self.capacity.indexing_rps - self.current_load.indexing_rps).max(0.0),
        }
    }
}

/// Dot-product bin-packing placement (inspired by Panigrahy et al., 2011).
///
/// For each candidate VM with available capacity, computes the normalized dot product
/// of the index's resource vector with the VM's remaining capacity. Each dimension is
/// divided by the VM's total capacity so all dimensions (CPU, memory, disk, query RPS,
/// indexing RPS) contribute equally to the score.
///
/// Selects the VM with the **highest** score — places index where its resource profile
/// aligns best with available headroom. This co-locates complementary workloads:
/// a CPU-heavy index scores higher on a VM with lots of spare CPU (i.e., one currently
/// loaded on disk/memory), spreading utilization across dimensions.
///
/// Returns `None` if no VM has sufficient capacity.
pub fn place_index(index_vector: &ResourceVector, vms: &[VmWithLoad]) -> Option<Uuid> {
    let now = Utc::now();
    let mut best: Option<(Uuid, f64)> = None;

    for vm in vms {
        if vm.status != "active" {
            continue;
        }
        if !is_fresh_load(vm.load_scraped_at, now, DEFAULT_LOAD_STALENESS_THRESHOLD) {
            continue;
        }

        // Check if adding this index would exceed any capacity dimension
        let new_load = vm.current_load.add(index_vector);
        if new_load.exceeds_capacity(&vm.capacity) {
            continue;
        }

        // Normalized dot product of index vector with VM's remaining capacity.
        // Each dimension is divided by VM capacity first so all dimensions
        // contribute equally (preventing byte-valued fields from dominating).
        // Higher score = index resource profile aligns with available headroom,
        // naturally co-locating complementary workloads.
        let remaining = vm.remaining();
        let score = index_vector.dot_normalized(&remaining, &vm.capacity);

        match &best {
            None => best = Some((vm.vm_id, score)),
            Some((_, best_score)) => {
                if score > *best_score {
                    best = Some((vm.vm_id, score));
                }
            }
        }
    }

    best.map(|(id, _)| id)
}

fn is_fresh_load(
    load_scraped_at: Option<DateTime<Utc>>,
    now: DateTime<Utc>,
    threshold: Duration,
) -> bool {
    let Some(scraped_at) = load_scraped_at else {
        return false;
    };

    match now.signed_duration_since(scraped_at).to_std() {
        Ok(age) => age <= threshold,
        Err(_) => true, // clock skew: treat future timestamps as fresh
    }
}

/// Batch placement: sort indexes by total_weight() descending (Decreasing variant),
/// then place one at a time, updating intermediate load after each placement.
///
/// Returns a list of (index_name, vm_id) assignments. Indexes that couldn't be placed
/// are omitted from the result.
pub fn place_batch(
    indexes: &mut [(String, ResourceVector)],
    vms: &mut [VmWithLoad],
) -> Vec<(String, Uuid)> {
    // Sort by total_weight descending — place heaviest indexes first
    indexes.sort_by(|a, b| {
        b.1.total_weight()
            .partial_cmp(&a.1.total_weight())
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    let mut assignments = Vec::new();

    for (name, vector) in indexes.iter() {
        if let Some(vm_id) = place_index(vector, vms) {
            // Update the VM's current load to reflect the new assignment
            if let Some(vm) = vms.iter_mut().find(|v| v.vm_id == vm_id) {
                vm.current_load = vm.current_load.add(vector);
            }
            assignments.push((name.clone(), vm_id));
        }
    }

    assignments
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    fn rv(cpu: f64, mem: u64, disk: u64, qrps: f64, irps: f64) -> ResourceVector {
        ResourceVector {
            cpu_weight: cpu,
            mem_rss_bytes: mem,
            disk_bytes: disk,
            query_rps: qrps,
            indexing_rps: irps,
        }
    }

    fn active_vm(id: Uuid, cap: ResourceVector, load: ResourceVector) -> VmWithLoad {
        VmWithLoad {
            vm_id: id,
            capacity: cap,
            current_load: load,
            status: "active".to_string(),
            load_scraped_at: Some(Utc::now()),
        }
    }

    #[test]
    fn remaining_clamps_to_zero() {
        let vm = VmWithLoad {
            vm_id: Uuid::new_v4(),
            capacity: rv(4.0, 1000, 2000, 100.0, 50.0),
            current_load: rv(5.0, 1500, 3000, 200.0, 100.0),
            status: "active".to_string(),
            load_scraped_at: Some(Utc::now()),
        };
        let r = vm.remaining();
        assert_eq!(r.cpu_weight, 0.0);
        assert_eq!(r.mem_rss_bytes, 0);
        assert_eq!(r.disk_bytes, 0);
        assert_eq!(r.query_rps, 0.0);
        assert_eq!(r.indexing_rps, 0.0);
    }

    #[test]
    fn remaining_subtracts_correctly() {
        let vm = active_vm(
            Uuid::new_v4(),
            rv(8.0, 16_000, 100_000, 500.0, 200.0),
            rv(3.0, 4_000, 30_000, 100.0, 50.0),
        );
        let r = vm.remaining();
        assert!((r.cpu_weight - 5.0).abs() < f64::EPSILON);
        assert_eq!(r.mem_rss_bytes, 12_000);
        assert_eq!(r.disk_bytes, 70_000);
        assert!((r.query_rps - 400.0).abs() < f64::EPSILON);
        assert!((r.indexing_rps - 150.0).abs() < f64::EPSILON);
    }

    #[test]
    fn place_index_returns_none_for_empty_list() {
        let idx = rv(1.0, 1000, 1000, 10.0, 5.0);
        assert!(place_index(&idx, &[]).is_none());
    }

    #[test]
    fn place_index_skips_inactive_vms() {
        let id = Uuid::new_v4();
        let vms = vec![VmWithLoad {
            vm_id: id,
            capacity: rv(8.0, 16_000, 100_000, 500.0, 200.0),
            current_load: rv(0.0, 0, 0, 0.0, 0.0),
            status: "draining".to_string(),
            load_scraped_at: Some(Utc::now()),
        }];
        assert!(place_index(&rv(1.0, 100, 100, 1.0, 1.0), &vms).is_none());
    }

    #[test]
    fn place_index_skips_stale_load_data() {
        let id = Uuid::new_v4();
        let vms = vec![VmWithLoad {
            vm_id: id,
            capacity: rv(8.0, 16_000, 100_000, 500.0, 200.0),
            current_load: rv(0.0, 0, 0, 0.0, 0.0),
            status: "active".to_string(),
            load_scraped_at: Some(Utc::now() - chrono::Duration::seconds(600)),
        }];
        assert!(place_index(&rv(1.0, 100, 100, 1.0, 1.0), &vms).is_none());
    }

    #[test]
    fn place_index_skips_vms_without_capacity() {
        let id = Uuid::new_v4();
        let vms = vec![active_vm(
            id,
            rv(4.0, 8_000, 50_000, 100.0, 50.0),
            rv(3.5, 7_900, 49_000, 99.0, 49.0),
        )];
        // Index needs more CPU than remaining
        let idx = rv(1.0, 50, 500, 0.5, 0.5);
        assert!(place_index(&idx, &vms).is_none());
    }

    /// Verifies that [`place_index`] selects the VM whose remaining capacity
    /// best aligns with the index's resource profile.
    #[test]
    fn place_index_picks_best_alignment() {
        let cpu_heavy_vm = active_vm(
            Uuid::new_v4(),
            rv(8.0, 16_000, 100_000, 500.0, 200.0),
            rv(1.0, 14_000, 90_000, 450.0, 180.0), // lots of CPU headroom
        );
        let mem_heavy_vm = active_vm(
            Uuid::new_v4(),
            rv(8.0, 16_000, 100_000, 500.0, 200.0),
            rv(7.0, 4_000, 90_000, 450.0, 180.0), // lots of mem headroom
        );

        // CPU-heavy index should prefer the VM with CPU headroom
        let cpu_idx = rv(2.0, 100, 500, 1.0, 1.0);
        let picked = place_index(&cpu_idx, &[cpu_heavy_vm.clone(), mem_heavy_vm.clone()]);
        assert_eq!(picked, Some(cpu_heavy_vm.vm_id));

        // Mem-heavy index should prefer the VM with mem headroom
        let mem_idx = rv(0.1, 10_000, 500, 1.0, 1.0);
        let picked = place_index(&mem_idx, &[cpu_heavy_vm.clone(), mem_heavy_vm.clone()]);
        assert_eq!(picked, Some(mem_heavy_vm.vm_id));
    }

    #[test]
    fn place_index_skips_none_scraped_at() {
        let vms = vec![VmWithLoad {
            vm_id: Uuid::new_v4(),
            capacity: rv(8.0, 16_000, 100_000, 500.0, 200.0),
            current_load: rv(0.0, 0, 0, 0.0, 0.0),
            status: "active".to_string(),
            load_scraped_at: None,
        }];
        assert!(place_index(&rv(1.0, 100, 100, 1.0, 1.0), &vms).is_none());
    }

    /// Verifies that [`place_batch`] sorts indexes by `total_weight` descending
    /// and places the heaviest first.
    #[test]
    fn place_batch_assigns_heaviest_first() {
        let vm_id = Uuid::new_v4();
        let mut vms = vec![active_vm(
            vm_id,
            rv(4.0, 8_000, 50_000, 200.0, 100.0),
            rv(0.0, 0, 0, 0.0, 0.0),
        )];
        let mut indexes = vec![
            ("small".to_string(), rv(0.5, 500, 1_000, 10.0, 5.0)),
            ("large".to_string(), rv(3.0, 6_000, 40_000, 150.0, 80.0)),
        ];
        let assignments = place_batch(&mut indexes, &mut vms);

        // Large should be placed first (higher total_weight), small may or may not fit after
        assert!(!assignments.is_empty());
        assert_eq!(assignments[0].0, "large");
        assert_eq!(assignments[0].1, vm_id);
    }

    /// Verifies that [`place_batch`] updates each VM's load after each
    /// placement so subsequent indexes see the accumulated load.
    #[test]
    fn place_batch_updates_intermediate_load() {
        let vm_id = Uuid::new_v4();
        let mut vms = vec![active_vm(
            vm_id,
            rv(4.0, 8_000, 50_000, 200.0, 100.0),
            rv(0.0, 0, 0, 0.0, 0.0),
        )];
        // Two indexes that each need >50% of capacity — only one can fit
        let mut indexes = vec![
            ("a".to_string(), rv(2.5, 5_000, 30_000, 120.0, 60.0)),
            ("b".to_string(), rv(2.5, 5_000, 30_000, 120.0, 60.0)),
        ];
        let assignments = place_batch(&mut indexes, &mut vms);
        assert_eq!(
            assignments.len(),
            1,
            "only one should fit after load update"
        );
    }

    #[test]
    fn is_fresh_load_treats_future_as_fresh() {
        let future = Utc::now() + chrono::Duration::seconds(60);
        assert!(is_fresh_load(
            Some(future),
            Utc::now(),
            Duration::from_secs(300)
        ));
    }
}
