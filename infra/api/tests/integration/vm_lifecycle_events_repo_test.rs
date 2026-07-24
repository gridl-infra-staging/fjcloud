use api::models::{NewVmLifecycleEvent, VmLifecycleEventType};
use api::repos::{PgVmLifecycleEventRepo, RepoError, VmLifecycleEventRepo};
use serde_json::{json, Value};
use uuid::Uuid;

use crate::common::support::pg_schema_harness::connect_and_migrate;

async fn seed_vm(pool: &sqlx::PgPool, hostname: &str) -> Uuid {
    let vm_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO vm_inventory (id, region, provider, hostname, flapjack_url) \
         VALUES ($1, 'us-east-1', 'aws', $2, $3)",
    )
    .bind(vm_id)
    .bind(hostname)
    .bind(format!("https://{hostname}"))
    .execute(pool)
    .await
    .expect("seed VM inventory row");
    vm_id
}

fn new_event(vm_id: Uuid, event_type: VmLifecycleEventType, detail: Value) -> NewVmLifecycleEvent {
    NewVmLifecycleEvent {
        vm_id,
        event_type,
        detail,
    }
}

#[tokio::test]
async fn vm_lifecycle_events_append_lists_all_event_types_with_json_detail_oldest_first() {
    let Some(db) = connect_and_migrate("it_vm_lifecycle_events_all_types").await else {
        return;
    };
    let repo = PgVmLifecycleEventRepo::new(db.pool.clone());
    let vm_id = seed_vm(&db.pool, "lifecycle-all-types.test").await;
    let event_inputs = [
        (
            VmLifecycleEventType::DetectedDead,
            json!({"detector":"host_status","provider_state":"stopped"}),
        ),
        (
            VmLifecycleEventType::ReplacementProvisioning,
            json!({"provider":"aws","region":"us-east-1"}),
        ),
        (
            VmLifecycleEventType::ReplacementBooted,
            json!({"replacement_vm_id":"vm-replacement"}),
        ),
        (
            VmLifecycleEventType::TenantsReplaced,
            json!({"tenant_count":2,"tenant_ids":["alpha","beta"]}),
        ),
        (
            VmLifecycleEventType::ReplacementFailed,
            json!({"error":"capacity_exhausted"}),
        ),
        (
            VmLifecycleEventType::ReplacementRefused,
            json!({"guardrail":"kill_switch_disabled"}),
        ),
    ];

    let empty = repo
        .list_for_vm(vm_id)
        .await
        .expect("list events for VM without history");
    assert_eq!(empty, Vec::new());

    let mut appended = Vec::new();
    for (event_type, detail) in event_inputs {
        let row = repo
            .append(new_event(vm_id, event_type, detail.clone()))
            .await
            .expect("append lifecycle event");
        assert_ne!(row.id, Uuid::nil());
        assert_eq!(row.vm_id, vm_id);
        assert_eq!(row.event_type, event_type);
        assert_eq!(row.detail, detail);
        appended.push(row);
        sqlx::query("SELECT pg_sleep(0.001)")
            .execute(&db.pool)
            .await
            .expect("separate event creation timestamps");
    }

    let listed = repo
        .list_for_vm(vm_id)
        .await
        .expect("list lifecycle events for VM");
    assert_eq!(listed, appended);
    assert_eq!(
        listed
            .iter()
            .map(|event| event.event_type.as_str())
            .collect::<Vec<_>>(),
        vec![
            "detected_dead",
            "replacement_provisioning",
            "replacement_booted",
            "tenants_replaced",
            "replacement_failed",
            "replacement_refused",
        ]
    );
}

#[tokio::test]
async fn vm_lifecycle_events_list_isolates_two_vm_ids() {
    let Some(db) = connect_and_migrate("it_vm_lifecycle_events_isolation").await else {
        return;
    };
    let repo = PgVmLifecycleEventRepo::new(db.pool.clone());
    let primary_vm_id = seed_vm(&db.pool, "lifecycle-primary.test").await;
    let other_vm_id = seed_vm(&db.pool, "lifecycle-other.test").await;

    let primary_event = repo
        .append(new_event(
            primary_vm_id,
            VmLifecycleEventType::DetectedDead,
            json!({"detector":"status"}),
        ))
        .await
        .expect("append primary VM event");
    repo.append(new_event(
        other_vm_id,
        VmLifecycleEventType::ReplacementRefused,
        json!({"guardrail":"tenant_migration_in_progress"}),
    ))
    .await
    .expect("append other VM event");

    let listed = repo
        .list_for_vm(primary_vm_id)
        .await
        .expect("list primary VM events");
    assert_eq!(listed, vec![primary_event]);
}

#[tokio::test]
async fn vm_lifecycle_events_rejects_unknown_vm_and_invalid_details() {
    let Some(db) = connect_and_migrate("it_vm_lifecycle_events_constraints").await else {
        return;
    };
    let repo = PgVmLifecycleEventRepo::new(db.pool.clone());
    let vm_id = seed_vm(&db.pool, "lifecycle-constraints.test").await;

    let unknown_vm_error = repo
        .append(new_event(
            Uuid::new_v4(),
            VmLifecycleEventType::DetectedDead,
            json!({"detector":"status"}),
        ))
        .await
        .expect_err("lifecycle events must reference canonical vm_inventory identity");
    match unknown_vm_error {
        RepoError::Other(message) => assert!(
            message.contains("foreign key constraint"),
            "expected PostgreSQL foreign-key failure, got: {message}"
        ),
        other => panic!("expected repository database error, got: {other}"),
    }

    let scalar_detail_error = repo
        .append(new_event(
            vm_id,
            VmLifecycleEventType::DetectedDead,
            json!("not-an-object"),
        ))
        .await
        .expect_err("detail must be a JSON object");
    assert!(
        matches!(scalar_detail_error, RepoError::Other(_)),
        "expected database check error, got {scalar_detail_error}"
    );

    let missing_guardrail_error = repo
        .append(new_event(
            vm_id,
            VmLifecycleEventType::ReplacementRefused,
            json!({"reason":"disabled"}),
        ))
        .await
        .expect_err("replacement_refused requires a non-empty guardrail detail");
    assert!(
        matches!(missing_guardrail_error, RepoError::Other(_)),
        "expected database check error, got {missing_guardrail_error}"
    );

    let blank_guardrail_error = repo
        .append(new_event(
            vm_id,
            VmLifecycleEventType::ReplacementRefused,
            json!({"guardrail":"   "}),
        ))
        .await
        .expect_err("replacement_refused guardrail must reject blank strings");
    assert!(
        matches!(blank_guardrail_error, RepoError::Other(_)),
        "expected database check error, got {blank_guardrail_error}"
    );
}

#[tokio::test]
async fn vm_lifecycle_events_direct_sql_update_and_delete_are_rejected() {
    let Some(db) = connect_and_migrate("it_vm_lifecycle_events_append_only").await else {
        return;
    };
    let repo = PgVmLifecycleEventRepo::new(db.pool.clone());
    let vm_id = seed_vm(&db.pool, "lifecycle-append-only.test").await;
    let event = repo
        .append(new_event(
            vm_id,
            VmLifecycleEventType::ReplacementFailed,
            json!({"error":"boot_timeout"}),
        ))
        .await
        .expect("append lifecycle event");

    let update_error = sqlx::query("UPDATE vm_lifecycle_events SET detail = '{}' WHERE id = $1")
        .bind(event.id)
        .execute(&db.pool)
        .await
        .expect_err("direct SQL UPDATE must be rejected");
    assert!(
        update_error.to_string().contains("append-only"),
        "expected append-only update rejection, got: {update_error}"
    );

    let delete_error = sqlx::query("DELETE FROM vm_lifecycle_events WHERE id = $1")
        .bind(event.id)
        .execute(&db.pool)
        .await
        .expect_err("direct SQL DELETE must be rejected");
    assert!(
        delete_error.to_string().contains("append-only"),
        "expected append-only delete rejection, got: {delete_error}"
    );

    let listed = repo
        .list_for_vm(vm_id)
        .await
        .expect("event remains queryable after rejected mutations");
    assert_eq!(listed, vec![event]);
}
