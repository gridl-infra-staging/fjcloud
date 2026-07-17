use async_trait::async_trait;
use reqwest::Client;
use serde_json::{json, Value};

use super::{hostname_for_domain, DnsError, DnsManager};

const CLOUDFLARE_API_BASE: &str = "https://api.cloudflare.com/client/v4";

pub struct CloudflareDnsManager {
    client: Client,
    api_token: String,
    zone_id: String,
    domain: String,
    api_base: String,
}

impl CloudflareDnsManager {
    pub fn new(client: Client, api_token: String, zone_id: String, domain: String) -> Self {
        Self {
            client,
            api_token,
            zone_id,
            domain,
            api_base: CLOUDFLARE_API_BASE.to_string(),
        }
    }

    #[cfg(test)]
    fn with_api_base(
        client: Client,
        api_token: String,
        zone_id: String,
        domain: String,
        api_base: String,
    ) -> Self {
        Self {
            client,
            api_token,
            zone_id,
            domain,
            api_base,
        }
    }

    fn hostname(&self, hostname: &str) -> String {
        hostname_for_domain(&self.domain, hostname)
    }

    fn records_endpoint(&self) -> String {
        format!("{}/zones/{}/dns_records", self.api_base, self.zone_id)
    }

    async fn request_json(
        &self,
        request: reqwest::RequestBuilder,
        action: &str,
    ) -> Result<Value, DnsError> {
        let response = request
            .bearer_auth(&self.api_token)
            .send()
            .await
            .map_err(|e| DnsError::Api(format!("Cloudflare {action} request failed: {e}")))?;
        let status = response.status();
        let body: Value = response.json().await.map_err(|e| {
            DnsError::Api(format!("Cloudflare {action} response parse failed: {e}"))
        })?;

        if body.get("success").and_then(Value::as_bool) == Some(true) {
            return Ok(body);
        }

        let errors = body
            .get("errors")
            .and_then(Value::as_array)
            .map(|entries| {
                entries
                    .iter()
                    .filter_map(|entry| entry.get("message").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("; ")
            })
            .filter(|message| !message.is_empty())
            .unwrap_or_else(|| format!("HTTP {status}"));

        Err(DnsError::Api(format!(
            "Cloudflare {action} API error: {errors}"
        )))
    }

    async fn lookup_record_id(&self, hostname: &str) -> Result<Option<String>, DnsError> {
        let fqdn = self.hostname(hostname);
        let body = self
            .request_json(
                self.client
                    .get(self.records_endpoint())
                    .query(&[("type", "A"), ("name", fqdn.as_str())]),
                "lookup",
            )
            .await?;

        Ok(body
            .get("result")
            .and_then(Value::as_array)
            .and_then(|records| records.first())
            .and_then(|record| record.get("id"))
            .and_then(Value::as_str)
            .map(str::to_string))
    }
}

#[async_trait]
impl DnsManager for CloudflareDnsManager {
    async fn create_record(&self, hostname: &str, ip: &str) -> Result<(), DnsError> {
        let fqdn = self.hostname(hostname);
        let payload = json!({
            "type": "A",
            "name": fqdn,
            "content": ip,
            "ttl": 300,
            "proxied": false,
        });

        if let Some(record_id) = self.lookup_record_id(hostname).await? {
            self.request_json(
                self.client
                    .put(format!("{}/{}", self.records_endpoint(), record_id))
                    .json(&payload),
                "update",
            )
            .await?;
        } else {
            self.request_json(
                self.client.post(self.records_endpoint()).json(&payload),
                "create",
            )
            .await?;
        }

        Ok(())
    }

    async fn delete_record(&self, hostname: &str) -> Result<(), DnsError> {
        let Some(record_id) = self.lookup_record_id(hostname).await? else {
            return Ok(());
        };

        self.request_json(
            self.client
                .delete(format!("{}/{}", self.records_endpoint(), record_id)),
            "delete",
        )
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{header, method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn create_record_creates_new_a_record_when_missing() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/client/v4/zones/zone_123/dns_records"))
            .and(query_param("type", "A"))
            .and(query_param("name", "vm-test.flapjack.foo"))
            .and(header("authorization", "Bearer token_123"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "success": true,
                "errors": [],
                "result": [],
            })))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/client/v4/zones/zone_123/dns_records"))
            .and(header("authorization", "Bearer token_123"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "success": true,
                "errors": [],
                "result": {"id": "new_record"},
            })))
            .mount(&server)
            .await;

        let manager = CloudflareDnsManager::with_api_base(
            Client::new(),
            "token_123".to_string(),
            "zone_123".to_string(),
            "flapjack.foo".to_string(),
            format!("{}/client/v4", server.uri()),
        );

        manager
            .create_record("vm-test.flapjack.foo", "203.0.113.10")
            .await
            .expect("create should succeed");
    }

    #[tokio::test]
    async fn delete_record_is_idempotent_when_record_is_missing() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/client/v4/zones/zone_123/dns_records"))
            .and(query_param("type", "A"))
            .and(query_param("name", "vm-missing.flapjack.foo"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "success": true,
                "errors": [],
                "result": [],
            })))
            .mount(&server)
            .await;

        let manager = CloudflareDnsManager::with_api_base(
            Client::new(),
            "token_123".to_string(),
            "zone_123".to_string(),
            "flapjack.foo".to_string(),
            format!("{}/client/v4", server.uri()),
        );

        manager
            .delete_record("vm-missing.flapjack.foo")
            .await
            .expect("delete should be idempotent when record does not exist");
    }
}
