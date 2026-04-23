//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/cold_tier/node_client.rs.
use async_trait::async_trait;

use super::ColdTierError;
use crate::services::flapjack_node::{
    FLAPJACK_APP_ID_HEADER, FLAPJACK_APP_ID_VALUE, FLAPJACK_AUTH_HEADER,
};

/// HTTP client abstraction for flapjack node operations (export/delete/import/verify).
/// Separate from FlapjackHttpClient (which is string-oriented for proxy use)
/// because export/import handle raw bytes.
#[async_trait]
pub trait FlapjackNodeClient: Send + Sync {
    /// Download an index export tarball from a flapjack node.
    async fn export_index(
        &self,
        flapjack_url: &str,
        index_name: &str,
        api_key: &str,
    ) -> Result<Vec<u8>, ColdTierError>;

    /// Delete an index from a flapjack node.
    async fn delete_index(
        &self,
        flapjack_url: &str,
        index_name: &str,
        api_key: &str,
    ) -> Result<(), ColdTierError>;

    /// Import an index tarball onto a flapjack node.
    async fn import_index(
        &self,
        flapjack_url: &str,
        index_name: &str,
        data: &[u8],
        api_key: &str,
    ) -> Result<(), ColdTierError>;

    /// Verify an index is queryable on a flapjack node.
    async fn verify_index(
        &self,
        flapjack_url: &str,
        index_name: &str,
        api_key: &str,
    ) -> Result<(), ColdTierError>;
}

/// Production implementation using reqwest.
pub struct ReqwestNodeClient {
    client: reqwest::Client,
}

impl ReqwestNodeClient {
    pub fn new(client: reqwest::Client) -> Self {
        Self { client }
    }

    fn with_node_auth(request: reqwest::RequestBuilder, api_key: &str) -> reqwest::RequestBuilder {
        request
            .header(FLAPJACK_AUTH_HEADER, api_key)
            .header(FLAPJACK_APP_ID_HEADER, FLAPJACK_APP_ID_VALUE)
    }
}

/// Builds a flapjack node URL for an index operation by appending
/// `/1/indexes/{index_name}` (plus optional trailing segments) to the base
/// URL. The index name is percent-encoded as a single path segment to
/// prevent path-traversal attacks. Strips any query or fragment from the
/// base URL.
fn build_index_operation_url<F>(
    flapjack_url: &str,
    index_name: &str,
    trailing_segments: &[&str],
    map_error: F,
) -> Result<reqwest::Url, ColdTierError>
where
    F: Fn(String) -> ColdTierError,
{
    let mut url = reqwest::Url::parse(flapjack_url)
        .map_err(|e| map_error(format!("invalid flapjack URL: {e}")))?;
    url.set_query(None);
    url.set_fragment(None);

    {
        let mut path_segments = url
            .path_segments_mut()
            .map_err(|_| map_error("flapjack URL cannot be used as a base URL".to_string()))?;
        path_segments.push("1");
        path_segments.push("indexes");
        path_segments.push(index_name);

        for segment in trailing_segments {
            path_segments.push(segment);
        }
    }

    Ok(url)
}

#[async_trait]
impl FlapjackNodeClient for ReqwestNodeClient {
    /// Downloads an index export tarball from the flapjack node's
    /// `/1/indexes/{name}/export` endpoint. Returns the raw bytes on
    /// success or a [`ColdTierError::Export`] on HTTP or transport failure.
    async fn export_index(
        &self,
        flapjack_url: &str,
        index_name: &str,
        api_key: &str,
    ) -> Result<Vec<u8>, ColdTierError> {
        let url = build_index_operation_url(
            flapjack_url,
            index_name,
            &["export"],
            ColdTierError::Export,
        )?;
        let resp = Self::with_node_auth(self.client.get(url), api_key)
            .send()
            .await
            .map_err(|e| ColdTierError::Export(format!("export request failed: {e}")))?;

        if !resp.status().is_success() {
            return Err(ColdTierError::Export(format!(
                "export returned HTTP {}",
                resp.status()
            )));
        }

        resp.bytes()
            .await
            .map(|b| b.to_vec())
            .map_err(|e| ColdTierError::Export(format!("failed reading export body: {e}")))
    }

    /// Deletes an index from the flapjack node via `DELETE /1/indexes/{name}`.
    /// Returns a [`ColdTierError::Evict`] on HTTP or transport failure.
    async fn delete_index(
        &self,
        flapjack_url: &str,
        index_name: &str,
        api_key: &str,
    ) -> Result<(), ColdTierError> {
        let url = build_index_operation_url(flapjack_url, index_name, &[], ColdTierError::Evict)?;
        let resp = Self::with_node_auth(self.client.delete(url), api_key)
            .send()
            .await
            .map_err(|e| ColdTierError::Evict(format!("delete request failed: {e}")))?;

        if !resp.status().is_success() {
            return Err(ColdTierError::Evict(format!(
                "delete returned HTTP {}",
                resp.status()
            )));
        }
        Ok(())
    }

    /// Uploads an index tarball to the flapjack node via
    /// `POST /1/indexes/{name}/import`. Returns a [`ColdTierError::Import`]
    /// on HTTP or transport failure.
    async fn import_index(
        &self,
        flapjack_url: &str,
        index_name: &str,
        data: &[u8],
        api_key: &str,
    ) -> Result<(), ColdTierError> {
        let url = build_index_operation_url(
            flapjack_url,
            index_name,
            &["import"],
            ColdTierError::Import,
        )?;
        let resp = Self::with_node_auth(self.client.post(url), api_key)
            .body(data.to_vec())
            .send()
            .await
            .map_err(|e| ColdTierError::Import(format!("import request failed: {e}")))?;

        if !resp.status().is_success() {
            return Err(ColdTierError::Import(format!(
                "import returned HTTP {}",
                resp.status()
            )));
        }
        Ok(())
    }

    /// Verifies that an index is queryable on the flapjack node via
    /// `POST /1/indexes/{name}/query`. Returns a [`ColdTierError::Verify`] if
    /// the index is not accessible or the request fails.
    async fn verify_index(
        &self,
        flapjack_url: &str,
        index_name: &str,
        api_key: &str,
    ) -> Result<(), ColdTierError> {
        let url =
            build_index_operation_url(flapjack_url, index_name, &["query"], ColdTierError::Verify)?;
        let resp = Self::with_node_auth(self.client.post(url), api_key)
            .json(&serde_json::json!({ "query": "" }))
            .send()
            .await
            .map_err(|e| ColdTierError::Verify(format!("verify request failed: {e}")))?;

        if !resp.status().is_success() {
            return Err(ColdTierError::Verify(format!(
                "verify returned HTTP {}",
                resp.status()
            )));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Confirms that a malicious index name containing path-traversal sequences,
    /// query parameters, and fragments is percent-encoded as a single path
    /// segment rather than rejected or interpreted literally.
    #[test]
    fn build_index_operation_url_encodes_index_name_as_a_single_path_segment() {
        let url = build_index_operation_url(
            "https://node.example",
            "tenant/../../admin?token=secret#frag",
            &["export"],
            ColdTierError::Export,
        )
        .expect("dangerous index names should be encoded, not rejected");

        assert_eq!(
            url.as_str(),
            "https://node.example/1/indexes/tenant%2F..%2F..%2Fadmin%3Ftoken=secret%23frag/export"
        );
        assert_eq!(url.query(), None);
        assert_eq!(url.fragment(), None);
    }
}
