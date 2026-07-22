use sqlx::Row;

use crate::common::support::pg_schema_harness;

const DISPUTES_COLUMNS_SQL: &str = "SELECT column_name, is_nullable, data_type
         FROM information_schema.columns
         WHERE table_schema = current_schema() AND table_name = 'disputes'";

const DISPUTES_UNIQUE_CONSTRAINT_SQL: &str = "SELECT tc.constraint_name
         FROM information_schema.table_constraints tc
         JOIN information_schema.constraint_column_usage ccu
           ON tc.constraint_name = ccu.constraint_name
          AND tc.table_schema = ccu.table_schema
         WHERE tc.table_schema = current_schema()
           AND tc.table_name = 'disputes'
           AND tc.constraint_type = 'UNIQUE'
           AND ccu.column_name = 'stripe_dispute_id'";

async fn connect_and_migrate() -> Option<pg_schema_harness::DbHarness> {
    pg_schema_harness::connect_and_migrate("migration_053_disputes").await
}

#[tokio::test]
async fn disputes_table_matches_stage1_contract() {
    let Some(db) = connect_and_migrate().await else {
        return;
    };

    let columns = sqlx::query(DISPUTES_COLUMNS_SQL)
        .fetch_all(&db.pool)
        .await
        .expect("query disputes columns");

    assert_eq!(
        columns.len(),
        14,
        "disputes must expose exactly the Stage 1 canonical columns"
    );

    let has_column = |name: &str, nullable: &str, data_type: &str| {
        columns.iter().any(|row| {
            row.get::<String, _>("column_name") == name
                && row.get::<String, _>("is_nullable") == nullable
                && row.get::<String, _>("data_type") == data_type
        })
    };

    assert!(has_column("id", "NO", "uuid"));
    assert!(has_column("stripe_dispute_id", "NO", "text"));
    assert!(has_column("stripe_charge_id", "NO", "text"));
    assert!(has_column("stripe_payment_intent_id", "YES", "text"));
    assert!(has_column("invoice_id", "YES", "uuid"));
    assert!(has_column("amount_cents", "NO", "bigint"));
    assert!(has_column("currency", "NO", "text"));
    assert!(has_column("reason", "YES", "text"));
    assert!(has_column("status", "NO", "text"));
    assert!(has_column(
        "evidence_due_by",
        "YES",
        "timestamp with time zone"
    ));
    assert!(has_column("disputed_at", "YES", "timestamp with time zone"));
    assert!(has_column("resolved_at", "YES", "timestamp with time zone"));
    assert!(has_column("created_at", "NO", "timestamp with time zone"));
    assert!(has_column("updated_at", "NO", "timestamp with time zone"));

    assert!(
        !columns
            .iter()
            .any(|row| row.get::<String, _>("column_name") == "customer_id"),
        "disputes must not duplicate customer ownership with a local customer_id column"
    );

    let unique_constraints: Vec<String> = sqlx::query_scalar(DISPUTES_UNIQUE_CONSTRAINT_SQL)
        .fetch_all(&db.pool)
        .await
        .expect("query unique constraints for stripe_dispute_id");

    assert!(
        !unique_constraints.is_empty(),
        "disputes.stripe_dispute_id must have a unique key"
    );
}

#[test]
fn disputes_schema_queries_do_not_contain_literal_backslashes() {
    assert!(
        !DISPUTES_COLUMNS_SQL.contains('\\'),
        "columns query must not include literal backslash characters"
    );
    assert!(
        !DISPUTES_UNIQUE_CONSTRAINT_SQL.contains('\\'),
        "unique constraint query must not include literal backslash characters"
    );
}
