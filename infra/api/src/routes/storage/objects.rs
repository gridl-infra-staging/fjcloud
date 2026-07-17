//! S3 object-level route handlers with inline metering.

use axum::extract::{Path, State};
use axum::response::Response;

use crate::services::storage::object_metering::{MeteredMutationKind, MeteredObjectMutation};
use crate::services::storage::s3_auth::S3AuthContext;
use crate::services::storage::s3_error::{self, S3ErrorResponse};
use crate::state::AppState;

use super::buckets::{
    as_header_refs, header_pairs, proxy_request, proxy_response_to_axum, resolve_and_verify_bucket,
};

/// PUT /:bucket/*key — PutObject with metering.
pub async fn put_object(
    State(state): State<AppState>,
    ctx: S3AuthContext,
    Path((bucket_name, key)): Path<(String, String)>,
    headers: axum::http::HeaderMap,
    body: axum::body::Bytes,
) -> Result<Response, S3ErrorResponse> {
    let bucket = resolve_and_verify_bucket(&state, &ctx, &bucket_name).await?;
    let forwarded_headers = header_pairs(&headers);
    let forwarded_header_refs = as_header_refs(&forwarded_headers);
    let resource = format!("/{bucket_name}/{key}");
    let resp = state
        .s3_object_metering
        .execute(MeteredObjectMutation {
            bucket_id: bucket.id,
            garage_bucket: &bucket.garage_bucket,
            key: &key,
            headers: &forwarded_header_refs,
            body: &body,
            kind: MeteredMutationKind::Put,
        })
        .await
        .map_err(|e| s3_error::from_proxy_error(&e, &resource, &ctx.access_key))?;

    Ok(proxy_response_to_axum(resp))
}

/// GET /:bucket/*key — GetObject with egress metering.
pub async fn get_object(
    State(state): State<AppState>,
    ctx: S3AuthContext,
    Path((bucket_name, key)): Path<(String, String)>,
    headers: axum::http::HeaderMap,
) -> Result<Response, S3ErrorResponse> {
    let bucket = resolve_and_verify_bucket(&state, &ctx, &bucket_name).await?;
    let forwarded_headers = header_pairs(&headers);
    let forwarded_header_refs = as_header_refs(&forwarded_headers);

    let garage_uri = format!("/{}/{}", bucket.garage_bucket, key);
    let resp = state
        .garage_proxy
        .forward(&proxy_request(
            "GET",
            &garage_uri,
            &forwarded_header_refs,
            &[],
        ))
        .await
        .map_err(|e| {
            s3_error::from_proxy_error(&e, &format!("/{bucket_name}/{key}"), &ctx.access_key)
        })?;

    if resp.status < 300 {
        let content_length = resp.content_length_bytes();

        if content_length > 0 {
            let repo = state.storage_bucket_repo.clone();
            let bucket_id = bucket.id;
            tokio::spawn(async move {
                if let Err(e) = repo.increment_egress(bucket_id, content_length).await {
                    tracing::warn!(error = %e, bucket_id = %bucket_id, "get_object egress metering failed");
                }
            });
        }
    }

    Ok(proxy_response_to_axum(resp))
}

/// DELETE /:bucket/*key — DeleteObject with metering (HEAD first for size).
pub async fn delete_object(
    State(state): State<AppState>,
    ctx: S3AuthContext,
    Path((bucket_name, key)): Path<(String, String)>,
    headers: axum::http::HeaderMap,
) -> Result<Response, S3ErrorResponse> {
    let bucket = resolve_and_verify_bucket(&state, &ctx, &bucket_name).await?;
    let resource = format!("/{bucket_name}/{key}");
    let forwarded_headers = header_pairs(&headers);
    let forwarded_header_refs = as_header_refs(&forwarded_headers);

    let resp = state
        .s3_object_metering
        .execute(MeteredObjectMutation {
            bucket_id: bucket.id,
            garage_bucket: &bucket.garage_bucket,
            key: &key,
            headers: &forwarded_header_refs,
            body: &[],
            kind: MeteredMutationKind::Delete,
        })
        .await
        .map_err(|e| s3_error::from_proxy_error(&e, &resource, &ctx.access_key))?;

    Ok(proxy_response_to_axum(resp))
}

/// HEAD /:bucket/*key — HeadObject (forward only, no metering).
pub async fn head_object(
    State(state): State<AppState>,
    ctx: S3AuthContext,
    Path((bucket_name, key)): Path<(String, String)>,
    headers: axum::http::HeaderMap,
) -> Result<Response, S3ErrorResponse> {
    let bucket = resolve_and_verify_bucket(&state, &ctx, &bucket_name).await?;
    let forwarded_headers = header_pairs(&headers);
    let forwarded_header_refs = as_header_refs(&forwarded_headers);

    let garage_uri = format!("/{}/{}", bucket.garage_bucket, key);
    let resp = state
        .garage_proxy
        .forward(&proxy_request(
            "HEAD",
            &garage_uri,
            &forwarded_header_refs,
            &[],
        ))
        .await
        .map_err(|e| {
            s3_error::from_proxy_error(&e, &format!("/{bucket_name}/{key}"), &ctx.access_key)
        })?;

    Ok(proxy_response_to_axum(resp))
}
