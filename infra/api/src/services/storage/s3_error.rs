//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar19_3_load_testing_chaos/fjcloud_dev/infra/api/src/services/storage/s3_error.rs.

use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use quick_xml::events::Event;
use quick_xml::Reader;

use super::s3_auth::S3AuthError;
use super::s3_proxy::ProxyError;
use super::s3_xml;

const INTERNAL_ERROR_CODE: &str = "InternalError";
const INTERNAL_ERROR_MESSAGE: &str = "We encountered an internal error. Please try again.";

/// A complete S3 error response ready to return to the client.
#[derive(Debug)]
pub struct S3ErrorResponse {
    pub status: u16,
    pub body: String,
}

impl IntoResponse for S3ErrorResponse {
    fn into_response(self) -> Response {
        let status = StatusCode::from_u16(self.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
        (
            status,
            [(header::CONTENT_TYPE, "application/xml")],
            self.body,
        )
            .into_response()
    }
}

/// Map an S3 error code to its HTTP status.
pub fn status_for_s3_code(code: &str) -> u16 {
    known_status_for_s3_code(code).unwrap_or(500)
}

/// Build a complete S3 error response from a Garage-style XML `<Error>` body.
pub fn from_garage_error_xml(
    xml: &str,
    fallback_resource: &str,
    fallback_request_id: &str,
) -> S3ErrorResponse {
    let Some(parsed) = parse_garage_error_xml(xml) else {
        return internal_error_response(fallback_resource, fallback_request_id);
    };

    let resource = parsed.resource.as_deref().unwrap_or(fallback_resource);
    let request_id = parsed.request_id.as_deref().unwrap_or(fallback_request_id);
    s3_error_response(&parsed.code, &parsed.message, resource, request_id)
}

/// Maps a known S3 error code to its HTTP status (e.g. `NoSuchKey` → 404,
/// `AccessDenied` → 403, `SlowDown` → 503). Returns `None` for
/// unrecognized codes, which are normalized to an internal error
/// downstream.
fn known_status_for_s3_code(code: &str) -> Option<u16> {
    match code {
        "NoSuchKey" | "NoSuchBucket" | "NoSuchUpload" => Some(404),
        "AccessDenied"
        | "SignatureDoesNotMatch"
        | "InvalidAccessKeyId"
        | "RequestTimeTooSkewed" => Some(403),
        "BucketAlreadyExists" | "BucketNotEmpty" => Some(409),
        "InvalidRange" => Some(416),
        "EntityTooSmall"
        | "MalformedXML"
        | "InvalidBucketName"
        | "AuthorizationHeaderMalformed"
        | "InvalidArgument" => Some(400),
        "SlowDown" => Some(503),
        "NotImplemented" => Some(501),
        INTERNAL_ERROR_CODE => Some(500),
        _ => None,
    }
}

fn normalize_error_parts<'a>(code: &'a str, message: &'a str) -> (&'a str, &'a str) {
    if known_status_for_s3_code(code).is_some() {
        (code, message)
    } else {
        (INTERNAL_ERROR_CODE, INTERNAL_ERROR_MESSAGE)
    }
}

/// Build a complete S3 error response from error details.
pub fn s3_error_response(
    code: &str,
    message: &str,
    resource: &str,
    request_id: &str,
) -> S3ErrorResponse {
    let (code, message) = normalize_error_parts(code, message);
    S3ErrorResponse {
        status: status_for_s3_code(code),
        body: s3_xml::error_response(code, message, resource, request_id),
    }
}

/// Build a generic S3 internal-error response without leaking server details.
pub fn internal_error_response(resource: &str, request_id: &str) -> S3ErrorResponse {
    s3_error_response(
        INTERNAL_ERROR_CODE,
        INTERNAL_ERROR_MESSAGE,
        resource,
        request_id,
    )
}

/// Convert a `ProxyError` into an S3 error response.
pub fn from_proxy_error(_err: &ProxyError, resource: &str, request_id: &str) -> S3ErrorResponse {
    internal_error_response(resource, request_id)
}

/// Convert an `S3AuthError` into an S3 error response.
pub fn from_auth_error(err: &S3AuthError, resource: &str, request_id: &str) -> S3ErrorResponse {
    let (code, message) = match err {
        S3AuthError::SignatureDoesNotMatch => ("SignatureDoesNotMatch", err.to_string()),
        S3AuthError::InvalidAccessKeyId => ("InvalidAccessKeyId", err.to_string()),
        S3AuthError::RequestTimeTooSkewed => ("RequestTimeTooSkewed", err.to_string()),
        S3AuthError::AccountDisabled => ("AccessDenied", err.to_string()),
        S3AuthError::MalformedAuth(_) => ("AuthorizationHeaderMalformed", err.to_string()),
        S3AuthError::Internal(_) => return internal_error_response(resource, request_id),
    };
    s3_error_response(code, &message, resource, request_id)
}

#[derive(Default)]
struct GarageErrorBuilder {
    code: Option<String>,
    message: Option<String>,
    resource: Option<String>,
    request_id: Option<String>,
}

impl GarageErrorBuilder {
    fn record(&mut self, open_tags: &[Vec<u8>], value: String) {
        let slot = match open_tags {
            [root, field] if root.as_slice() == b"Error" => match field.as_slice() {
                b"Code" => &mut self.code,
                b"Message" => &mut self.message,
                b"Resource" => &mut self.resource,
                b"RequestId" => &mut self.request_id,
                _ => return,
            },
            _ => return,
        };
        *slot = Some(value);
    }

    fn build(self) -> Option<ParsedGarageError> {
        Some(ParsedGarageError {
            code: non_empty_value(self.code)?,
            message: non_empty_value(self.message)?,
            resource: non_empty_value(self.resource),
            request_id: non_empty_value(self.request_id),
        })
    }
}

struct ParsedGarageError {
    code: String,
    message: String,
    resource: Option<String>,
    request_id: Option<String>,
}

/// Parses a Garage `<Error>` XML response body using a streaming
/// `quick_xml` reader. Extracts `Code`, `Message`, `Resource`, and
/// `RequestId` fields. Returns `None` if the XML is malformed, missing
/// the `<Error>` root, or lacks a non-empty `Code` and `Message`.
fn parse_garage_error_xml(xml: &str) -> Option<ParsedGarageError> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);

    let mut open_tags = Vec::<Vec<u8>>::new();
    let mut saw_error_root = false;
    let mut closed_error_root = false;
    let mut builder = GarageErrorBuilder::default();

    loop {
        match reader.read_event() {
            Ok(Event::Start(start)) => {
                let tag = start.name().as_ref().to_vec();
                if open_tags.is_empty() {
                    if saw_error_root || tag.as_slice() != b"Error" {
                        return None;
                    }
                    saw_error_root = true;
                }
                open_tags.push(tag);
            }
            Ok(Event::Empty(_empty)) => {
                if open_tags.is_empty() || closed_error_root {
                    return None;
                }
            }
            Ok(Event::Text(text)) => {
                let value = text.unescape().ok()?.into_owned();
                if open_tags.is_empty() {
                    if value.is_empty() {
                        continue;
                    }
                    return None;
                }
                builder.record(&open_tags, value);
            }
            Ok(Event::CData(text)) => {
                let value = text.decode().ok()?.into_owned();
                if open_tags.is_empty() {
                    return None;
                }
                builder.record(&open_tags, value);
            }
            Ok(Event::End(end)) => {
                let open_tag = open_tags.pop()?;
                if open_tag.as_slice() != end.name().as_ref() {
                    return None;
                }
                if open_tags.is_empty() {
                    closed_error_root = true;
                }
            }
            Ok(Event::Eof) => {
                if open_tags.is_empty() && closed_error_root {
                    break;
                }
                return None;
            }
            Err(_) => return None,
            _ => {}
        }
    }

    builder.build()
}

fn non_empty_value(value: Option<String>) -> Option<String> {
    value.and_then(|value| (!value.is_empty()).then_some(value))
}
