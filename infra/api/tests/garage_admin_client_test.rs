use api::services::storage::garage_admin::ReqwestGarageAdminClient;
use api::services::storage::GarageAdminClient;
use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug, PartialEq)]
struct RecordedRequest {
    method: &'static str,
    path: &'static str,
    query: HashMap<String, String>,
    body: Value,
    auth_header: Option<String>,
}

#[derive(Clone, Default)]
struct RequestLog {
    entries: Arc<Mutex<Vec<RecordedRequest>>>,
}

impl RequestLog {
    fn push(&self, entry: RecordedRequest) {
        self.entries.lock().unwrap().push(entry);
    }

    fn snapshot(&self) -> Vec<RecordedRequest> {
        self.entries.lock().unwrap().clone()
    }
}

async fn create_bucket(
    State(log): State<RequestLog>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Json<Value> {
    log.push(RecordedRequest {
        method: "POST",
        path: "/v2/CreateBucket",
        query: HashMap::new(),
        body,
        auth_header: headers
            .get("authorization")
            .and_then(|value| value.to_str().ok())
            .map(str::to_string),
    });
    Json(json!({ "id": "bucket-123" }))
}

async fn get_bucket_info(
    State(log): State<RequestLog>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    log.push(RecordedRequest {
        method: "GET",
        path: "/v2/GetBucketInfo",
        query,
        body: Value::Null,
        auth_header: headers
            .get("authorization")
            .and_then(|value| value.to_str().ok())
            .map(str::to_string),
    });
    Json(json!({ "id": "bucket-123" }))
}

async fn create_key(
    State(log): State<RequestLog>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Json<Value> {
    log.push(RecordedRequest {
        method: "POST",
        path: "/v2/CreateKey",
        query: HashMap::new(),
        body,
        auth_header: headers
            .get("authorization")
            .and_then(|value| value.to_str().ok())
            .map(str::to_string),
    });
    Json(json!({
        "accessKeyId": "garage-key-123",
        "secretAccessKey": "garage-secret-123"
    }))
}

async fn allow_bucket_key(
    State(log): State<RequestLog>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Json<Value> {
    log.push(RecordedRequest {
        method: "POST",
        path: "/v2/AllowBucketKey",
        query: HashMap::new(),
        body,
        auth_header: headers
            .get("authorization")
            .and_then(|value| value.to_str().ok())
            .map(str::to_string),
    });
    Json(json!({ "ok": true }))
}

async fn delete_key(
    State(log): State<RequestLog>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    log.push(RecordedRequest {
        method: "POST",
        path: "/v2/DeleteKey",
        query,
        body: Value::Null,
        auth_header: headers
            .get("authorization")
            .and_then(|value| value.to_str().ok())
            .map(str::to_string),
    });
    Json(json!({ "ok": true }))
}

async fn delete_bucket(
    State(log): State<RequestLog>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    log.push(RecordedRequest {
        method: "POST",
        path: "/v2/DeleteBucket",
        query,
        body: Value::Null,
        auth_header: headers
            .get("authorization")
            .and_then(|value| value.to_str().ok())
            .map(str::to_string),
    });
    Json(json!({ "ok": true }))
}

async fn spawn_mock_server(log: RequestLog) -> String {
    let app = Router::new()
        .route("/v2/CreateBucket", post(create_bucket))
        .route("/v2/GetBucketInfo", get(get_bucket_info))
        .route("/v2/CreateKey", post(create_key))
        .route("/v2/AllowBucketKey", post(allow_bucket_key))
        .route("/v2/DeleteKey", post(delete_key))
        .route("/v2/DeleteBucket", post(delete_bucket))
        .with_state(log);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    format!("http://{address}")
}

#[tokio::test]
async fn reqwest_garage_admin_client_uses_v2_api_contract() {
    let log = RequestLog::default();
    let endpoint = spawn_mock_server(log.clone()).await;
    let client =
        ReqwestGarageAdminClient::new(reqwest::Client::new(), endpoint, "test-token".to_string());

    let bucket = client.create_bucket("gridl-bucket").await.unwrap();
    assert_eq!(bucket.id, "bucket-123");

    let bucket_lookup = client.get_bucket_by_alias("gridl-bucket").await.unwrap();
    assert_eq!(bucket_lookup.id, "bucket-123");

    let key = client.create_key("gridl_s3_example").await.unwrap();
    assert_eq!(key.id, "garage-key-123");
    assert_eq!(key.secret_key, "garage-secret-123");

    client
        .allow_key("bucket-123", "garage-key-123", true, true)
        .await
        .unwrap();
    client.delete_key("garage-key-123").await.unwrap();
    client.delete_bucket("bucket-123").await.unwrap();

    assert_eq!(
        log.snapshot(),
        vec![
            RecordedRequest {
                method: "POST",
                path: "/v2/CreateBucket",
                query: HashMap::new(),
                body: json!({ "globalAlias": "gridl-bucket" }),
                auth_header: Some("Bearer test-token".to_string()),
            },
            RecordedRequest {
                method: "GET",
                path: "/v2/GetBucketInfo",
                query: HashMap::from([("globalAlias".to_string(), "gridl-bucket".to_string(),)]),
                body: Value::Null,
                auth_header: Some("Bearer test-token".to_string()),
            },
            RecordedRequest {
                method: "POST",
                path: "/v2/CreateKey",
                query: HashMap::new(),
                body: json!({ "name": "gridl_s3_example" }),
                auth_header: Some("Bearer test-token".to_string()),
            },
            RecordedRequest {
                method: "POST",
                path: "/v2/AllowBucketKey",
                query: HashMap::new(),
                body: json!({
                    "bucketId": "bucket-123",
                    "accessKeyId": "garage-key-123",
                    "permissions": {
                        "read": true,
                        "write": true,
                        "owner": false
                    }
                }),
                auth_header: Some("Bearer test-token".to_string()),
            },
            RecordedRequest {
                method: "POST",
                path: "/v2/DeleteKey",
                query: HashMap::from([("id".to_string(), "garage-key-123".to_string())]),
                body: Value::Null,
                auth_header: Some("Bearer test-token".to_string()),
            },
            RecordedRequest {
                method: "POST",
                path: "/v2/DeleteBucket",
                query: HashMap::from([("id".to_string(), "bucket-123".to_string())]),
                body: Value::Null,
                auth_header: Some("Bearer test-token".to_string()),
            },
        ]
    );
}
