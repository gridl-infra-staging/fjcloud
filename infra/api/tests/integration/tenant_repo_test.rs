use crate::common::MockTenantRepo;
use api::models::tenant::CustomerTenant;
use api::repos::tenant_repo::TenantRepo;
use api::repos::PgTenantRepo;
use api::repos::RepoError;
use std::sync::Arc;
use uuid::Uuid;

fn setup() -> (Arc<MockTenantRepo>, Uuid, Uuid) {
    let repo = Arc::new(MockTenantRepo::new());
    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();

    // Seed deployment info so summaries can be produced
    repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("https://vm-abc.flapjack.foo"),
        "healthy",
        "running",
    );

    (repo, customer_id, deployment_id)
}

#[test]
fn pg_tenant_bulk_lookup_is_single_any_query() {
    let source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/repos/pg_tenant_repo.rs"),
    )
    .expect("read pg_tenant_repo source");
    let body = crate::common::source_assertions::function_body(&source, "list_by_vms")
        .expect("PgTenantRepo must implement list_by_vms");

    assert!(
        body.contains("ANY($1)"),
        "PgTenantRepo::list_by_vms must use a single PostgreSQL ANY($1) lookup"
    );
    assert_eq!(
        body.matches("sqlx::query_as::<_, CustomerTenant>").count(),
        1,
        "PgTenantRepo::list_by_vms must construct exactly one CustomerTenant query"
    );
    assert!(
        !body.contains("list_by_vm"),
        "PgTenantRepo::list_by_vms must not fan out through list_by_vm"
    );
}

#[test]
fn pg_tenant_count_by_customers_is_single_any_query() {
    let source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/repos/pg_tenant_repo.rs"),
    )
    .expect("read pg_tenant_repo source");
    let body = crate::common::source_assertions::function_body(&source, "count_by_customers")
        .expect("PgTenantRepo must implement count_by_customers");

    assert!(
        body.contains("ANY($1)"),
        "PgTenantRepo::count_by_customers must use a single PostgreSQL ANY($1) lookup"
    );
    assert!(
        body.contains("GROUP BY"),
        "PgTenantRepo::count_by_customers must aggregate with a single GROUP BY query"
    );
    assert!(
        !body.contains("count_by_customer("),
        "PgTenantRepo::count_by_customers must not fan out through count_by_customer"
    );
}

#[tokio::test]
async fn count_by_customers_empty_slice_returns_empty_map_without_query() {
    let (repo, customer_id, deployment_id) = setup();
    repo.create(customer_id, "idx-1", deployment_id)
        .await
        .unwrap();

    let counts = repo.count_by_customers(&[]).await.unwrap();
    assert!(
        counts.is_empty(),
        "empty customer slice must return an empty map"
    );
    assert_eq!(
        repo.count_by_customers_call_count(),
        0,
        "empty-slice batch call must not issue a query"
    );
}

#[tokio::test]
async fn count_by_customers_mock_matches_per_customer_counts() {
    let repo = Arc::new(MockTenantRepo::new());
    let customer_a = Uuid::new_v4();
    let customer_b = Uuid::new_v4();
    let customer_zero = Uuid::new_v4();

    let running_dep = Uuid::new_v4();
    let terminated_dep = Uuid::new_v4();
    repo.seed_deployment(
        running_dep,
        "us-east-1",
        Some("https://vm-1.flapjack.foo"),
        "healthy",
        "running",
    );
    repo.seed_deployment(terminated_dep, "eu-west-1", None, "unknown", "terminated");

    repo.create(customer_a, "a1", running_dep).await.unwrap();
    repo.create(customer_a, "a2", running_dep).await.unwrap();
    repo.create(customer_a, "a-dead", terminated_dep)
        .await
        .unwrap();
    repo.create(customer_b, "b1", running_dep).await.unwrap();

    let ids = [customer_a, customer_b, customer_zero];
    let counts = repo.count_by_customers(&ids).await.unwrap();

    // Terminated deployments are excluded, so customer_a has 2 live indexes.
    assert_eq!(counts.get(&customer_a).copied(), Some(2));
    assert_eq!(counts.get(&customer_b).copied(), Some(1));
    // Customer with zero live indexes is absent from the map (GROUP BY parity).
    assert_eq!(counts.get(&customer_zero).copied(), None);
    assert_eq!(repo.count_by_customers_call_count(), 1);

    // Each present entry equals the per-customer count.
    for id in [customer_a, customer_b] {
        assert_eq!(
            counts.get(&id).copied().unwrap_or(0),
            repo.count_by_customer(id).await.unwrap()
        );
    }
}

#[tokio::test]
async fn pg_tenant_count_by_customers_matches_per_customer_counts() {
    let Some(db) =
        crate::common::support::pg_schema_harness::connect_and_migrate("tenant_count_by_customers")
            .await
    else {
        return;
    };
    let repo = PgTenantRepo::new(db.pool.clone());

    let customer_two = Uuid::new_v4();
    let customer_one = Uuid::new_v4();
    let customer_zero = Uuid::new_v4();
    for (idx, customer_id) in [customer_two, customer_one, customer_zero]
        .into_iter()
        .enumerate()
    {
        crate::common::support::pg_schema_harness::insert_active_customer(
            &db.pool,
            customer_id,
            idx as i64 + 1,
        )
        .await;
    }

    let running_dep_a = Uuid::new_v4();
    let running_dep_b = Uuid::new_v4();
    let running_dep_c = Uuid::new_v4();
    let terminated_dep = Uuid::new_v4();
    insert_deployment(
        &db.pool,
        running_dep_a,
        customer_two,
        "cnt-a",
        "running",
        None,
    )
    .await;
    insert_deployment(
        &db.pool,
        running_dep_b,
        customer_two,
        "cnt-b",
        "running",
        None,
    )
    .await;
    insert_deployment(
        &db.pool,
        running_dep_c,
        customer_one,
        "cnt-c",
        "running",
        None,
    )
    .await;
    insert_deployment(
        &db.pool,
        terminated_dep,
        customer_two,
        "cnt-dead",
        "terminated",
        None,
    )
    .await;

    let vm = Uuid::new_v4();
    insert_vm_inventory(&db.pool, vm, "cnt-vm").await;
    insert_tenant(&db.pool, customer_two, "t-a", running_dep_a, vm).await;
    insert_tenant(&db.pool, customer_two, "t-b", running_dep_b, vm).await;
    insert_tenant(&db.pool, customer_two, "t-dead", terminated_dep, vm).await;
    insert_tenant(&db.pool, customer_one, "t-c", running_dep_c, vm).await;

    let ids = [customer_two, customer_one, customer_zero];
    let batched = repo.count_by_customers(&ids).await.unwrap();

    // Terminated deployment excluded → customer_two has 2 live indexes.
    assert_eq!(batched.get(&customer_two).copied(), Some(2));
    assert_eq!(batched.get(&customer_one).copied(), Some(1));
    // Zero-index customer absent from the grouped result.
    assert_eq!(batched.get(&customer_zero).copied(), None);

    // Known-answer parity: batched value equals the per-customer count query.
    for id in ids {
        let per_customer = repo.count_by_customer(id).await.unwrap();
        assert_eq!(batched.get(&id).copied().unwrap_or(0), per_customer);
    }
}

#[tokio::test]
async fn pg_tenant_bulk_lookup_matches_raw_per_vm_semantics() {
    let Some(db) =
        crate::common::support::pg_schema_harness::connect_and_migrate("tenant_bulk_lookup").await
    else {
        return;
    };
    let repo = PgTenantRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    let vm_with_two_tenants = Uuid::new_v4();
    let vm_with_terminated_tenant = Uuid::new_v4();
    let vm_with_zero_tenants = Uuid::new_v4();
    let running_deployment_id = Uuid::new_v4();
    let second_running_deployment_id = Uuid::new_v4();
    let terminated_deployment_id = Uuid::new_v4();

    crate::common::support::pg_schema_harness::insert_active_customer(&db.pool, customer_id, 1)
        .await;
    for (vm_id, hostname) in [
        (vm_with_two_tenants, "tenant-bulk-a"),
        (vm_with_terminated_tenant, "tenant-bulk-b"),
        (vm_with_zero_tenants, "tenant-bulk-empty"),
    ] {
        insert_vm_inventory(&db.pool, vm_id, hostname).await;
    }
    insert_deployment(
        &db.pool,
        running_deployment_id,
        customer_id,
        "tenant-bulk-running-a",
        "running",
        Some("http://tenant-bulk-running-a:7700"),
    )
    .await;
    insert_deployment(
        &db.pool,
        second_running_deployment_id,
        customer_id,
        "tenant-bulk-running-b",
        "running",
        Some("http://tenant-bulk-running-b:7700"),
    )
    .await;
    insert_deployment(
        &db.pool,
        terminated_deployment_id,
        customer_id,
        "tenant-bulk-terminated",
        "terminated",
        None,
    )
    .await;
    insert_tenant(
        &db.pool,
        customer_id,
        "tenant-a",
        running_deployment_id,
        vm_with_two_tenants,
    )
    .await;
    insert_tenant(
        &db.pool,
        customer_id,
        "tenant-b",
        second_running_deployment_id,
        vm_with_two_tenants,
    )
    .await;
    insert_tenant(
        &db.pool,
        customer_id,
        "tenant-terminated",
        terminated_deployment_id,
        vm_with_terminated_tenant,
    )
    .await;

    let vm_ids = [
        vm_with_two_tenants,
        vm_with_terminated_tenant,
        vm_with_zero_tenants,
    ];
    let bulk = repo.list_by_vms(&vm_ids).await.unwrap();
    let mut per_vm = Vec::new();
    for vm_id in vm_ids {
        per_vm.extend(repo.list_by_vm(vm_id).await.unwrap());
    }

    assert_eq!(
        tenant_rows_by_stable_values(bulk),
        tenant_rows_by_stable_values(per_vm)
    );
}

#[tokio::test]
async fn pg_find_by_tenant_id_global_returns_summary_with_vm_id() {
    let Some(db) =
        crate::common::support::pg_schema_harness::connect_and_migrate("tenant_global_vm_id").await
    else {
        return;
    };
    let repo = PgTenantRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    let vm_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();

    crate::common::support::pg_schema_harness::insert_active_customer(&db.pool, customer_id, 1)
        .await;
    insert_vm_inventory(&db.pool, vm_id, "tenant-global-vm").await;
    insert_deployment(
        &db.pool,
        deployment_id,
        customer_id,
        "tenant-global-running",
        "running",
        Some("http://tenant-global-running:7700"),
    )
    .await;
    insert_tenant(&db.pool, customer_id, "global-idx", deployment_id, vm_id).await;

    // The derived FromRow requires every summary column, including vm_id, to be
    // present in the SELECT — a missing column returns ColumnNotFound, so this
    // Some path fails outright if the global lookup drops vm_id.
    let found = repo
        .find_by_tenant_id_global("global-idx")
        .await
        .expect("global lookup must decode the summary row");
    let summary = found.expect("inserted tenant must be found");
    assert_eq!(summary.tenant_id, "global-idx");
    assert_eq!(summary.customer_id, customer_id);
    assert_eq!(summary.vm_id, Some(vm_id));
    assert_eq!(summary.region, "us-east-1");
    assert_eq!(
        summary.flapjack_url.as_deref(),
        Some("http://tenant-global-running:7700")
    );
}

#[tokio::test]
async fn create_inserts_and_returns_tenant() {
    let (repo, customer_id, deployment_id) = setup();

    let tenant = repo
        .create(customer_id, "my-index", deployment_id)
        .await
        .unwrap();

    assert_eq!(tenant.customer_id, customer_id);
    assert_eq!(tenant.tenant_id, "my-index");
    assert_eq!(tenant.deployment_id, deployment_id);
}

#[tokio::test]
async fn create_duplicate_returns_conflict() {
    let (repo, customer_id, deployment_id) = setup();

    repo.create(customer_id, "my-index", deployment_id)
        .await
        .unwrap();
    let result = repo.create(customer_id, "my-index", deployment_id).await;

    assert!(matches!(result, Err(RepoError::Conflict(_))));
}

#[tokio::test]
async fn find_by_customer_returns_all_with_deployment_info() {
    let (repo, customer_id, deployment_id) = setup();

    repo.create(customer_id, "index-a", deployment_id)
        .await
        .unwrap();
    repo.create(customer_id, "index-b", deployment_id)
        .await
        .unwrap();

    let summaries = repo.find_by_customer(customer_id).await.unwrap();
    assert_eq!(summaries.len(), 2);

    // Verify deployment info is joined
    for s in &summaries {
        assert_eq!(s.region, "us-east-1");
        assert_eq!(
            s.flapjack_url.as_deref(),
            Some("https://vm-abc.flapjack.foo")
        );
        assert_eq!(s.health_status, "healthy");
    }
}

#[tokio::test]
async fn find_by_customer_excludes_terminated_deployments() {
    let repo = Arc::new(MockTenantRepo::new());
    let customer_id = Uuid::new_v4();

    let running_dep = Uuid::new_v4();
    let terminated_dep = Uuid::new_v4();

    repo.seed_deployment(
        running_dep,
        "us-east-1",
        Some("https://vm-1.flapjack.foo"),
        "healthy",
        "running",
    );
    repo.seed_deployment(terminated_dep, "eu-west-1", None, "unknown", "terminated");

    repo.create(customer_id, "live-index", running_dep)
        .await
        .unwrap();
    repo.create(customer_id, "dead-index", terminated_dep)
        .await
        .unwrap();

    let summaries = repo.find_by_customer(customer_id).await.unwrap();
    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].tenant_id, "live-index");
}

#[tokio::test]
async fn find_by_name_returns_single() {
    let (repo, customer_id, deployment_id) = setup();

    repo.create(customer_id, "my-index", deployment_id)
        .await
        .unwrap();
    repo.create(customer_id, "other-index", deployment_id)
        .await
        .unwrap();

    let summary = repo.find_by_name(customer_id, "my-index").await.unwrap();
    assert!(summary.is_some());
    let s = summary.unwrap();
    assert_eq!(s.tenant_id, "my-index");
    assert_eq!(s.region, "us-east-1");

    // Non-existent returns None
    let missing = repo
        .find_by_name(customer_id, "no-such-index")
        .await
        .unwrap();
    assert!(missing.is_none());
}

#[tokio::test]
async fn find_by_name_excludes_terminated_deployment() {
    let repo = Arc::new(MockTenantRepo::new());
    let customer_id = Uuid::new_v4();
    let terminated_dep = Uuid::new_v4();

    repo.seed_deployment(terminated_dep, "us-east-1", None, "unknown", "terminated");
    repo.create(customer_id, "dead-index", terminated_dep)
        .await
        .unwrap();

    // Index exists in the catalog but its deployment is terminated — should return None
    let result = repo.find_by_name(customer_id, "dead-index").await.unwrap();
    assert!(
        result.is_none(),
        "find_by_name must exclude indexes on terminated deployments"
    );
}

#[tokio::test]
async fn count_by_customer_excludes_terminated_deployments() {
    let repo = Arc::new(MockTenantRepo::new());
    let customer_id = Uuid::new_v4();

    let running_dep = Uuid::new_v4();
    let terminated_dep = Uuid::new_v4();

    repo.seed_deployment(
        running_dep,
        "us-east-1",
        Some("https://vm-1.flapjack.foo"),
        "healthy",
        "running",
    );
    repo.seed_deployment(terminated_dep, "eu-west-1", None, "unknown", "terminated");

    repo.create(customer_id, "live-index", running_dep)
        .await
        .unwrap();
    repo.create(customer_id, "dead-index", terminated_dep)
        .await
        .unwrap();

    // Count should only include indexes on non-terminated deployments
    let count = repo.count_by_customer(customer_id).await.unwrap();
    assert_eq!(
        count, 1,
        "count_by_customer must exclude indexes on terminated deployments"
    );
}

#[tokio::test]
async fn delete_removes_and_returns_true() {
    let (repo, customer_id, deployment_id) = setup();

    repo.create(customer_id, "my-index", deployment_id)
        .await
        .unwrap();
    let deleted = repo.delete(customer_id, "my-index").await.unwrap();
    assert!(deleted);

    // Verify it's gone
    let count = repo.count_by_customer(customer_id).await.unwrap();
    assert_eq!(count, 0);
}

#[tokio::test]
async fn delete_non_existent_returns_false() {
    let (repo, customer_id, _) = setup();

    let deleted = repo.delete(customer_id, "no-such-index").await.unwrap();
    assert!(!deleted);
}

#[tokio::test]
async fn count_by_customer_is_accurate() {
    let (repo, customer_id, deployment_id) = setup();

    assert_eq!(repo.count_by_customer(customer_id).await.unwrap(), 0);

    repo.create(customer_id, "idx-1", deployment_id)
        .await
        .unwrap();
    assert_eq!(repo.count_by_customer(customer_id).await.unwrap(), 1);

    repo.create(customer_id, "idx-2", deployment_id)
        .await
        .unwrap();
    assert_eq!(repo.count_by_customer(customer_id).await.unwrap(), 2);

    // Different customer's indexes shouldn't count
    let other_customer = Uuid::new_v4();
    repo.create(other_customer, "idx-1", deployment_id)
        .await
        .unwrap();
    assert_eq!(repo.count_by_customer(customer_id).await.unwrap(), 2);
    assert_eq!(repo.count_by_customer(other_customer).await.unwrap(), 1);
}

#[tokio::test]
async fn create_defaults_service_type_to_flapjack() {
    let (repo, customer_id, deployment_id) = setup();

    let tenant = repo
        .create(customer_id, "my-index", deployment_id)
        .await
        .unwrap();

    assert_eq!(tenant.service_type, "flapjack");
}

#[tokio::test]
async fn find_by_customer_includes_service_type_in_summary() {
    let (repo, customer_id, deployment_id) = setup();

    repo.create(customer_id, "index-a", deployment_id)
        .await
        .unwrap();

    let summaries = repo.find_by_customer(customer_id).await.unwrap();
    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].service_type, "flapjack");
}

#[tokio::test]
async fn find_by_name_includes_service_type_in_summary() {
    let (repo, customer_id, deployment_id) = setup();

    repo.create(customer_id, "my-index", deployment_id)
        .await
        .unwrap();

    let summary = repo
        .find_by_name(customer_id, "my-index")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(summary.service_type, "flapjack");
}

#[tokio::test]
async fn find_by_deployment_returns_all_indexes_on_vm() {
    let repo = Arc::new(MockTenantRepo::new());
    let dep_a = Uuid::new_v4();
    let dep_b = Uuid::new_v4();
    let customer = Uuid::new_v4();

    repo.seed_deployment(
        dep_a,
        "us-east-1",
        Some("https://vm-a.flapjack.foo"),
        "healthy",
        "running",
    );
    repo.seed_deployment(
        dep_b,
        "eu-west-1",
        Some("https://vm-b.flapjack.foo"),
        "healthy",
        "running",
    );

    repo.create(customer, "idx-on-a-1", dep_a).await.unwrap();
    repo.create(customer, "idx-on-a-2", dep_a).await.unwrap();
    repo.create(customer, "idx-on-b", dep_b).await.unwrap();

    let on_a = repo.find_by_deployment(dep_a).await.unwrap();
    assert_eq!(on_a.len(), 2);
    assert!(on_a.iter().all(|t| t.deployment_id == dep_a));

    let on_b = repo.find_by_deployment(dep_b).await.unwrap();
    assert_eq!(on_b.len(), 1);
    assert_eq!(on_b[0].tenant_id, "idx-on-b");

    let on_empty = repo.find_by_deployment(Uuid::new_v4()).await.unwrap();
    assert!(on_empty.is_empty());
}

async fn insert_vm_inventory(pool: &sqlx::PgPool, id: Uuid, hostname: &str) {
    sqlx::query(
        "INSERT INTO vm_inventory (id, region, provider, hostname, flapjack_url, capacity) \
         VALUES ($1, 'us-east-1', 'aws', $2, $3, '{}')",
    )
    .bind(id)
    .bind(hostname)
    .bind(format!("http://{hostname}:7700"))
    .execute(pool)
    .await
    .expect("insert VM inventory row");
}

async fn insert_deployment(
    pool: &sqlx::PgPool,
    id: Uuid,
    customer_id: Uuid,
    node_id: &str,
    status: &str,
    flapjack_url: Option<&str>,
) {
    sqlx::query(
        "INSERT INTO customer_deployments \
         (id, customer_id, node_id, region, vm_type, vm_provider, status, flapjack_url, terminated_at) \
         VALUES ($1, $2, $3, 'us-east-1', 'shared', 'aws', $4, $5, \
                 CASE WHEN $4 = 'terminated' THEN NOW() ELSE NULL END)",
    )
    .bind(id)
    .bind(customer_id)
    .bind(node_id)
    .bind(status)
    .bind(flapjack_url)
    .execute(pool)
    .await
    .expect("insert deployment row");
}

async fn insert_tenant(
    pool: &sqlx::PgPool,
    customer_id: Uuid,
    tenant_id: &str,
    deployment_id: Uuid,
    vm_id: Uuid,
) {
    sqlx::query(
        "INSERT INTO customer_tenants (customer_id, tenant_id, deployment_id, vm_id) \
         VALUES ($1, $2, $3, $4)",
    )
    .bind(customer_id)
    .bind(tenant_id)
    .bind(deployment_id)
    .bind(vm_id)
    .execute(pool)
    .await
    .expect("insert tenant row");
}

fn tenant_rows_by_stable_values(
    mut tenants: Vec<CustomerTenant>,
) -> Vec<(Uuid, String, Uuid, Uuid)> {
    let mut rows = tenants
        .drain(..)
        .map(|tenant| {
            (
                tenant.customer_id,
                tenant.tenant_id,
                tenant.deployment_id,
                tenant.vm_id.expect("bulk test tenants are VM-placed"),
            )
        })
        .collect::<Vec<_>>();
    rows.sort();
    rows
}
