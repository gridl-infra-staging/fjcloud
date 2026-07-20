// WARNING: This file contains UNSAFE SQL patterns for testing purposes only
// This file is used to validate the SQL guard detection in Stage 4

// UNSAFE: Using format! to construct query string
let query = sqlx::query(&format!("SELECT * FROM users WHERE id = {}", user_id));

// UNSAFE: Using string concatenation
let query = sqlx::query(&("SELECT * FROM users WHERE name = '" + &username + "'"));

// UNSAFE: Variable interpolation pattern
let query = sqlx::query(&query_string);
