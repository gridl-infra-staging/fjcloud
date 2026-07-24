use async_trait::async_trait;

#[async_trait]
pub trait WebhookHttpClient: Send + Sync {
    async fn get_text(&self, url: &str) -> Result<String, String>;
    async fn get_success(&self, url: &str) -> Result<(), String>;
}

pub struct ReqwestWebhookHttpClient {
    client: reqwest::Client,
}

impl ReqwestWebhookHttpClient {
    pub fn new(client: reqwest::Client) -> Self {
        Self { client }
    }
}

#[async_trait]
impl WebhookHttpClient for ReqwestWebhookHttpClient {
    async fn get_text(&self, url: &str) -> Result<String, String> {
        let response = self
            .client
            .get(url)
            .send()
            .await
            .map_err(|error| format!("webhook HTTP GET failed for {url}: {error}"))?;

        if !response.status().is_success() {
            return Err(format!(
                "webhook HTTP GET failed for {url}: status {}",
                response.status()
            ));
        }

        response
            .text()
            .await
            .map_err(|error| format!("webhook HTTP response body read failed for {url}: {error}"))
    }

    async fn get_success(&self, url: &str) -> Result<(), String> {
        let response = self
            .client
            .get(url)
            .send()
            .await
            .map_err(|error| format!("webhook HTTP GET failed for {url}: {error}"))?;

        if !response.status().is_success() {
            return Err(format!(
                "webhook HTTP GET failed for {url}: status {}",
                response.status()
            ));
        }

        Ok(())
    }
}
