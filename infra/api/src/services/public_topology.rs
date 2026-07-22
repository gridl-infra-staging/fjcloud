use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::Value;

use crate::models::resource_vector::ResourceVector;
use crate::models::vm_inventory::VmInventory;
use crate::services::placement::{is_fresh_load, DEFAULT_LOAD_STALENESS_THRESHOLD};

pub const PUBLIC_TOPOLOGY_MIN_REFRESH_INTERVAL_SECS: u64 = 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "lowercase")]
pub enum UtilizationBucket {
    Green,
    Yellow,
    Red,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PublicVmView {
    pub region: String,
    pub provider: String,
    pub utilization: Option<UtilizationBucket>,
}

pub fn utilization_bucket(
    capacity: &Value,
    current_load: &Value,
    load_scraped_at: Option<DateTime<Utc>>,
    now: DateTime<Utc>,
) -> Option<UtilizationBucket> {
    if !is_fresh_load(load_scraped_at, now, DEFAULT_LOAD_STALENESS_THRESHOLD) {
        return None;
    }

    let capacity = serde_json::from_value::<ResourceVector>(capacity.clone()).ok()?;
    let current_load = serde_json::from_value::<ResourceVector>(current_load.clone()).ok()?;
    if !has_valid_capacity(&capacity) || !has_valid_load(&current_load) {
        return None;
    }

    let max_ratio = maximum_utilization_ratio(&capacity, &current_load);
    Some(match max_ratio {
        ratio if ratio < 0.50 => UtilizationBucket::Green,
        ratio if ratio <= 0.80 => UtilizationBucket::Yellow,
        _ => UtilizationBucket::Red,
    })
}

pub fn to_public_topology(vms: &[&VmInventory], now: DateTime<Utc>) -> Vec<PublicVmView> {
    vms.iter()
        .map(|vm| PublicVmView {
            region: vm.region.clone(),
            provider: vm.provider.clone(),
            utilization: utilization_bucket(
                &vm.capacity,
                &vm.current_load,
                vm.load_scraped_at,
                now,
            ),
        })
        .collect()
}

fn has_valid_capacity(capacity: &ResourceVector) -> bool {
    capacity.cpu_weight.is_finite()
        && capacity.cpu_weight > 0.0
        && capacity.mem_rss_bytes > 0
        && capacity.disk_bytes > 0
        && capacity.query_rps.is_finite()
        && capacity.query_rps > 0.0
        && capacity.indexing_rps.is_finite()
        && capacity.indexing_rps > 0.0
}

fn has_valid_load(load: &ResourceVector) -> bool {
    load.cpu_weight.is_finite()
        && load.cpu_weight >= 0.0
        && load.query_rps.is_finite()
        && load.query_rps >= 0.0
        && load.indexing_rps.is_finite()
        && load.indexing_rps >= 0.0
}

fn maximum_utilization_ratio(capacity: &ResourceVector, load: &ResourceVector) -> f64 {
    [
        load.cpu_weight / capacity.cpu_weight,
        load.mem_rss_bytes as f64 / capacity.mem_rss_bytes as f64,
        load.disk_bytes as f64 / capacity.disk_bytes as f64,
        load.query_rps / capacity.query_rps,
        load.indexing_rps / capacity.indexing_rps,
    ]
    .into_iter()
    .fold(0.0_f64, f64::max)
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use chrono::{Duration, TimeZone, Utc};
    use serde_json::{json, Value};
    use uuid::Uuid;

    use super::*;
    use crate::models::vm_inventory::VmInventory;
    use crate::services::placement::DEFAULT_LOAD_STALENESS_THRESHOLD;

    const ABSOLUTE_CAPACITY_SENTINEL: u64 = 424_242_424_242;

    fn now() -> chrono::DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 7, 20, 16, 0, 0).unwrap()
    }

    fn vector(
        cpu_weight: f64,
        mem_rss_bytes: u64,
        disk_bytes: u64,
        query_rps: f64,
        indexing_rps: f64,
    ) -> Value {
        json!({
            "cpu_weight": cpu_weight,
            "mem_rss_bytes": mem_rss_bytes,
            "disk_bytes": disk_bytes,
            "query_rps": query_rps,
            "indexing_rps": indexing_rps,
        })
    }

    fn vm(region: &str, provider: &str, load_ratio: f64) -> VmInventory {
        VmInventory {
            id: Uuid::parse_str("a81bc81b-dead-4e5d-abff-90865d1e13b1").unwrap(),
            region: region.to_owned(),
            provider: provider.to_owned(),
            hostname: "private-hostname-sentinel.internal".to_owned(),
            flapjack_url: "http://192.0.2.217:7700".to_owned(),
            capacity: vector(
                ABSOLUTE_CAPACITY_SENTINEL as f64,
                ABSOLUTE_CAPACITY_SENTINEL,
                ABSOLUTE_CAPACITY_SENTINEL,
                ABSOLUTE_CAPACITY_SENTINEL as f64,
                ABSOLUTE_CAPACITY_SENTINEL as f64,
            ),
            current_load: vector(
                ABSOLUTE_CAPACITY_SENTINEL as f64 * load_ratio,
                (ABSOLUTE_CAPACITY_SENTINEL as f64 * load_ratio) as u64,
                (ABSOLUTE_CAPACITY_SENTINEL as f64 * load_ratio) as u64,
                ABSOLUTE_CAPACITY_SENTINEL as f64 * load_ratio,
                ABSOLUTE_CAPACITY_SENTINEL as f64 * load_ratio,
            ),
            load_scraped_at: Some(now()),
            status: "active".to_owned(),
            created_at: now(),
            updated_at: now(),
        }
    }

    fn bucket(capacity: Value, current_load: Value) -> Option<UtilizationBucket> {
        utilization_bucket(&capacity, &current_load, Some(now()), now())
    }

    #[test]
    fn to_public_topology_never_leaks_host_or_absolute_capacity() {
        let first = vm("us-east-1", "aws", 0.25);
        let second = vm("eu-west-1", "hetzner", 0.90);

        let serialized =
            serde_json::to_value(to_public_topology(&[&first, &second], now())).unwrap();
        let serialized_text = serialized.to_string();

        for sentinel in [
            "a81bc81b-dead-4e5d-abff-90865d1e13b1",
            "private-hostname-sentinel.internal",
            "192.0.2.217",
            "http://192.0.2.217:7700",
            "424242424242",
        ] {
            assert!(
                !serialized_text.contains(sentinel),
                "public topology leaked sentinel {sentinel}: {serialized_text}"
            );
        }

        assert_eq!(serialized[0]["region"], "us-east-1");
        assert_eq!(serialized[1]["region"], "eu-west-1");
        for public_vm in serialized.as_array().unwrap() {
            let keys = public_vm
                .as_object()
                .unwrap()
                .keys()
                .cloned()
                .collect::<BTreeSet<_>>();
            assert_eq!(
                keys,
                BTreeSet::from([
                    "provider".to_owned(),
                    "region".to_owned(),
                    "utilization".to_owned(),
                ])
            );
            assert!(
                public_vm["utilization"].is_null()
                    || matches!(
                        public_vm["utilization"].as_str(),
                        Some("green" | "yellow" | "red")
                    )
            );
        }
    }

    #[test]
    fn utilization_buckets_cover_boundaries_and_worst_dimension() {
        let capacity = vector(100.0, 100, 100, 100.0, 100.0);
        let cases = [
            (
                vector(49.0, 49, 49, 49.0, 49.0),
                UtilizationBucket::Green,
                "green",
            ),
            (
                vector(50.0, 50, 50, 50.0, 50.0),
                UtilizationBucket::Yellow,
                "yellow",
            ),
            (
                vector(80.0, 80, 80, 80.0, 80.0),
                UtilizationBucket::Yellow,
                "yellow",
            ),
            (
                vector(81.0, 81, 81, 81.0, 81.0),
                UtilizationBucket::Red,
                "red",
            ),
            (
                vector(10.0, 10, 90, 10.0, 10.0),
                UtilizationBucket::Red,
                "red",
            ),
        ];

        for (load, expected_bucket, expected_json) in cases {
            let actual = bucket(capacity.clone(), load).unwrap();
            assert_eq!(actual, expected_bucket);
            assert_eq!(serde_json::to_value(actual).unwrap(), expected_json);
        }
    }

    #[test]
    fn stale_load_returns_none() {
        let capacity = vector(100.0, 100, 100, 100.0, 100.0);
        let load = vector(10.0, 10, 10, 10.0, 10.0);
        let threshold = Duration::from_std(DEFAULT_LOAD_STALENESS_THRESHOLD).unwrap();

        assert_eq!(
            utilization_bucket(&capacity, &load, Some(now() - threshold), now()),
            Some(UtilizationBucket::Green)
        );
        assert_eq!(
            utilization_bucket(
                &capacity,
                &load,
                Some(now() - threshold - Duration::seconds(1)),
                now()
            ),
            None
        );
        assert_eq!(utilization_bucket(&capacity, &load, None, now()), None);
    }

    #[test]
    fn invalid_telemetry_returns_none() {
        let valid_capacity = vector(100.0, 100, 100, 100.0, 100.0);
        let zero_load = vector(0.0, 0, 0, 0.0, 0.0);
        assert_eq!(
            bucket(valid_capacity.clone(), zero_load.clone()),
            Some(UtilizationBucket::Green)
        );

        let invalid_capacities = [
            vector(0.0, 0, 0, 0.0, 0.0),
            vector(0.0, 100, 100, 100.0, 100.0),
            vector(100.0, 0, 100, 100.0, 100.0),
            vector(100.0, 100, 0, 100.0, 100.0),
            vector(100.0, 100, 100, 0.0, 100.0),
            vector(100.0, 100, 100, 100.0, 0.0),
            vector(-1.0, 100, 100, 100.0, 100.0),
            json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": -1.0,
                "disk_bytes": 100,
                "query_rps": 100.0,
                "indexing_rps": 100.0,
            }),
            json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": 100,
                "disk_bytes": 100,
                "query_rps": "100",
                "indexing_rps": 100.0,
            }),
            json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": 100,
                "disk_bytes": 100,
                "query_rps": 100.0,
            }),
        ];
        for capacity in invalid_capacities {
            assert_eq!(bucket(capacity, zero_load.clone()), None);
        }

        for load in [
            vector(-1.0, 0, 0, 0.0, 0.0),
            vector(0.0, 0, 0, -1.0, 0.0),
            vector(0.0, 0, 0, 0.0, -1.0),
            json!({
                "cpu_weight": 0.0,
                "mem_rss_bytes": 0,
                "disk_bytes": 0,
                "query_rps": 0.0,
            }),
            json!({
                "cpu_weight": false,
                "mem_rss_bytes": 0,
                "disk_bytes": 0,
                "query_rps": 0.0,
                "indexing_rps": 0.0,
            }),
        ] {
            assert_eq!(bucket(valid_capacity.clone(), load), None);
        }
    }
}
