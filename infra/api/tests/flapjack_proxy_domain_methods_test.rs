#[path = "common/mod.rs"]
mod common;

use common::flapjack_proxy_test_support::setup;
use serde_json::json;

#[tokio::test]
async fn update_index_settings_sends_post_with_body() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream_response = json!({"updatedAt": "2026-02-25T00:00:00Z", "taskID": 42});
    http.push_json_response(200, upstream_response.clone());

    let settings = json!({
        "searchableAttributes": ["title", "body"],
        "filterableAttributes": ["category"]
    });

    let result = proxy
        .update_index_settings(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            settings.clone(),
        )
        .await
        .expect("update_index_settings should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/indexes/products/settings"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, Some(settings));
}

// ---------------------------------------------------------------------------
// Stage 4: search_rules
// ---------------------------------------------------------------------------

#[tokio::test]
async fn search_rules_sends_post_to_rules_search() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream_response = json!({
        "hits": [
            {"objectID": "rule-1", "description": "Boost shoes"},
            {"objectID": "rule-2", "description": "Hide discontinued"}
        ],
        "nbHits": 2,
        "page": 0,
        "nbPages": 1
    });
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .search_rules(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            "",
            0,
            50,
        )
        .await
        .expect("search_rules should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/indexes/products/rules/search"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(
        requests[0].json_body,
        Some(json!({"query": "", "page": 0, "hitsPerPage": 50}))
    );
}

// ---------------------------------------------------------------------------
// Stage 4: save_rule
// ---------------------------------------------------------------------------

#[tokio::test]
async fn save_rule_sends_put_with_rule_body() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream_response =
        json!({"taskID": 7, "updatedAt": "2026-02-25T01:00:00Z", "id": "boost-shoes"});
    http.push_json_response(200, upstream_response.clone());

    let rule = json!({
        "objectID": "boost-shoes",
        "conditions": [{"pattern": "shoes", "anchoring": "contains"}],
        "consequence": {"promote": [{"objectID": "shoe-1", "position": 0}]},
        "description": "Boost shoes to top"
    });

    let result = proxy
        .save_rule(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            "boost-shoes",
            rule.clone(),
        )
        .await
        .expect("save_rule should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::PUT);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/indexes/products/rules/boost-shoes"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, Some(rule));
}

// ---------------------------------------------------------------------------
// Stage 4: get_rule
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_rule_sends_get_to_rules_object_id() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let rule_response = json!({
        "objectID": "boost-shoes",
        "conditions": [{"pattern": "shoes", "anchoring": "contains"}],
        "consequence": {"promote": [{"objectID": "shoe-1", "position": 0}]},
        "description": "Boost shoes to top",
        "enabled": true
    });
    http.push_json_response(200, rule_response.clone());

    let result = proxy
        .get_rule(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            "boost-shoes",
        )
        .await
        .expect("get_rule should succeed");

    assert_eq!(result, rule_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/indexes/products/rules/boost-shoes"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

// ---------------------------------------------------------------------------
// Stage 4: delete_rule
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_rule_sends_delete_to_rules_object_id() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream_response = json!({"taskID": 12, "deletedAt": "2026-02-25T02:00:00Z"});
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .delete_rule(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            "boost-shoes",
        )
        .await
        .expect("delete_rule should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::DELETE);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/indexes/products/rules/boost-shoes"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

// ---------------------------------------------------------------------------
// Stage 5: synonyms
// ---------------------------------------------------------------------------

#[tokio::test]
async fn search_synonyms_sends_post_to_synonyms_search() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream_response = json!({
        "hits": [
            {"objectID": "laptop-syn", "type": "synonym", "synonyms": ["laptop", "notebook"]}
        ],
        "nbHits": 1
    });
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .search_synonyms(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            "",
            None,
            0,
            50,
        )
        .await
        .expect("search_synonyms should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/indexes/products/synonyms/search"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(
        requests[0].json_body,
        Some(json!({"query": "", "page": 0, "hitsPerPage": 50}))
    );
}

#[tokio::test]
async fn search_synonyms_with_type_filter_includes_type_in_body() {
    let (http, _ssm, proxy) = setup().await;

    http.push_json_response(200, json!({"hits": [], "nbHits": 0}));

    proxy
        .search_synonyms(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            "",
            Some("onewaysynonym"),
            0,
            50,
        )
        .await
        .expect("search_synonyms should succeed");

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].json_body,
        Some(json!({
            "query": "",
            "type": "onewaysynonym",
            "page": 0,
            "hitsPerPage": 50
        }))
    );
}

#[tokio::test]
async fn save_synonym_sends_put_with_synonym_body() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream_response =
        json!({"taskID": 7, "updatedAt": "2026-02-25T01:00:00Z", "id": "laptop-syn"});
    http.push_json_response(200, upstream_response.clone());

    let synonym = json!({
        "objectID": "laptop-syn",
        "type": "synonym",
        "synonyms": ["laptop", "notebook", "computer"]
    });

    let result = proxy
        .save_synonym(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            "laptop-syn",
            synonym.clone(),
        )
        .await
        .expect("save_synonym should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::PUT);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/indexes/products/synonyms/laptop-syn"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, Some(synonym));
}

#[tokio::test]
async fn get_synonym_sends_get_to_synonyms_object_id() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let synonym_response = json!({
        "objectID": "laptop-syn",
        "type": "synonym",
        "synonyms": ["laptop", "notebook", "computer"]
    });
    http.push_json_response(200, synonym_response.clone());

    let result = proxy
        .get_synonym(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            "laptop-syn",
        )
        .await
        .expect("get_synonym should succeed");

    assert_eq!(result, synonym_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/indexes/products/synonyms/laptop-syn"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn delete_synonym_sends_delete_to_synonyms_object_id() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream_response = json!({"taskID": 12, "deletedAt": "2026-02-25T02:00:00Z"});
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .delete_synonym(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            "laptop-syn",
        )
        .await
        .expect("delete_synonym should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::DELETE);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/indexes/products/synonyms/laptop-syn"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

// ---------------------------------------------------------------------------
// Stage 5: query suggestions
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_qs_config_sends_get_to_configs_index_name() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let config = json!({
        "indexName": "products",
        "sourceIndices": [
            {
                "indexName": "products",
                "minHits": 5,
                "minLetters": 4,
                "facets": [],
                "generate": [],
                "analyticsTags": [],
                "replicas": false
            }
        ],
        "languages": ["en"],
        "exclude": [],
        "allowSpecialCharacters": false,
        "enablePersonalization": false
    });
    http.push_json_response(200, config.clone());

    let result = proxy
        .get_qs_config(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
        )
        .await
        .expect("get_qs_config should succeed");

    assert_eq!(result, config);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/configs/products"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn upsert_qs_config_creates_when_not_exists() {
    let (http, _ssm, proxy) = setup().await;

    let config = json!({
        "sourceIndices": [
            {
                "indexName": "products",
                "minHits": 5,
                "minLetters": 4,
                "facets": [],
                "generate": [],
                "analyticsTags": [],
                "replicas": false
            }
        ],
        "languages": ["en"],
        "exclude": [],
        "allowSpecialCharacters": false,
        "enablePersonalization": false
    });

    http.push_text_response(404, "{\"error\":\"config not found\"}");
    let created_response = json!({"status": "created"});
    http.push_json_response(200, created_response.clone());

    let result = proxy
        .upsert_qs_config(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            config.clone(),
        )
        .await
        .expect("upsert_qs_config should create on 404");

    assert_eq!(result, created_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 2);

    assert_eq!(requests[0].method, reqwest::Method::PUT);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/configs/products"
    );
    assert_eq!(requests[0].json_body, Some(config.clone()));

    assert_eq!(requests[1].method, reqwest::Method::POST);
    assert_eq!(requests[1].url, "https://vm-a1.flapjack.foo/1/configs");
    assert_eq!(
        requests[1].json_body,
        Some(json!({
            "indexName": "products",
            "sourceIndices": [
                {
                    "indexName": "products",
                    "minHits": 5,
                    "minLetters": 4,
                    "facets": [],
                    "generate": [],
                    "analyticsTags": [],
                    "replicas": false
                }
            ],
            "languages": ["en"],
            "exclude": [],
            "allowSpecialCharacters": false,
            "enablePersonalization": false
        }))
    );
}

#[tokio::test]
async fn upsert_qs_config_updates_when_exists() {
    let (http, _ssm, proxy) = setup().await;

    let config = json!({
        "sourceIndices": [],
        "languages": ["en"],
        "exclude": [],
        "allowSpecialCharacters": false,
        "enablePersonalization": false
    });

    let updated_response = json!({"status": "updated"});
    http.push_json_response(200, updated_response.clone());

    let result = proxy
        .upsert_qs_config(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            config.clone(),
        )
        .await
        .expect("upsert_qs_config should update when PUT succeeds");

    assert_eq!(result, updated_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::PUT);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/configs/products"
    );
    assert_eq!(requests[0].json_body, Some(config));
}

#[tokio::test]
async fn get_qs_status_sends_get_to_configs_index_name_status() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let status_response = json!({
        "indexName": "products",
        "isRunning": false,
        "lastBuiltAt": "2026-02-25T03:00:00Z",
        "lastSuccessfulBuiltAt": "2026-02-25T03:00:00Z"
    });
    http.push_json_response(200, status_response.clone());

    let result = proxy
        .get_qs_status(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
        )
        .await
        .expect("get_qs_status should succeed");

    assert_eq!(result, status_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/configs/products/status"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn delete_qs_config_sends_delete_to_configs_index_name() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream_response = json!({"deletedAt": "2026-02-25T04:00:00Z"});
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .delete_qs_config(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
        )
        .await
        .expect("delete_qs_config should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::DELETE);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/configs/products"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

// ---------------------------------------------------------------------------
// Documents: batch_documents
// ---------------------------------------------------------------------------

#[tokio::test]
async fn documents_batch_sends_post_to_batch_endpoint() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream_response = json!({
        "taskID": 99,
        "objectIDs": ["obj-1", "obj-2"]
    });
    http.push_json_response(200, upstream_response.clone());

    let batch_body = json!({
        "requests": [
            {"action": "addObject", "body": {"objectID": "obj-1", "title": "First"}},
            {"action": "addObject", "body": {"objectID": "obj-2", "title": "Second"}}
        ]
    });

    let result = proxy
        .batch_documents(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            batch_body.clone(),
        )
        .await
        .expect("batch_documents should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/indexes/products/batch"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, Some(batch_body));
}

// ---------------------------------------------------------------------------
// Documents: browse_documents
// ---------------------------------------------------------------------------

#[tokio::test]
async fn documents_browse_sends_post_with_cursor_and_params() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream_response = json!({
        "hits": [{"objectID": "obj-1", "title": "First"}],
        "nbHits": 1,
        "page": 0,
        "nbPages": 1,
        "hitsPerPage": 20,
        "cursor": "abc123"
    });
    http.push_json_response(200, upstream_response.clone());

    let browse_body = json!({
        "hitsPerPage": 20
    });

    let result = proxy
        .browse_documents(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            browse_body.clone(),
        )
        .await
        .expect("browse_documents should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/indexes/products/browse"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, Some(browse_body));
}

#[tokio::test]
async fn documents_browse_with_cursor_forwards_cursor() {
    let (http, _ssm, proxy) = setup().await;

    http.push_json_response(
        200,
        json!({"hits": [], "nbHits": 0, "page": 1, "nbPages": 1, "hitsPerPage": 20}),
    );

    let browse_body = json!({
        "cursor": "abc123",
        "hitsPerPage": 20
    });

    proxy
        .browse_documents(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            browse_body.clone(),
        )
        .await
        .expect("browse_documents with cursor should succeed");

    let requests = http.take_requests();
    assert_eq!(requests[0].json_body, Some(browse_body));
}

// ---------------------------------------------------------------------------
// Documents: get_document
// ---------------------------------------------------------------------------

#[tokio::test]
async fn documents_get_sends_get_to_object_endpoint() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream_response = json!({
        "objectID": "obj-42",
        "title": "My Document",
        "description": "Some content"
    });
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .get_document(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            "obj-42",
        )
        .await
        .expect("get_document should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/indexes/products/obj-42"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

// ---------------------------------------------------------------------------
// Documents: delete_document
// ---------------------------------------------------------------------------

#[tokio::test]
async fn documents_delete_sends_delete_to_object_endpoint() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream_response = json!({
        "taskID": 101,
        "deletedAt": "2026-03-18T12:00:00Z"
    });
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .delete_document(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            "obj-42",
        )
        .await
        .expect("delete_document should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::DELETE);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/indexes/products/obj-42"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

// ---------------------------------------------------------------------------
// Stage 6: analytics
