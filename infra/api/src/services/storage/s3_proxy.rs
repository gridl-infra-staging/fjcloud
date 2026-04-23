//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/storage/s3_proxy.rs.

use axum::body::Body;
use chrono::Utc;
use sha2::{Digest, Sha256};

use super::s3_auth;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Bundled configuration for the Garage S3 proxy.
pub struct GarageProxyConfig {
    pub endpoint: String,
    pub access_key: String,
    pub secret_key: String,
    pub region: String,
}

/// Garage S3 proxy — re-signs and forwards requests.
pub struct GarageProxy {
    client: reqwest::Client,
    config: GarageProxyConfig,
}

/// Inbound request to forward to Garage.
pub struct ProxyRequest<'a> {
    pub method: &'a str,
    pub uri: &'a str,
    pub headers: &'a [(&'a str, &'a str)],
    pub body: &'a [u8],
}

/// Response from Garage after header filtering.
pub struct ProxyResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Body,
}

impl ProxyResponse {
    pub fn content_length_bytes(&self) -> i64 {
        self.headers
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case("content-length"))
            .and_then(|(_, value)| value.parse::<i64>().ok())
            .unwrap_or(0)
    }
}

/// Errors from proxy forwarding.
#[derive(Debug, thiserror::Error)]
pub enum ProxyError {
    #[error("upstream connection error: {0}")]
    UpstreamConnect(String),

    #[error("internal proxy error: {0}")]
    Internal(String),
}

struct ProxySigningInput<'a> {
    method: &'a str,
    path: &'a str,
    query: &'a str,
    amz_date: &'a str,
    date_stamp: &'a str,
    payload_hash: &'a str,
}

// ---------------------------------------------------------------------------
// Response header allowlist / denylist
// ---------------------------------------------------------------------------

/// Headers forwarded from Garage to the client (case-insensitive match).
const RESPONSE_HEADER_ALLOWLIST: &[&str] = &[
    "content-type",
    "content-length",
    "etag",
    "last-modified",
    "x-amz-request-id",
    "x-amz-id-2",
    "x-amz-version-id",
    "x-amz-delete-marker",
    "x-amz-server-side-encryption",
    "content-range",
    "accept-ranges",
    "cache-control",
    "content-disposition",
    "content-encoding",
    "expires",
];

/// Headers that must never be forwarded (hop-by-hop + Garage internals).
const RESPONSE_HEADER_DENYLIST: &[&str] = &[
    "connection",
    "keep-alive",
    "transfer-encoding",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "upgrade",
    "server",
];

/// Request headers to strip before re-signing (inbound client auth).
const REQUEST_STRIP_HEADERS: &[&str] = &[
    "authorization",
    "x-amz-date",
    "x-amz-content-sha256",
    "x-amz-security-token",
];

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

impl GarageProxy {
    pub fn new(client: reqwest::Client, config: GarageProxyConfig) -> Self {
        Self { client, config }
    }

    pub fn from_env(client: reqwest::Client) -> Self {
        let config = GarageProxyConfig {
            endpoint: std::env::var("GARAGE_S3_ENDPOINT")
                .unwrap_or_else(|_| "http://127.0.0.1:3900".to_string()),
            access_key: std::env::var("GARAGE_S3_ACCESS_KEY").unwrap_or_default(),
            secret_key: std::env::var("GARAGE_S3_SECRET_KEY").unwrap_or_default(),
            region: std::env::var("GARAGE_S3_REGION").unwrap_or_else(|_| "garage".to_string()),
        };
        Self::new(client, config)
    }

    /// Forward a request to Garage, re-signing with internal credentials.
    pub async fn forward(&self, request: &ProxyRequest<'_>) -> Result<ProxyResponse, ProxyError> {
        let (path, query) = split_uri(request.uri);
        let url = build_target_url(&self.config.endpoint, path, query);
        let payload_hash = hex::encode(Sha256::digest(request.body));
        let now = Utc::now();
        let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
        let date_stamp = now.format("%Y%m%d").to_string();

        let signing_headers = build_signing_headers(
            &self.config.endpoint,
            request.headers,
            &amz_date,
            &payload_hash,
        );
        let signing_input = ProxySigningInput {
            method: request.method,
            path,
            query,
            amz_date: &amz_date,
            date_stamp: &date_stamp,
            payload_hash: &payload_hash,
        };
        let auth_header = self.build_auth_header(&signing_headers, &signing_input)?;

        let response = self
            .send_request(request, &url, &signing_headers, &auth_header)
            .await?;

        Ok(to_proxy_response(response))
    }

    /// Constructs an AWS SigV4 `Authorization` header for a Garage-bound
    /// request. Builds the canonical request from the method, URI, query,
    /// signing headers, and payload hash, then derives the signing key and
    /// computes the HMAC-SHA256 signature.
    fn build_auth_header(
        &self,
        signing_headers: &[(String, String)],
        signing_input: &ProxySigningInput<'_>,
    ) -> Result<String, ProxyError> {
        let header_refs: Vec<(&str, &str)> = signing_headers
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        let mut signed_names = signed_header_names(signing_headers);
        signed_names.dedup();

        let canon_uri = s3_auth::canonical_uri(signing_input.path);
        let canon_query = s3_auth::canonical_query(signing_input.query);
        let canon_hdrs = s3_auth::canonical_headers(&header_refs, &signed_names)
            .map_err(|e| ProxyError::Internal(e.to_string()))?;
        let signed_headers_str = signed_names.join(";");

        let canonical_req = s3_auth::CanonicalRequestParts {
            method: signing_input.method,
            uri: &canon_uri,
            query: &canon_query,
            headers: &canon_hdrs,
            signed_headers: &signed_headers_str,
            payload_hash: signing_input.payload_hash,
        }
        .build();

        let credential_scope =
            s3_auth::build_credential_scope(signing_input.date_stamp, &self.config.region, "s3");
        let sts = s3_auth::build_string_to_sign(
            signing_input.amz_date,
            &credential_scope,
            &canonical_req,
        );
        let signing_key = s3_auth::derive_signing_key(
            &self.config.secret_key,
            signing_input.date_stamp,
            &self.config.region,
            "s3",
        );
        let signature = hex::encode(s3_auth::hmac_sha256(&signing_key, sts.as_bytes()));

        Ok(s3_auth::build_authorization_header(
            &self.config.access_key,
            &credential_scope,
            &signed_headers_str,
            &signature,
        ))
    }

    /// Assembles and sends the re-signed HTTP request to the Garage backend.
    /// Attaches all signing headers plus the `Authorization` header, includes
    /// the request body when present, and maps transport failures to
    /// [`ProxyError::UpstreamConnect`].
    async fn send_request(
        &self,
        request: &ProxyRequest<'_>,
        url: &str,
        signing_headers: &[(String, String)],
        auth_header: &str,
    ) -> Result<reqwest::Response, ProxyError> {
        let reqwest_method = reqwest::Method::from_bytes(request.method.as_bytes())
            .map_err(|e| ProxyError::Internal(format!("invalid method: {e}")))?;

        let mut builder = self.client.request(reqwest_method, url);
        for (name, value) in signing_headers {
            builder = builder.header(name.as_str(), value.as_str());
        }
        builder = builder.header("authorization", auth_header);

        if !request.body.is_empty() {
            builder = builder.body(request.body.to_vec());
        }

        builder
            .send()
            .await
            .map_err(|e| ProxyError::UpstreamConnect(format!("failed to connect to Garage: {e}")))
    }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

fn extract_host(endpoint: &str) -> String {
    endpoint
        .strip_prefix("https://")
        .or_else(|| endpoint.strip_prefix("http://"))
        .unwrap_or(endpoint)
        .split('/')
        .next()
        .unwrap_or(endpoint)
        .to_string()
}

fn split_uri(uri: &str) -> (&str, &str) {
    uri.split_once('?').unwrap_or((uri, ""))
}

fn build_target_url(endpoint: &str, path: &str, query: &str) -> String {
    let base = endpoint.trim_end_matches('/');
    if query.is_empty() {
        format!("{base}{path}")
    } else {
        format!("{base}{path}?{query}")
    }
}

/// Builds the sorted list of headers included in the SigV4 signature.
/// Starts with the standard `host`, `x-amz-date`, and
/// `x-amz-content-sha256` headers, then appends client-supplied headers
/// (lowercased) that are not in the strip list. The result is sorted
/// lexicographically by header name.
fn build_signing_headers(
    endpoint: &str,
    request_headers: &[(&str, &str)],
    amz_date: &str,
    payload_hash: &str,
) -> Vec<(String, String)> {
    let host = extract_host(endpoint);
    let mut signing_headers = s3_auth::standard_headers(&host, amz_date, payload_hash)
        .into_iter()
        .map(|(name, value)| (name.to_string(), value.to_string()))
        .collect::<Vec<_>>();

    for &(name, value) in request_headers {
        let lower = name.to_ascii_lowercase();
        if !REQUEST_STRIP_HEADERS.contains(&lower.as_str()) && lower != "host" {
            signing_headers.push((lower, value.to_string()));
        }
    }

    signing_headers.sort_by(|a, b| a.0.cmp(&b.0));
    signing_headers
}

fn signed_header_names(signing_headers: &[(String, String)]) -> Vec<String> {
    signing_headers
        .iter()
        .map(|(name, _)| name.to_ascii_lowercase())
        .collect()
}

fn to_proxy_response(response: reqwest::Response) -> ProxyResponse {
    let status = response.status().as_u16();
    let headers = filter_response_headers(response.headers());
    let body = Body::from_stream(response.bytes_stream());
    ProxyResponse {
        status,
        headers,
        body,
    }
}

/// Filters Garage response headers through an allowlist/denylist.
/// Headers on the denylist are dropped first, then only headers on the
/// allowlist are forwarded. Non-UTF-8 header values are silently skipped.
fn filter_response_headers(headers: &reqwest::header::HeaderMap) -> Vec<(String, String)> {
    let mut result = Vec::new();
    for (name, value) in headers {
        let name_lower = name.as_str().to_ascii_lowercase();

        if RESPONSE_HEADER_DENYLIST
            .iter()
            .any(|denied| *denied == name_lower)
        {
            continue;
        }

        if RESPONSE_HEADER_ALLOWLIST
            .iter()
            .any(|allowed| *allowed == name_lower)
        {
            if let Ok(val) = value.to_str() {
                result.push((name_lower, val.to_string()));
            }
        }
    }
    result
}
