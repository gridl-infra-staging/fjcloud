#![allow(dead_code)]

use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use uuid::Uuid;

pub struct DbHarness {
    pub pool: PgPool,
    pub schema: String,
}

impl Drop for DbHarness {
    fn drop(&mut self) {
        let schema = self.schema.clone();
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
    let Ok(url) = std::env::var("DATABASE_URL") else {
        println!("SKIP: DATABASE_URL not set — skipping {schema_prefix} SQL integration tests");
        return None;
    };

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

    sqlx::migrate!("../migrations")
        .run(&pool)
        .await
        .expect("run migrations");

    Some(DbHarness { pool, schema })
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
