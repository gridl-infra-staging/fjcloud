//! Auth vocabulary for the Flapjack Cloud platform.
//!
//! **Management scopes** govern what a customer's API key can do on the Flapjack Cloud
//! management API. **Flapjack ACLs** ([`VALID_ACLS`]) govern what a flapjack
//! search key can do on a VM. The two vocabularies are orthogonal.

use crate::errors::ApiError;

pub const INDEXES_READ: &str = "indexes:read";
pub const INDEXES_WRITE: &str = "indexes:write";
pub const KEYS_MANAGE: &str = "keys:manage";
pub const BILLING_READ: &str = "billing:read";
pub const SEARCH: &str = "search";

/// All valid management scopes. Used for creation-time validation.
pub const ALL_SCOPES: &[&str] = &[
    INDEXES_READ,
    INDEXES_WRITE,
    KEYS_MANAGE,
    BILLING_READ,
    SEARCH,
];

// ---------------------------------------------------------------------------
// Flapjack ACLs (orthogonal to management scopes above)
// ---------------------------------------------------------------------------

/// Valid flapjack search-key ACLs. Used by index key creation (validation) and
/// onboarding credential generation (defaults).
pub const VALID_ACLS: &[&str] = &["search", "browse", "addObject"];

// ---------------------------------------------------------------------------
// Management scope validation
// ---------------------------------------------------------------------------

/// Validate that all provided scopes are in the vocabulary.
/// Existing keys with non-vocabulary scopes are tolerated at auth time (soft
/// validation), but new keys must use the canonical vocabulary.
pub fn validate_scopes(scopes: &[String]) -> Result<(), ApiError> {
    for scope in scopes {
        if !ALL_SCOPES.contains(&scope.as_str()) {
            return Err(ApiError::BadRequest(format!(
                "invalid scope '{}': must be one of {:?}",
                scope, ALL_SCOPES
            )));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_all_canonical_scopes_pass() {
        let scopes: Vec<String> = ALL_SCOPES.iter().map(|s| s.to_string()).collect();
        assert!(validate_scopes(&scopes).is_ok());
    }

    #[test]
    fn validate_single_valid_scope() {
        assert!(validate_scopes(&["search".to_string()]).is_ok());
        assert!(validate_scopes(&["indexes:read".to_string()]).is_ok());
        assert!(validate_scopes(&["indexes:write".to_string()]).is_ok());
        assert!(validate_scopes(&["keys:manage".to_string()]).is_ok());
        assert!(validate_scopes(&["billing:read".to_string()]).is_ok());
    }

    #[test]
    fn validate_empty_list_passes() {
        assert!(validate_scopes(&[]).is_ok());
    }

    #[test]
    fn validate_rejects_unknown_scope() {
        let err = validate_scopes(&["admin".to_string()]).unwrap_err();
        match err {
            ApiError::BadRequest(msg) => {
                assert!(msg.contains("invalid scope 'admin'"), "got: {msg}")
            }
            other => panic!("expected BadRequest, got: {other:?}"),
        }
    }

    #[test]
    fn validate_rejects_legacy_read_scope() {
        let err = validate_scopes(&["read".to_string()]).unwrap_err();
        match err {
            ApiError::BadRequest(msg) => {
                assert!(msg.contains("invalid scope 'read'"), "got: {msg}")
            }
            other => panic!("expected BadRequest, got: {other:?}"),
        }
    }

    #[test]
    fn validate_rejects_mix_of_valid_and_invalid() {
        let scopes = vec!["search".to_string(), "bogus".to_string()];
        let err = validate_scopes(&scopes).unwrap_err();
        match err {
            ApiError::BadRequest(msg) => assert!(msg.contains("bogus"), "got: {msg}"),
            other => panic!("expected BadRequest, got: {other:?}"),
        }
    }

    #[test]
    fn all_scopes_constant_has_five_entries() {
        assert_eq!(ALL_SCOPES.len(), 5);
    }

    #[test]
    fn scope_constants_match_all_scopes_array() {
        assert!(ALL_SCOPES.contains(&INDEXES_READ));
        assert!(ALL_SCOPES.contains(&INDEXES_WRITE));
        assert!(ALL_SCOPES.contains(&KEYS_MANAGE));
        assert!(ALL_SCOPES.contains(&BILLING_READ));
        assert!(ALL_SCOPES.contains(&SEARCH));
    }

    #[test]
    fn valid_acls_contains_expected_flapjack_acls() {
        assert_eq!(VALID_ACLS.len(), 3);
        assert!(VALID_ACLS.contains(&"search"));
        assert!(VALID_ACLS.contains(&"browse"));
        assert!(VALID_ACLS.contains(&"addObject"));
    }
}
