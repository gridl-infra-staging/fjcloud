use axum::Json;
use serde_json::{json, Value};

pub async fn version() -> Json<Value> {
    Json(json!({
        // 40-char lowercase hex SHA from the dev repo at sync time. Use this
        // to map back to a commit in gridl-infra-dev/fjcloud_dev. The literal
        // "local-dev" indicates this binary was not built through the
        // mirror-CI release path.
        "dev_sha": env!("FJCLOUD_DEV_SHA"),
        // 40-char lowercase hex SHA of the mirror commit this binary was
        // built from. Lives in gridl-infra-{staging,prod}/fjcloud.
        "mirror_sha": env!("FJCLOUD_MIRROR_SHA"),
        // ISO 8601 UTC timestamp of the debbie sync that produced the mirror
        // commit. Helps distinguish "stale mirror, fresh build" from "fresh
        // mirror, stale build."
        "synced_at": env!("FJCLOUD_SYNCED_AT"),
        // ISO 8601 UTC timestamp of the cargo build itself. Differs from
        // synced_at when CI builds long after sync (rare but possible).
        "build_time": env!("FJCLOUD_BUILD_TIME"),
    }))
}
