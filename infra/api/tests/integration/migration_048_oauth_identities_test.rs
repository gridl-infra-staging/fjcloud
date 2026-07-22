//! Schema-contract test for migration `048_oauth_identities`.
//!
//! This test pins the Stage 1 OAuth identity schema contract. After the
//! full migration chain runs, `oauth_identities` must exist as the canonical
//! mapping from provider identities to `customers` rows.
//! It also ensures migration 048 is present in the compiled migration set.
use sqlx::{PgPool, Row};
use uuid::Uuid;

use crate::common::support::pg_schema_harness;

async fn cleanup_customer(pool: &PgPool, customer_id: Uuid) {
    let _ = sqlx::query("DELETE FROM customers WHERE id = $1")
        .bind(customer_id)
        .execute(pool)
        .await;
}

#[tokio::test]
async fn oauth_identities_schema_contract_is_enforced() {
    let Some(db) = pg_schema_harness::connect_and_migrate("migration_048_oauth").await else {
        return;
    };
    let pool = &db.pool;

    let columns = sqlx::query(
        "SELECT column_name, is_nullable, data_type \
         FROM information_schema.columns \
         WHERE table_schema = current_schema() AND table_name = 'oauth_identities'",
    )
    .fetch_all(pool)
    .await
    .expect("query oauth_identities columns");

    assert_eq!(
        columns.len(),
        5,
        "oauth_identities must expose exactly the Stage 1 canonical columns"
    );

    let has_column = |name: &str, nullable: &str, data_type: &str| {
        columns.iter().any(|row| {
            row.get::<String, _>("column_name") == name
                && row.get::<String, _>("is_nullable") == nullable
                && row.get::<String, _>("data_type") == data_type
        })
    };

    assert!(has_column("id", "NO", "uuid"));
    assert!(has_column("customer_id", "NO", "uuid"));
    assert!(has_column("provider", "NO", "text"));
    assert!(has_column("provider_user_id", "NO", "text"));
    assert!(has_column("linked_at", "NO", "timestamp with time zone"));

    let pk_columns: Vec<String> = sqlx::query_scalar(
        "SELECT kcu.column_name \
         FROM information_schema.table_constraints tc \
         JOIN information_schema.key_column_usage kcu \
           ON tc.constraint_name = kcu.constraint_name \
          AND tc.table_schema = kcu.table_schema \
         WHERE tc.table_schema = current_schema() \
           AND tc.table_name = 'oauth_identities' \
           AND tc.constraint_type = 'PRIMARY KEY' \
         ORDER BY kcu.ordinal_position",
    )
    .fetch_all(pool)
    .await
    .expect("query oauth_identities primary key columns");

    assert_eq!(pk_columns, vec!["id".to_string()]);

    let primary_customer_id = Uuid::new_v4();
    let secondary_customer_id = Uuid::new_v4();
    sqlx::query("INSERT INTO customers (id, name, email, status) VALUES ($1, $2, $3, 'active')")
        .bind(primary_customer_id)
        .bind("OAuth Identity Primary Customer")
        .bind(format!(
            "oauth-identity-primary-{}@integration.test",
            &primary_customer_id.to_string()[..8]
        ))
        .execute(pool)
        .await
        .expect("insert primary customer fixture");

    sqlx::query("INSERT INTO customers (id, name, email, status) VALUES ($1, $2, $3, 'active')")
        .bind(secondary_customer_id)
        .bind("OAuth Identity Secondary Customer")
        .bind(format!(
            "oauth-identity-secondary-{}@integration.test",
            &secondary_customer_id.to_string()[..8]
        ))
        .execute(pool)
        .await
        .expect("insert secondary customer fixture");

    sqlx::query(
        "INSERT INTO oauth_identities (customer_id, provider, provider_user_id) \
         VALUES ($1, $2, $3)",
    )
    .bind(primary_customer_id)
    .bind("github")
    .bind("user-1")
    .execute(pool)
    .await
    .expect("insert first oauth identity");

    let duplicate_attempt = sqlx::query(
        "INSERT INTO oauth_identities (customer_id, provider, provider_user_id) \
         VALUES ($1, $2, $3)",
    )
    .bind(secondary_customer_id)
    .bind("github")
    .bind("user-1")
    .execute(pool)
    .await;

    assert!(
        duplicate_attempt.is_err(),
        "(provider, provider_user_id) must be unique across oauth_identities"
    );

    sqlx::query(
        "INSERT INTO oauth_identities (customer_id, provider, provider_user_id) \
         VALUES ($1, $2, $3)",
    )
    .bind(primary_customer_id)
    .bind("github")
    .bind("user-2")
    .execute(pool)
    .await
    .expect("insert non-duplicate oauth identity for same provider");

    sqlx::query(
        "INSERT INTO oauth_identities (customer_id, provider, provider_user_id) \
         VALUES ($1, $2, $3)",
    )
    .bind(primary_customer_id)
    .bind("google")
    .bind("user-1")
    .execute(pool)
    .await
    .expect("insert non-duplicate oauth identity for same provider user id on different provider");

    sqlx::query(
        "INSERT INTO oauth_identities (customer_id, provider, provider_user_id) \
         VALUES ($1, $2, $3)",
    )
    .bind(secondary_customer_id)
    .bind("github")
    .bind("user-3")
    .execute(pool)
    .await
    .expect("insert second customer oauth identity with distinct provider tuple");

    let count_before_delete: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM oauth_identities WHERE customer_id = $1")
            .bind(primary_customer_id)
            .fetch_one(pool)
            .await
            .expect("count oauth identities before customer delete");
    assert_eq!(count_before_delete, 3);

    sqlx::query("DELETE FROM customers WHERE id = $1")
        .bind(primary_customer_id)
        .execute(pool)
        .await
        .expect("hard-delete primary customer fixture");

    let count_after_delete: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM oauth_identities WHERE customer_id = $1")
            .bind(primary_customer_id)
            .fetch_one(pool)
            .await
            .expect("count oauth identities after customer delete");
    assert_eq!(
        count_after_delete, 0,
        "primary customer delete must cascade to oauth_identities"
    );

    let secondary_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM oauth_identities WHERE customer_id = $1")
            .bind(secondary_customer_id)
            .fetch_one(pool)
            .await
            .expect("count oauth identities for secondary customer");
    assert_eq!(secondary_count, 1);

    cleanup_customer(pool, primary_customer_id).await;
    cleanup_customer(pool, secondary_customer_id).await;
}
