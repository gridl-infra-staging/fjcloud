#![allow(dead_code)]

//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/tests/storage_s3_auth_support.rs.
use chrono::{DateTime, Utc};
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

const TEST_REGION: &str = "us-east-1";
const TEST_SERVICE: &str = "s3";
const TEST_MASTER_KEY: [u8; 32] = [0x42; 32];

pub(crate) const EMPTY_SHA256: &str =
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

// ---------------------------------------------------------------------------
// SigningRequest — bundles all inputs for test-side SigV4 signing
// ---------------------------------------------------------------------------

/// Test-side request-signing parameters. Bundles the 7 values every test needs
/// into a struct so public methods stay within the 6-parameter hard limit.
pub(crate) struct SigningRequest<'a> {
    pub method: &'a str,
    pub uri: &'a str,
    pub headers: &'a [(&'a str, &'a str)],
    pub payload_hash: &'a str,
    pub access_key: &'a str,
    pub secret_key: &'a str,
    pub timestamp: &'a DateTime<Utc>,
}

impl SigningRequest<'_> {
    /// Sign with default scope (TEST_REGION / TEST_SERVICE), auto-derived signed headers.
    pub(crate) fn sign(&self) -> String {
        let signed_headers = canonical_signed_headers(self.headers);
        let date = self.timestamp.format("%Y%m%d").to_string();
        self.build_auth(&signed_headers, &date, TEST_SERVICE)
    }

    /// Sign with a custom credential date and service (for scope-mismatch tests).
    pub(crate) fn sign_with_scope(&self, credential_date: &str, service: &str) -> String {
        let signed_headers = canonical_signed_headers(self.headers);
        self.build_auth(&signed_headers, credential_date, service)
    }

    /// Sign with an explicit signed-headers list (for missing/wrong header tests).
    pub(crate) fn sign_with_signed_headers(&self, names: &[&str]) -> String {
        let date = self.timestamp.format("%Y%m%d").to_string();
        let signed: Vec<String> = names.iter().map(|s| s.to_string()).collect();
        self.build_auth(&signed, &date, TEST_SERVICE)
    }

    /// Produces a complete AWS SigV4 `Authorization` header value for the request.
    ///
    /// Mirrors the production signing logic in `services/storage/s3_auth.rs` so
    /// tests can generate valid (or deliberately wrong) signatures without
    /// depending on the production code path.
    ///
    /// Steps performed:
    /// 1. Build the canonical request (method, URI, query, headers, payload hash)
    /// 2. Compose the string-to-sign with the AWS4-HMAC-SHA256 prefix and scope
    /// 3. Derive the signing key via four-step HMAC-SHA256 chain
    /// 4. Return the `AWS4-HMAC-SHA256 Credential=…, SignedHeaders=…, Signature=…` string
    ///
    /// `cred_date` and `service` are accepted as parameters (rather than always
    /// using `TEST_REGION`/`TEST_SERVICE`) so callers can construct scope-mismatch
    /// test cases via `sign_with_scope`.
    fn build_auth(&self, signed_headers: &[String], cred_date: &str, service: &str) -> String {
        let amz_date = self.timestamp.format("%Y%m%dT%H%M%SZ").to_string();
        let (path, query) = self.uri.split_once('?').unwrap_or((self.uri, ""));
        let canonical_request = format!(
            "{}\n{}\n{}\n{}\n{}\n{}",
            self.method,
            build_canonical_uri(path),
            build_canonical_query(query),
            build_canonical_headers(self.headers, signed_headers),
            signed_headers.join(";"),
            self.payload_hash,
        );
        let scope = format!("{cred_date}/{TEST_REGION}/{service}/aws4_request");
        let string_to_sign = format!(
            "AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{}",
            hex::encode(Sha256::digest(canonical_request.as_bytes()))
        );
        let signing_key = derive_signing_key(self.secret_key, cred_date, TEST_REGION, service);
        let signature = hex::encode(hmac_sha256(&signing_key, string_to_sign.as_bytes()));

        format!(
            "AWS4-HMAC-SHA256 Credential={}/{scope}, SignedHeaders={}, Signature={signature}",
            self.access_key,
            signed_headers.join(";"),
        )
    }
}

// TestHarness lives in storage_s3_auth_test.rs (the only consumer) to avoid
// a cross-module dependency on `common::mocks` which breaks when this file
// is compiled as a standalone test crate by Cargo.

pub(crate) fn standard_headers(amz_date: &str) -> Vec<(&'static str, &str)> {
    vec![
        ("host", "s3.flapjack.foo"),
        ("x-amz-date", amz_date),
        ("x-amz-content-sha256", EMPTY_SHA256),
    ]
}

// ---------------------------------------------------------------------------
// Internal SigV4 helpers (test-side only, mirrors s3_auth.rs logic)
// ---------------------------------------------------------------------------

fn canonical_signed_headers(headers: &[(&str, &str)]) -> Vec<String> {
    let mut pairs: Vec<(String, String)> = headers
        .iter()
        .map(|(name, value)| (name.to_ascii_lowercase(), value.to_string()))
        .collect();
    pairs.sort_by(|a, b| a.0.cmp(&b.0));

    let mut names = Vec::new();
    for (name, _) in pairs {
        if names.last() != Some(&name) {
            names.push(name);
        }
    }
    names
}

fn build_canonical_headers(headers: &[(&str, &str)], signed_headers: &[String]) -> String {
    let mut result = String::new();
    for name in signed_headers {
        let values = headers
            .iter()
            .filter(|(header_name, _)| header_name.eq_ignore_ascii_case(name))
            .map(|(_, value)| *value)
            .collect::<Vec<_>>();
        result.push_str(name);
        result.push(':');
        result.push_str(&normalize_test_value(&values.join(",")));
        result.push('\n');
    }
    result
}

/// Normalizes an HTTP header value to its canonical SigV4 form.
///
/// Trims leading/trailing whitespace and collapses consecutive internal spaces
/// to a single space, matching the AWS SigV4 spec for canonical header values.
/// Used when assembling the canonical-headers block inside `build_canonical_headers`.
fn normalize_test_value(value: &str) -> String {
    let trimmed = value.trim();
    let mut result = String::with_capacity(trimmed.len());
    let mut prev_space = false;
    for ch in trimmed.chars() {
        if ch == ' ' {
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

fn build_canonical_uri(path: &str) -> String {
    if path.is_empty() {
        return "/".to_string();
    }
    aws_uri_encode(path, false)
}

/// Produces the canonical query string component of an AWS SigV4 canonical request.
///
/// Splits the raw query on `&`, percent-encodes each key and value with
/// `aws_uri_encode` (query mode — slashes are encoded), then sorts pairs
/// lexicographically by key (then value for equal keys) and rejoins with `&`.
/// Returns an empty string for requests with no query component.
fn build_canonical_query(query: &str) -> String {
    if query.is_empty() {
        return String::new();
    }
    let mut pairs: Vec<(String, String)> = query
        .split('&')
        .filter(|segment| !segment.is_empty())
        .map(|pair| {
            let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
            (aws_uri_encode(key, true), aws_uri_encode(value, true))
        })
        .collect();
    pairs.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
    pairs
        .iter()
        .map(|(key, value)| format!("{key}={value}"))
        .collect::<Vec<_>>()
        .join("&")
}

/// Percent-encodes a string according to AWS SigV4 URI-encoding rules.
///
/// Unreserved characters (`A-Z a-z 0-9 - . _ ~`) are passed through unchanged.
/// When `encode_slash` is `false` (path mode), `/` is also passed through.
/// Already-encoded `%XX` sequences are preserved and upper-cased.
/// All other bytes are replaced with `%XX` using uppercase hex digits.
///
/// Used for both path segments (`encode_slash=false`) and query-string keys/values
/// (`encode_slash=true`) when building canonical requests.
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
            && bytes[index + 1].is_ascii_hexdigit()
            && bytes[index + 2].is_ascii_hexdigit()
        {
            encoded.push('%');
            encoded.push((bytes[index + 1] as char).to_ascii_uppercase());
            encoded.push((bytes[index + 2] as char).to_ascii_uppercase());
            index += 3;
            continue;
        }

        encoded.push_str(&format!("%{byte:02X}"));
        index += 1;
    }

    encoded
}

fn is_unreserved(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~')
}

fn derive_signing_key(secret: &str, date: &str, region: &str, service: &str) -> Vec<u8> {
    let k_date = hmac_sha256(format!("AWS4{secret}").as_bytes(), date.as_bytes());
    let k_region = hmac_sha256(&k_date, region.as_bytes());
    let k_service = hmac_sha256(&k_region, service.as_bytes());
    hmac_sha256(&k_service, b"aws4_request")
}

fn hmac_sha256(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC key length");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}
