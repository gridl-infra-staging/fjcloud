use super::*;

fn take_reservation_race_result(
    result: &Arc<Mutex<Option<Result<AlgoliaImportJob, RepoError>>>>,
) -> Result<AlgoliaImportJob, RepoError> {
    result
        .lock()
        .unwrap()
        .take()
        .expect("reservation hook must record a result")
}

fn take_route_race_snapshot(snapshot: &Arc<Mutex<Option<RouteRaceSnapshot>>>) -> RouteRaceSnapshot {
    snapshot
        .lock()
        .unwrap()
        .take()
        .expect("remote boundary hook must record a route snapshot")
}

#[derive(Debug, PartialEq, Eq)]
struct RouteRaceSnapshot {
    tenants: Vec<TenantRowSnapshot>,
    deployments: Vec<DeploymentRowSnapshot>,
    replicas: Vec<ReplicaRowSnapshot>,
    operations: Vec<ImportOperationRowSnapshot>,
}

async fn route_race_snapshot(pool: &PgPool, customer_id: Uuid, target: &str) -> RouteRaceSnapshot {
    RouteRaceSnapshot {
        tenants: tenant_rows(pool, customer_id).await,
        deployments: deployment_rows(pool, customer_id).await,
        replicas: replica_rows(pool, customer_id, target).await,
        operations: import_operation_rows(pool, customer_id, target).await,
    }
}

#[tokio::test]
async fn create_index_on_shared_vm_reservation_wins_before_intent() {
    assert_create_route_refuses_reservation(
        "catalog_route_create_reservation_before_intent",
        ActiveReservationKind::Import,
    )
    .await;
}

#[tokio::test]
async fn create_index_on_shared_vm_reservation_races_after_intent_before_remote_work() {
    let Some(db) = connect_and_migrate("catalog_route_create_reservation_after_intent").await
    else {
        return;
    };
    let customer_repo = mock_repo();
    let customer = customer_repo
        .seed_verified_shared_customer("Create Race", "create-race-after-intent@test.com");
    insert_active_customer(&db.pool, customer.id, 1).await;
    let vm_id =
        insert_route_test_vm(&db.pool, "us-east-1", "https://route-create-race.invalid").await;
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let reservation_result = Arc::new(Mutex::new(None));
    let before_remote_snapshot = Arc::new(Mutex::new(None));
    http_client.before_next_send({
        let reservation_pool = pool_in_schema(&db.schema).await;
        let reservation_result = Arc::clone(&reservation_result);
        let snapshot_pool = pool_in_schema(&db.schema).await;
        let before_remote_snapshot = Arc::clone(&before_remote_snapshot);
        move || async move {
            let snapshot = route_race_snapshot(&snapshot_pool, customer.id, "products").await;
            let discovered = state_discovery_after_success(&snapshot_pool, customer.id, "products").await;
            assert!(
                matches!(discovered, Err(DiscoveryError::NotFound)),
                "provisioning route intent must not be discoverable before remote create, got {discovered:?}"
            );
            *before_remote_snapshot.lock().unwrap() = Some(snapshot);

            let result = PgAlgoliaImportJobRepo::new(reservation_pool)
                .create(import_job(
                    customer.id,
                    "products",
                    "route-create-race-after-intent",
                ))
                .await;
            *reservation_result.lock().unwrap() = Some(result);
        }
    });
    let route_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let app = route_test_app(route_pool, customer_repo, http_client.clone());
    let before = route_race_snapshot(&db.pool, customer.id, "products").await;
    assert!(before.tenants.is_empty());
    assert!(before.deployments.is_empty());
    assert!(before.replicas.is_empty());
    assert!(before.operations.is_empty());

    let response = app
        .oneshot(create_index_request(
            "products",
            &create_test_jwt(customer.id),
        ))
        .await
        .expect("create index race response");

    let response_status = response.status();
    let response_body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("read create race response body");
    let response_json: serde_json::Value =
        serde_json::from_slice(&response_body).expect("create race JSON response");
    let reservation = take_reservation_race_result(&reservation_result);
    let at_remote_boundary = take_route_race_snapshot(&before_remote_snapshot);
    assert_eq!(
        at_remote_boundary.tenants.len(),
        1,
        "route must commit exactly one lifecycle intent before remote create"
    );
    assert_eq!(at_remote_boundary.tenants[0].tenant_id, "products");
    assert_eq!(
        at_remote_boundary.tenants[0].tier, "provisioning",
        "route must publish a provisioning intent before remote create"
    );
    assert_eq!(
        at_remote_boundary.tenants[0].vm_id, None,
        "provisioning intent must remain non-active before remote create"
    );
    assert_eq!(
        at_remote_boundary.tenants[0].service_type, "flapjack",
        "route-owned create intent must preserve the flapjack service owner"
    );
    assert_eq!(
        at_remote_boundary.deployments.len(),
        1,
        "route must create exactly one deployment for the lifecycle intent"
    );
    assert_eq!(
        at_remote_boundary.tenants[0].deployment_id, at_remote_boundary.deployments[0].id,
        "provisioning tenant must point at the route-created deployment"
    );
    assert_eq!(
        at_remote_boundary.replicas, before.replicas,
        "remote-boundary create intent must not mutate replica routing"
    );
    assert_eq!(
        at_remote_boundary.operations, before.operations,
        "remote-boundary create intent must not create an import operation"
    );
    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1, "route winner must issue one engine call");
    let request = &requests[0];
    let expected_physical_uid = flapjack_index_uid(customer.id, "products");
    assert_eq!(request.method, Method::POST);
    assert_eq!(request.url, "https://route-create-race.invalid/1/indexes");
    assert_eq!(
        request.json_body,
        Some(json!({"uid": expected_physical_uid})),
        "route create must target the tenant-scoped physical UID"
    );
    assert_eq!(
        response_status,
        StatusCode::CREATED,
        "route owner must complete after rejecting the later reservation; body={response_json} reservation={reservation:?}"
    );
    assert!(
        matches!(
            &reservation,
            Err(RepoError::Conflict(message)) if message == "destination_changed"
        ),
        "route-owned provisioning intent must make the later reservation lose with destination_changed, got {reservation:?}"
    );
    assert_eq!(
        import_operation_rows(&db.pool, customer.id, "products").await,
        before.operations,
        "the losing reservation must not leave an operation intent"
    );
    assert_eq!(
        replica_rows(&db.pool, customer.id, "products").await,
        before.replicas,
        "the race must not mutate replica routing"
    );
    let after_tenants = tenant_rows(&db.pool, customer.id).await;
    let after_deployments = deployment_rows(&db.pool, customer.id).await;
    let after = route_race_snapshot(&db.pool, customer.id, "products").await;
    assert_eq!(after_tenants.len(), 1);
    assert_eq!(after_tenants[0].tenant_id, "products");
    assert_eq!(after_tenants[0].tier, "active");
    assert_eq!(after_tenants[0].vm_id, Some(vm_id));
    assert_eq!(after_deployments.len(), 1);
    assert_eq!(after_tenants[0].deployment_id, after_deployments[0].id);
    assert_eq!(
        after_deployments, at_remote_boundary.deployments,
        "route finalization must preserve the deployment identity published in the intent"
    );
    assert_eq!(
        after_tenants[0].deployment_id, at_remote_boundary.tenants[0].deployment_id,
        "route finalization must activate the same deployment identity"
    );
    assert_eq!(
        after.replicas, before.replicas,
        "successful route create race must not leave replica mutations"
    );
    assert_eq!(
        after.operations, before.operations,
        "successful route create race must not leave import operations"
    );
    assert!(
        after
            .tenants
            .iter()
            .all(|tenant| tenant.tier != "provisioning"),
        "successful route create race must not leave stale provisioning intents"
    );
}

#[tokio::test]
async fn create_index_on_shared_vm_resumes_compatible_provisioning_intent() {
    let Some(db) = connect_and_migrate("catalog_route_create_resume_intent").await else {
        return;
    };
    let customer_repo = mock_repo();
    let customer =
        customer_repo.seed_verified_shared_customer("Create Resume", "create-resume@test.com");
    insert_active_customer(&db.pool, customer.id, 1).await;
    let vm_id = insert_route_test_vm(&db.pool, "us-east-1", "https://route-resume.invalid").await;
    let deployment_id = insert_shared_provisioning_intent(
        &db.pool,
        customer.id,
        "products",
        vm_id,
        "https://route-resume.invalid",
    )
    .await;
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = mock_node_secret_manager();
    let route_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let app = route_test_app_with_node_secret_manager(
        route_pool,
        customer_repo,
        http_client.clone(),
        node_secret_manager,
    );
    let before = route_race_snapshot(&db.pool, customer.id, "products").await;
    assert_eq!(before.tenants.len(), 1);
    assert_eq!(before.tenants[0].tier, "provisioning");
    assert_eq!(before.tenants[0].vm_id, None);
    assert_eq!(before.tenants[0].deployment_id, deployment_id);
    assert_eq!(before.deployments.len(), 1);

    let response = app
        .oneshot(create_index_request(
            "products",
            &create_test_jwt(customer.id),
        ))
        .await
        .expect("resume create response");

    let response_status = response.status();
    let response_body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("read resume response body");
    let response_json: serde_json::Value =
        serde_json::from_slice(&response_body).expect("resume response JSON");
    assert_eq!(
        response_status,
        StatusCode::CREATED,
        "compatible provisioning intent must resume and publish active; body={response_json}"
    );
    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1, "resume must issue one engine create");
    assert_eq!(requests[0].method, Method::POST);
    assert_eq!(requests[0].url, "https://route-resume.invalid/1/indexes");
    assert_eq!(
        requests[0].json_body,
        Some(json!({"uid": flapjack_index_uid(customer.id, "products")}))
    );
    assert_eq!(
        import_operation_rows(&db.pool, customer.id, "products").await,
        before.operations
    );
    assert_eq!(
        replica_rows(&db.pool, customer.id, "products").await,
        before.replicas
    );
    let after_tenants = tenant_rows(&db.pool, customer.id).await;
    let after_deployments = deployment_rows(&db.pool, customer.id).await;
    assert_eq!(after_tenants.len(), 1);
    assert_eq!(after_tenants[0].deployment_id, deployment_id);
    assert_eq!(after_tenants[0].vm_id, Some(vm_id));
    assert_eq!(after_tenants[0].tier, "active");
    assert_eq!(after_deployments, before.deployments);
}

#[tokio::test]
async fn create_index_on_shared_vm_remote_failure_rolls_back_owned_intent() {
    let Some(db) = connect_and_migrate("catalog_route_create_remote_failure_rollback").await else {
        return;
    };
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_shared_customer(
        "Create Failure Rollback",
        "create-failure-rollback@test.com",
    );
    insert_active_customer(&db.pool, customer.id, 1).await;
    insert_route_test_vm(
        &db.pool,
        "us-east-1",
        "https://route-create-failure.invalid",
    )
    .await;
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    http_client.push_error(ProxyError::FlapjackError {
        status: 500,
        message: "injected create failure".to_string(),
    });
    let node_secret_manager = Arc::new(ObservingSeedSecretManager::new(
        pool_in_schema(&db.schema).await,
        customer.id,
        "products",
    ));
    let route_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let app = route_test_app_with_node_secret_manager(
        route_pool,
        customer_repo,
        http_client.clone(),
        node_secret_manager.clone(),
    );
    let before = route_race_snapshot(&db.pool, customer.id, "products").await;
    assert!(before.tenants.is_empty());
    assert!(before.deployments.is_empty());
    assert!(before.replicas.is_empty());
    assert!(before.operations.is_empty());

    let response = app
        .oneshot(create_index_request(
            "products",
            &create_test_jwt(customer.id),
        ))
        .await
        .expect("remote failure create response");

    let response_status = response.status();
    let response_body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("read remote failure response body");
    assert_ne!(
        response_status,
        StatusCode::CREATED,
        "remote failure must preserve the primary error; body={}",
        String::from_utf8_lossy(&response_body)
    );
    assert_eq!(
        node_secret_manager.observed_tiers(),
        vec![Some("provisioning".to_string())],
        "admin-key setup must observe the committed provisioning intent"
    );
    assert_eq!(http_client.take_requests().len(), 1);
    assert!(
        tenant_rows(&db.pool, customer.id).await.is_empty(),
        "owned provisioning intent must be removed after remote failure"
    );
    let deployments = deployment_rows(&db.pool, customer.id).await;
    assert_eq!(deployments.len(), 1);
    assert_eq!(
        deployments[0].status, "terminated",
        "unreferenced route-created deployment must be terminated after rollback"
    );
    assert_eq!(
        import_operation_rows(&db.pool, customer.id, "products").await,
        before.operations
    );
    assert_eq!(
        replica_rows(&db.pool, customer.id, "products").await,
        before.replicas
    );
}

#[tokio::test]
async fn delete_index_reservation_wins_before_intent() {
    assert_delete_route_refuses_reservation(
        "catalog_route_delete_reservation_before_intent",
        ActiveReservationKind::Replacement,
    )
    .await;
}

async fn insert_shared_provisioning_intent(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    vm_id: Uuid,
    flapjack_url: &str,
) -> Uuid {
    let deployment_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO customer_deployments
         (id, customer_id, node_id, region, vm_type, vm_provider, status,
          provider_vm_id, hostname, flapjack_url, health_status)
         VALUES ($1, $2, $3, 'us-east-1', 'shared', 'aws', 'provisioning',
                 $4, $5, $6, 'unknown')",
    )
    .bind(deployment_id)
    .bind(customer_id)
    .bind(format!("node-{deployment_id}"))
    .bind(vm_id.to_string())
    .bind(format!("vm-{vm_id}"))
    .bind(flapjack_url)
    .execute(pool)
    .await
    .expect("insert shared provisioning deployment");
    sqlx::query(
        "INSERT INTO customer_tenants
         (customer_id, tenant_id, deployment_id, tier, service_type)
         VALUES ($1, $2, $3, 'provisioning', 'flapjack')",
    )
    .bind(customer_id)
    .bind(target)
    .bind(deployment_id)
    .execute(pool)
    .await
    .expect("insert shared provisioning intent");
    deployment_id
}

#[tokio::test]
async fn delete_index_reservation_races_after_intent_before_finalization() {
    let Some(db) = connect_and_migrate("catalog_route_delete_reservation_after_intent").await
    else {
        return;
    };
    let customer_repo = mock_repo();
    let customer = customer_repo
        .seed_verified_shared_customer("Delete Race", "delete-race-after-intent@test.com");
    insert_replace_target(&db.pool, customer.id, "products").await;
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let reservation_result = Arc::new(Mutex::new(None));
    let before_finalization_snapshot = Arc::new(Mutex::new(None));
    http_client.after_next_send({
        let reservation_pool = pool_in_schema(&db.schema).await;
        let reservation_result = Arc::clone(&reservation_result);
        let snapshot_pool = pool_in_schema(&db.schema).await;
        let before_finalization_snapshot = Arc::clone(&before_finalization_snapshot);
        move || async move {
            let snapshot = route_race_snapshot(&snapshot_pool, customer.id, "products").await;
            let discovered = state_discovery_after_success(&snapshot_pool, customer.id, "products").await;
            assert!(
                matches!(discovered, Err(DiscoveryError::NotFound)),
                "deleting route intent must not be discoverable before finalization, got {discovered:?}"
            );
            *before_finalization_snapshot.lock().unwrap() = Some(snapshot);

            let result = PgAlgoliaImportJobRepo::new(reservation_pool)
                .create_replace(replace_job(
                    customer.id,
                    "products",
                    "route-delete-race-after-intent",
                ))
                .await;
            *reservation_result.lock().unwrap() = Some(result);
        }
    });
    let node_secret_manager = mock_node_secret_manager();
    let deployment_node_id = deployment_rows(&db.pool, customer.id).await[0]
        .node_id
        .clone();
    node_secret_manager
        .create_node_api_key(&deployment_node_id, "us-east-1")
        .await
        .expect("seed delete route node secret");
    let route_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let app = route_test_app_with_node_secret_manager(
        route_pool,
        customer_repo,
        http_client.clone(),
        node_secret_manager,
    );
    let before = route_race_snapshot(&db.pool, customer.id, "products").await;
    assert_eq!(before.tenants.len(), 1);
    assert_eq!(before.tenants[0].tier, "active");
    assert!(before.tenants[0].vm_id.is_some());
    assert_eq!(before.deployments.len(), 1);
    assert!(before.replicas.is_empty());
    assert!(before.operations.is_empty());

    let response = app
        .oneshot(delete_index_request(
            "products",
            &create_test_jwt(customer.id),
        ))
        .await
        .expect("delete index race response");

    let response_status = response.status();
    let response_body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("read delete race response body");
    let reservation = take_reservation_race_result(&reservation_result);
    let before_finalization = take_route_race_snapshot(&before_finalization_snapshot);
    assert_eq!(
        before_finalization.tenants.len(),
        1,
        "delete route must publish exactly one lifecycle intent before finalization"
    );
    assert_eq!(before_finalization.tenants[0].tenant_id, "products");
    assert_eq!(
        before_finalization.tenants[0].tier, "deleting",
        "delete route must publish a deleting intent before finalization"
    );
    assert_eq!(
        before_finalization.tenants[0].deployment_id, before.tenants[0].deployment_id,
        "delete intent must preserve the active deployment identity"
    );
    assert_eq!(
        before_finalization.tenants[0].vm_id, before.tenants[0].vm_id,
        "delete intent must preserve the active VM identity"
    );
    assert_eq!(
        before_finalization.deployments, before.deployments,
        "delete intent must not rewrite deployment ownership before finalization"
    );
    assert_eq!(
        before_finalization.replicas, before.replicas,
        "delete intent must not mutate replica routing before finalization"
    );
    assert_eq!(
        before_finalization.operations, before.operations,
        "delete intent must not create an import operation before finalization"
    );
    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1, "route winner must issue one engine call");
    let request = &requests[0];
    let expected_physical_uid = flapjack_index_uid(customer.id, "products");
    assert_eq!(request.method, Method::DELETE);
    assert_eq!(
        request.url,
        format!("https://private.invalid/1/indexes/{expected_physical_uid}"),
        "route delete must target the tenant-scoped physical UID path"
    );
    assert_eq!(request.json_body, None);
    assert_eq!(
        response_status,
        StatusCode::NO_CONTENT,
        "route owner must complete after rejecting the later reservation; body={} reservation={reservation:?}",
        String::from_utf8_lossy(&response_body)
    );
    assert!(
        matches!(
            &reservation,
            Err(RepoError::Conflict(message)) if message == "destination_conflict"
        ),
        "route-owned deleting intent must make the later reservation lose with a stable destination conflict, got {reservation:?}"
    );
    let after = route_race_snapshot(&db.pool, customer.id, "products").await;
    assert!(
        after.tenants.is_empty(),
        "successful delete must leave no stale or discoverable catalog route"
    );
    assert_eq!(
        after.deployments, before.deployments,
        "delete must not rewrite deployment ownership"
    );
    assert_eq!(
        after.replicas, before.replicas,
        "the race must not mutate replica routing"
    );
    assert_eq!(
        after.operations, before.operations,
        "the losing reservation must not leave an operation intent"
    );
    assert!(
        after.tenants.iter().all(|tenant| tenant.tier != "deleting"),
        "successful delete must remove the operation-owned deleting row"
    );
}

#[tokio::test]
async fn cold_tier_intent_blocks_replace_reservation_before_remote_export() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_cold_tier_intent_race").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let source_vm_id = load_target_identity(&db.pool, customer, "products")
        .await
        .vm_id
        .expect("cold-tier target has source VM");
    let node_client = Arc::new(CountingColdTierNodeClient::default());
    node_client.attempt_replace_reservation_during_export(
        pool_in_schema(&db.schema).await,
        customer,
        "products",
        "cold-tier-export-race",
    );
    let service_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let service = cold_tier_service(&service_pool, node_client.clone());
    let candidate = cold_tier_candidate(&db.pool, customer, "products", source_vm_id).await;

    let snapshot_id = service
        .snapshot_candidate(&candidate, "https://private.invalid", "us-east-1")
        .await
        .expect("cold-tier writer owns the target after publishing its intent");

    assert!(
        matches!(
            node_client.take_replace_reservation_result(),
            Err(RepoError::Conflict(message)) if message == "destination_conflict"
        ),
        "the persisted cold intent must exclude replacement import admission"
    );
    assert_eq!(
        node_client.remote_call_count(),
        2,
        "export and source eviction must run outside the database guard"
    );
    assert_eq!(
        load_target_identity(&db.pool, customer, "products").await,
        CatalogLifecycleTargetIdentity {
            deployment_id: tenant_rows(&db.pool, customer).await[0].deployment_id,
            vm_id: None,
            tier: "cold".to_string(),
            cold_snapshot_id: Some(snapshot_id),
            service_type: "flapjack".to_string(),
        }
    );
    let snapshots = cold_snapshot_rows(&db.pool, customer, "products").await;
    assert_eq!(snapshots.len(), 1);
    assert_eq!(snapshots[0].id, snapshot_id);
    assert_eq!(snapshots[0].status, "completed");
    assert_eq!(snapshots[0].size_bytes, b"snapshot".len() as i64);
}

#[tokio::test]
async fn cold_tier_failure_rollback_preserves_service_type_drift() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_cold_tier_rollback_drift").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let original_identity = load_target_identity(&db.pool, customer, "products").await;
    let source_vm_id = original_identity
        .vm_id
        .expect("cold-tier target has source VM");
    let node_client = Arc::new(CountingColdTierNodeClient::default());
    node_client.drift_service_type_during_export(
        pool_in_schema(&db.schema).await,
        customer,
        "products",
    );
    let service_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let service = cold_tier_service(&service_pool, node_client.clone());

    service
        .run_cycle(&|vm_id| {
            (vm_id == source_vm_id).then(|| {
                (
                    "https://private.invalid".to_string(),
                    "us-east-1".to_string(),
                )
            })
        })
        .await
        .expect("cold-tier cycle handles candidate failure");

    assert_eq!(
        node_client.remote_call_count(),
        1,
        "export fails before source eviction and outside the database guard"
    );
    let identity_after = load_target_identity(&db.pool, customer, "products").await;
    assert_eq!(
        identity_after.deployment_id,
        original_identity.deployment_id
    );
    assert_eq!(identity_after.vm_id, Some(source_vm_id));
    assert_eq!(identity_after.tier, "cold");
    assert_eq!(identity_after.cold_snapshot_id, None);
    assert_eq!(identity_after.service_type, "shared");
    let snapshots = cold_snapshot_rows(&db.pool, customer, "products").await;
    assert_eq!(snapshots.len(), 1);
    assert_eq!(
        snapshots[0].status, "exporting",
        "stale rollback must not compensate the operation intent after identity drift"
    );
}
