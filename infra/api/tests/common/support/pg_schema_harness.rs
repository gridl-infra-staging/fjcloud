#![allow(dead_code)]

use std::borrow::Cow;
use std::time::Duration;

use sqlx::migrate::{MigrateError, Migrator};
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use uuid::Uuid;

pub fn postgres_timestamp(
    timestamp: chrono::DateTime<chrono::Utc>,
) -> chrono::DateTime<chrono::Utc> {
    chrono::DateTime::from_timestamp_micros(timestamp.timestamp_micros()).unwrap_or(timestamp)
}

pub struct DbHarness {
    pub pool: PgPool,
    pub schema: String,
    backend_pid: i32,
}

const SCHEMA_CLEANUP_DROP_WAIT: Duration = Duration::from_millis(250);

impl Drop for DbHarness {
    fn drop(&mut self) {
        let schema = self.schema.clone();
        let backend_pid = self.backend_pid;
        let database_url = std::env::var("DATABASE_URL").ok();
        let (cleanup_done_tx, cleanup_done_rx) = std::sync::mpsc::channel();
        let cleanup_worker = std::thread::Builder::new()
            .name("pg_customer_repo_schema_cleanup".to_string())
            .spawn(move || {
                let Some(url) = database_url else {
                    let _ = cleanup_done_tx.send(());
                    return;
                };
                if let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    runtime.block_on(async move {
                        if let Ok(admin_pool) = PgPool::connect(&url).await {
                            sqlx::query_scalar::<_, bool>("SELECT pg_terminate_backend($1)")
                                .bind(backend_pid)
                                .fetch_optional(&admin_pool)
                                .await
                                .ok();
                            cleanup_schema(&admin_pool, &schema).await;
                        }
                    });
                }
                let _ = cleanup_done_tx.send(());
            });
        if cleanup_worker.is_ok() {
            // Timed-out tests can leave PostgreSQL locks that block DROP SCHEMA;
            // DbHarness::drop must not hide the original bounded failure.
            let _ = cleanup_done_rx.recv_timeout(SCHEMA_CLEANUP_DROP_WAIT);
        }
    }
}

pub async fn connect_and_migrate(schema_prefix: &str) -> Option<DbHarness> {
    let harness = connect_without_migrations(schema_prefix).await?;

    isolated_schema_migrator()
        .run(&harness.pool)
        .await
        .expect("run migrations");
    Some(harness)
}

pub async fn connect_and_migrate_required(schema_prefix: &str) -> DbHarness {
    let harness = connect_without_migrations_required(schema_prefix).await;

    isolated_schema_migrator()
        .run(&harness.pool)
        .await
        .expect("run migrations");
    harness
}

pub async fn connect_and_migrate_through(
    schema_prefix: &str,
    max_version: i64,
) -> Option<DbHarness> {
    let harness = connect_without_migrations(schema_prefix).await?;
    migrate_through_version(&harness.pool, max_version)
        .await
        .expect("run migrations through requested version");
    Some(harness)
}

pub async fn migrate_through_version(pool: &PgPool, max_version: i64) -> Result<(), MigrateError> {
    let all_migrations = sqlx::migrate!("../migrations");
    assert!(
        all_migrations.version_exists(max_version),
        "migration version {max_version} must exist"
    );
    let mut migrator = Migrator {
        migrations: Cow::Owned(
            all_migrations
                .iter()
                .filter(|migration| migration.version <= max_version)
                .cloned()
                .collect(),
        ),
        ..Migrator::DEFAULT
    };
    migrator.set_locking(false);
    migrator.run(pool).await
}

fn isolated_schema_migrator() -> Migrator {
    let mut migrator = sqlx::migrate!("../migrations");
    // Each test owns a fresh schema and `_sqlx_migrations` table via search_path;
    // sqlx's database-wide advisory lock only creates the cross-test
    // `connect_and_migrate` convoy captured in the admin_vms reference tests.
    migrator.set_locking(false);
    migrator
}

pub async fn connect_without_migrations(schema_prefix: &str) -> Option<DbHarness> {
    let url = match std::env::var("DATABASE_URL") {
        Ok(url) => url,
        Err(_) => {
            println!("SKIP: DATABASE_URL not set - skipping PostgreSQL schema harness test");
            return None;
        }
    };

    Some(connect_without_migrations_with_url(schema_prefix, &url).await)
}

pub async fn connect_without_migrations_required(schema_prefix: &str) -> DbHarness {
    let url = require_database_url(std::env::var("DATABASE_URL"));
    connect_without_migrations_with_url(schema_prefix, &url).await
}

async fn connect_without_migrations_with_url(schema_prefix: &str, url: &str) -> DbHarness {
    let schema = isolated_schema_name(schema_prefix);
    let quoted_schema = quote_pg_identifier(&schema);

    let admin_pool = PgPool::connect(url)
        .await
        .expect("connect to integration test DB");
    sqlx::query(&format!("CREATE SCHEMA {quoted_schema}"))
        .execute(&admin_pool)
        .await
        .expect("create isolated schema for SQL integration test");

    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(url)
        .await
        .expect("connect to integration test DB");
    sqlx::query(&format!("SET search_path TO {quoted_schema}"))
        .execute(&pool)
        .await
        .expect("set test schema search_path");
    let backend_pid = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&pool)
        .await
        .expect("capture isolated test connection PID");

    DbHarness {
        pool,
        schema,
        backend_pid,
    }
}

pub async fn pool_in_schema(schema: &str, max_connections: u32) -> PgPool {
    let database_url = require_database_url(std::env::var("DATABASE_URL"));
    let quoted_schema = quote_pg_identifier(schema);
    PgPoolOptions::new()
        .max_connections(max_connections)
        .after_connect(move |connection, _metadata| {
            let quoted_schema = quoted_schema.clone();
            Box::pin(async move {
                sqlx::query(&format!("SET search_path TO {quoted_schema}"))
                    .execute(connection)
                    .await?;
                Ok(())
            })
        })
        .connect(&database_url)
        .await
        .expect("connect pool to isolated schema")
}

pub fn require_database_url(result: Result<String, std::env::VarError>) -> String {
    result.expect("DATABASE_URL must be set for PostgreSQL integration tests")
}

pub async fn schema_exists(pool: &PgPool, schema: &str) -> bool {
    sqlx::query_scalar::<_, bool>("SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = $1)")
        .bind(schema)
        .fetch_one(pool)
        .await
        .expect("check schema existence")
}

pub async fn cleanup_schema(pool: &PgPool, schema: &str) {
    sqlx::query("SET search_path TO public")
        .execute(pool)
        .await
        .ok();

    let quoted_schema = quote_pg_identifier(schema);
    sqlx::query(&format!("DROP SCHEMA IF EXISTS {quoted_schema} CASCADE"))
        .execute(pool)
        .await
        .ok();
}

fn isolated_schema_name(schema_prefix: &str) -> String {
    assert!(
        !schema_prefix.is_empty()
            && schema_prefix
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_'),
        "schema_prefix must contain only ASCII letters, digits, or underscores"
    );
    format!("{schema_prefix}_{}", Uuid::new_v4().simple())
}

fn quote_pg_identifier(identifier: &str) -> String {
    format!("\"{}\"", identifier.replace('"', "\"\""))
}

pub async fn insert_active_customer(pool: &PgPool, customer_id: Uuid, generation: i64) {
    sqlx::query(
        "INSERT INTO customers (id, name, email, status, lifecycle_generation) \
         VALUES ($1, 'Algolia lifecycle customer', $2, 'active', $3)",
    )
    .bind(customer_id)
    .bind(format!("{customer_id}@algolia-lifecycle.test"))
    .bind(generation)
    .execute(pool)
    .await
    .expect("insert active Algolia lifecycle customer");
}

#[cfg(test)]
mod tests {
    use super::{isolated_schema_name, quote_pg_identifier};

    #[test]
    fn embedded_migration_versions_are_unique() {
        let mut versions = std::collections::BTreeSet::new();
        for migration in sqlx::migrate!("../migrations").iter() {
            assert!(
                versions.insert(migration.version),
                "migration version {} is declared more than once",
                migration.version
            );
        }
    }

    #[test]
    fn quote_pg_identifier_escapes_embedded_quotes() {
        assert_eq!(
            quote_pg_identifier("tenant\"; DROP SCHEMA public CASCADE; --"),
            "\"tenant\"\"; DROP SCHEMA public CASCADE; --\""
        );
    }

    #[test]
    fn isolated_schema_name_rejects_non_identifier_prefixes() {
        let result = std::panic::catch_unwind(|| {
            isolated_schema_name("tenant; DROP SCHEMA public CASCADE; --")
        });
        assert!(
            result.is_err(),
            "schema prefixes with SQL metacharacters must be rejected"
        );
    }
}
