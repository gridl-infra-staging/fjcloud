#![allow(dead_code)]

use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use uuid::Uuid;

pub struct DbHarness {
    pub pool: PgPool,
    pub schema: String,
    backend_pid: i32,
}

impl Drop for DbHarness {
    fn drop(&mut self) {
        let schema = self.schema.clone();
        let backend_pid = self.backend_pid;
        let database_url = std::env::var("DATABASE_URL").ok();
        let cleanup_worker = std::thread::Builder::new()
            .name("pg_customer_repo_schema_cleanup".to_string())
            .spawn(move || {
                let Some(url) = database_url else {
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
            });
        if let Ok(join_handle) = cleanup_worker {
            let _ = join_handle.join();
        }
    }
}

pub async fn connect_and_migrate(schema_prefix: &str) -> Option<DbHarness> {
    let url = match std::env::var("DATABASE_URL") {
        Ok(url) => url,
        Err(_) => {
            println!("SKIP: DATABASE_URL not set - skipping PostgreSQL schema harness test");
            return None;
        }
    };

    let schema = isolated_schema_name(schema_prefix);
    let quoted_schema = quote_pg_identifier(&schema);

    let admin_pool = PgPool::connect(&url)
        .await
        .expect("connect to integration test DB");
    sqlx::query(&format!("CREATE SCHEMA {quoted_schema}"))
        .execute(&admin_pool)
        .await
        .expect("create isolated schema for SQL integration test");

    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(&url)
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

    sqlx::migrate!("../migrations")
        .run(&pool)
        .await
        .expect("run migrations");

    Some(DbHarness {
        pool,
        schema,
        backend_pid,
    })
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
