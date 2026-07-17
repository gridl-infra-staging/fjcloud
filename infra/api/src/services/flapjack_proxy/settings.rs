//! Settings normalization for the Flapjack search-engine proxy.
use super::{FlapjackProxy, ProxyError};
use serde_json::{Map, Value};

fn mirror_array_field(settings: &mut Map<String, Value>, canonical_key: &str, engine_key: &str) {
    if !settings.contains_key(canonical_key) {
        if let Some(Value::Array(values)) = settings.get(engine_key) {
            settings.insert(canonical_key.to_string(), Value::Array(values.clone()));
        }
    }

    if let Some(Value::Array(values)) = settings.get(canonical_key) {
        settings.insert(engine_key.to_string(), Value::Array(values.clone()));
    }
}

fn normalize_index_settings_for_dashboard(settings: Value) -> Value {
    let Value::Object(mut object) = settings else {
        return settings;
    };

    mirror_array_field(&mut object, "filterableAttributes", "attributesForFaceting");
    mirror_array_field(&mut object, "displayedAttributes", "attributesToRetrieve");

    Value::Object(object)
}

fn normalize_index_settings_for_engine(settings: Value) -> Value {
    let Value::Object(mut object) = settings else {
        return settings;
    };

    if let Some(Value::Array(values)) = object.get("filterableAttributes") {
        object.insert(
            "attributesForFaceting".to_string(),
            Value::Array(values.clone()),
        );
    }
    if let Some(Value::Array(values)) = object.get("displayedAttributes") {
        object.insert(
            "attributesToRetrieve".to_string(),
            Value::Array(values.clone()),
        );
    }

    Value::Object(object)
}

impl FlapjackProxy {
    /// GET /1/indexes/{index_name}/settings
    pub async fn get_index_settings(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/indexes/{index_name}/settings");

        let resp = self
            .send_authenticated_request(reqwest::Method::GET, url, api_key, None)
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        let settings: Value =
            Self::parse_json_response(&resp.body, "failed to parse settings response")?;
        Ok(normalize_index_settings_for_dashboard(settings))
    }

    /// POST /1/indexes/{index_name}/settings — partial-merge update of index settings.
    pub async fn update_index_settings(
        &self,
        flapjack_url: &str,
        node_id: &str,
        region: &str,
        index_name: &str,
        settings: serde_json::Value,
    ) -> Result<serde_json::Value, ProxyError> {
        let api_key = self.get_admin_key(node_id, region).await?;
        let url = format!("{flapjack_url}/1/indexes/{index_name}/settings");

        let normalized_settings = normalize_index_settings_for_engine(settings);
        let resp = self
            .send_authenticated_request(
                reqwest::Method::POST,
                url,
                api_key,
                Some(normalized_settings),
            )
            .await?;
        Self::check_response_status(resp.status, &resp.body)?;

        Self::parse_json_response(&resp.body, "failed to parse settings update response")
    }
}
