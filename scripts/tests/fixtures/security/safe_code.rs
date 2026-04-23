// Test fixture: safe parameterized SQL pattern.
// This file must NOT trigger the security scanner.

async fn get_user(pool: &PgPool, user_id: &str) -> Result<User, sqlx::Error> {
    sqlx::query_as("SELECT * FROM users WHERE id = $1")
        .bind(user_id)
        .fetch_one(pool)
        .await
}
