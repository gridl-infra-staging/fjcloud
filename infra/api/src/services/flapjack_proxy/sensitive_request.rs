use std::fmt;

use super::{FlapjackHttpResponse, ProxyError};
use zeroize::{Zeroize, Zeroizing};

/// A credential-bearing request view whose body cannot outlive the transport
/// call. Transports may inspect or serialize it while sending, but cannot
/// retain the service-owned buffer.
pub struct SensitiveFlapjackHttpRequest<'a> {
    pub method: reqwest::Method,
    pub url: &'a str,
    pub api_key: &'a str,
    pub json_body: &'a str,
    #[cfg(test)]
    pub body_drop_probe: Option<std::sync::Arc<std::sync::atomic::AtomicU8>>,
}

impl fmt::Debug for SensitiveFlapjackHttpRequest<'_> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SensitiveFlapjackHttpRequest")
            .field("method", &self.method)
            .field("url", &self.url)
            .field("api_key", &"<redacted>")
            .field("json_body", &"<redacted>")
            .finish()
    }
}

pub(super) async fn send(
    client: &reqwest::Client,
    request: SensitiveFlapjackHttpRequest<'_>,
) -> Result<FlapjackHttpResponse, ProxyError> {
    let body = reqwest::Body::from(bytes::Bytes::from_owner(SensitiveRequestBody::new(
        request.json_body,
        #[cfg(test)]
        request.body_drop_probe.clone(),
    )));
    let req = client
        .request(request.method, request.url)
        .header("X-Algolia-API-Key", request.api_key)
        .header("X-Algolia-Application-Id", "flapjack")
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(body);

    let resp = req.send().await.map_err(|error| {
        if error.is_timeout() {
            ProxyError::Timeout
        } else {
            ProxyError::Unreachable(error.to_string())
        }
    })?;
    let status = resp.status().as_u16();
    let body = resp.text().await.map_err(|error| {
        ProxyError::Unreachable(format!("failed to read response body: {error}"))
    })?;

    Ok(FlapjackHttpResponse {
        status,
        body,
        request_api_key: request.api_key.to_owned(),
    })
}

struct SensitiveRequestBody {
    bytes: Zeroizing<Vec<u8>>,
    #[cfg(test)]
    drop_probe: Option<std::sync::Arc<std::sync::atomic::AtomicU8>>,
}

impl SensitiveRequestBody {
    fn new(
        json_body: &str,
        #[cfg(test)] drop_probe: Option<std::sync::Arc<std::sync::atomic::AtomicU8>>,
    ) -> Self {
        Self {
            bytes: Zeroizing::new(json_body.as_bytes().to_vec()),
            #[cfg(test)]
            drop_probe,
        }
    }
}

impl AsRef<[u8]> for SensitiveRequestBody {
    fn as_ref(&self) -> &[u8] {
        self.bytes.as_slice()
    }
}

impl Drop for SensitiveRequestBody {
    fn drop(&mut self) {
        self.bytes.zeroize();
        #[cfg(test)]
        if let Some(probe) = &self.drop_probe {
            let was_zeroized = self.bytes.iter().all(|byte| *byte == 0);
            probe.store(
                if was_zeroized { 1 } else { 2 },
                std::sync::atomic::Ordering::SeqCst,
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU8, Ordering};
    use std::sync::Arc;

    use super::*;

    #[tokio::test]
    async fn transport_owned_body_clone_is_zeroized_after_send() {
        let probe = Arc::new(AtomicU8::new(0));
        let _ = send(
            &reqwest::Client::new(),
            SensitiveFlapjackHttpRequest {
                method: reqwest::Method::POST,
                url: "http://127.0.0.1:1/1/migrations/algolia",
                api_key: "admin-key",
                json_body: r#"{"appId":"source-app","apiKey":"source-secret","sourceIndex":"products","overwrite":false}"#,
                body_drop_probe: Some(probe.clone()),
            },
        )
        .await;

        assert_eq!(probe.load(Ordering::SeqCst), 1);
    }
}
