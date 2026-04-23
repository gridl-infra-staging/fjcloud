use super::{FlapjackProxy, ProxyError};

impl FlapjackProxy {
    /// GET /1/configs/{index_name} — get query suggestions config.
    pub async fn get_qs_config(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/configs/{index_name}");

        let resp = self
            .send_authenticated_request(reqwest::Method::GET, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(
            &resp.body,
            "failed to parse get query suggestions config response",
        )
    }

    /// Upsert query suggestions config:
    /// 1) PUT /1/configs/{index_name}
    /// 2) if 404, POST /1/configs with body containing indexName.
    pub async fn upsert_qs_config(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
        config: serde_json::Value,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let put_url = format!("{flapjack_url}/1/configs/{index_name}");

        let put_resp = self
            .send_authenticated_request(
                reqwest::Method::PUT,
                put_url,
                api_key.clone(),
                Some(config.clone()),
            )
            .await?;

        if put_resp.status == 404 {
            let post_url = format!("{flapjack_url}/1/configs");
            let post_body = match config {
                serde_json::Value::Object(mut map) => {
                    map.insert("indexName".to_string(), serde_json::json!(index_name));
                    serde_json::Value::Object(map)
                }
                other => serde_json::json!({
                    "indexName": index_name,
                    "config": other
                }),
            };

            let post_resp = self
                .send_authenticated_request(
                    reqwest::Method::POST,
                    post_url,
                    api_key,
                    Some(post_body),
                )
                .await?;
            Self::check_response_status(post_resp.status, &post_resp.body)?;

            return Self::parse_json_response(
                &post_resp.body,
                "failed to parse create query suggestions config response",
            );
        }

        Self::check_response_status(put_resp.status, &put_resp.body)?;
        Self::parse_json_response(
            &put_resp.body,
            "failed to parse update query suggestions config response",
        )
    }

    /// GET /1/configs/{index_name}/status — get query suggestions build status.
    pub async fn get_qs_status(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/configs/{index_name}/status");

        let resp = self
            .send_authenticated_request(reqwest::Method::GET, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(
            &resp.body,
            "failed to parse get query suggestions status response",
        )
    }

    /// DELETE /1/configs/{index_name} — delete query suggestions config.
    pub async fn delete_qs_config(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/configs/{index_name}");

        let resp = self
            .send_authenticated_request(reqwest::Method::DELETE, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(
            &resp.body,
            "failed to parse delete query suggestions config response",
        )
    }
}
