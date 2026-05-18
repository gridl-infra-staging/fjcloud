use chrono::Duration;

pub const LOGIN_THRESHOLD: u32 = 5;
pub const LOGIN_WINDOW: Duration = Duration::minutes(15);
pub const LOGIN_LOCK_DURATION: Duration = Duration::minutes(30);
