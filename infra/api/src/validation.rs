use crate::errors::ApiError;
use reqwest::Url;
use rust_decimal::Decimal;
use std::collections::HashSet;
use std::net::IpAddr;
use std::sync::LazyLock;

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

/// Maximum password byte length to prevent excessive memory allocation (Argon2
/// pre-hashes via Blake2b, but we still bound inputs for consistency and
/// defense-in-depth).
///
/// The minimum counts Unicode code points for customer-facing policy semantics;
/// the maximum remains a byte bound for input-size control. Login deliberately
/// checks only this maximum before verify_password, so existing users below the
/// current minimum can still authenticate.
pub const MAX_PASSWORD_LEN: usize = 128;
pub const MIN_PASSWORD_LEN: usize = 15;

pub fn validate_password_max_bytes(field: &str, password: &str) -> Result<(), ApiError> {
    if password.len() > MAX_PASSWORD_LEN {
        return Err(ApiError::BadRequest(format!(
            "{field} must be at most {MAX_PASSWORD_LEN} bytes"
        )));
    }
    Ok(())
}

/// True when the code points yield at least `MIN_PASSWORD_LEN` items. Stops
/// pulling as soon as the minimum is reached, so the scan is bounded by the
/// policy floor rather than by the caller-supplied length. Takes an iterator
/// (not `&str`) so tests can assert that work bound directly.
fn meets_min_code_points(code_points: impl Iterator<Item = char>) -> bool {
    code_points.take(MIN_PASSWORD_LEN).count() == MIN_PASSWORD_LEN
}

/// Vendored weak-password blocklist, loaded once from the in-tree corpus via
/// `include_str!` — no remote breach API is ever contacted at runtime. Entries
/// are pre-normalized to lowercase during corpus preparation (see the file
/// header); `#` lines are header comments and blank lines are skipped. The
/// loading rule here must mirror that preparation so the asset and the runtime
/// check cannot drift.
static WEAK_PASSWORDS: LazyLock<HashSet<&'static str>> = LazyLock::new(|| {
    include_str!("validation/weak_passwords.txt")
        .lines()
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .collect()
});

/// Canonical count seam for the parsed corpus. Tests assert this against the
/// exact entry count recorded in the `weak_passwords.txt` header so an empty or
/// partially parsed corpus cannot silently disable the weak-password check.
#[cfg(test)]
fn weak_password_count() -> usize {
    WEAK_PASSWORDS.len()
}

/// Single normalization owner for weak-password comparison. Case-insensitive is
/// the minimum requirement; the identical lowercasing drove corpus preparation,
/// so preparing the asset and looking a candidate up here stay in lockstep.
fn is_weak_password(password: &str) -> bool {
    WEAK_PASSWORDS.contains(password.to_lowercase().as_str())
}

pub fn validate_password(password: &str) -> Result<(), ApiError> {
    // Byte cap first: it is O(1) on a `&str`, so an unauthenticated signup or
    // reset caller cannot force a scan proportional to an oversized body.
    validate_password_max_bytes("password", password)?;
    if !meets_min_code_points(password.chars()) {
        return Err(ApiError::BadRequest(format!(
            "password must be at least {MIN_PASSWORD_LEN} characters"
        )));
    }
    // Corpus consulted only after the cheap byte-cap and minimum-length gates
    // pass, so an oversized or too-short input never reaches the hash lookup.
    if is_weak_password(password) {
        return Err(ApiError::BadRequest(
            "password is too common; choose another password".into(),
        ));
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
// Loopback URL hosts
// ---------------------------------------------------------------------------

/// Returns true when a URL has an exact loopback host: `localhost`, any IPv4
/// 127/8 address, or IPv6 loopback. URL parsing owns host extraction so prefix
/// bypasses and credential tricks cannot be mistaken for local addresses.
pub fn is_loopback_url(url: &Url) -> bool {
    match url.host_str() {
        Some("localhost") => true,
        Some(host) => host
            .trim_start_matches('[')
            .trim_end_matches(']')
            .parse::<IpAddr>()
            .is_ok_and(|addr| addr.is_loopback()),
        None => false,
    }
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

    fn assert_bad_request_message(result: Result<(), ApiError>, expected: &str) {
        match result {
            Err(ApiError::BadRequest(message)) => assert_eq!(message, expected),
            other => panic!("expected BadRequest({expected:?}), got {other:?}"),
        }
    }

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
    fn password_rejects_fourteen_code_points() {
        let password = "a".repeat(14);
        assert_bad_request_message(
            validate_password(&password),
            "password must be at least 15 characters",
        );
    }

    #[test]
    fn password_rejects_three_emoji_code_points() {
        let password = "\u{1f512}".repeat(3);
        assert_bad_request_message(
            validate_password(&password),
            "password must be at least 15 characters",
        );
    }

    #[test]
    fn password_accepts_fifteen_code_points_with_spaces_and_non_ascii() {
        assert!(validate_password("abc café 123456").is_ok());
    }

    #[test]
    fn password_too_long() {
        let s = "a".repeat(129);
        assert_bad_request_message(validate_password(&s), "password must be at most 128 bytes");
    }

    #[test]
    fn password_accepts_128_byte_maximum() {
        let s = "\u{1f512}".repeat(32);
        assert_eq!(s.len(), MAX_PASSWORD_LEN);
        assert!(validate_password(&s).is_ok());
    }

    /// Wraps a code-point iterator and records how many items were pulled, so
    /// the minimum check's work bound can be asserted instead of timed.
    struct CountingCodePoints<'a> {
        inner: std::str::Chars<'a>,
        consumed: &'a std::cell::Cell<usize>,
    }

    impl Iterator for CountingCodePoints<'_> {
        type Item = char;

        fn next(&mut self) -> Option<char> {
            let next = self.inner.next();
            if next.is_some() {
                self.consumed.set(self.consumed.get() + 1);
            }
            next
        }
    }

    #[test]
    fn min_code_point_check_stops_at_the_minimum() {
        let password = "a".repeat(100_000);
        let consumed = std::cell::Cell::new(0);
        assert!(meets_min_code_points(CountingCodePoints {
            inner: password.chars(),
            consumed: &consumed,
        }));
        assert_eq!(consumed.get(), MIN_PASSWORD_LEN);
    }

    #[test]
    fn min_code_point_check_consumes_only_a_short_password() {
        let password = "a".repeat(MIN_PASSWORD_LEN - 1);
        let consumed = std::cell::Cell::new(0);
        assert!(!meets_min_code_points(CountingCodePoints {
            inner: password.chars(),
            consumed: &consumed,
        }));
        assert_eq!(consumed.get(), MIN_PASSWORD_LEN - 1);
    }

    #[test]
    fn password_over_byte_cap_is_rejected_without_traversing_the_input() {
        // 1 MiB of attacker-controlled input: `password.len()` is O(1) on a
        // `&str`, so the byte cap must reject this before any code-point scan.
        let password = "a".repeat(1024 * 1024);
        assert_bad_request_message(
            validate_password(&password),
            "password must be at most 128 bytes",
        );
    }

    /// The exact surviving entry count recorded in the `weak_passwords.txt`
    /// header. Asserted directly so a truncated, empty, or partially parsed
    /// corpus cannot let the weak-password check pass vacuously.
    const EXPECTED_WEAK_PASSWORD_COUNT: usize = 10898;

    /// A specimen that is definitely present in the vendored corpus and is at
    /// least 15 code points, so it clears the byte-cap and minimum-length gates
    /// and reaches the weak-password branch.
    const KNOWN_WEAK_SPECIMEN: &str = "passwordpassword";

    #[test]
    fn weak_password_corpus_count_matches_header() {
        assert_eq!(weak_password_count(), EXPECTED_WEAK_PASSWORD_COUNT);
    }

    #[test]
    fn password_rejects_known_common_specimen() {
        assert!(KNOWN_WEAK_SPECIMEN.chars().count() >= MIN_PASSWORD_LEN);
        assert_bad_request_message(
            validate_password(KNOWN_WEAK_SPECIMEN),
            "password is too common; choose another password",
        );
    }

    #[test]
    fn weak_password_match_is_case_insensitive() {
        assert_bad_request_message(
            validate_password(&KNOWN_WEAK_SPECIMEN.to_uppercase()),
            "password is too common; choose another password",
        );
    }

    #[test]
    fn password_rejects_below_minimum_when_byte_length_alone_would_pass() {
        // Four lock emoji: 4 Unicode code points but 16 UTF-8 bytes. A byte-based
        // minimum (`password.len()`) would accept this; only code-point counting
        // rejects it, so this specimen fails if the minimum ever regresses to bytes.
        let password = "\u{1f512}".repeat(4);
        assert_eq!(password.chars().count(), 4);
        assert!(password.len() >= MIN_PASSWORD_LEN);
        assert_bad_request_message(
            validate_password(&password),
            "password must be at least 15 characters",
        );
    }

    // -- is_loopback_url --

    #[test]
    fn loopback_url_accepts_exact_localhost_and_ip_loopback_hosts() {
        for value in [
            "http://localhost:7700",
            "https://localhost:7700/path?q=1",
            "http://127.0.0.1:7700",
            "http://127.0.0.199:7700",
            "http://[::1]:7700",
        ] {
            let url = Url::parse(value).unwrap();
            assert!(is_loopback_url(&url), "{value} should be loopback");
        }
    }

    #[test]
    fn loopback_url_rejects_remote_and_prefix_bypass_hosts() {
        for value in [
            "http://10.0.0.5:7700",
            "https://vm-abc.flapjack.foo:7700",
            "http://192.168.1.1:7700",
            "http://localhost.evil.com:7700",
            "http://127.0.0.1.attacker.com:7700",
        ] {
            let url = Url::parse(value).unwrap();
            assert!(!is_loopback_url(&url), "{value} should not be loopback");
        }
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
