use aes_gcm::aead::{Aead, OsRng};
use aes_gcm::{AeadCore, Aes256Gcm, KeyInit, Nonce};
use rand::Rng;

/// Encrypt a plaintext secret using AES-256-GCM.
/// Returns (ciphertext, nonce). The nonce is 12 bytes.
pub fn encrypt_secret(
    plaintext: &str,
    master_key: &[u8; 32],
) -> Result<(Vec<u8>, Vec<u8>), String> {
    let cipher = Aes256Gcm::new(master_key.into());
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);

    let ciphertext = cipher
        .encrypt(&nonce, plaintext.as_bytes())
        .map_err(|e| format!("encryption failed: {e}"))?;

    Ok((ciphertext, nonce.to_vec()))
}

/// Decrypt a ciphertext using AES-256-GCM.
pub fn decrypt_secret(
    ciphertext: &[u8],
    nonce_bytes: &[u8],
    master_key: &[u8; 32],
) -> Result<String, String> {
    if nonce_bytes.len() != 12 {
        return Err(format!(
            "invalid AES-GCM nonce length: expected 12 bytes, got {}",
            nonce_bytes.len()
        ));
    }

    let cipher = Aes256Gcm::new(master_key.into());
    let nonce = Nonce::from_slice(nonce_bytes);

    let plaintext = cipher
        .decrypt(nonce, ciphertext)
        .map_err(|e| format!("decryption failed: {e}"))?;

    String::from_utf8(plaintext).map_err(|e| format!("decrypted data is not valid UTF-8: {e}"))
}

const ACCESS_KEY_PREFIX: &str = "gridl_s3_";
const ACCESS_KEY_RANDOM_LEN: usize = 20;
const SECRET_KEY_LEN: usize = 40;
const MASTER_KEY_LEN: usize = 32;

pub fn parse_master_key_hex(hex_key: &str) -> Result<[u8; MASTER_KEY_LEN], String> {
    let bytes = hex::decode(hex_key).map_err(|e| format!("invalid hex master key: {e}"))?;
    if bytes.len() != MASTER_KEY_LEN {
        return Err(format!(
            "invalid storage master key length: expected {} bytes, got {}",
            MASTER_KEY_LEN,
            bytes.len()
        ));
    }

    let mut key = [0u8; MASTER_KEY_LEN];
    key.copy_from_slice(&bytes);
    Ok(key)
}

/// Generate an access key in the format `gridl_s3_{20 alphanumeric chars}`.
pub fn generate_access_key() -> String {
    let random_part: String = rand::thread_rng()
        .sample_iter(&rand::distributions::Alphanumeric)
        .take(ACCESS_KEY_RANDOM_LEN)
        .map(char::from)
        .collect();
    format!("{ACCESS_KEY_PREFIX}{random_part}")
}

/// Return a deterministic 32-byte master key for local dev mode.
/// Derived via SHA-256 from a fixed domain-separation string so it is
/// stable across restarts but can never be confused with a real secret.
/// Only used when NODE_SECRET_BACKEND=memory and STORAGE_ENCRYPTION_KEY is absent.
pub fn deterministic_dev_master_key() -> [u8; 32] {
    use sha2::{Digest, Sha256};
    let hash = Sha256::digest(b"fjcloud-local-dev-storage-master-key-v1");
    let mut key = [0u8; 32];
    key.copy_from_slice(&hash);
    key
}

/// Generate a 40-character random alphanumeric secret key.
pub fn generate_secret_key() -> String {
    rand::thread_rng()
        .sample_iter(&rand::distributions::Alphanumeric)
        .take(SECRET_KEY_LEN)
        .map(char::from)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_key() -> [u8; 32] {
        [0x42; 32]
    }

    #[test]
    fn encrypt_decrypt_round_trip() {
        let key = test_key();
        let plaintext = "my-secret-value-12345";

        let (ciphertext, nonce) = encrypt_secret(plaintext, &key).unwrap();
        assert_ne!(ciphertext, plaintext.as_bytes());
        assert_eq!(nonce.len(), 12);

        let decrypted = decrypt_secret(&ciphertext, &nonce, &key).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn wrong_key_fails_decryption() {
        let key = test_key();
        let (ciphertext, nonce) = encrypt_secret("secret", &key).unwrap();

        let wrong_key = [0xFF; 32];
        let result = decrypt_secret(&ciphertext, &nonce, &wrong_key);
        assert!(result.is_err());
    }

    #[test]
    fn generate_access_key_format() {
        let ak = generate_access_key();
        assert!(ak.starts_with("gridl_s3_"));
        assert_eq!(ak.len(), 9 + ACCESS_KEY_RANDOM_LEN); // "gridl_s3_" = 9 chars
        assert!(ak[9..].chars().all(|c| c.is_alphanumeric()));
    }

    #[test]
    fn generate_secret_key_format() {
        let sk = generate_secret_key();
        assert_eq!(sk.len(), SECRET_KEY_LEN);
        assert!(sk.chars().all(|c| c.is_alphanumeric()));
    }

    #[test]
    fn generated_keys_are_unique() {
        let ak1 = generate_access_key();
        let ak2 = generate_access_key();
        assert_ne!(ak1, ak2);

        let sk1 = generate_secret_key();
        let sk2 = generate_secret_key();
        assert_ne!(sk1, sk2);
    }

    #[test]
    fn invalid_nonce_length_returns_error() {
        let key = test_key();
        let (ciphertext, _) = encrypt_secret("secret", &key).unwrap();

        let result = decrypt_secret(&ciphertext, &[0xAA; 8], &key);
        assert!(result.is_err());
    }

    #[test]
    fn parse_master_key_hex_validates_input() {
        let valid = "42".repeat(32);
        assert_eq!(parse_master_key_hex(&valid).unwrap(), [0x42; 32]);
        assert!(parse_master_key_hex("abcd").is_err());
        assert!(parse_master_key_hex(&"zz".repeat(32)).is_err());
    }

    #[test]
    fn deterministic_dev_master_key_is_32_bytes() {
        let key = deterministic_dev_master_key();
        assert_eq!(key.len(), 32);
    }

    #[test]
    fn deterministic_dev_master_key_is_stable_across_calls() {
        let k1 = deterministic_dev_master_key();
        let k2 = deterministic_dev_master_key();
        assert_eq!(k1, k2, "dev key must be deterministic across calls");
    }

    #[test]
    fn deterministic_dev_master_key_is_not_all_zeros() {
        let key = deterministic_dev_master_key();
        assert_ne!(key, [0u8; 32], "dev key must not be the all-zeros key");
    }

    #[test]
    fn deterministic_dev_master_key_encrypt_decrypt_round_trip() {
        let key = deterministic_dev_master_key();
        let plaintext = "dev-mode-secret-value";

        let (ciphertext, nonce) = encrypt_secret(plaintext, &key).unwrap();
        let decrypted = decrypt_secret(&ciphertext, &nonce, &key).unwrap();
        assert_eq!(decrypted, plaintext);
    }
}
