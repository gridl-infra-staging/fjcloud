/// Returns the crate version from Cargo.toml at compile time.
pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// Check args for `--version` or `-V`. Returns `true` if version was printed
/// (caller should exit).
pub fn check_version_flag() -> bool {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("metering-agent {}", version());
        return true;
    }
    false
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_not_empty() {
        let v = version();
        assert!(!v.is_empty());
    }

    #[test]
    fn version_matches_cargo_toml() {
        // The version should be "0.1.0" as defined in Cargo.toml
        assert_eq!(version(), "0.1.0");
    }
}
