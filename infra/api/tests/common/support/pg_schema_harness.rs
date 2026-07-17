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
    let url = require_database_url(std::env::var("DATABASE_URL"));

    let schema = format!("{schema_prefix}_{}", Uuid::new_v4().simple());

    let admin_pool = PgPool::connect(&url)
        .await
        .expect("connect to integration test DB");
    sqlx::query(&format!("CREATE SCHEMA {schema}"))
        .execute(&admin_pool)
        .await
        .expect("create isolated schema for SQL integration test");

    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(&url)
        .await
        .expect("connect to integration test DB");
    sqlx::query(&format!("SET search_path TO {schema}"))
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

    sqlx::query(&format!("DROP SCHEMA IF EXISTS {schema} CASCADE"))
        .execute(pool)
        .await
        .ok();
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
