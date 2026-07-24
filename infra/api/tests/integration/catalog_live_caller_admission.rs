use super::*;

pub(super) async fn assert_live_replica_call(
    binding: &CatalogLiveBinding,
) -> crate::common::catalog_live_binding::LiveCallerRefusal {
    let caller =
        classify_live_replica_caller(binding.caller_owner_path(), binding.caller_source_anchor());
    match caller {
        LiveReplicaCaller::RouteCreate | LiveReplicaCaller::RouteRemove => {
            assert_live_replica_route_call(binding, caller)
        }
        LiveReplicaCaller::ServiceCreate | LiveReplicaCaller::ServiceRemove => {
            assert_live_replica_service_call(binding, caller).await
        }
    }
}

fn assert_live_replica_route_call(
    binding: &CatalogLiveBinding,
    caller: LiveReplicaCaller,
) -> crate::common::catalog_live_binding::LiveCallerRefusal {
    let target = binding.target_index();
    match caller {
        LiveReplicaCaller::RouteCreate => binding.assert_tenant_destination_conflict(
            "POST",
            &format!("/indexes/{target}/replicas"),
            &json!({"region": "invalid-region"}),
        ),
        LiveReplicaCaller::RouteRemove => binding.assert_tenant_destination_conflict(
            "DELETE",
            &format!("/indexes/{target}/replicas/{}", Uuid::new_v4()),
            &json!({}),
        ),
        _ => panic!("replica route helper received a service caller"),
    }
}

async fn assert_live_replica_service_call(
    binding: &CatalogLiveBinding,
    caller: LiveReplicaCaller,
) -> crate::common::catalog_live_binding::LiveCallerRefusal {
    let service = guarded_replica_service(binding.pool());
    match caller {
        LiveReplicaCaller::ServiceCreate => {
            let result = service
                .create_replica(
                    binding.customer_id(),
                    binding.target_index(),
                    "invalid-region",
                )
                .await;
            binding.confirm_destination_conflict(
                matches!(result, Err(ReplicaError::DestinationConflict)),
                "live replica create",
            )
        }
        LiveReplicaCaller::ServiceRemove => {
            let result = service
                .remove_replica(
                    binding.customer_id(),
                    binding.target_index(),
                    Uuid::new_v4(),
                )
                .await;
            binding.confirm_destination_conflict(
                matches!(result, Err(ReplicaError::DestinationConflict)),
                "live replica remove",
            )
        }
        _ => panic!("replica service helper received a route caller"),
    }
}

#[derive(Clone, Copy)]
enum LiveReplicaCaller {
    RouteCreate,
    RouteRemove,
    ServiceCreate,
    ServiceRemove,
}

impl LiveReplicaCaller {
    fn evidence_name(self) -> &'static str {
        match self {
            Self::RouteCreate => "route_create",
            Self::RouteRemove => "route_remove",
            Self::ServiceCreate => "service_create",
            Self::ServiceRemove => "service_remove",
        }
    }
}

fn classify_live_replica_caller(owner_path: &str, source_anchor: &str) -> LiveReplicaCaller {
    match (owner_path, source_anchor) {
        ("infra/api/src/routes/indexes/replicas.rs", "replica_service.create_replica") => {
            LiveReplicaCaller::RouteCreate
        }
        ("infra/api/src/routes/indexes/replicas.rs", "replica_service.remove_replica") => {
            LiveReplicaCaller::RouteRemove
        }
        ("infra/api/src/services/replica.rs", "replica_repo.create")
        | ("infra/api/src/repos/pg_index_replica_repo.rs", "pg_index_replica_repo.create") => {
            LiveReplicaCaller::ServiceCreate
        }
        ("infra/api/src/services/replica.rs", "replica_repo.delete")
        | ("infra/api/src/repos/pg_index_replica_repo.rs", "pg_index_replica_repo.delete") => {
            LiveReplicaCaller::ServiceRemove
        }
        _ => panic!("unsupported live replica caller {owner_path}::{source_anchor}"),
    }
}

pub(super) async fn assert_live_restore_call(
    binding: &CatalogLiveBinding,
) -> crate::common::catalog_live_binding::LiveCallerRefusal {
    let (service, _) = restore_service(binding.pool(), Arc::new(NoopRestoreNodeClient), None);
    let result = service
        .initiate_restore(binding.customer_id(), binding.target_index())
        .await;
    binding.confirm_destination_conflict(
        matches!(result, Err(RestoreError::DestinationConflict)),
        "live restore initiation",
    )
}

pub(super) async fn assert_live_migration_call(
    binding: &CatalogLiveBinding,
) -> crate::common::catalog_live_binding::LiveCallerRefusal {
    let http_client = Arc::new(CountingMigrationHttpClient::default());
    let result = migration_service(binding.pool(), http_client.clone())
        .execute(MigrationRequest {
            index_name: binding.target_index().to_string(),
            customer_id: binding.customer_id(),
            source_vm_id: Uuid::new_v4(),
            dest_vm_id: Uuid::new_v4(),
            requested_by: "catalog-live-caller".to_string(),
        })
        .await;
    assert_eq!(
        http_client.request_count(),
        0,
        "reservation-refused live migration must not dispatch remote work"
    );
    binding.confirm_destination_conflict(
        matches!(result, Err(MigrationError::DestinationConflict)),
        "live migration",
    )
}

pub(super) async fn assert_live_cold_tier_call(
    binding: &CatalogLiveBinding,
) -> crate::common::catalog_live_binding::LiveCallerRefusal {
    let tenant = api::models::tenant::CustomerTenant {
        customer_id: binding.customer_id(),
        tenant_id: binding.target_index().to_string(),
        deployment_id: Uuid::new_v4(),
        created_at: Utc::now(),
        vm_id: Some(Uuid::new_v4()),
        tier: "active".to_string(),
        last_accessed_at: None,
        cold_snapshot_id: None,
        resource_quota: json!({}),
        service_type: "flapjack".to_string(),
    };
    let candidate = ColdTierCandidate::from_tenant(&tenant).expect("tenant has a source VM");
    let node_client = Arc::new(CountingColdTierNodeClient::default());
    let result = cold_tier_service(binding.pool(), node_client.clone())
        .snapshot_candidate(&candidate, "https://private.invalid", "us-east-1")
        .await;
    assert_eq!(
        node_client.remote_call_count(),
        0,
        "reservation-refused live cold-tier call must not dispatch remote work"
    );
    binding.confirm_destination_conflict(
        matches!(result, Err(ColdTierError::DestinationConflict)),
        "live cold-tier snapshot",
    )
}

pub(super) async fn assert_live_region_failover_call(
    binding: &CatalogLiveBinding,
) -> crate::common::catalog_live_binding::LiveCallerRefusal {
    let vm_repo = mock_vm_inventory_repo();
    let source_vm = vm_repo.seed("us-east-1", "https://source-down.invalid");
    let replica_vm = vm_repo.seed("us-west-1", "https://replica-healthy.invalid");
    let tenant_repo = mock_tenant_repo();
    let deployment_id = Uuid::new_v4();
    tenant_repo
        .create(binding.customer_id(), binding.target_index(), deployment_id)
        .await
        .expect("seed live failover caller tenant");
    tenant_repo
        .set_vm_id(binding.customer_id(), binding.target_index(), source_vm.id)
        .await
        .expect("assign live failover caller source VM");
    let replica_repo = Arc::new(api::repos::InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            binding.customer_id(),
            binding.target_index(),
            source_vm.id,
            replica_vm.id,
            "us-west-1",
        )
        .await
        .expect("seed live failover caller replica");
    replica_repo
        .set_status(replica.id, "active")
        .await
        .expect("activate live failover caller replica");
    let monitor = RegionFailoverMonitor::new(
        vm_repo,
        tenant_repo.clone(),
        replica_repo.clone(),
        mock_alert_service(),
        Arc::new(IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(
            binding.pool().clone(),
        ))),
        RegionFailoverConfig {
            cycle_interval_secs: 30,
            unhealthy_threshold: 1,
            recovery_threshold: 1,
        },
    );

    monitor
        .run_cycle_with_health(|url| !url.contains("source-down"))
        .await;

    let tenant = tenant_repo
        .find_raw(binding.customer_id(), binding.target_index())
        .await
        .expect("read live failover caller tenant")
        .expect("live failover caller tenant remains present");
    let replica = replica_repo
        .get(replica.id)
        .await
        .expect("read live failover caller replica")
        .expect("live failover caller replica remains present");
    binding.confirm_destination_conflict(
        tenant.vm_id == Some(source_vm.id) && replica.status == "active",
        "live region failover",
    )
}

/// A live create-import target has no tenant row yet. Reservation admission
/// must therefore run before caller-specific lookup and validation so every
/// production caller refuses the same live target with `destination_conflict`,
/// rather than escaping through an incidental not-found or validation error.
#[tokio::test]
async fn create_import_reservation_preempts_incompatible_caller_prerequisites() {
    let Some(db) = connect_and_migrate("catalog_live_caller_admission_create").await else {
        return;
    };
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    PgAlgoliaImportJobRepo::new(db.pool.clone())
        .create(import_job(
            customer_id,
            "live_import_target",
            "live-caller-admission",
        ))
        .await
        .expect("create live import reservation");

    let replica_result = guarded_replica_service(&db.pool)
        .create_replica(customer_id, "live_import_target", "invalid-region")
        .await;
    assert!(
        matches!(replica_result, Err(ReplicaError::DestinationConflict)),
        "reservation must preempt replica region and target validation, got {replica_result:?}"
    );

    let remove_replica_result = guarded_replica_service(&db.pool)
        .remove_replica(customer_id, "live_import_target", Uuid::new_v4())
        .await;
    assert!(
        matches!(
            remove_replica_result,
            Err(ReplicaError::DestinationConflict)
        ),
        "reservation must preempt replica lookup, got {remove_replica_result:?}"
    );

    let (restore_service, _) = restore_service(&db.pool, Arc::new(NoopRestoreNodeClient), None);
    let restore_result = restore_service
        .initiate_restore(customer_id, "live_import_target")
        .await;
    assert!(
        matches!(restore_result, Err(RestoreError::DestinationConflict)),
        "reservation must preempt restore target lookup, got {restore_result:?}"
    );

    let migration_http = Arc::new(CountingMigrationHttpClient::default());
    let migration_result = migration_service(&db.pool, migration_http.clone())
        .execute(MigrationRequest {
            index_name: "live_import_target".to_string(),
            customer_id,
            source_vm_id: Uuid::new_v4(),
            dest_vm_id: Uuid::new_v4(),
            requested_by: "catalog-live-caller".to_string(),
        })
        .await;
    assert!(
        matches!(migration_result, Err(MigrationError::DestinationConflict)),
        "reservation must preempt migration VM and target validation, got {migration_result:?}"
    );
    assert_eq!(
        migration_http.request_count(),
        0,
        "reservation-refused migration must not dispatch remote work"
    );
}

/// Cold-tier snapshot admission must reject the reserved logical target before
/// it dereferences candidate infrastructure. This lets the source-built catalog
/// scenario bind the production caller to the live job even though the live
/// create-import target has not published catalog placement yet.
#[tokio::test]
async fn replacement_reservation_preempts_cold_tier_source_lookup() {
    let Some(db) = connect_and_migrate("catalog_live_caller_admission_cold").await else {
        return;
    };
    let customer_id = Uuid::new_v4();
    insert_replace_target(&db.pool, customer_id, "products").await;
    PgAlgoliaImportJobRepo::new(db.pool.clone())
        .create_replace(replace_job(
            customer_id,
            "products",
            "cold-live-caller-admission",
        ))
        .await
        .expect("create replacement reservation");

    let source_vm_id = load_target_identity(&db.pool, customer_id, "products")
        .await
        .vm_id
        .expect("replacement target has source VM");
    let mut candidate = cold_tier_candidate(&db.pool, customer_id, "products", source_vm_id).await;
    candidate.source_vm_id = Uuid::new_v4();
    let result = cold_tier_service(&db.pool, Arc::new(CountingColdTierNodeClient::default()))
        .snapshot_candidate(&candidate, "https://private.invalid", "us-east-1")
        .await;

    assert!(
        matches!(result, Err(ColdTierError::DestinationConflict)),
        "reservation must preempt cold-tier source lookup, got {result:?}"
    );
}

#[test]
fn replica_writer_keys_select_their_exact_live_entrypoint() {
    let inventory: serde_json::Value = serde_json::from_str(include_str!(
        "../../../../scripts/tests/fixtures/catalog_lifecycle_writers.json"
    ))
    .expect("writer inventory must be valid JSON");
    let replica_rows = inventory["writers"]
        .as_array()
        .expect("writer inventory must contain rows")
        .iter()
        .filter(|row| {
            row["live_scenario_key"]
                .as_str()
                .is_some_and(|selection| selection.contains("replica_create_remove_races"))
        });

    let mut observed = Vec::new();
    for row in replica_rows {
        let owner_path = row["owner_path"].as_str().unwrap();
        let source_anchor = row["source_anchor"].as_str().unwrap();
        observed.push(classify_live_replica_caller(owner_path, source_anchor).evidence_name());
    }
    observed.sort_unstable();

    assert_eq!(
        observed,
        [
            "route_create",
            "route_remove",
            "service_create",
            "service_create",
            "service_remove",
            "service_remove",
        ]
    );
}
