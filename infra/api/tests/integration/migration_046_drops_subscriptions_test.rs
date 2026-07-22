//! Schema-contract test for migration `046_drop_subscriptions`.
//!
//! Stage 2 of the subscription-gutting wave drops the deprecated
//! `subscriptions` table at the schema boundary while metered-billing
//! paths continue to live on `customers.billing_plan`. This test
//! pins the contract: after the full migration chain runs against a
//! real Postgres, `subscriptions` must be absent from the migrated schema.
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
use crate::common::support::pg_schema_harness;

async fn connect_and_migrate() -> Option<pg_schema_harness::DbHarness> {
    pg_schema_harness::connect_and_migrate("migration_046_subscriptions").await
}

#[tokio::test]
async fn subscriptions_table_is_absent_after_migrations() {
    let Some(db) = connect_and_migrate().await else {
        return;
    };

    let exists: bool = sqlx::query_scalar(
        "SELECT EXISTS (
            SELECT 1
            FROM information_schema.tables
            WHERE table_schema = current_schema()
              AND table_name = 'subscriptions'
        )",
    )
    .fetch_one(&db.pool)
    .await
    .expect("query subscriptions table existence");

    assert!(
        !exists,
        "subscriptions table must be absent after migrations \
         (information_schema reported exists={exists}); migration 046 \
         (drop_subscriptions) is the schema owner for this contract"
    );
}
