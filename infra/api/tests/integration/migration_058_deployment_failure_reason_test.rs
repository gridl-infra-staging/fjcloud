//! Schema-contract tests for migration `058_deployment_failure_reason`.
//!
//! These are red KATs for the engine-health provisioning gate. They avoid
//! production model fields so the integration binary still compiles before the
//! migration and repository implementation exist.
use sqlx::{PgPool, Row};

async fn connect_and_migrate() -> Option<PgPool> {
    let Ok(url) = std::env::var("DATABASE_URL") else {
        println!(
            "SKIP: DATABASE_URL not set - skipping migration_058_deployment_failure_reason schema test"
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
async fn migration_058_engine_health_failure_reason_is_present_in_compiled_set() {
    let migrations = sqlx::migrate!("../migrations");
    let found = migrations
        .iter()
        .any(|m| m.version == 58 && m.description.contains("deployment failure reason"));
    assert!(
        found,
        "migration 058_deployment_failure_reason must be present in the compiled migration set"
    );
}

#[tokio::test]
async fn customer_deployments_failure_reason_schema_contract_engine_health() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let columns = sqlx::query(
        "SELECT column_name, is_nullable, data_type \
         FROM information_schema.columns \
         WHERE table_schema = 'public' AND table_name = 'customer_deployments' \
           AND column_name = 'failure_reason'",
    )
    .fetch_all(&pool)
    .await
    .expect("query customer_deployments.failure_reason from information_schema");

    assert_eq!(
        columns.len(),
        1,
        "migration 058 must add exactly one failure_reason column to customer_deployments"
    );

    let column = &columns[0];
    assert_eq!(column.get::<String, _>("column_name"), "failure_reason");
    assert_eq!(
        column.get::<String, _>("is_nullable"),
        "YES",
        "customer_deployments.failure_reason must be nullable"
    );
    assert_eq!(
        column.get::<String, _>("data_type"),
        "text",
        "customer_deployments.failure_reason must be TEXT"
    );
}

#[test]
fn migration_058_source_declares_nullable_text_failure_reason_engine_health() {
    let migration_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("api crate should have infra parent")
        .join("migrations/058_deployment_failure_reason.sql");
    let migration = std::fs::read_to_string(&migration_path)
        .expect("migration 058_deployment_failure_reason.sql must exist");

    assert!(
        migration.contains("ALTER TABLE customer_deployments"),
        "migration 058 must alter customer_deployments"
    );
    let executable_sql = migration
        .lines()
        .map(|line| line.split_once("--").map_or(line, |(sql, _comment)| sql))
        .collect::<Vec<_>>()
        .join("\n");
    let normalized_sql = executable_sql
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_uppercase();
    let failure_reason_statement = normalized_sql
        .split(';')
        .find(|statement| {
            statement.contains("ALTER TABLE CUSTOMER_DEPLOYMENTS")
                && statement.contains("ADD COLUMN FAILURE_REASON TEXT")
        })
        .expect("migration 058 must add failure_reason TEXT");

    assert!(
        !failure_reason_statement.contains("NOT NULL"),
        "migration 058 must leave failure_reason nullable; do not declare NOT NULL"
    );
    let not_null_tightening = normalized_sql.split(';').find(|statement| {
        statement.contains("FAILURE_REASON")
            && statement.contains("SET NOT NULL")
            && !statement.contains("DROP NOT NULL")
    });
    assert!(
        not_null_tightening.is_none(),
        "migration 058 must not make failure_reason non-nullable in a later statement: {:?}",
        not_null_tightening.map(str::trim)
    );
}
