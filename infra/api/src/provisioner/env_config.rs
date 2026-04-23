//! Shared environment-variable parsing helpers for provisioner configuration.
//!
//! Every provisioner (OCI, GCP, Hetzner) needs to read typed values from env
//! vars with consistent trimming, empty-value rejection, and error messages.
//! This module is the single source of truth for that logic.

/// Read a required environment variable, trimming whitespace.
/// Returns an error if the variable is unset or empty after trimming.
pub(crate) fn required_env(key: &str) -> Result<String, String> {
    let value = std::env::var(key).map_err(|_| format!("{key} not set"))?;
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(format!("{key} is empty"));
    }
    Ok(trimmed.to_string())
}

/// Read an optional environment variable, trimming whitespace.
/// Returns `None` if the variable is unset or empty after trimming.
pub(crate) fn optional_env(key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

/// Parse a `u32` from an environment variable, falling back to `default`
/// if the variable is unset. Returns an error if the value is not a valid
/// positive integer or is zero.
pub(crate) fn parse_u32_env(key: &str, default: u32) -> Result<u32, String> {
    match std::env::var(key) {
        Ok(raw) => {
            let parsed = raw
                .trim()
                .parse::<u32>()
                .map_err(|_| format!("{key} must be a positive integer, got '{raw}'"))?;
            if parsed == 0 {
                return Err(format!("{key} must be >= 1"));
            }
            Ok(parsed)
        }
        Err(_) => Ok(default),
    }
}

/// Parse a `u64` from an environment variable, falling back to `default`
/// if the variable is unset. Returns an error if the value is not a valid
/// positive integer or is zero.
pub(crate) fn parse_u64_env(key: &str, default: u64) -> Result<u64, String> {
    match std::env::var(key) {
        Ok(raw) => {
            let parsed = raw
                .trim()
                .parse::<u64>()
                .map_err(|_| format!("{key} must be a positive integer, got '{raw}'"))?;
            if parsed == 0 {
                return Err(format!("{key} must be >= 1"));
            }
            Ok(parsed)
        }
        Err(_) => Ok(default),
    }
}

/// Parse an `f32` from an environment variable, falling back to `default`
/// if the variable is unset. Returns an error if the value is not a valid
/// positive number or is zero/negative.
pub(crate) fn parse_f32_env(key: &str, default: f32) -> Result<f32, String> {
    match std::env::var(key) {
        Ok(raw) => {
            let parsed = raw
                .trim()
                .parse::<f32>()
                .map_err(|_| format!("{key} must be a positive number, got '{raw}'"))?;
            if parsed <= 0.0 {
                return Err(format!("{key} must be > 0"));
            }
            Ok(parsed)
        }
        Err(_) => Ok(default),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// Env-var tests must be serialized because `std::env::set_var` is process-global.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn with_env<F: FnOnce()>(vars: &[(&str, &str)], f: F) {
        let _guard = ENV_LOCK.lock().unwrap();
        let keys: Vec<&str> = vars.iter().map(|(k, _)| *k).collect();
        for (k, v) in vars {
            unsafe { std::env::set_var(k, v) };
        }
        f();
        for k in keys {
            unsafe { std::env::remove_var(k) };
        }
    }

    fn without_env<F: FnOnce()>(keys: &[&str], f: F) {
        let _guard = ENV_LOCK.lock().unwrap();
        for k in keys {
            unsafe { std::env::remove_var(k) };
        }
        f();
    }

    // --- required_env ---

    #[test]
    fn required_env_returns_trimmed_value() {
        with_env(&[("TEST_REQ_1", "  hello  ")], || {
            assert_eq!(required_env("TEST_REQ_1").unwrap(), "hello");
        });
    }

    #[test]
    fn required_env_errors_when_unset() {
        without_env(&["TEST_REQ_MISSING"], || {
            let err = required_env("TEST_REQ_MISSING").unwrap_err();
            assert_eq!(err, "TEST_REQ_MISSING not set");
        });
    }

    #[test]
    fn required_env_errors_when_empty() {
        with_env(&[("TEST_REQ_EMPTY", "   ")], || {
            let err = required_env("TEST_REQ_EMPTY").unwrap_err();
            assert_eq!(err, "TEST_REQ_EMPTY is empty");
        });
    }

    // --- optional_env ---

    #[test]
    fn optional_env_returns_trimmed_value() {
        with_env(&[("TEST_OPT_1", "  value  ")], || {
            assert_eq!(optional_env("TEST_OPT_1"), Some("value".to_string()));
        });
    }

    #[test]
    fn optional_env_returns_none_when_unset() {
        without_env(&["TEST_OPT_MISSING"], || {
            assert_eq!(optional_env("TEST_OPT_MISSING"), None);
        });
    }

    #[test]
    fn optional_env_returns_none_when_empty() {
        with_env(&[("TEST_OPT_EMPTY", "  ")], || {
            assert_eq!(optional_env("TEST_OPT_EMPTY"), None);
        });
    }

    // --- parse_u32_env ---

    #[test]
    fn parse_u32_env_parses_valid_value() {
        with_env(&[("TEST_U32", "  42  ")], || {
            assert_eq!(parse_u32_env("TEST_U32", 10).unwrap(), 42);
        });
    }

    #[test]
    fn parse_u32_env_uses_default_when_unset() {
        without_env(&["TEST_U32_DEF"], || {
            assert_eq!(parse_u32_env("TEST_U32_DEF", 10).unwrap(), 10);
        });
    }

    #[test]
    fn parse_u32_env_rejects_zero() {
        with_env(&[("TEST_U32_ZERO", "0")], || {
            let err = parse_u32_env("TEST_U32_ZERO", 10).unwrap_err();
            assert_eq!(err, "TEST_U32_ZERO must be >= 1");
        });
    }

    #[test]
    fn parse_u32_env_rejects_non_numeric() {
        with_env(&[("TEST_U32_BAD", "abc")], || {
            let err = parse_u32_env("TEST_U32_BAD", 10).unwrap_err();
            assert_eq!(err, "TEST_U32_BAD must be a positive integer, got 'abc'");
        });
    }

    // --- parse_u64_env ---

    #[test]
    fn parse_u64_env_parses_valid_value() {
        with_env(&[("TEST_U64", "  2000  ")], || {
            assert_eq!(parse_u64_env("TEST_U64", 100).unwrap(), 2000);
        });
    }

    #[test]
    fn parse_u64_env_uses_default_when_unset() {
        without_env(&["TEST_U64_DEF"], || {
            assert_eq!(parse_u64_env("TEST_U64_DEF", 100).unwrap(), 100);
        });
    }

    #[test]
    fn parse_u64_env_rejects_zero() {
        with_env(&[("TEST_U64_ZERO", "0")], || {
            let err = parse_u64_env("TEST_U64_ZERO", 100).unwrap_err();
            assert_eq!(err, "TEST_U64_ZERO must be >= 1");
        });
    }

    #[test]
    fn parse_u64_env_rejects_non_numeric() {
        with_env(&[("TEST_U64_BAD", "xyz")], || {
            let err = parse_u64_env("TEST_U64_BAD", 100).unwrap_err();
            assert_eq!(err, "TEST_U64_BAD must be a positive integer, got 'xyz'");
        });
    }

    // --- parse_f32_env ---

    #[test]
    fn parse_f32_env_parses_valid_value() {
        with_env(&[("TEST_F32", "  3.5  ")], || {
            let val = parse_f32_env("TEST_F32", 1.0).unwrap();
            assert!((val - 3.5).abs() < f32::EPSILON);
        });
    }

    #[test]
    fn parse_f32_env_uses_default_when_unset() {
        without_env(&["TEST_F32_DEF"], || {
            let val = parse_f32_env("TEST_F32_DEF", 1.0).unwrap();
            assert!((val - 1.0).abs() < f32::EPSILON);
        });
    }

    #[test]
    fn parse_f32_env_rejects_zero() {
        with_env(&[("TEST_F32_ZERO", "0.0")], || {
            let err = parse_f32_env("TEST_F32_ZERO", 1.0).unwrap_err();
            assert_eq!(err, "TEST_F32_ZERO must be > 0");
        });
    }

    #[test]
    fn parse_f32_env_rejects_negative() {
        with_env(&[("TEST_F32_NEG", "-1.0")], || {
            let err = parse_f32_env("TEST_F32_NEG", 1.0).unwrap_err();
            assert_eq!(err, "TEST_F32_NEG must be > 0");
        });
    }

    #[test]
    fn parse_f32_env_rejects_non_numeric() {
        with_env(&[("TEST_F32_BAD", "nope")], || {
            let err = parse_f32_env("TEST_F32_BAD", 1.0).unwrap_err();
            assert_eq!(err, "TEST_F32_BAD must be a positive number, got 'nope'");
        });
    }
}
