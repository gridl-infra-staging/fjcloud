use axum::http::{HeaderValue, Request};
use tower_http::request_id::{MakeRequestId, RequestId};
use uuid::Uuid;

/// Generates a UUID v4 for each request that doesn't already have an `x-request-id` header.
#[derive(Clone, Default)]
pub struct UuidRequestId;

impl MakeRequestId for UuidRequestId {
    fn make_request_id<B>(&mut self, _request: &Request<B>) -> Option<RequestId> {
        let id = Uuid::new_v4().to_string();
        Some(RequestId::new(
            HeaderValue::from_str(&id).expect("UUID is always a valid header value"),
        ))
    }
}
