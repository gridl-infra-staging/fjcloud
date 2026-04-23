//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/validation.rs.

use crate::errors::ApiError;
use rust_decimal::Decimal;

// ---------------------------------------------------------------------------
// String length
// ---------------------------------------------------------------------------

/// Validate that a string field is within an acceptable length range.
pub fn validate_length(field: &str, value: &str, max: usize) -> Result<(), ApiError> {
    if value.len() > max {
        return Err(ApiError::BadRequest(format!(
            "{field} must be at most {max} characters"
        )));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Passwords
// ---------------------------------------------------------------------------

/// Maximum password length to prevent excessive memory allocation (Argon2 pre-hashes
/// via Blake2b, but we still bound inputs for consistency and defense-in-depth).
pub const MAX_PASSWORD_LEN: usize = 128;
pub const MIN_PASSWORD_LEN: usize = 8;

pub fn validate_password(password: &str) -> Result<(), ApiError> {
    if password.len() < MIN_PASSWORD_LEN {
        return Err(ApiError::BadRequest(format!(
            "password must be at least {MIN_PASSWORD_LEN} characters"
        )));
    }
    if password.len() > MAX_PASSWORD_LEN {
        return Err(ApiError::BadRequest(format!(
            "password must be at most {MAX_PASSWORD_LEN} characters"
        )));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Names & text fields
// ---------------------------------------------------------------------------

pub const MAX_NAME_LEN: usize = 128;
pub const MAX_EMAIL_LEN: usize = 254; // RFC 5321
pub const MAX_DESCRIPTION_LEN: usize = 1000;
pub const MAX_API_KEY_NAME_LEN: usize = 128;
pub const MAX_SEARCH_QUERY_LEN: usize = 1000;

/// Maximum number of ACL entries in a single create-key request.
pub const MAX_ACL_ENTRIES: usize = 10;

/// Maximum number of scopes in a single create-api-key request.
pub const MAX_SCOPE_ENTRIES: usize = 20;

// ---------------------------------------------------------------------------
// Email (basic format check, reused from auth.rs)
// ---------------------------------------------------------------------------

/// Validates an email address with RFC 5321 length limits and basic structural
/// checks: requires a `local@domain` split, non-empty local part, domain with
/// at least one dot, and rejects leading/trailing dots or dashes and consecutive
/// dots in the domain.
pub fn validate_email(email: &str) -> Result<(), ApiError> {
    if email.len() > MAX_EMAIL_LEN {
        return Err(ApiError::BadRequest(format!(
            "email must be at most {MAX_EMAIL_LEN} characters"
        )));
    }

    let parts: Vec<&str> = email.splitn(2, '@').collect();
    if parts.len() != 2 {
        return Err(ApiError::BadRequest("invalid email format".into()));
    }
    let local = parts[0];
    let domain = parts[1];
    if local.is_empty() || domain.len() < 3 {
        return Err(ApiError::BadRequest("invalid email format".into()));
    }
    if !domain.contains('.')
        || domain.starts_with('.')
        || domain.ends_with('.')
        || domain.starts_with('-')
        || domain.ends_with('-')
        || domain.contains("..")
    {
        return Err(ApiError::BadRequest("invalid email format".into()));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Path segments (proxy URL construction safety)
// ---------------------------------------------------------------------------

/// Maximum length for path segments used in proxy URL construction.
pub const MAX_PATH_SEGMENT_LEN: usize = 256;

/// Validate that a value is safe to interpolate as a single URL path segment.
/// Rejects path traversal (`/`, `..`), query/fragment injection (`?`, `#`),
/// backslash, null bytes, control characters, and percent-encoded delimiters.
/// Used for object_id, experiment id, and any other user-supplied values that
/// become part of a proxy URL path.
pub fn validate_path_segment(field: &str, value: &str) -> Result<(), ApiError> {
    if value.is_empty() {
        return Err(ApiError::BadRequest(format!("{field} must not be empty")));
    }
    if value.len() > MAX_PATH_SEGMENT_LEN {
        return Err(ApiError::BadRequest(format!(
            "{field} must be at most {MAX_PATH_SEGMENT_LEN} characters"
        )));
    }
    if value == "." || value == ".." {
        return Err(ApiError::BadRequest(format!(
            "{field} contains invalid path traversal"
        )));
    }
    for ch in value.chars() {
        if ch == '/'
            || ch == '\\'
            || ch == '?'
            || ch == '#'
            || ch == '%'
            || ch == '\0'
            || ch.is_control()
        {
            return Err(ApiError::BadRequest(format!(
                "{field} contains invalid characters"
            )));
        }
    }
    Ok(())
}

/// Validate that a value is safe to percent-encode before interpolation into a
/// single upstream URL path segment.
///
/// Unlike `validate_path_segment`, this allows reserved characters such as `/`
/// because callers re-encode the full value before constructing the proxy URL.
/// It still rejects empty values, traversal segments, null bytes, and control
/// characters.
pub fn validate_path_value_for_encoding(field: &str, value: &str) -> Result<(), ApiError> {
    if value.is_empty() {
        return Err(ApiError::BadRequest(format!("{field} must not be empty")));
    }
    if value.len() > MAX_PATH_SEGMENT_LEN {
        return Err(ApiError::BadRequest(format!(
            "{field} must be at most {MAX_PATH_SEGMENT_LEN} characters"
        )));
    }
    if value == "." || value == ".." {
        return Err(ApiError::BadRequest(format!(
            "{field} contains invalid path traversal"
        )));
    }
    if value.chars().any(|ch| ch == '\0' || ch.is_control()) {
        return Err(ApiError::BadRequest(format!(
            "{field} contains invalid characters"
        )));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Decimal bounds (rate card fields)
// ---------------------------------------------------------------------------

pub fn validate_non_negative_decimal(field: &str, value: &str) -> Result<Decimal, ApiError> {
    let dec: Decimal = value
        .parse()
        .map_err(|_| ApiError::BadRequest(format!("invalid decimal: {field}")))?;
    if dec < Decimal::ZERO {
        return Err(ApiError::BadRequest(format!(
            "{field} must not be negative"
        )));
    }
    Ok(dec)
}

#[cfg(test)]
mod tests {
    use super::*;

    // -- validate_length --

    #[test]
    fn length_within_limit_is_ok() {
        assert!(validate_length("name", "alice", MAX_NAME_LEN).is_ok());
    }

    #[test]
    fn length_at_limit_is_ok() {
        let s = "a".repeat(MAX_NAME_LEN);
        assert!(validate_length("name", &s, MAX_NAME_LEN).is_ok());
    }

    #[test]
    fn length_over_limit_is_err() {
        let s = "a".repeat(MAX_NAME_LEN + 1);
        assert!(validate_length("name", &s, MAX_NAME_LEN).is_err());
    }

    // -- validate_password --

    #[test]
    fn password_too_short() {
        assert!(validate_password("short").is_err());
    }

    #[test]
    fn password_too_long() {
        let s = "a".repeat(129);
        assert!(validate_password(&s).is_err());
    }

    #[test]
    fn password_at_min() {
        assert!(validate_password("12345678").is_ok());
    }

    #[test]
    fn password_at_max() {
        let s = "a".repeat(128);
        assert!(validate_password(&s).is_ok());
    }

    // -- validate_email --

    #[test]
    fn email_valid() {
        assert!(validate_email("alice@example.com").is_ok());
    }

    #[test]
    fn email_too_long() {
        let long = format!("{}@example.com", "a".repeat(250));
        assert!(validate_email(&long).is_err());
    }

    #[test]
    fn email_no_at() {
        assert!(validate_email("noatsign").is_err());
    }

    #[test]
    fn email_no_domain_dot() {
        assert!(validate_email("user@localhost").is_err());
    }

    // -- validate_non_negative_decimal --

    #[test]
    fn decimal_valid_positive() {
        assert!(validate_non_negative_decimal("rate", "1.50").is_ok());
    }

    #[test]
    fn decimal_zero_is_ok() {
        assert!(validate_non_negative_decimal("rate", "0").is_ok());
    }

    #[test]
    fn decimal_negative_is_err() {
        assert!(validate_non_negative_decimal("rate", "-0.01").is_err());
    }

    #[test]
    fn decimal_invalid_string() {
        assert!(validate_non_negative_decimal("rate", "not_a_number").is_err());
    }

    // -- validate_path_segment --

    #[test]
    fn path_segment_valid_alphanumeric() {
        assert!(validate_path_segment("id", "rule-123_abc").is_ok());
    }

    #[test]
    fn path_segment_empty_is_err() {
        assert!(validate_path_segment("id", "").is_err());
    }

    #[test]
    fn path_segment_slash_rejected() {
        assert!(validate_path_segment("id", "../../admin").is_err());
    }

    #[test]
    fn path_segment_single_slash_rejected() {
        assert!(validate_path_segment("id", "a/b").is_err());
    }

    #[test]
    fn path_segment_question_mark_rejected() {
        assert!(validate_path_segment("id", "foo?evil=true").is_err());
    }

    #[test]
    fn path_segment_hash_rejected() {
        assert!(validate_path_segment("id", "foo#fragment").is_err());
    }

    #[test]
    fn path_segment_backslash_rejected() {
        assert!(validate_path_segment("id", "foo\\bar").is_err());
    }

    #[test]
    fn path_segment_null_byte_rejected() {
        assert!(validate_path_segment("id", "foo\0bar").is_err());
    }

    #[test]
    fn path_segment_dotdot_rejected() {
        assert!(validate_path_segment("id", "..").is_err());
    }

    #[test]
    fn path_segment_single_dot_rejected() {
        assert!(validate_path_segment("id", ".").is_err());
    }

    #[test]
    fn path_segment_too_long() {
        let long = "a".repeat(MAX_PATH_SEGMENT_LEN + 1);
        assert!(validate_path_segment("id", &long).is_err());
    }

    #[test]
    fn path_segment_at_max_len_is_ok() {
        let s = "a".repeat(MAX_PATH_SEGMENT_LEN);
        assert!(validate_path_segment("id", &s).is_ok());
    }

    #[test]
    fn path_segment_with_dots_in_middle_is_ok() {
        assert!(validate_path_segment("id", "rule.v2.test").is_ok());
    }

    #[test]
    fn path_segment_control_char_rejected() {
        assert!(validate_path_segment("id", "foo\nbar").is_err());
    }

    #[test]
    fn path_segment_percent_encoded_reserved_chars_rejected() {
        assert!(validate_path_segment("id", "foo%2Fbar").is_err());
        assert!(validate_path_segment("id", "%2e%2e").is_err());
    }

    #[test]
    fn path_value_for_encoding_allows_reserved_chars() {
        assert!(validate_path_value_for_encoding("user_token", "user token/1?foo#bar%2F").is_ok());
    }

    #[test]
    fn path_value_for_encoding_rejects_traversal_segments() {
        assert!(validate_path_value_for_encoding("user_token", ".").is_err());
        assert!(validate_path_value_for_encoding("user_token", "..").is_err());
    }

    #[test]
    fn path_value_for_encoding_rejects_control_chars() {
        assert!(validate_path_value_for_encoding("user_token", "foo\nbar").is_err());
        assert!(validate_path_value_for_encoding("user_token", "foo\0bar").is_err());
    }
}
