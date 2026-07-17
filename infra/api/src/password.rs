use crate::errors::ApiError;

pub fn hash_password(password: &str) -> Result<String, ApiError> {
    use argon2::{
        password_hash::{rand_core::OsRng, SaltString},
        Argon2, PasswordHasher,
    };
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| ApiError::Internal(format!("password hashing failed: {e}")))
}

pub fn verify_password(password: &str, hash: &str) -> bool {
    use argon2::{Argon2, PasswordHash, PasswordVerifier};
    let parsed = match PasswordHash::new(hash) {
        Ok(h) => h,
        Err(_) => return false,
    };
    Argon2::default()
        .verify_password(password.as_bytes(), &parsed)
        .is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_then_verify_correct_password() {
        let hash = hash_password("hunter2").unwrap();
        assert!(verify_password("hunter2", &hash));
    }

    #[test]
    fn verify_rejects_wrong_password() {
        let hash = hash_password("correct-password").unwrap();
        assert!(!verify_password("wrong-password", &hash));
    }

    #[test]
    fn hash_produces_argon2_format() {
        let hash = hash_password("test").unwrap();
        assert!(
            hash.starts_with("$argon2"),
            "expected argon2 prefix, got: {hash}"
        );
    }

    #[test]
    fn different_calls_produce_different_hashes() {
        let h1 = hash_password("same").unwrap();
        let h2 = hash_password("same").unwrap();
        assert_ne!(h1, h2, "salts should differ");
        assert!(verify_password("same", &h1));
        assert!(verify_password("same", &h2));
    }

    #[test]
    fn verify_returns_false_for_invalid_hash_string() {
        assert!(!verify_password("anything", "not-a-valid-hash"));
    }

    #[test]
    fn verify_returns_false_for_empty_hash() {
        assert!(!verify_password("anything", ""));
    }

    #[test]
    fn hash_empty_password_succeeds() {
        let hash = hash_password("").unwrap();
        assert!(verify_password("", &hash));
        assert!(!verify_password("notempty", &hash));
    }
}
