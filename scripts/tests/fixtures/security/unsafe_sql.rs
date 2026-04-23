// Test fixture: intentionally insecure SQL interpolation pattern.
// This file exists solely to validate the security scanner catches it.

fn get_user(user_id: &str) -> String {
    let query = format!("SELECT * FROM users WHERE id = {}", user_id);
    query
}
