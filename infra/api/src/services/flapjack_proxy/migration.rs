use crate::services::algolia_import::{AlgoliaImportSubmitPayload, AsyncMigrationStatusResponse};

use super::{FlapjackProxy, ProxyError};

impl FlapjackProxy {
    pub(crate) async fn submit_algolia_migration(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        body: AlgoliaImportSubmitPayload,
    ) -> Result<AsyncMigrationStatusResponse, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!(
            "{}/1/migrations/algolia",
            flapjack_url.trim_end_matches('/')
        );

        let resp = self
            .send_authenticated_sensitive_request(
                reqwest::Method::POST,
                &url,
                &api_key,
                body.as_json(),
            )
            .await?;
        // Committed linkage may only follow an exact engine `202 Accepted`. Any
        // other status — including a stray 2xx like 200/201/204 — is not a valid
        // async-submit acknowledgement and must never narrow ambiguous intent to
        // committed, so reject it here before the response body is trusted.
        if resp.status != 202 {
            return Err(ProxyError::FlapjackError {
                status: resp.status,
                message: resp.body,
            });
        }

        Self::parse_json_response(
            &resp.body,
            "failed to parse algolia migration submit response",
        )
    }

    pub async fn algolia_migration_status(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        engine_job_id: &str,
    ) -> Result<AsyncMigrationStatusResponse, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let job_id = Self::encode_path_segment(engine_job_id);
        let url = format!(
            "{}/1/migrations/algolia/{job_id}",
            flapjack_url.trim_end_matches('/')
        );

        let resp = self
            .send_authenticated_request(reqwest::Method::GET, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(
            &resp.body,
            "failed to parse algolia migration status response",
        )
    }

    pub async fn cancel_algolia_migration(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        engine_job_id: &str,
    ) -> Result<AsyncMigrationStatusResponse, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let job_id = Self::encode_path_segment(engine_job_id);
        let url = format!(
            "{}/1/migrations/algolia/{job_id}/cancel",
            flapjack_url.trim_end_matches('/')
        );

        let resp = self
            .send_authenticated_request(reqwest::Method::POST, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(
            &resp.body,
            "failed to parse algolia migration cancel response",
        )
    }

    pub async fn acknowledge_algolia_migration(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        engine_job_id: &str,
    ) -> Result<(), ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let job_id = Self::encode_path_segment(engine_job_id);
        let url = format!(
            "{}/1/migrations/algolia/{job_id}/acknowledge",
            flapjack_url.trim_end_matches('/')
        );

        let resp = self
            .send_authenticated_request(reqwest::Method::POST, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)
    }
}
