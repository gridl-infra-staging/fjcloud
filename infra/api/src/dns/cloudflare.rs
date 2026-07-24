use async_trait::async_trait;
use chrono::{DateTime, Utc};
use reqwest::Client;
use serde::Deserialize;
use serde_json::{json, Value};

use super::{hostname_for_domain, DnsARecord, DnsError, DnsManager};

const CLOUDFLARE_API_BASE: &str = "https://api.cloudflare.com/client/v4";
const CLOUDFLARE_LIST_PAGE_SIZE: u32 = 100;

#[derive(Deserialize)]
struct CloudflareARecord {
    name: String,
    created_on: DateTime<Utc>,
}

#[derive(Deserialize)]
struct CloudflareResultInfo {
    page: u32,
    total_pages: u32,
}

#[derive(Deserialize)]
struct CloudflareListPage {
    result: Vec<CloudflareARecord>,
    result_info: CloudflareResultInfo,
}

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

    async fn list_a_records(&self) -> Result<Vec<DnsARecord>, DnsError> {
        let mut page_number = 1;
        let mut records = Vec::new();

        loop {
            let body = self
                .request_json(
                    self.client.get(self.records_endpoint()).query(&[
                        ("type", "A".to_string()),
                        ("page", page_number.to_string()),
                        ("per_page", CLOUDFLARE_LIST_PAGE_SIZE.to_string()),
                    ]),
                    "list",
                )
                .await?;
            let page: CloudflareListPage = serde_json::from_value(body).map_err(|error| {
                DnsError::Api(format!("Cloudflare list response is incomplete: {error}"))
            })?;
            if page.result_info.page != page_number
                || page.result_info.total_pages < page.result_info.page
            {
                return Err(DnsError::Api(format!(
                    "Cloudflare list pagination is inconsistent at page {page_number}"
                )));
            }
            records.extend(page.result.into_iter().map(|record| DnsARecord {
                hostname: record.name.trim_end_matches('.').to_string(),
                created_at: record.created_on,
            }));

            if page_number == page.result_info.total_pages {
                return Ok(records);
            }
            page_number += 1;
        }
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

    #[tokio::test]
    async fn orphan_report_cloudflare_listing_exhausts_all_a_record_pages() {
        let server = MockServer::start().await;
        for (page, hostname) in [
            (1, "vm-shared-first.flapjack.foo"),
            (2, "vm-shared-second.flapjack.foo"),
        ] {
            Mock::given(method("GET"))
                .and(path("/client/v4/zones/zone_123/dns_records"))
                .and(query_param("type", "A"))
                .and(query_param("page", page.to_string()))
                .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                    "success": true,
                    "errors": [],
                    "result": [{
                        "id": format!("record_{page}"),
                        "name": hostname,
                        "type": "A",
                        "created_on": "2026-07-20T12:00:00Z"
                    }],
                    "result_info": {
                        "page": page,
                        "per_page": 100,
                        "count": 1,
                        "total_count": 2,
                        "total_pages": 2
                    }
                })))
                .expect(1)
                .mount(&server)
                .await;
        }

        let manager = CloudflareDnsManager::with_api_base(
            Client::new(),
            "token_123".to_string(),
            "zone_123".to_string(),
            "flapjack.foo".to_string(),
            format!("{}/client/v4", server.uri()),
        );

        let records = manager
            .list_a_records()
            .await
            .expect("all Cloudflare pages should be listed");

        assert_eq!(records.len(), 2);
        assert_eq!(records[0].hostname, "vm-shared-first.flapjack.foo");
        assert_eq!(records[1].hostname, "vm-shared-second.flapjack.foo");
    }
}
