//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/storage/s3_auth.rs.

use std::fmt::Write as _;
use std::sync::Arc;

use chrono::{DateTime, NaiveDateTime, Utc};
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use uuid::Uuid;

use crate::models::customer::{customer_auth_state, CustomerAuthState};
use crate::repos::customer_repo::CustomerRepo;
use crate::repos::storage_key_repo::StorageKeyRepo;
use crate::services::storage::encryption::decrypt_secret;

type HmacSha256 = Hmac<Sha256>;

/// Maximum allowed clock skew between client and server (15 minutes).
const MAX_CLOCK_SKEW_SECONDS: i64 = 15 * 60;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Verified authentication context returned on successful SigV4 verification.
#[derive(Debug, Clone)]
pub struct S3AuthContext {
    pub access_key: String,
    pub customer_id: Uuid,
    pub bucket_id: Uuid,
}

/// Errors from SigV4 authentication.
#[derive(Debug, thiserror::Error)]
pub enum S3AuthError {
    #[error("the request signature does not match the signature you provided")]
    SignatureDoesNotMatch,

    #[error("the AWS access key ID you provided does not exist in our records")]
    InvalidAccessKeyId,

    #[error("the difference between the request time and the current time is too large")]
    RequestTimeTooSkewed,

    #[error("account is disabled")]
    AccountDisabled,

    #[error("authorization header is malformed: {0}")]
    MalformedAuth(String),

    #[error("internal error: {0}")]
    Internal(String),
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

pub struct S3AuthService {
    key_repo: Arc<dyn StorageKeyRepo + Send + Sync>,
    customer_repo: Arc<dyn CustomerRepo + Send + Sync>,
    master_key: [u8; 32],
}

impl S3AuthService {
    pub fn new(
        key_repo: Arc<dyn StorageKeyRepo + Send + Sync>,
        customer_repo: Arc<dyn CustomerRepo + Send + Sync>,
        master_key: [u8; 32],
    ) -> Self {
        Self {
            key_repo,
            customer_repo,
            master_key,
        }
    }

    /// Authenticate an inbound S3 request by verifying its SigV4 signature.
    ///
    /// Returns a verified `S3AuthContext` or an appropriate `S3AuthError`.
    /// Never logs secret material.
    pub async fn authenticate(
        &self,
        method: &str,
        uri: &str,
        headers: &[(&str, &str)],
    ) -> Result<S3AuthContext, S3AuthError> {
        // 1. Parse Authorization header
        let auth_value = find_header(headers, "authorization")
            .ok_or_else(|| S3AuthError::MalformedAuth("missing authorization header".into()))?;
        let parsed = parse_authorization(auth_value)?;
        validate_signed_headers(&parsed.signed_headers)?;

        // 2. Check clock skew
        let (request_timestamp_header, request_timestamp_value) = find_request_timestamp(headers)?;
        let request_time =
            parse_sigv4_timestamp(request_timestamp_value, request_timestamp_header)?;
        validate_credential_scope(&parsed, &request_time)?;
        check_clock_skew(request_time)?;

        // 3. Look up access key (repo filters revoked keys)
        let row = self
            .key_repo
            .get_by_access_key(&parsed.access_key)
            .await
            .map_err(|e| S3AuthError::Internal(e.to_string()))?
            .ok_or(S3AuthError::InvalidAccessKeyId)?;

        // 3b. Check customer status using the shared auth gate
        let customer = self
            .customer_repo
            .find_by_id(row.customer_id)
            .await
            .map_err(|e| S3AuthError::Internal(e.to_string()))?;
        match customer_auth_state(customer.as_ref()) {
            CustomerAuthState::Suspended => return Err(S3AuthError::AccountDisabled),
            CustomerAuthState::Missing => return Err(S3AuthError::InvalidAccessKeyId),
            CustomerAuthState::Active => {}
        }

        // 4. Decrypt secret key
        let secret_key =
            decrypt_secret(&row.secret_key_enc, &row.secret_key_nonce, &self.master_key)
                .map_err(|e| S3AuthError::Internal(e.to_string()))?;

        // 5. Payload hash
        let payload_hash = find_header(headers, "x-amz-content-sha256").ok_or_else(|| {
            S3AuthError::MalformedAuth("missing x-amz-content-sha256 header".into())
        })?;

        // 6. Canonical request
        let (path, query) = uri.split_once('?').unwrap_or((uri, ""));
        let canon_uri = canonical_uri(path);
        let canon_query = canonical_query(query);
        let canon_hdrs = canonical_headers(headers, &parsed.signed_headers)?;
        let signed_headers_str = parsed.signed_headers.join(";");

        let canonical_req = CanonicalRequestParts {
            method,
            uri: &canon_uri,
            query: &canon_query,
            headers: &canon_hdrs,
            signed_headers: &signed_headers_str,
            payload_hash,
        }
        .build();

        // 7. String to sign
        let credential_scope =
            build_credential_scope(&parsed.date_stamp, &parsed.region, &parsed.service);
        let sts = build_string_to_sign(request_timestamp_value, &credential_scope, &canonical_req);

        // 8. Derive signing key and compute expected signature
        let signing_key = derive_signing_key(
            &secret_key,
            &parsed.date_stamp,
            &parsed.region,
            &parsed.service,
        );
        let expected = hex::encode(hmac_sha256(&signing_key, sts.as_bytes()));

        // 9. Constant-time compare
        if expected.len() != parsed.signature.len()
            || expected
                .as_bytes()
                .ct_eq(parsed.signature.as_bytes())
                .unwrap_u8()
                != 1
        {
            return Err(S3AuthError::SignatureDoesNotMatch);
        }

        Ok(S3AuthContext {
            access_key: parsed.access_key,
            customer_id: row.customer_id,
            bucket_id: row.bucket_id,
        })
    }
}

// ---------------------------------------------------------------------------
// Public pure helpers (reusable by s3_proxy.rs re-signing)
// ---------------------------------------------------------------------------

/// Build the canonical URI by preserving path structure and AWS-encoding bytes
/// that are not unreserved characters or `/`.
pub fn canonical_uri(path: &str) -> String {
    if path.is_empty() {
        return "/".to_string();
    }
    aws_uri_encode(path, false)
}

/// Build the canonical query string: sort key=value pairs alphabetically.
pub fn canonical_query(query: &str) -> String {
    if query.is_empty() {
        return String::new();
    }
    let mut pairs: Vec<(String, String)> = query
        .split('&')
        .filter(|s| !s.is_empty())
        .map(|pair| {
            let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
            (aws_uri_encode(k, true), aws_uri_encode(v, true))
        })
        .collect();
    pairs.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
    pairs
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("&")
}

/// Build the canonical headers string from request headers, filtered to
/// only those in `signed_header_names` (must be lowercase and pre-sorted).
pub fn canonical_headers(
    headers: &[(&str, &str)],
    signed_header_names: &[String],
) -> Result<String, S3AuthError> {
    let mut result = String::new();
    for name in signed_header_names {
        let values: Vec<&str> = headers
            .iter()
            .filter(|(k, _)| k.to_ascii_lowercase() == *name)
            .map(|(_, v)| *v)
            .collect();
        if values.is_empty() {
            return Err(S3AuthError::MalformedAuth(format!(
                "signed header missing from request: {name}"
            )));
        }
        let joined = values.join(",");
        let normalized = normalize_header_value(&joined);
        result.push_str(name);
        result.push(':');
        result.push_str(&normalized);
        result.push('\n');
    }
    Ok(result)
}

/// Derive the SigV4 signing key from the secret and credential scope parts.
pub fn derive_signing_key(secret: &str, date: &str, region: &str, service: &str) -> [u8; 32] {
    let k_date = hmac_sha256(format!("AWS4{secret}").as_bytes(), date.as_bytes());
    let k_region = hmac_sha256(&k_date, region.as_bytes());
    let k_service = hmac_sha256(&k_region, service.as_bytes());
    hmac_sha256(&k_service, b"aws4_request")
}

/// HMAC-SHA256 keyed hash.
pub fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(data);
    mac.finalize().into_bytes().into()
}

/// Pre-computed components for a SigV4 canonical request.
pub struct CanonicalRequestParts<'a> {
    pub method: &'a str,
    pub uri: &'a str,
    pub query: &'a str,
    pub headers: &'a str,
    pub signed_headers: &'a str,
    pub payload_hash: &'a str,
}

impl CanonicalRequestParts<'_> {
    /// Assemble the SigV4 canonical request string.
    pub fn build(&self) -> String {
        format!(
            "{}\n{}\n{}\n{}\n{}\n{}",
            self.method, self.uri, self.query, self.headers, self.signed_headers, self.payload_hash
        )
    }
}

/// Build the SigV4 credential scope string.
pub fn build_credential_scope(date: &str, region: &str, service: &str) -> String {
    format!("{date}/{region}/{service}/aws4_request")
}

/// Build the SigV4 string to sign from the timestamp, scope, and canonical request.
pub fn build_string_to_sign(
    amz_date: &str,
    credential_scope: &str,
    canonical_request: &str,
) -> String {
    format!(
        "AWS4-HMAC-SHA256\n{amz_date}\n{credential_scope}\n{}",
        hex::encode(Sha256::digest(canonical_request.as_bytes()))
    )
}

/// Build the SigV4 Authorization header value.
pub fn build_authorization_header(
    access_key: &str,
    credential_scope: &str,
    signed_headers: &str,
    signature: &str,
) -> String {
    format!(
        "AWS4-HMAC-SHA256 Credential={access_key}/{credential_scope}, SignedHeaders={signed_headers}, Signature={signature}"
    )
}

/// Standard S3 request headers for outbound signing (host, date, content hash).
pub fn standard_headers<'a>(
    host: &'a str,
    amz_date: &'a str,
    payload_hash: &'a str,
) -> Vec<(&'static str, &'a str)> {
    vec![
        ("host", host),
        ("x-amz-content-sha256", payload_hash),
        ("x-amz-date", amz_date),
    ]
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

fn find_header<'a>(headers: &[(&str, &'a str)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(k, _)| k.to_ascii_lowercase() == name)
        .map(|(_, v)| *v)
}

/// Parsed components from an AWS4 Authorization header.
struct ParsedAuth {
    access_key: String,
    date_stamp: String,
    region: String,
    service: String,
    signed_headers: Vec<String>,
    signature: String,
}

/// Parse `AWS4-HMAC-SHA256 Credential=KEY/DATE/REGION/SERVICE/aws4_request, SignedHeaders=..., Signature=...`
fn parse_authorization(value: &str) -> Result<ParsedAuth, S3AuthError> {
    let value = value
        .strip_prefix("AWS4-HMAC-SHA256 ")
        .ok_or_else(|| S3AuthError::MalformedAuth("unsupported auth scheme".into()))?;

    let mut credential = None;
    let mut signed_headers_raw = None;
    let mut signature = None;

    for part in value
        .split(',')
        .map(str::trim)
        .filter(|part| !part.is_empty())
    {
        if let Some(val) = part.strip_prefix("Credential=") {
            set_auth_component(&mut credential, val, "Credential")?;
        } else if let Some(val) = part.strip_prefix("SignedHeaders=") {
            set_auth_component(&mut signed_headers_raw, val, "SignedHeaders")?;
        } else if let Some(val) = part.strip_prefix("Signature=") {
            set_auth_component(&mut signature, val, "Signature")?;
        }
    }

    let credential =
        credential.ok_or_else(|| S3AuthError::MalformedAuth("missing Credential".into()))?;
    let signed_headers_raw = signed_headers_raw
        .ok_or_else(|| S3AuthError::MalformedAuth("missing SignedHeaders".into()))?;
    let signature = signature
        .ok_or_else(|| S3AuthError::MalformedAuth("missing Signature".into()))?
        .to_string();

    // Credential = access_key/date/region/service/aws4_request
    let cred_parts: Vec<&str> = credential.splitn(2, '/').collect();
    if cred_parts.len() != 2 {
        return Err(S3AuthError::MalformedAuth(
            "invalid Credential format".into(),
        ));
    }
    let access_key = cred_parts[0].to_string();
    let scope_parts: Vec<&str> = cred_parts[1].split('/').collect();
    if scope_parts.len() != 4 || scope_parts[3] != "aws4_request" {
        return Err(S3AuthError::MalformedAuth(
            "invalid credential scope".into(),
        ));
    }

    let signed_headers: Vec<String> = signed_headers_raw
        .split(';')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect();

    Ok(ParsedAuth {
        access_key,
        date_stamp: scope_parts[0].to_string(),
        region: scope_parts[1].to_string(),
        service: scope_parts[2].to_string(),
        signed_headers,
        signature,
    })
}

fn set_auth_component<'a>(
    slot: &mut Option<&'a str>,
    value: &'a str,
    field_name: &str,
) -> Result<(), S3AuthError> {
    if slot.replace(value).is_some() {
        return Err(S3AuthError::MalformedAuth(format!(
            "duplicate {field_name}"
        )));
    }
    Ok(())
}

fn parse_sigv4_timestamp(s: &str, header_name: &str) -> Result<DateTime<Utc>, S3AuthError> {
    NaiveDateTime::parse_from_str(s, "%Y%m%dT%H%M%SZ")
        .map(|dt| dt.and_utc())
        .map_err(|e| S3AuthError::MalformedAuth(format!("invalid {header_name}: {e}")))
}

fn find_request_timestamp<'a>(
    headers: &[(&str, &'a str)],
) -> Result<(&'static str, &'a str), S3AuthError> {
    if let Some(value) = find_header(headers, "x-amz-date") {
        return Ok(("x-amz-date", value));
    }

    if let Some(value) = find_header(headers, "date") {
        return Ok(("Date", value));
    }

    Err(S3AuthError::MalformedAuth(
        "missing x-amz-date or Date header".into(),
    ))
}

fn check_clock_skew(request_time: DateTime<Utc>) -> Result<(), S3AuthError> {
    let diff = (Utc::now() - request_time).num_seconds().abs();
    if diff > MAX_CLOCK_SKEW_SECONDS {
        return Err(S3AuthError::RequestTimeTooSkewed);
    }
    Ok(())
}

/// Validates the SigV4 `SignedHeaders` list: must be non-empty, include
/// `host`, contain only lowercase names, and be lexicographically sorted
/// with no duplicates.
fn validate_signed_headers(signed_headers: &[String]) -> Result<(), S3AuthError> {
    if signed_headers.is_empty() {
        return Err(S3AuthError::MalformedAuth(
            "SignedHeaders must not be empty".into(),
        ));
    }

    if !signed_headers.iter().any(|name| name == "host") {
        return Err(S3AuthError::MalformedAuth(
            "SignedHeaders must include host".into(),
        ));
    }

    for header_name in signed_headers {
        if header_name != &header_name.to_ascii_lowercase() {
            return Err(S3AuthError::MalformedAuth(
                "SignedHeaders entries must be lowercase".into(),
            ));
        }
    }

    if signed_headers.windows(2).any(|pair| pair[0] >= pair[1]) {
        return Err(S3AuthError::MalformedAuth(
            "SignedHeaders entries must be unique and sorted".into(),
        ));
    }

    Ok(())
}

/// Validates the credential scope from the parsed `Authorization` header:
/// the date stamp must match the request date (`YYYYMMDD`) and the service
/// field must be `"s3"`.
fn validate_credential_scope(
    parsed: &ParsedAuth,
    request_time: &DateTime<Utc>,
) -> Result<(), S3AuthError> {
    if parsed.date_stamp != request_time.format("%Y%m%d").to_string() {
        return Err(S3AuthError::MalformedAuth(
            "credential scope date must match request date".into(),
        ));
    }

    if parsed.service != "s3" {
        return Err(S3AuthError::MalformedAuth(
            "credential scope service must be s3".into(),
        ));
    }

    Ok(())
}

/// Trim leading/trailing whitespace and collapse sequential spaces to one.
fn normalize_header_value(value: &str) -> String {
    let trimmed = value.trim();
    let mut result = String::with_capacity(trimmed.len());
    let mut prev_space = false;
    for ch in trimmed.chars() {
        if ch == ' ' || ch == '\t' {
            if !prev_space {
                result.push(' ');
            }
            prev_space = true;
        } else {
            result.push(ch);
            prev_space = false;
        }
    }
    result
}

/// Percent-encodes a URI component per AWS SigV4 rules: unreserved
/// characters (`A-Z`, `a-z`, `0-9`, `-`, `.`, `_`, `~`) pass through,
/// slashes pass through when `encode_slash` is false, existing
/// percent-encoded triplets are uppercased, and all other bytes are
/// percent-encoded.
fn aws_uri_encode(value: &str, encode_slash: bool) -> String {
    let bytes = value.as_bytes();
    let mut encoded = String::with_capacity(value.len());
    let mut index = 0;

    while index < bytes.len() {
        let byte = bytes[index];
        if is_unreserved(byte) || (!encode_slash && byte == b'/') {
            encoded.push(byte as char);
            index += 1;
            continue;
        }

        if byte == b'%'
            && index + 2 < bytes.len()
            && is_hex_digit(bytes[index + 1])
            && is_hex_digit(bytes[index + 2])
        {
            encoded.push('%');
            encoded.push((bytes[index + 1] as char).to_ascii_uppercase());
            encoded.push((bytes[index + 2] as char).to_ascii_uppercase());
            index += 3;
            continue;
        }

        let _ = write!(encoded, "%{byte:02X}");
        index += 1;
    }

    encoded
}

fn is_unreserved(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~')
}

fn is_hex_digit(byte: u8) -> bool {
    byte.is_ascii_hexdigit()
}
