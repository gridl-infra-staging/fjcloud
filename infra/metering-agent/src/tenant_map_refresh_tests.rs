use super::*;
use uuid::Uuid;

fn refresh_entries(
    first_customer: Uuid,
    new_customer: Uuid,
    local_flapjack_url: &str,
) -> Vec<TenantMapEntry> {
    vec![
        TenantMapEntry {
            tenant_id: "products".to_string(),
            flapjack_uid: Some(format!("{}_products", first_customer.as_simple())),
            customer_id: first_customer,
            vm_id: None,
            flapjack_url: Some(local_flapjack_url.to_string()),
            tier: "active".to_string(),
            created_at: chrono::DateTime::<chrono::Utc>::UNIX_EPOCH,
        },
        TenantMapEntry {
            tenant_id: "new-index".to_string(),
            flapjack_uid: None,
            customer_id: new_customer,
            vm_id: None,
            flapjack_url: Some(local_flapjack_url.to_string()),
            tier: "active".to_string(),
            created_at: chrono::DateTime::<chrono::Utc>::UNIX_EPOCH,
        },
    ]
}

/// Guards the periodic-refresh invariant: the cache must not be replaced
/// before `refresh_interval` has elapsed, but must be fully replaced once
/// the interval has passed.
///
/// The test advances a simulated clock by 120 s (below the 300 s interval)
/// and verifies no refresh occurs, then advances past 600 s and verifies
/// that the new payload — including a previously absent `new-index` — is
/// now present in the cache.
#[test]
fn metering_refreshes_tenant_map_periodically() {
    let tenant_map: TenantCustomerMap = Arc::new(DashMap::new());
    let refresh_interval = Duration::from_secs(300);
    let mut last_refresh = Some(Instant::now());
    let local_flapjack_url = "http://localhost:7700";

    let first_customer = Uuid::new_v4();
    tenant_map.insert(
        "products".to_string(),
        TenantAttribution {
            customer_id: first_customer,
            tenant_id: "products".to_string(),
            tier: "active".to_string(),
            created_at: chrono::DateTime::<chrono::Utc>::UNIX_EPOCH,
        },
    );

    let did_refresh = refresh_tenant_map_cache_if_due(
        &tenant_map,
        &mut last_refresh,
        Instant::now() + Duration::from_secs(120),
        refresh_interval,
        local_flapjack_url,
        refresh_entries(first_customer, Uuid::new_v4(), local_flapjack_url),
    );
    assert!(!did_refresh);
    assert!(tenant_map.get("new-index").is_none());

    let new_customer = Uuid::new_v4();
    let did_refresh = refresh_tenant_map_cache_if_due(
        &tenant_map,
        &mut last_refresh,
        Instant::now() + Duration::from_secs(601),
        refresh_interval,
        local_flapjack_url,
        refresh_entries(first_customer, new_customer, local_flapjack_url),
    );
    assert!(did_refresh);
    assert_eq!(
        tenant_map
            .get("new-index")
            .expect("new-index should be present after refresh")
            .value()
            .customer_id,
        new_customer
    );
}
