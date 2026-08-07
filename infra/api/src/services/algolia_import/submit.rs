//! Engine submit target, request serialization, and engine-error decoding.
use std::fmt;

use serde::Serialize;
use zeroize::{Zeroize, Zeroizing};

use crate::models::algolia_import_job::SourceImportProvider;
use crate::services::flapjack_proxy::ProxyError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineTarget {
    pub(super) flapjack_url: String,
    pub(super) node_id: String,
    pub(super) region: String,
}

impl EngineTarget {
    pub fn new(
        flapjack_url: impl Into<String>,
        node_id: impl Into<String>,
        region: impl Into<String>,
    ) -> Self {
        Self {
            flapjack_url: flapjack_url.into(),
            node_id: node_id.into(),
            region: region.into(),
        }
    }
}

pub struct AlgoliaImportSubmitRequest {
    pub(super) source_provider: SourceImportProvider,
    source_connection_id: Zeroizing<String>,
    api_key: Zeroizing<String>,
    source_index: String,
    target_index: Option<String>,
    overwrite: bool,
    #[cfg(test)]
    wipe_probe: Option<std::sync::Arc<std::sync::atomic::AtomicU8>>,
}

impl AlgoliaImportSubmitRequest {
    pub fn new(
        source_provider: SourceImportProvider,
        source_connection_id: String,
        api_key: Zeroizing<String>,
        source_index: String,
        target_index: Option<String>,
        overwrite: bool,
    ) -> Self {
        Self {
            source_provider,
            source_connection_id: Zeroizing::new(source_connection_id),
            api_key,
            source_index,
            target_index,
            overwrite,
            #[cfg(test)]
            wipe_probe: None,
        }
    }

    pub(super) fn into_payload(self) -> AlgoliaImportSubmitPayload {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct AlgoliaWireRequest<'a> {
            app_id: &'a str,
            api_key: &'a str,
            source_index: &'a str,
            #[serde(skip_serializing_if = "Option::is_none")]
            target_index: Option<&'a str>,
            overwrite: bool,
        }

        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct MeilisearchWireRequest<'a> {
            endpoint: &'a str,
            api_key: &'a str,
            source_index: &'a str,
            #[serde(skip_serializing_if = "Option::is_none")]
            target_index: Option<&'a str>,
            overwrite: bool,
        }

        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct TypesenseWireRequest<'a> {
            node: &'a str,
            api_key: &'a str,
            source_index: &'a str,
            #[serde(skip_serializing_if = "Option::is_none")]
            target_index: Option<&'a str>,
            overwrite: bool,
        }

        let api_key = self.api_key.as_str();
        let source_index = self.source_index.as_str();
        let target_index = self.target_index.as_deref();
        let overwrite = self.overwrite;
        let json = match self.source_provider {
            SourceImportProvider::Algolia => serde_json::to_string(&AlgoliaWireRequest {
                app_id: self.source_connection_id.as_str(),
                api_key,
                source_index,
                target_index,
                overwrite,
            }),
            SourceImportProvider::Meilisearch => serde_json::to_string(&MeilisearchWireRequest {
                endpoint: self.source_connection_id.as_str(),
                api_key,
                source_index,
                target_index,
                overwrite,
            }),
            SourceImportProvider::Typesense => serde_json::to_string(&TypesenseWireRequest {
                node: self.source_connection_id.as_str(),
                api_key,
                source_index,
                target_index,
                overwrite,
            }),
        };
        let json = json.expect("serializing the import wire request cannot fail");
        AlgoliaImportSubmitPayload {
            json: Zeroizing::new(json),
            #[cfg(test)]
            wipe_probe: self.wipe_probe.clone(),
        }
    }

    #[cfg(test)]
    pub(super) fn with_wipe_probe(
        mut self,
        probe: std::sync::Arc<std::sync::atomic::AtomicU8>,
    ) -> Self {
        self.wipe_probe = Some(probe);
        self
    }
}

pub(crate) struct AlgoliaImportSubmitPayload {
    json: Zeroizing<String>,
    #[cfg(test)]
    wipe_probe: Option<std::sync::Arc<std::sync::atomic::AtomicU8>>,
}

impl AlgoliaImportSubmitPayload {
    pub(crate) fn as_json(&self) -> &str {
        self.json.as_str()
    }
}

impl Drop for AlgoliaImportSubmitPayload {
    fn drop(&mut self) {
        self.json.zeroize();
        #[cfg(test)]
        if let Some(probe) = &self.wipe_probe {
            let was_zeroized = self.json.as_bytes().iter().all(|byte| *byte == 0);
            probe.store(
                if was_zeroized { 1 } else { 2 },
                std::sync::atomic::Ordering::SeqCst,
            );
        }
    }
}

impl fmt::Debug for AlgoliaImportSubmitRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AlgoliaImportSubmitRequest")
            .field("source_provider", &self.source_provider)
            .field("source_connection_id", &"<redacted>")
            .field("api_key", &"<redacted>")
            .field("source_index", &"<redacted>")
            .field("target_index", &self.target_index)
            .field("overwrite", &self.overwrite)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AlgoliaImportEngineError {
    #[error("engine request failed with HTTP {status}")]
    Engine { status: u16, code: Option<String> },
    #[error("malformed engine response: {0}")]
    MalformedResponse(String),
    #[error("engine transport failed: {0}")]
    Transport(String),
}

impl AlgoliaImportEngineError {
    pub(super) fn from_proxy(error: ProxyError) -> Self {
        match error {
            ProxyError::FlapjackError {
                status: 200,
                message,
            } => Self::MalformedResponse(message),
            ProxyError::FlapjackError { status, message } => Self::Engine {
                status,
                code: parse_error_code(&message),
            },
            ProxyError::Unreachable(message) | ProxyError::SecretError(message) => {
                Self::Transport(message)
            }
            ProxyError::Timeout => Self::Transport("request timed out".to_string()),
        }
    }
}

fn parse_error_code(message: &str) -> Option<String> {
    serde_json::from_str::<serde_json::Value>(message)
        .ok()
        .and_then(|value| {
            value
                .get("code")
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned)
        })
}
