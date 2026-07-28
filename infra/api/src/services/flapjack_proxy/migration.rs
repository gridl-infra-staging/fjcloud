use uuid::Uuid;

use crate::models::SourceImportProvider;
use crate::services::algolia_import::{AlgoliaImportSubmitPayload, AsyncMigrationStatusResponse};

use super::{FlapjackHttpResponse, FlapjackProxy, ProxyError};

#[derive(Clone, Copy)]
struct MigrationTransportTarget<'a> {
    flapjack_url: &'a str,
    node_id: &'a str,
    region: &'a str,
}

impl<'a> MigrationTransportTarget<'a> {
    fn new(flapjack_url: &'a str, node_id: &'a str, region: &'a str) -> Self {
        Self {
            flapjack_url,
            node_id,
            region,
        }
    }
}

enum MigrationEngineRoute<'a> {
    Submit,
    Status(&'a str),
    Cancel(&'a str),
    Acknowledge(&'a str),
}

fn migration_url(
    flapjack_url: &str,
    source_provider: SourceImportProvider,
    route: MigrationEngineRoute<'_>,
) -> String {
    let base = format!(
        "{}/1/migrations/{}",
        flapjack_url.trim_end_matches('/'),
        source_provider.as_str()
    );
    match route {
        MigrationEngineRoute::Submit => base,
        MigrationEngineRoute::Status(engine_job_id) => {
            format!(
                "{base}/{}",
                FlapjackProxy::encode_path_segment(engine_job_id)
            )
        }
        MigrationEngineRoute::Cancel(engine_job_id) => format!(
            "{base}/{}/cancel",
            FlapjackProxy::encode_path_segment(engine_job_id)
        ),
        MigrationEngineRoute::Acknowledge(engine_job_id) => format!(
            "{base}/{}/acknowledge",
            FlapjackProxy::encode_path_segment(engine_job_id)
        ),
    }
}

impl FlapjackProxy {
    async fn submit_migration(
        &self,
        target: MigrationTransportTarget<'_>,
        source_provider: SourceImportProvider,
        body: AlgoliaImportSubmitPayload,
    ) -> Result<AsyncMigrationStatusResponse, ProxyError> {
        let api_key = self.get_admin_key(target.node_id, target.region).await?;
        let url = migration_url(
            target.flapjack_url,
            source_provider,
            MigrationEngineRoute::Submit,
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

    async fn migration_status(
        &self,
        target: MigrationTransportTarget<'_>,
        source_provider: SourceImportProvider,
        engine_job_id: &str,
    ) -> Result<AsyncMigrationStatusResponse, ProxyError> {
        let api_key = self.get_admin_key(target.node_id, target.region).await?;
        let url = migration_url(
            target.flapjack_url,
            source_provider,
            MigrationEngineRoute::Status(engine_job_id),
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

    async fn cancel_migration(
        &self,
        target: MigrationTransportTarget<'_>,
        source_provider: SourceImportProvider,
        engine_job_id: &str,
    ) -> Result<AsyncMigrationStatusResponse, ProxyError> {
        let api_key = self.get_admin_key(target.node_id, target.region).await?;
        let url = migration_url(
            target.flapjack_url,
            source_provider,
            MigrationEngineRoute::Cancel(engine_job_id),
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

    async fn acknowledge_migration(
        &self,
        target: MigrationTransportTarget<'_>,
        source_provider: SourceImportProvider,
        engine_job_id: &str,
    ) -> Result<(), ProxyError> {
        let api_key = self.get_admin_key(target.node_id, target.region).await?;
        let url = migration_url(
            target.flapjack_url,
            source_provider,
            MigrationEngineRoute::Acknowledge(engine_job_id),
        );

        let resp = self
            .send_authenticated_request(reqwest::Method::POST, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)
    }

    pub(crate) async fn submit_algolia_migration(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        body: AlgoliaImportSubmitPayload,
    ) -> Result<AsyncMigrationStatusResponse, ProxyError> {
        self.submit_migration(
            MigrationTransportTarget::new(flapjack_url, node_id, region),
            SourceImportProvider::Algolia,
            body,
        )
        .await
    }

    pub async fn algolia_migration_status(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        engine_job_id: &str,
    ) -> Result<AsyncMigrationStatusResponse, ProxyError> {
        self.migration_status(
            MigrationTransportTarget::new(flapjack_url, node_id, region),
            SourceImportProvider::Algolia,
            engine_job_id,
        )
        .await
    }

    pub async fn cancel_algolia_migration(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        engine_job_id: &str,
    ) -> Result<AsyncMigrationStatusResponse, ProxyError> {
        self.cancel_migration(
            MigrationTransportTarget::new(flapjack_url, node_id, region),
            SourceImportProvider::Algolia,
            engine_job_id,
        )
        .await
    }

    pub async fn acknowledge_algolia_migration(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        engine_job_id: &str,
    ) -> Result<(), ProxyError> {
        self.acknowledge_migration(
            MigrationTransportTarget::new(flapjack_url, node_id, region),
            SourceImportProvider::Algolia,
            engine_job_id,
        )
        .await
    }

    pub async fn privacy_scrub_algolia_migration(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        erasure_handle: Uuid,
    ) -> Result<FlapjackHttpResponse, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!(
            "{}/1/migrations/privacy-scrub",
            flapjack_url.trim_end_matches('/')
        );
        let body = serde_json::json!({
            "scrubId": erasure_handle,
            "tenant": format!("erased-{erasure_handle}"),
            "expectedGeneration": "erased-tombstone-v1",
            "objectIDs": [],
            "synonymIDs": [],
            "ruleIDs": []
        })
        .to_string();

        let resp = self
            .send_authenticated_sensitive_request(reqwest::Method::POST, &url, &api_key, &body)
            .await?;
        if resp.status != 202 {
            return Err(ProxyError::FlapjackError {
                status: resp.status,
                message: resp.body,
            });
        }
        Ok(resp)
    }
}
