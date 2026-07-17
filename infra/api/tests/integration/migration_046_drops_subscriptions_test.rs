//! Schema-contract test for migration `046_drop_subscriptions`.
//!
//! Stage 2 of the subscription-gutting wave drops the deprecated
//! `subscriptions` table at the schema boundary while metered-billing
//! paths continue to live on `customers.billing_plan`. This test
//! pins the contract: after the full migration chain runs against a
//! real Postgres, `to_regclass('public.subscriptions')` must be NULL.
//!
//! ## Running
//!
//!   DATABASE_URL=postgres://user:pass@localhost/flapjack_test \
//!     cargo test -p api --test migration_046_drops_subscriptions_test
//!
//! Without `DATABASE_URL` the test exits early with a SKIP line —
//! same contract as `pg_customer_repo_test.rs` and
//! `admin_token_audit_test.rs`.
//!
//! ## Why this test exists
//!
//! Migration ordering bugs are silent: an accidental revert of `046`
//! or a later migration that recreates `subscriptions` would not be
//! caught by compile-time SQL checks (the runtime queries are all
//! string literals). This test asserts the post-migration schema
//! state directly so any regression flips it red.
use sqlx::PgPool;

async fn connect_and_migrate() -> Option<PgPool> {
    let Ok(url) = std::env::var("DATABASE_URL") else {
        println!(
            "SKIP: DATABASE_URL not set — skipping migration_046_drops_subscriptions schema test"
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
async fn subscriptions_table_is_absent_after_migrations() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    // `to_regclass` returns NULL when the relation does not exist,
    // and the qualified OID otherwise. We assert NULL — anything else
    // means migration 046 (or its successor) has stopped dropping
    // `subscriptions`.
    let regclass: Option<String> =
        sqlx::query_scalar("SELECT to_regclass('public.subscriptions')::text")
            .fetch_one(&pool)
            .await
            .expect("query to_regclass for subscriptions");

    assert!(
        regclass.is_none(),
        "subscriptions table must be absent after migrations \
         (to_regclass returned {regclass:?}); migration 046 \
         (drop_subscriptions) is the schema owner for this contract"
    );
}
