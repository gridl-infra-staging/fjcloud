// Test fixture: intentionally insecure Command::new pattern.
// This file exists solely to validate the security scanner catches it.

use std::process::Command;

fn run_user_command(user_input: &str) {
    let output = Command::new(user_input)
        .output()
        .expect("failed to execute");
}
