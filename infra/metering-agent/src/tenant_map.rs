use std::sync::Arc;
#[cfg(test)]
use std::time::{Duration, Instant};

use dashmap::DashMap;

use super::Config;

pub type TenantCustomerMap = Arc<DashMap<String, TenantAttribution>>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TenantAttribution {
    pub customer_id: uuid::Uuid,
    pub tenant_id: String,
    pub tier: String,
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct TenantMapEntry {
    pub tenant_id: String,
    #[serde(default)]
    pub flapjack_uid: Option<String>,
    pub customer_id: uuid::Uuid,
    pub vm_id: Option<uuid::Uuid>,
    #[serde(default)]
    pub flapjack_url: Option<String>,
    #[serde(default = "default_tier")]
    pub tier: String,
}

pub fn default_tier() -> String {
    "active".to_string()
}

pub fn is_cold_tier(tier: &str) -> bool {
    matches!(tier, "cold" | "restoring")
}

pub fn resolve_tenant_attribution(
    tenant_map: &TenantCustomerMap,
    tenant_id: &str,
) -> Option<TenantAttribution> {
    tenant_map.get(tenant_id).map(|entry| entry.value().clone())
}

pub fn normalize_url(url: &str) -> String {
    url.trim_end_matches('/').to_string()
}

pub async fn fetch_tenant_map(
    cfg: &Config,
    http: &reqwest::Client,
) -> anyhow::Result<Vec<TenantMapEntry>> {
    let response = http
        .get(cfg.tenant_map_url())
        .header("x-internal-key", &cfg.internal_key)
        .send()
        .await?
        .error_for_status()?;
    Ok(response.json::<Vec<TenantMapEntry>>().await?)
}

/// Atomically replace the in-memory tenant-map cache with a fresh set of
/// entries from the control-plane.
///
/// The cache is cleared first, then repopulated according to the following
/// routing rules:
///
/// - **No routing metadata** (all entries lack `flapjack_url`): every entry
///   is accepted.  This is the single-node / local-dev mode where there is no
///   multi-VM topology.
/// - **Routing metadata present** (at least one entry has `flapjack_url`):
///   only entries whose `flapjack_url` matches `local_flapjack_url` (after
///   stripping trailing slashes) are kept.  Entries without a URL are skipped
///   — they cannot be routed to this node.
///
/// Duplicate `tenant_id` values within the local subset are deduplicated:
/// the first occurrence wins and a warning is logged for subsequent ones.
///
/// `vm_id` is intentionally unused — it exists in the payload for future
/// routing use but is not needed for attribution.
pub fn replace_tenant_map_cache(
    tenant_map: &TenantCustomerMap,
    entries: Vec<TenantMapEntry>,
    local_flapjack_url: &str,
) {
    tenant_map.clear();
    let local_url = normalize_url(local_flapjack_url);
    let has_routing_metadata = entries.iter().any(|entry| entry.flapjack_url.is_some());

    for entry in entries {
        let _ = entry.vm_id;
        if has_routing_metadata {
            let Some(entry_url) = entry.flapjack_url.as_deref() else {
                continue;
            };
            if normalize_url(entry_url) != local_url {
                continue;
            }
        }

        if tenant_map.contains_key(&entry.tenant_id) {
            tracing::warn!(
                tenant_id = entry.tenant_id.as_str(),
                "duplicate tenant_id in tenant-map payload for local node; keeping first mapping"
            );
            continue;
        }

        let canonical_tenant_id = entry.tenant_id;
        let alias_flapjack_uid = entry.flapjack_uid;
        let customer_id = entry.customer_id;
        let tier = entry.tier;

        tenant_map.insert(
            canonical_tenant_id.clone(),
            TenantAttribution {
                customer_id,
                tenant_id: canonical_tenant_id.clone(),
                tier: tier.clone(),
            },
        );

        if let Some(flapjack_uid) = alias_flapjack_uid {
            if flapjack_uid != canonical_tenant_id && !tenant_map.contains_key(&flapjack_uid) {
                tenant_map.insert(
                    flapjack_uid,
                    TenantAttribution {
                        customer_id,
                        tenant_id: canonical_tenant_id,
                        tier,
                    },
                );
            }
        }
    }
}

/// Refresh the tenant-map cache only when the refresh interval has elapsed.
///
/// Used in tests to drive time-based refresh logic without real async I/O.
/// `last_refresh` is `None` on first call (always refreshes) and is updated
/// to `now` on every refresh.  Returns `true` if a refresh was performed,
/// `false` if the interval has not yet elapsed.
///
/// This function is `#[cfg(test)]` only — production code uses the async
/// `refresh_tenant_map` function on a `tokio::time::interval` ticker.
#[cfg(test)]
pub(crate) fn refresh_tenant_map_cache_if_due(
    tenant_map: &TenantCustomerMap,
    last_refresh: &mut Option<Instant>,
    now: Instant,
    refresh_interval: Duration,
    local_flapjack_url: &str,
    entries: Vec<TenantMapEntry>,
) -> bool {
    let due = match last_refresh {
        None => true,
        Some(last) => now.duration_since(*last) >= refresh_interval,
    };
    if !due {
        return false;
    }

    replace_tenant_map_cache(tenant_map, entries, local_flapjack_url);
    *last_refresh = Some(now);
    true
}

pub async fn refresh_tenant_map(
    cfg: &Config,
    http: &reqwest::Client,
    tenant_map: &TenantCustomerMap,
) -> anyhow::Result<usize> {
    let entries = fetch_tenant_map(cfg, http).await?;
    replace_tenant_map_cache(tenant_map, entries, &cfg.flapjack_url);
    Ok(tenant_map.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{extract::State, http::HeaderMap, routing::get, Router};
    use std::time::{Duration, Instant};
    use tokio::net::TcpListener;
    use uuid::Uuid;

    #[derive(Clone)]
    struct HeaderCaptureState {
        observed_key: Arc<std::sync::Mutex<Option<String>>>,
    }

    async fn spawn_tenant_map_server(
        state: HeaderCaptureState,
    ) -> (String, tokio::task::JoinHandle<()>) {
        let app = Router::new()
            .route("/internal/tenant-map", get(capture_tenant_map_headers))
            .with_state(state);
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("listener should bind");
        let addr = listener.local_addr().expect("listener should expose addr");
        let handle = tokio::spawn(async move {
            axum::serve(listener, app)
                .await
                .expect("test server should run");
        });
        (format!("http://{addr}"), handle)
    }

    async fn capture_tenant_map_headers(
        State(state): State<HeaderCaptureState>,
        headers: HeaderMap,
    ) -> String {
        let observed = headers
            .get("x-internal-key")
            .and_then(|value| value.to_str().ok())
            .map(ToOwned::to_owned);
        *state
            .observed_key
            .lock()
            .expect("header capture mutex should lock") = observed;
        "[]".to_string()
    }

    // ---- Pure function tests ------------------------------------------------

    #[test]
    fn default_tier_is_active() {
        assert_eq!(default_tier(), "active");
    }

    #[test]
    fn is_cold_tier_cold() {
        assert!(is_cold_tier("cold"));
    }

    #[test]
    fn is_cold_tier_restoring() {
        assert!(is_cold_tier("restoring"));
    }

    #[test]
    fn is_cold_tier_active_is_false() {
        assert!(!is_cold_tier("active"));
    }

    #[test]
    fn is_cold_tier_empty_is_false() {
        assert!(!is_cold_tier(""));
    }

    #[test]
    fn is_cold_tier_case_sensitive() {
        assert!(!is_cold_tier("Cold"));
        assert!(!is_cold_tier("COLD"));
    }

    #[test]
    fn normalize_url_strips_trailing_slash() {
        assert_eq!(
            normalize_url("https://api.example.com/"),
            "https://api.example.com"
        );
    }

    #[test]
    fn normalize_url_strips_multiple_trailing_slashes() {
        assert_eq!(
            normalize_url("https://api.example.com///"),
            "https://api.example.com"
        );
    }

    #[test]
    fn normalize_url_no_trailing_slash_unchanged() {
        assert_eq!(
            normalize_url("https://api.example.com"),
            "https://api.example.com"
        );
    }

    #[test]
    fn normalize_url_empty_string() {
        assert_eq!(normalize_url(""), "");
    }

    #[test]
    fn normalize_url_just_slash() {
        assert_eq!(normalize_url("/"), "");
    }

    #[test]
    fn resolve_tenant_attribution_found() {
        let map: TenantCustomerMap = Arc::new(DashMap::new());
        let cid = Uuid::new_v4();
        map.insert(
            "products".to_string(),
            TenantAttribution {
                customer_id: cid,
                tenant_id: "products".to_string(),
                tier: "active".to_string(),
            },
        );
        let result = resolve_tenant_attribution(&map, "products");
        assert_eq!(result.unwrap().customer_id, cid);
    }

    #[test]
    fn resolve_tenant_attribution_not_found() {
        let map: TenantCustomerMap = Arc::new(DashMap::new());
        assert!(resolve_tenant_attribution(&map, "missing").is_none());
    }

    #[test]
    fn resolve_tenant_attribution_preserves_tier() {
        let map: TenantCustomerMap = Arc::new(DashMap::new());
        map.insert(
            "cold-idx".to_string(),
            TenantAttribution {
                customer_id: Uuid::new_v4(),
                tenant_id: "cold-idx".to_string(),
                tier: "cold".to_string(),
            },
        );
        assert_eq!(
            resolve_tenant_attribution(&map, "cold-idx").unwrap().tier,
            "cold"
        );
    }

    #[test]
    fn resolve_tenant_attribution_alias_preserves_canonical_tenant_id() {
        let map: TenantCustomerMap = Arc::new(DashMap::new());
        let cid = Uuid::new_v4();
        map.insert(
            format!("{}_products", cid.as_simple()),
            TenantAttribution {
                customer_id: cid,
                tenant_id: "products".to_string(),
                tier: "active".to_string(),
            },
        );

        let result = resolve_tenant_attribution(&map, &format!("{}_products", cid.as_simple()))
            .expect("flapjack uid alias should resolve");
        assert_eq!(result.customer_id, cid);
        assert_eq!(result.tenant_id, "products");
    }

    // ---- replace_tenant_map_cache edge cases --------------------------------

    /// Guards the no-routing-metadata path: when the payload contains no
    /// `flapjack_url` values, all entries should be accepted into the cache
    /// regardless of the `local_flapjack_url`.
    ///
    /// This is the single-node / dev mode where every index on the scrape
    /// target belongs to this node.
    #[test]
    fn replace_cache_no_routing_metadata_includes_all() {
        let map: TenantCustomerMap = Arc::new(DashMap::new());
        let c1 = Uuid::new_v4();
        let c2 = Uuid::new_v4();
        replace_tenant_map_cache(
            &map,
            vec![
                TenantMapEntry {
                    tenant_id: "a".to_string(),
                    flapjack_uid: None,
                    customer_id: c1,
                    vm_id: None,
                    flapjack_url: None,
                    tier: "active".to_string(),
                },
                TenantMapEntry {
                    tenant_id: "b".to_string(),
                    flapjack_uid: None,
                    customer_id: c2,
                    vm_id: None,
                    flapjack_url: None,
                    tier: "active".to_string(),
                },
            ],
            "http://localhost:7700",
        );
        assert_eq!(map.len(), 2);
    }

    /// Guards the deduplication invariant: if the payload contains two entries
    /// with the same `tenant_id`, only the first is kept and the second is
    /// dropped with a warning.
    ///
    /// This prevents ambiguous customer attribution when the control-plane
    /// accidentally returns duplicate rows for the same index.
    #[test]
    fn replace_cache_deduplicates_tenant_ids() {
        let map: TenantCustomerMap = Arc::new(DashMap::new());
        let first = Uuid::new_v4();
        let second = Uuid::new_v4();
        replace_tenant_map_cache(
            &map,
            vec![
                TenantMapEntry {
                    tenant_id: "dup".to_string(),
                    flapjack_uid: None,
                    customer_id: first,
                    vm_id: None,
                    flapjack_url: None,
                    tier: "active".to_string(),
                },
                TenantMapEntry {
                    tenant_id: "dup".to_string(),
                    flapjack_uid: None,
                    customer_id: second,
                    vm_id: None,
                    flapjack_url: None,
                    tier: "active".to_string(),
                },
            ],
            "http://localhost:7700",
        );
        assert_eq!(map.len(), 1);
        assert_eq!(map.get("dup").unwrap().customer_id, first);
    }

    #[tokio::test]
    async fn fetch_tenant_map_sends_internal_key_header() {
        let observed_key = Arc::new(std::sync::Mutex::new(None));
        let state = HeaderCaptureState {
            observed_key: Arc::clone(&observed_key),
        };
        let (base_url, handle) = spawn_tenant_map_server(state).await;
        let cfg = Config {
            flapjack_url: "http://localhost:7700".to_string(),
            flapjack_api_key: "node-api-key".to_string(),
            internal_key: "internal-key-123".to_string(),
            scrape_interval: Duration::from_secs(60),
            storage_poll_interval: Duration::from_secs(300),
            tenant_map_refresh_interval: Duration::from_secs(300),
            database_url: "postgres://localhost/test".to_string(),
            customer_id: Uuid::new_v4(),
            node_id: "node-a".to_string(),
            region: "us-east-1".to_string(),
            health_port: 9091,
            tenant_map_url: format!("{base_url}/internal/tenant-map"),
            cold_storage_usage_url: format!("{base_url}/internal/cold-storage-usage"),
        };
        let http = reqwest::Client::new();

        let entries = fetch_tenant_map(&cfg, &http)
            .await
            .expect("tenant map request should succeed");

        assert!(entries.is_empty());
        assert_eq!(
            observed_key
                .lock()
                .expect("header capture mutex should lock")
                .clone(),
            Some("internal-key-123".to_string())
        );
        handle.abort();
    }

    #[test]
    fn replace_cache_clears_old_entries() {
        let map: TenantCustomerMap = Arc::new(DashMap::new());
        map.insert(
            "old".to_string(),
            TenantAttribution {
                customer_id: Uuid::new_v4(),
                tenant_id: "old".to_string(),
                tier: "active".to_string(),
            },
        );
        replace_tenant_map_cache(&map, vec![], "http://localhost:7700");
        assert_eq!(map.len(), 0);
    }

    /// Guards the routing-metadata filter: when at least one entry in the
    /// payload carries a `flapjack_url`, entries that lack a URL are silently
    /// skipped.
    ///
    /// In a multi-VM deployment the control plane may return a mixed payload
    /// where some indexes have routing metadata and some do not.  An entry
    /// without a URL cannot be reliably routed to this node, so accepting it
    /// would risk incorrect customer attribution.
    #[test]
    fn replace_cache_skips_entries_without_url_when_routing_metadata_present() {
        let map: TenantCustomerMap = Arc::new(DashMap::new());
        replace_tenant_map_cache(
            &map,
            vec![
                TenantMapEntry {
                    tenant_id: "with-url".to_string(),
                    flapjack_uid: None,
                    customer_id: Uuid::new_v4(),
                    vm_id: None,
                    flapjack_url: Some("http://localhost:7700".to_string()),
                    tier: "active".to_string(),
                },
                TenantMapEntry {
                    tenant_id: "no-url".to_string(),
                    flapjack_uid: None,
                    customer_id: Uuid::new_v4(),
                    vm_id: None,
                    flapjack_url: None,
                    tier: "active".to_string(),
                },
            ],
            "http://localhost:7700",
        );
        assert_eq!(map.len(), 1);
        assert!(map.get("with-url").is_some());
        assert!(map.get("no-url").is_none());
    }

    #[test]
    fn tenant_map_entry_defaults_tier_to_active() {
        let json = r#"{"tenant_id": "t1", "customer_id": "00000000-0000-0000-0000-000000000001"}"#;
        let entry: TenantMapEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry.tier, "active");
        assert!(entry.flapjack_uid.is_none());
        assert!(entry.vm_id.is_none());
        assert!(entry.flapjack_url.is_none());
    }

    #[test]
    fn replace_cache_stores_flapjack_uid_alias() {
        let map: TenantCustomerMap = Arc::new(DashMap::new());
        let customer_id = Uuid::new_v4();
        let flapjack_uid = format!("{}_products", customer_id.as_simple());
        replace_tenant_map_cache(
            &map,
            vec![TenantMapEntry {
                tenant_id: "products".to_string(),
                flapjack_uid: Some(flapjack_uid.clone()),
                customer_id,
                vm_id: None,
                flapjack_url: Some("http://localhost:7700".to_string()),
                tier: "active".to_string(),
            }],
            "http://localhost:7700",
        );

        assert_eq!(map.len(), 2);
        assert_eq!(
            map.get("products")
                .expect("canonical tenant id should be cached")
                .tenant_id,
            "products"
        );
        assert_eq!(
            map.get(&flapjack_uid)
                .expect("flapjack uid alias should be cached")
                .tenant_id,
            "products"
        );
    }

    // ---- Existing integration-style tests -----------------------------------

    /// Guards the URL-routing filter end-to-end: when two entries share the
    /// same `tenant_id` but point to different `flapjack_url`s, only the
    /// entry whose URL matches the local node's URL (after trailing-slash
    /// normalisation) is accepted into the cache.
    ///
    /// This is the core multi-VM safety property — each agent must only meter
    /// the indexes hosted on its own flapjack instance.
    #[test]
    fn metering_filters_tenant_map_to_local_flapjack_url() {
        let tenant_map: TenantCustomerMap = Arc::new(DashMap::new());
        let local_url = "https://vm-local.flapjack.foo";

        let local_customer = Uuid::new_v4();
        let remote_customer = Uuid::new_v4();

        replace_tenant_map_cache(
            &tenant_map,
            vec![
                TenantMapEntry {
                    tenant_id: "products".to_string(),
                    flapjack_uid: Some(format!("{}_products", local_customer.as_simple())),
                    customer_id: local_customer,
                    vm_id: Some(Uuid::new_v4()),
                    flapjack_url: Some(local_url.to_string()),
                    tier: "active".to_string(),
                },
                TenantMapEntry {
                    tenant_id: "products".to_string(),
                    flapjack_uid: Some(format!("{}_products", remote_customer.as_simple())),
                    customer_id: remote_customer,
                    vm_id: Some(Uuid::new_v4()),
                    flapjack_url: Some("https://vm-remote.flapjack.foo".to_string()),
                    tier: "active".to_string(),
                },
            ],
            "https://vm-local.flapjack.foo/",
        );

        assert_eq!(tenant_map.len(), 2);
        assert_eq!(
            tenant_map
                .get("products")
                .expect("local products mapping should be present")
                .value()
                .customer_id,
            local_customer
        );
        assert_eq!(
            tenant_map
                .get(&format!("{}_products", local_customer.as_simple()))
                .expect("local flapjack uid alias should be present")
                .value()
                .customer_id,
            local_customer
        );
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
            },
        );

        let did_refresh = refresh_tenant_map_cache_if_due(
            &tenant_map,
            &mut last_refresh,
            Instant::now() + Duration::from_secs(120),
            refresh_interval,
            local_flapjack_url,
            vec![
                TenantMapEntry {
                    tenant_id: "products".to_string(),
                    flapjack_uid: Some(format!("{}_products", first_customer.as_simple())),
                    customer_id: first_customer,
                    vm_id: None,
                    flapjack_url: Some(local_flapjack_url.to_string()),
                    tier: "active".to_string(),
                },
                TenantMapEntry {
                    tenant_id: "new-index".to_string(),
                    flapjack_uid: None,
                    customer_id: Uuid::new_v4(),
                    vm_id: None,
                    flapjack_url: Some(local_flapjack_url.to_string()),
                    tier: "active".to_string(),
                },
            ],
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
            vec![
                TenantMapEntry {
                    tenant_id: "products".to_string(),
                    flapjack_uid: Some(format!("{}_products", first_customer.as_simple())),
                    customer_id: first_customer,
                    vm_id: None,
                    flapjack_url: Some(local_flapjack_url.to_string()),
                    tier: "active".to_string(),
                },
                TenantMapEntry {
                    tenant_id: "new-index".to_string(),
                    flapjack_uid: None,
                    customer_id: new_customer,
                    vm_id: None,
                    flapjack_url: Some(local_flapjack_url.to_string()),
                    tier: "active".to_string(),
                },
            ],
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
}
