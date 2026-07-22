//! Schema-contract test for migration `052_auth_lockout_state`.
//!
//! Proves the 9 lockout/rate-limit columns exist on `customers` with the
//! correct nullability and data types after the full migration chain runs.
use sqlx::Row;

use crate::common::support::pg_schema_harness;

#[tokio::test]
async fn auth_lockout_columns_schema_contract() {
    let Some(db) = pg_schema_harness::connect_and_migrate("migration_052_lockout").await else {
        return;
    };
    let pool = &db.pool;

    let columns = sqlx::query(
        "SELECT column_name, is_nullable, data_type, column_default \
         FROM information_schema.columns \
         WHERE table_schema = current_schema() AND table_name = 'customers' \
           AND column_name IN ( \
               'failed_login_count', 'failed_login_window_start', 'login_locked_until', \
               'failed_verify_count', 'failed_verify_window_start', 'verify_locked_until', \
               'failed_reset_count', 'failed_reset_window_start', 'reset_locked_until' \
           )",
    )
    .fetch_all(pool)
    .await
    .expect("query lockout columns from information_schema");

    assert_eq!(
        columns.len(),
        9,
        "migration 052 must add exactly 9 lockout columns to customers"
    );

    let has_column = |name: &str, nullable: &str, data_type: &str| {
        columns.iter().any(|row| {
            row.get::<String, _>("column_name") == name
                && row.get::<String, _>("is_nullable") == nullable
                && row.get::<String, _>("data_type") == data_type
        })
    };

    // Login lockout columns
    assert!(
        has_column("failed_login_count", "NO", "integer"),
        "failed_login_count must be NOT NULL integer"
    );
    assert!(
        has_column(
            "failed_login_window_start",
            "YES",
            "timestamp with time zone"
        ),
        "failed_login_window_start must be nullable timestamptz"
    );
    assert!(
        has_column("login_locked_until", "YES", "timestamp with time zone"),
        "login_locked_until must be nullable timestamptz"
    );

    // Verify lockout columns
    assert!(
        has_column("failed_verify_count", "NO", "integer"),
        "failed_verify_count must be NOT NULL integer"
    );
    assert!(
        has_column(
            "failed_verify_window_start",
            "YES",
            "timestamp with time zone"
        ),
        "failed_verify_window_start must be nullable timestamptz"
    );
    assert!(
        has_column("verify_locked_until", "YES", "timestamp with time zone"),
        "verify_locked_until must be nullable timestamptz"
    );

    // Reset lockout columns
    assert!(
        has_column("failed_reset_count", "NO", "integer"),
        "failed_reset_count must be NOT NULL integer"
    );
    assert!(
        has_column(
            "failed_reset_window_start",
            "YES",
            "timestamp with time zone"
        ),
        "failed_reset_window_start must be nullable timestamptz"
    );
    assert!(
        has_column("reset_locked_until", "YES", "timestamp with time zone"),
        "reset_locked_until must be nullable timestamptz"
    );

    // Verify defaults for count columns
    let count_cols: Vec<_> = columns
        .iter()
        .filter(|row| {
            let name: String = row.get("column_name");
            name.ends_with("_count")
        })
        .collect();
    for row in &count_cols {
        let default: Option<String> = row.get("column_default");
        assert_eq!(
            default.as_deref(),
            Some("0"),
            "count column {} must default to 0",
            row.get::<String, _>("column_name")
        );
    }
}

#[tokio::test]
async fn migration_052_is_present_in_compiled_set() {
    let migrations = sqlx::migrate!("../migrations");
    let found = migrations
        .iter()
        .any(|m| m.description.contains("auth lockout state"));
    assert!(
        found,
        "migration 052_auth_lockout_state must be present in the compiled migration set"
    );
}
