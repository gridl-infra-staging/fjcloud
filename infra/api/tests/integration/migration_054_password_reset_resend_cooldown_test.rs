//! Schema-contract test for migration `054_password_reset_resend_cooldown`.
//!
//! Proves the durable password-reset resend cooldown column exists on
//! `customers` with the expected nullability and type after the full migration
//! chain runs.
use sqlx::{PgPool, Row};

async fn connect_and_migrate() -> Option<PgPool> {
    let Ok(url) = std::env::var("DATABASE_URL") else {
        println!(
            "SKIP: DATABASE_URL not set — skipping migration_054_password_reset_resend_cooldown schema test"
        );
        return None;
    };
    let pool = PgPool::connect(&url)
        .await
        .expect("connect to integration test DB");
    sqlx::migrate!("../migrations")
        .run(&pool)
        .await
        .expect("run migrations");
    Some(pool)
}

#[tokio::test]
async fn password_reset_resend_cooldown_column_schema_contract() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let columns = sqlx::query(
        "SELECT column_name, is_nullable, data_type \
         FROM information_schema.columns \
         WHERE table_schema = 'public' AND table_name = 'customers' \
           AND column_name = 'resend_password_reset_sent_at'",
    )
    .fetch_all(&pool)
    .await
    .expect("query resend password reset cooldown column from information_schema");

    assert_eq!(
        columns.len(),
        1,
        "migration 054 must add exactly one resend_password_reset_sent_at column to customers"
    );

    let column = &columns[0];
    assert_eq!(
        column.get::<String, _>("column_name"),
        "resend_password_reset_sent_at",
        "column name must match the durable password-reset resend owner field"
    );
    assert_eq!(
        column.get::<String, _>("is_nullable"),
        "YES",
        "resend_password_reset_sent_at must be nullable"
    );
    assert_eq!(
        column.get::<String, _>("data_type"),
        "timestamp with time zone",
        "resend_password_reset_sent_at must be timestamptz"
    );
}

#[tokio::test]
async fn migration_054_is_present_in_compiled_set() {
    let migrations = sqlx::migrate!("../migrations");
    let found = migrations
        .iter()
        .any(|m| m.description.contains("password reset resend cooldown"));
    assert!(
        found,
        "migration 054_password_reset_resend_cooldown must be present in the compiled migration set"
    );
}
