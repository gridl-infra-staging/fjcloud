//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/routes/storage/buckets.rs.

use axum::extract::{Path, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};

use crate::services::storage::s3_auth::S3AuthContext;
use crate::services::storage::s3_error::{self, S3ErrorResponse};
use crate::services::storage::s3_xml;
use crate::state::AppState;

/// GET / — ListBuckets.
pub async fn list_buckets(
    State(state): State<AppState>,
    ctx: S3AuthContext,
) -> Result<Response, S3ErrorResponse> {
    let buckets = state
        .storage_bucket_repo
        .list_by_customer(ctx.customer_id)
        .await
        .map_err(|e| {
            tracing::error!(error = %e, "list_by_customer failed");
            s3_error::internal_error_response("/", &ctx.access_key)
        })?;

    // S3 access keys are bucket-scoped, so the service-level listing must not
    // reveal sibling bucket names owned by the same customer.
    let entries: Vec<s3_xml::BucketEntry> = buckets
        .iter()
        .filter(|bucket| bucket.id == ctx.bucket_id)
        .map(|b| s3_xml::BucketEntry {
            name: b.name.clone(),
            creation_date: b.created_at.to_rfc3339(),
        })
        .collect();

    let owner_id = ctx.customer_id.to_string();
    let body = s3_xml::list_buckets_result(&owner_id, &owner_id, &entries);
    Ok((
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/xml")],
        body,
    )
        .into_response())
}

/// PUT /:bucket — CreateBucket.
pub async fn create_bucket(
    ctx: S3AuthContext,
    Path(bucket_name): Path<String>,
) -> Result<Response, S3ErrorResponse> {
    // Stage 5 S3 keys are bucket-scoped, so they must not provision new buckets.
    Err(s3_error::s3_error_response(
        "AccessDenied",
        "Access Denied",
        &format!("/{bucket_name}"),
        &ctx.access_key,
    ))
}

/// HEAD /:bucket — HeadBucket (forward to Garage).
pub async fn head_bucket(
    State(state): State<AppState>,
    ctx: S3AuthContext,
    Path(bucket_name): Path<String>,
    headers: HeaderMap,
) -> Result<Response, S3ErrorResponse> {
    let bucket = resolve_and_verify_bucket(&state, &ctx, &bucket_name).await?;
    let forwarded_headers = header_pairs(&headers);
    let forwarded_header_refs = as_header_refs(&forwarded_headers);
    let bucket_resource = bucket_resource(&bucket_name);

    let resp = state
        .garage_proxy
        .forward(&proxy_request(
            "HEAD",
            &garage_bucket_uri(&bucket, None),
            &forwarded_header_refs,
            &[],
        ))
        .await
        .map_err(|e| s3_error::from_proxy_error(&e, &bucket_resource, &ctx.access_key))?;

    Ok(proxy_response_to_axum(resp))
}

/// DELETE /:bucket — DeleteBucket.
pub async fn delete_bucket(
    State(state): State<AppState>,
    ctx: S3AuthContext,
    Path(bucket_name): Path<String>,
) -> Result<Response, S3ErrorResponse> {
    let bucket = resolve_and_verify_bucket(&state, &ctx, &bucket_name).await?;
    let bucket_resource = bucket_resource(&bucket_name);

    state
        .storage_service
        .delete_bucket(bucket.id)
        .await
        .map_err(|e| storage_error_to_s3(&e, &bucket_resource, &ctx.access_key))?;

    Ok(StatusCode::NO_CONTENT.into_response())
}

/// GET /:bucket — ListObjectsV2 (forward to Garage).
pub async fn list_objects_v2(
    State(state): State<AppState>,
    ctx: S3AuthContext,
    Path(bucket_name): Path<String>,
    uri: axum::http::Uri,
    headers: HeaderMap,
) -> Result<Response, S3ErrorResponse> {
    let bucket = resolve_and_verify_bucket(&state, &ctx, &bucket_name).await?;
    let forwarded_headers = header_pairs(&headers);
    let forwarded_header_refs = as_header_refs(&forwarded_headers);
    let bucket_resource = bucket_resource(&bucket_name);

    let resp = state
        .garage_proxy
        .forward(&proxy_request(
            "GET",
            &garage_bucket_uri(&bucket, uri.query()),
            &forwarded_header_refs,
            &[],
        ))
        .await
        .map_err(|e| s3_error::from_proxy_error(&e, &bucket_resource, &ctx.access_key))?;

    Ok(proxy_response_to_axum(resp))
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

use crate::models::storage::StorageBucket;
use crate::services::storage::s3_proxy::{ProxyRequest, ProxyResponse};
use crate::services::storage::StorageError;

/// Resolve bucket by name and verify the auth context's bucket_id matches.
pub(super) async fn resolve_and_verify_bucket(
    state: &AppState,
    ctx: &S3AuthContext,
    bucket_name: &str,
) -> Result<StorageBucket, S3ErrorResponse> {
    let bucket_resource = bucket_resource(bucket_name);
    let bucket = state
        .storage_bucket_repo
        .get_by_name(ctx.customer_id, bucket_name)
        .await
        .map_err(|e| {
            tracing::error!(error = %e, "get_by_name failed");
            s3_error::internal_error_response(&bucket_resource, &ctx.access_key)
        })?
        .ok_or_else(|| {
            s3_error::s3_error_response(
                "NoSuchBucket",
                "The specified bucket does not exist",
                &bucket_resource,
                &ctx.access_key,
            )
        })?;

    if bucket.id != ctx.bucket_id {
        return Err(s3_error::s3_error_response(
            "AccessDenied",
            "Access Denied",
            &bucket_resource,
            &ctx.access_key,
        ));
    }

    Ok(bucket)
}

fn bucket_resource(bucket_name: &str) -> String {
    format!("/{bucket_name}")
}

fn garage_bucket_uri(bucket: &StorageBucket, query: Option<&str>) -> String {
    match query {
        Some(query) => format!("/{}?{query}", bucket.garage_bucket),
        None => format!("/{}", bucket.garage_bucket),
    }
}

pub(super) fn proxy_request<'a>(
    method: &'a str,
    uri: &'a str,
    headers: &'a [(&'a str, &'a str)],
    body: &'a [u8],
) -> ProxyRequest<'a> {
    ProxyRequest {
        method,
        uri,
        headers,
        body,
    }
}

pub(super) fn header_pairs(headers: &HeaderMap) -> Vec<(String, String)> {
    headers
        .iter()
        .filter_map(|(name, value)| {
            value
                .to_str()
                .ok()
                .map(|value| (name.as_str().to_string(), value.to_string()))
        })
        .collect()
}

pub(super) fn as_header_refs(headers: &[(String, String)]) -> Vec<(&str, &str)> {
    headers
        .iter()
        .map(|(name, value)| (name.as_str(), value.as_str()))
        .collect()
}

pub(super) fn proxy_response_to_axum(resp: ProxyResponse) -> Response {
    let status = StatusCode::from_u16(resp.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let mut builder = axum::http::Response::builder().status(status);
    for (name, value) in &resp.headers {
        if let Ok(header_name) = name.parse::<axum::http::header::HeaderName>() {
            if let Ok(header_value) = value.parse::<axum::http::header::HeaderValue>() {
                builder = builder.header(header_name, header_value);
            }
        }
    }
    builder
        .body(resp.body)
        .unwrap_or_else(|_| (StatusCode::INTERNAL_SERVER_ERROR, "internal error").into_response())
}

/// Map a [`StorageError`] to the corresponding S3-compatible XML error response.
///
/// `NotFound` → `NoSuchBucket`, `Conflict` → `BucketAlreadyExists`, anything
/// else → generic `InternalError`.
fn storage_error_to_s3(err: &StorageError, resource: &str, request_id: &str) -> S3ErrorResponse {
    match err {
        StorageError::NotFound(_) => s3_error::s3_error_response(
            "NoSuchBucket",
            "The specified bucket does not exist",
            resource,
            request_id,
        ),
        StorageError::Conflict(_) => s3_error::s3_error_response(
            "BucketAlreadyExists",
            "The requested bucket name is not available",
            resource,
            request_id,
        ),
        _ => s3_error::internal_error_response(resource, request_id),
    }
}
