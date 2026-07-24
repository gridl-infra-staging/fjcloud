use api::repos::PgAlgoliaImportJobRepo;
use serde::Deserialize;
use serde_json::Value;
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use std::net::IpAddr;
use std::path::PathBuf;
use std::process::Command;
use uuid::Uuid;

const LIVE_JOB_ID_ENV: &str = "ALGOLIA_IMPORT_CATALOG_LIVE_JOB_ID";
const LIVE_CUSTOMER_ID_ENV: &str = "ALGOLIA_IMPORT_CATALOG_LIVE_CUSTOMER_ID";
const LIVE_TARGET_INDEX_ENV: &str = "ALGOLIA_IMPORT_CATALOG_LIVE_TARGET_INDEX";
const LIVE_API_URL_ENV: &str = "ALGOLIA_IMPORT_CATALOG_LIVE_API_URL";
const LIVE_AUTH_CONFIG_ENV: &str = "ALGOLIA_IMPORT_CATALOG_LIVE_AUTH_CONFIG";
const LIVE_ADMIN_KEY_ENV: &str = "ALGOLIA_IMPORT_CATALOG_LIVE_ADMIN_KEY";
const LIVE_SELECTION_ENV: &str = "ALGOLIA_IMPORT_CATALOG_LIVE_SELECTION";
const LIVE_CALLER_KEY_ENV: &str = "ALGOLIA_IMPORT_CATALOG_LIVE_CALLER_KEY";
const WRITER_INVENTORY_JSON: &str =
    include_str!("../../../../scripts/tests/fixtures/catalog_lifecycle_writers.json");

/// In-process proof that a production scenario started and finished while the
/// catalog probe's exact import reservation remained active.
pub struct CatalogLiveBinding {
    selection: String,
    context: LiveContext,
    caller_mapping: Option<LiveCallerMapping>,
    pool: PgPool,
}

pub struct LiveCallerRefusal {
    source: Option<LiveCallerSource>,
}

struct LiveCallerSource {
    owner_path: String,
    source_anchor: String,
}

impl LiveCallerRefusal {
    pub fn with_source(mut self, owner_path: &str, source_anchor: &str) -> Self {
        self.source = Some(LiveCallerSource {
            owner_path: owner_path.to_string(),
            source_anchor: source_anchor.to_string(),
        });
        self
    }
}

impl CatalogLiveBinding {
    /// Returns `None` for ordinary isolated integration runs. When the catalog
    /// runner supplies any live context, every field becomes mandatory.
    pub async fn begin() -> Option<Self> {
        let context = LiveContext::from_env()?;
        let selection = required_env(LIVE_SELECTION_ENV);
        require_evidence_component(&selection, "selection");
        let caller_mapping = context
            .caller_key
            .as_deref()
            .map(|caller_key| require_live_caller_mapping(&selection, caller_key));
        observe_job_through_tenant_api(&context);
        let pool = PgPoolOptions::new()
            .max_connections(1)
            .connect(&required_env("DATABASE_URL"))
            .await
            .expect("connect to the catalog probe database");
        assert_active_reservation(&pool, &context).await;
        Some(Self {
            selection,
            context,
            caller_mapping,
            pool,
        })
    }

    /// Emits the sole binding record only after the scenario body has
    /// completed and the same canonical reservation is still active.
    pub async fn finish(self) {
        self.verify_active_and_emit_binding().await;
    }

    pub fn customer_id(&self) -> Uuid {
        self.context.customer_id
    }

    pub fn target_index(&self) -> &str {
        &self.context.target_index
    }

    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    pub fn caller_owner_path(&self) -> &str {
        &self
            .caller_mapping
            .as_ref()
            .expect("catalog live caller mapping is required for caller evidence")
            .owner_path
    }

    pub fn caller_source_anchor(&self) -> &str {
        &self
            .caller_mapping
            .as_ref()
            .expect("catalog live caller mapping is required for caller evidence")
            .source_anchor
    }

    pub fn confirm_destination_conflict(
        &self,
        refused: bool,
        caller_description: &str,
    ) -> LiveCallerRefusal {
        assert!(
            refused,
            "{caller_description} did not refuse the live import target with destination_conflict"
        );
        LiveCallerRefusal { source: None }
    }

    pub fn assert_tenant_destination_conflict(
        &self,
        method: &str,
        path: &str,
        body: &Value,
    ) -> LiveCallerRefusal {
        let url = format!("{}{}", self.context.api_url, path);
        let output = Command::new("curl")
            .args([
                "--silent",
                "--show-error",
                "--config",
                self.context
                    .auth_config
                    .to_str()
                    .expect("live auth config path must be valid Unicode"),
                "--header",
                "Content-Type: application/json",
                "--data",
                &body.to_string(),
                "--output",
                "-",
                "--write-out",
                "\n%{http_code}",
                "--request",
                method,
                &url,
            ])
            .output()
            .expect("execute tenant-scoped live catalog caller");
        assert!(
            output.status.success(),
            "tenant-scoped live catalog caller failed"
        );
        assert_destination_conflict_response(&output.stdout, "tenant-scoped live catalog caller");
        LiveCallerRefusal { source: None }
    }

    pub async fn assert_admin_destination_conflict(
        &self,
        path: &str,
        body: &Value,
    ) -> LiveCallerRefusal {
        let response = reqwest::Client::new()
            .post(format!("{}{}", self.context.api_url, path))
            .header("x-admin-key", &self.context.admin_key)
            .json(body)
            .send()
            .await
            .expect("execute admin-scoped live catalog caller");
        let status = response.status();
        let payload: Value = response
            .json()
            .await
            .expect("admin-scoped live catalog caller response must be JSON");
        assert_eq!(
            status,
            reqwest::StatusCode::CONFLICT,
            "admin-scoped live catalog caller must return conflict: {payload}"
        );
        assert_eq!(
            payload.get("error").and_then(Value::as_str),
            Some("destination_conflict"),
            "admin-scoped live catalog caller returned the wrong refusal"
        );
        LiveCallerRefusal { source: None }
    }

    pub async fn finish_after_refused_caller(self, _refusal: LiveCallerRefusal) {
        let mapping = self
            .caller_mapping
            .as_ref()
            .expect("catalog live caller key is required for caller evidence");
        if let Some(source) = &_refusal.source {
            assert_eq!(
                source.owner_path, mapping.owner_path,
                "catalog live caller evidence owner_path must come from the executed source"
            );
            assert_eq!(
                source.source_anchor, mapping.source_anchor,
                "catalog live caller evidence source_anchor must come from the executed source"
            );
        }
        self.verify_active_and_emit_binding().await;
        println!(
            "CATALOG_LIVE_CALLER|caller_key={}|selection={}|job_id={}|customer_id={}|target_index={}|outcome=refused",
            mapping.live_caller_key,
            self.selection,
            self.context.job_id,
            self.context.customer_id,
            self.context.target_index
        );
    }

    async fn verify_active_and_emit_binding(&self) {
        observe_job_through_tenant_api(&self.context);
        assert_active_reservation(&self.pool, &self.context).await;
        println!(
            "CATALOG_LIVE_BINDING|selection={}|job_id={}|customer_id={}|target_index={}",
            self.selection,
            self.context.job_id,
            self.context.customer_id,
            self.context.target_index
        );
    }
}

#[derive(Debug, Deserialize)]
struct LiveCallerInventory {
    writers: Vec<LiveCallerMapping>,
}

#[derive(Clone, Debug, Deserialize)]
struct LiveCallerMapping {
    owner_path: String,
    source_anchor: String,
    live_phase: String,
    live_scenario_key: String,
    live_caller_key: String,
}

fn require_live_caller_mapping(selection: &str, caller_key: &str) -> LiveCallerMapping {
    let inventory: LiveCallerInventory = serde_json::from_str(WRITER_INVENTORY_JSON)
        .expect("catalog lifecycle writer inventory must be valid JSON");
    let mut matches = inventory.writers.into_iter().filter(|writer| {
        writer.live_phase == "catalog"
            && writer.live_scenario_key == selection
            && writer.live_caller_key == caller_key
    });
    let mapping = matches
        .next()
        .expect("catalog live caller key must belong to the exact source-built selection");
    assert!(
        matches.next().is_none(),
        "catalog live caller mapping must be unique"
    );
    mapping
}

struct LiveContext {
    job_id: Uuid,
    customer_id: Uuid,
    target_index: String,
    api_url: String,
    auth_config: PathBuf,
    admin_key: String,
    caller_key: Option<String>,
}

impl LiveContext {
    fn from_env() -> Option<Self> {
        let job_id = match std::env::var(LIVE_JOB_ID_ENV) {
            Ok(value) if !value.is_empty() => value,
            Ok(_) | Err(std::env::VarError::NotPresent) => return None,
            Err(error) => panic!("{LIVE_JOB_ID_ENV} is not valid Unicode: {error}"),
        };
        let customer_id = required_env(LIVE_CUSTOMER_ID_ENV);
        let target_index = required_env(LIVE_TARGET_INDEX_ENV);
        let api_url = required_env(LIVE_API_URL_ENV);
        let auth_config = PathBuf::from(required_env(LIVE_AUTH_CONFIG_ENV));
        let admin_key = required_env(LIVE_ADMIN_KEY_ENV);
        let caller_key = std::env::var(LIVE_CALLER_KEY_ENV)
            .ok()
            .filter(|value| !value.is_empty());

        require_evidence_component(&target_index, "target index");
        if let Some(caller_key) = &caller_key {
            require_evidence_component(caller_key, "caller key");
        }
        assert!(
            auth_config.is_file(),
            "{LIVE_AUTH_CONFIG_ENV} must name the runner-owned curl config"
        );

        Some(Self {
            job_id: Uuid::parse_str(&job_id).expect("live catalog job id must be a UUID"),
            customer_id: Uuid::parse_str(&customer_id)
                .expect("live catalog customer id must be a UUID"),
            target_index,
            api_url: require_loopback_http_url(&api_url),
            auth_config,
            admin_key,
            caller_key,
        })
    }
}

fn require_loopback_http_url(api_url: &str) -> String {
    let parsed = reqwest::Url::parse(api_url).expect("live catalog API URL must parse");
    assert!(
        matches!(parsed.scheme(), "http" | "https"),
        "{LIVE_API_URL_ENV} must be an HTTP(S) URL"
    );
    let is_loopback = parsed.host_str().is_some_and(|host| {
        host.eq_ignore_ascii_case("localhost")
            || host
                .parse::<IpAddr>()
                .is_ok_and(|address| address.is_loopback())
    });
    assert!(
        is_loopback,
        "{LIVE_API_URL_ENV} must stay on loopback so live probe credentials never leave the local stack"
    );
    parsed.as_str().trim_end_matches('/').to_string()
}

fn assert_destination_conflict_response(response: &[u8], caller_description: &str) {
    let response =
        std::str::from_utf8(response).expect("live catalog caller response must be valid UTF-8");
    let (body, status) = response
        .rsplit_once('\n')
        .expect("live catalog caller response must include an HTTP status");
    let payload: Value =
        serde_json::from_str(body).expect("live catalog caller response must be JSON");
    assert_eq!(
        status, "409",
        "{caller_description} must return conflict: {payload}"
    );
    assert_eq!(
        payload.get("error").and_then(Value::as_str),
        Some("destination_conflict"),
        "{caller_description} returned the wrong refusal"
    );
}

async fn assert_active_reservation(pool: &PgPool, context: &LiveContext) {
    let predicate = PgAlgoliaImportJobRepo::active_reservation_predicate_for_contract_tests();
    let query = format!(
        "SELECT EXISTS (
             SELECT 1
             FROM algolia_import_jobs
             WHERE id = $1
               AND customer_id = $2
               AND logical_target = $3
               AND ({predicate})
         )"
    );
    let active: bool = sqlx::query_scalar(&query)
        .bind(context.job_id)
        .bind(context.customer_id)
        .bind(&context.target_index)
        .fetch_one(pool)
        .await
        .expect("query the live catalog reservation");
    assert!(
        active,
        "catalog production scenario did not execute under its live import reservation"
    );
}

fn observe_job_through_tenant_api(context: &LiveContext) {
    let url = format!(
        "{}/migration/algolia/jobs/{}",
        context.api_url, context.job_id
    );
    let output = Command::new("curl")
        .args([
            "--silent",
            "--show-error",
            "--config",
            context
                .auth_config
                .to_str()
                .expect("live auth config path must be valid Unicode"),
            "--output",
            "-",
            "--write-out",
            "\n%{http_code}",
            "--request",
            "GET",
            &url,
        ])
        .output()
        .expect("execute tenant-scoped live job observation");
    assert!(
        output.status.success(),
        "tenant-scoped live job observation failed"
    );
    let response =
        String::from_utf8(output.stdout).expect("live job response must contain valid UTF-8");
    let (body, status) = response
        .rsplit_once('\n')
        .expect("live job response must include an HTTP status");
    assert_eq!(status, "200", "live job must remain tenant-visible");
    let payload: Value = serde_json::from_str(body).expect("live job response must be JSON");
    assert_eq!(
        payload.get("id").and_then(Value::as_str),
        Some(context.job_id.to_string().as_str()),
        "tenant API returned a different import job"
    );
    assert_eq!(
        payload
            .pointer("/destination/target")
            .and_then(Value::as_str),
        Some(context.target_index.as_str()),
        "tenant API returned a different import target"
    );
}

fn required_env(name: &str) -> String {
    std::env::var(name)
        .unwrap_or_else(|_| panic!("{name} is required when live catalog context is enabled"))
}

fn require_evidence_component(value: &str, label: &str) {
    assert!(
        !value.is_empty()
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b':')),
        "{label} contains an unsafe evidence character"
    );
}

#[cfg(test)]
mod tests {
    use super::{
        require_evidence_component, require_live_caller_mapping, require_loopback_http_url,
    };

    #[test]
    fn evidence_components_reject_record_delimiters_and_newlines() {
        for invalid in ["", "scenario|forged", "scenario\nforged", "scenario/forged"] {
            assert!(
                std::panic::catch_unwind(|| require_evidence_component(invalid, "test")).is_err(),
                "{invalid:?} must not be accepted in structured evidence"
            );
        }
    }

    #[test]
    fn canonical_selection_and_target_characters_are_safe() {
        require_evidence_component(
            "catalog_lifecycle_leases::remote_races::create_index",
            "selection",
        );
        require_evidence_component("fjcloud_import_catalog_probe_123_target", "target");
    }

    #[test]
    fn live_api_url_must_resolve_to_loopback_host() {
        assert_eq!(
            require_loopback_http_url("http://127.0.0.1:3099/"),
            "http://127.0.0.1:3099"
        );
        assert_eq!(
            require_loopback_http_url("https://localhost:3099"),
            "https://localhost:3099"
        );
        for invalid in [
            "ftp://127.0.0.1:3099",
            "https://example.com/live-probe",
            "http://192.0.2.10:3099",
        ] {
            assert!(
                std::panic::catch_unwind(|| require_loopback_http_url(invalid)).is_err(),
                "{invalid:?} must not be accepted for live probe credentials"
            );
        }
    }

    #[test]
    fn live_caller_key_must_belong_to_the_exact_fixture_selection() {
        let inventory: serde_json::Value = serde_json::from_str(super::WRITER_INVENTORY_JSON)
            .expect("writer inventory must be valid JSON");
        let rows = inventory["writers"]
            .as_array()
            .expect("writer inventory must contain rows")
            .iter()
            .filter(|row| row["live_phase"] == "catalog")
            .collect::<Vec<_>>();

        for row in &rows {
            let mapping = require_live_caller_mapping(
                row["live_scenario_key"].as_str().unwrap(),
                row["live_caller_key"].as_str().unwrap(),
            );
            assert_eq!(
                mapping.source_anchor,
                row["source_anchor"].as_str().unwrap()
            );
            assert_eq!(mapping.owner_path, row["owner_path"].as_str().unwrap());
        }

        let first = rows[0];
        let different_selection = rows
            .iter()
            .find(|row| row["live_scenario_key"] != first["live_scenario_key"])
            .expect("inventory has multiple catalog scenarios");
        assert!(
            std::panic::catch_unwind(|| {
                require_live_caller_mapping(
                    different_selection["live_scenario_key"].as_str().unwrap(),
                    first["live_caller_key"].as_str().unwrap(),
                );
            })
            .is_err(),
            "a caller key cannot be relabelled as a different production scenario"
        );
    }
}
