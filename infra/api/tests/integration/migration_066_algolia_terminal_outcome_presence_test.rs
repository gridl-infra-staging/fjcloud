use chrono::Utc;

use crate::common::support::pg_schema_harness::connect_without_migrations;

#[tokio::test]
async fn migration_066_backfills_erased_rows_before_enforcing_shape() {
    let Some(db) = connect_without_migrations("migration_066_terminal_outcome").await else {
        return;
    };

    sqlx::query(
        "CREATE TABLE algolia_import_jobs (
            id BIGSERIAL PRIMARY KEY,
            erased_at TIMESTAMPTZ
        )",
    )
    .execute(&db.pool)
    .await
    .expect("create pre-migration algolia import job shape");
    sqlx::query("INSERT INTO algolia_import_jobs (erased_at) VALUES (NULL), ($1)")
        .bind(Utc::now())
        .execute(&db.pool)
        .await
        .expect("seed active and erased legacy rows");

    sqlx::raw_sql(include_str!(
        "../../../migrations/066_algolia_import_terminal_outcome_presence.sql"
    ))
    .execute(&db.pool)
    .await
    .expect("migration 066 must upgrade a table containing erased rows");

    let rows: Vec<(bool, Option<bool>)> = sqlx::query_as(
        "SELECT erased_at IS NOT NULL, terminal_outcome_observed
         FROM algolia_import_jobs
         ORDER BY erased_at NULLS FIRST",
    )
    .fetch_all(&db.pool)
    .await
    .expect("read migrated presence facts");
    assert_eq!(rows, vec![(false, Some(false)), (true, None)]);
}
