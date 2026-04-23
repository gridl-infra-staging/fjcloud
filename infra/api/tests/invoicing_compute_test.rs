mod common;

use api::errors::ApiError;
use api::invoicing::{
    compute_invoice_for_customer, compute_invoice_for_customer_with_shared_inputs, BillingRepos,
    ObjectStorageEgressMetadata, SharedBillingData,
};
use api::models::cold_snapshot::NewColdSnapshot;
use api::models::customer::BillingPlan;
use api::models::storage::NewStorageBucket;
use api::models::{CustomerRateOverrideRow, RateCardRow};
use api::repos::cold_snapshot_repo::ColdSnapshotRepo;
use api::repos::storage_bucket_repo::StorageBucketRepo;
use chrono::{Datelike, NaiveDate, Utc};
use rust_decimal_macros::dec;
use serde_json::json;
use uuid::Uuid;

use common::{
    mock_cold_snapshot_repo, mock_rate_card_repo, mock_storage_bucket_repo, mock_usage_repo,
};

fn sample_rate_card(minimum_spend_cents: i64) -> RateCardRow {
    RateCardRow {
        id: Uuid::new_v4(),
        name: "default".to_string(),
        effective_from: Utc::now(),
        effective_until: None,
        storage_rate_per_mb_month: dec!(0.20),
        region_multipliers: json!({}),
        minimum_spend_cents,
        shared_minimum_spend_cents: 200,
        cold_storage_rate_per_gb_month: dec!(0.02),
        object_storage_rate_per_gb_month: dec!(0.024),
        object_storage_egress_rate_per_gb: dec!(0.01),
        created_at: Utc::now(),
    }
}

fn current_month_bounds() -> (NaiveDate, NaiveDate) {
    let now = Utc::now().date_naive();
    let start = NaiveDate::from_ymd_opt(now.year(), now.month(), 1).unwrap();
    let (next_year, next_month) = if now.month() == 12 {
        (now.year() + 1, 1)
    } else {
        (now.year(), now.month() + 1)
    };
    let next_start = NaiveDate::from_ymd_opt(next_year, next_month, 1).unwrap();
    let end = next_start.pred_opt().unwrap();
    (start, end)
}

#[tokio::test]
async fn compute_invoice_for_customer_returns_not_found_without_active_rate_card() {
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let cold_snapshot_repo = mock_cold_snapshot_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let customer_id = Uuid::new_v4();
    let (start, end) = current_month_bounds();

    let repos = BillingRepos {
        rate_card_repo: rate_card_repo.as_ref(),
        usage_repo: usage_repo.as_ref(),
        cold_snapshot_repo: cold_snapshot_repo.as_ref(),
        storage_bucket_repo: storage_bucket_repo.as_ref(),
    };
    let result =
        compute_invoice_for_customer(&repos, customer_id, start, end, BillingPlan::Free, dec!(0))
            .await;

    match result {
        Err(ApiError::NotFound(msg)) => assert_eq!(msg, "no active rate card"),
        Err(other) => panic!("expected NotFound, got {other:?}"),
        Ok(_) => panic!("expected NotFound error, got Ok result"),
    }
}

#[tokio::test]
async fn compute_invoice_for_customer_applies_rate_override_when_present() {
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let cold_snapshot_repo = mock_cold_snapshot_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let customer_id = Uuid::new_v4();
    let (start, end) = current_month_bounds();

    let card = sample_rate_card(0);
    let card_id = card.id;
    rate_card_repo.seed_active_card(card);
    rate_card_repo.seed_override(CustomerRateOverrideRow {
        customer_id,
        rate_card_id: card_id,
        overrides: json!({"storage_rate_per_mb_month": "0.25"}),
        created_at: Utc::now(),
    });

    // Seed constant 10 MB/day across the full billing period so summarize() yields 10 mb_months.
    let hot_storage_bytes_per_day = billing::types::BYTES_PER_MB * 10;
    let mut day = start;
    while day <= end {
        usage_repo.seed(
            customer_id,
            day,
            "us-east-1",
            0,
            0,
            hot_storage_bytes_per_day,
            0,
        );
        day = day.succ_opt().expect("valid next day in billing period");
    }

    let repos = BillingRepos {
        rate_card_repo: rate_card_repo.as_ref(),
        usage_repo: usage_repo.as_ref(),
        cold_snapshot_repo: cold_snapshot_repo.as_ref(),
        storage_bucket_repo: storage_bucket_repo.as_ref(),
    };
    let invoice =
        compute_invoice_for_customer(&repos, customer_id, start, end, BillingPlan::Free, dec!(0))
            .await
            .unwrap();

    assert_eq!(invoice.subtotal_cents, 250);
    assert_eq!(invoice.total_cents, 250);
    assert!(!invoice.minimum_applied);

    let storage_item = invoice
        .line_items
        .iter()
        .find(|li| li.unit == "mb_months")
        .expect("hot storage line item missing");
    assert_eq!(storage_item.amount_cents, 250);
}

#[tokio::test]
async fn compute_invoice_for_customer_includes_cold_storage_gb_months() {
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let cold_snapshot_repo = mock_cold_snapshot_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let customer_id = Uuid::new_v4();
    let (start, end) = current_month_bounds();

    rate_card_repo.seed_active_card(sample_rate_card(0));

    let snapshot = cold_snapshot_repo
        .create(NewColdSnapshot {
            customer_id,
            tenant_id: "cold-only-index".to_string(),
            source_vm_id: Uuid::new_v4(),
            object_key: "cold/test/snapshot.fj".to_string(),
        })
        .await
        .expect("create snapshot");
    cold_snapshot_repo
        .set_exporting(snapshot.id)
        .await
        .expect("set exporting");
    cold_snapshot_repo
        .set_completed(snapshot.id, billing::types::BYTES_PER_GIB * 200, "abc123")
        .await
        .expect("set completed");

    let repos = BillingRepos {
        rate_card_repo: rate_card_repo.as_ref(),
        usage_repo: usage_repo.as_ref(),
        cold_snapshot_repo: cold_snapshot_repo.as_ref(),
        storage_bucket_repo: storage_bucket_repo.as_ref(),
    };
    let invoice =
        compute_invoice_for_customer(&repos, customer_id, start, end, BillingPlan::Free, dec!(0))
            .await
            .unwrap();

    assert_eq!(invoice.subtotal_cents, 400);
    assert_eq!(invoice.total_cents, 400);

    let cold_item = invoice
        .line_items
        .iter()
        .find(|li| li.unit == "cold_gb_months")
        .expect("cold storage line item missing");
    assert_eq!(cold_item.amount_cents, 400);
}

// -------------------------------------------------------------------------
// Object storage invoice computation tests
// -------------------------------------------------------------------------

#[tokio::test]
async fn compute_invoice_includes_object_storage_from_buckets() {
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let cold_snapshot_repo = mock_cold_snapshot_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let customer_id = Uuid::new_v4();
    let (start, end) = current_month_bounds();

    rate_card_repo.seed_active_card(sample_rate_card(0));

    // Create a bucket with 10 GB stored and 5 GB egress (0 watermark)
    let one_gb = billing::types::BYTES_PER_GIB;
    let bucket = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id,
                name: "my-bucket".to_string(),
            },
            "garage-internal-bucket",
        )
        .await
        .unwrap();
    storage_bucket_repo
        .increment_size(bucket.id, one_gb * 10, 100)
        .await
        .unwrap();
    storage_bucket_repo
        .increment_egress(bucket.id, one_gb * 5)
        .await
        .unwrap();

    let repos = BillingRepos {
        rate_card_repo: rate_card_repo.as_ref(),
        usage_repo: usage_repo.as_ref(),
        cold_snapshot_repo: cold_snapshot_repo.as_ref(),
        storage_bucket_repo: storage_bucket_repo.as_ref(),
    };
    let invoice =
        compute_invoice_for_customer(&repos, customer_id, start, end, BillingPlan::Free, dec!(0))
            .await
            .unwrap();

    // 10 GB × $0.024/GB = 24 cents
    let obj_li = invoice
        .line_items
        .iter()
        .find(|li| li.unit == "object_storage_gb_months")
        .expect("object storage line item missing");
    assert_eq!(obj_li.amount_cents, 24);

    // 5 GB × $0.01/GB = 5 cents
    let egress_li = invoice
        .line_items
        .iter()
        .find(|li| li.unit == "object_storage_egress_gb")
        .expect("object storage egress line item missing");
    assert_eq!(egress_li.amount_cents, 5);

    assert_eq!(invoice.subtotal_cents, 29);
}

#[tokio::test]
async fn compute_invoice_multiple_buckets_aggregated() {
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let cold_snapshot_repo = mock_cold_snapshot_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let customer_id = Uuid::new_v4();
    let (start, end) = current_month_bounds();

    rate_card_repo.seed_active_card(sample_rate_card(0));

    let one_gb = billing::types::BYTES_PER_GIB;

    // Bucket A: 5 GB stored, 2 GB egress
    let bucket_a = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id,
                name: "bucket-a".to_string(),
            },
            "garage-a",
        )
        .await
        .unwrap();
    storage_bucket_repo
        .increment_size(bucket_a.id, one_gb * 5, 50)
        .await
        .unwrap();
    storage_bucket_repo
        .increment_egress(bucket_a.id, one_gb * 2)
        .await
        .unwrap();

    // Bucket B: 15 GB stored, 8 GB egress, 3 GB already billed (watermark)
    let bucket_b = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id,
                name: "bucket-b".to_string(),
            },
            "garage-b",
        )
        .await
        .unwrap();
    storage_bucket_repo
        .increment_size(bucket_b.id, one_gb * 15, 150)
        .await
        .unwrap();
    storage_bucket_repo
        .increment_egress(bucket_b.id, one_gb * 8)
        .await
        .unwrap();
    storage_bucket_repo
        .update_egress_watermark(bucket_b.id, one_gb * 3)
        .await
        .unwrap();

    let repos = BillingRepos {
        rate_card_repo: rate_card_repo.as_ref(),
        usage_repo: usage_repo.as_ref(),
        cold_snapshot_repo: cold_snapshot_repo.as_ref(),
        storage_bucket_repo: storage_bucket_repo.as_ref(),
    };
    let invoice =
        compute_invoice_for_customer(&repos, customer_id, start, end, BillingPlan::Free, dec!(0))
            .await
            .unwrap();

    // Storage: (5 + 15) = 20 GB × $0.024 = 48 cents
    let obj_li = invoice
        .line_items
        .iter()
        .find(|li| li.unit == "object_storage_gb_months")
        .expect("object storage line item missing");
    assert_eq!(obj_li.amount_cents, 48);

    // Egress: bucket_a(2-0) + bucket_b(8-3) = 7 GB × $0.01 = 7 cents
    let egress_li = invoice
        .line_items
        .iter()
        .find(|li| li.unit == "object_storage_egress_gb")
        .expect("object storage egress line item missing");
    assert_eq!(egress_li.amount_cents, 7);
}

#[tokio::test]
async fn compute_invoice_object_storage_without_hot_usage() {
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let cold_snapshot_repo = mock_cold_snapshot_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let customer_id = Uuid::new_v4();
    let (start, end) = current_month_bounds();

    rate_card_repo.seed_active_card(sample_rate_card(0));

    // Customer has only object storage, no hot-usage rows
    let one_gb = billing::types::BYTES_PER_GIB;
    let bucket = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id,
                name: "storage-only".to_string(),
            },
            "garage-storage-only",
        )
        .await
        .unwrap();
    storage_bucket_repo
        .increment_size(bucket.id, one_gb * 100, 1000)
        .await
        .unwrap();

    let repos = BillingRepos {
        rate_card_repo: rate_card_repo.as_ref(),
        usage_repo: usage_repo.as_ref(),
        cold_snapshot_repo: cold_snapshot_repo.as_ref(),
        storage_bucket_repo: storage_bucket_repo.as_ref(),
    };
    let invoice =
        compute_invoice_for_customer(&repos, customer_id, start, end, BillingPlan::Free, dec!(0))
            .await
            .unwrap();

    // 100 GB × $0.024 = $2.40 = 240 cents
    let obj_li = invoice
        .line_items
        .iter()
        .find(|li| li.unit == "object_storage_gb_months")
        .expect("object storage line item missing for storage-only customer");
    assert_eq!(obj_li.amount_cents, 240);
    assert_eq!(invoice.subtotal_cents, 240);
}

#[tokio::test]
async fn compute_invoice_ignores_other_customers_buckets() {
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let cold_snapshot_repo = mock_cold_snapshot_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let customer_id = Uuid::new_v4();
    let other_customer = Uuid::new_v4();
    let (start, end) = current_month_bounds();

    rate_card_repo.seed_active_card(sample_rate_card(0));

    let one_gb = billing::types::BYTES_PER_GIB;

    // Our customer: 5 GB
    let bucket = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id,
                name: "mine".to_string(),
            },
            "garage-mine",
        )
        .await
        .unwrap();
    storage_bucket_repo
        .increment_size(bucket.id, one_gb * 5, 50)
        .await
        .unwrap();

    // Other customer: 100 GB (should not be billed to our customer)
    let other_bucket = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id: other_customer,
                name: "theirs".to_string(),
            },
            "garage-theirs",
        )
        .await
        .unwrap();
    storage_bucket_repo
        .increment_size(other_bucket.id, one_gb * 100, 1000)
        .await
        .unwrap();

    let repos = BillingRepos {
        rate_card_repo: rate_card_repo.as_ref(),
        usage_repo: usage_repo.as_ref(),
        cold_snapshot_repo: cold_snapshot_repo.as_ref(),
        storage_bucket_repo: storage_bucket_repo.as_ref(),
    };
    let invoice =
        compute_invoice_for_customer(&repos, customer_id, start, end, BillingPlan::Free, dec!(0))
            .await
            .unwrap();

    // Only 5 GB × $0.024 = 12 cents
    let obj_li = invoice
        .line_items
        .iter()
        .find(|li| li.unit == "object_storage_gb_months")
        .expect("object storage line item missing");
    assert_eq!(obj_li.amount_cents, 12);
}

#[tokio::test]
async fn compute_invoice_applies_customer_egress_carryforward_to_whole_cent_split() {
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let cold_snapshot_repo = mock_cold_snapshot_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let customer_id = Uuid::new_v4();
    let (start, end) = current_month_bounds();

    rate_card_repo.seed_active_card(sample_rate_card(0));

    let one_gb = billing::types::BYTES_PER_GIB;
    let bucket = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id,
                name: "carryforward-bucket".to_string(),
            },
            "garage-carryforward-bucket",
        )
        .await
        .unwrap();
    storage_bucket_repo
        .increment_egress(bucket.id, one_gb / 2)
        .await
        .unwrap();

    let repos = BillingRepos {
        rate_card_repo: rate_card_repo.as_ref(),
        usage_repo: usage_repo.as_ref(),
        cold_snapshot_repo: cold_snapshot_repo.as_ref(),
        storage_bucket_repo: storage_bucket_repo.as_ref(),
    };
    let invoice = compute_invoice_for_customer(
        &repos,
        customer_id,
        start,
        end,
        BillingPlan::Free,
        dec!(0.6),
    )
    .await
    .unwrap();

    let egress = invoice
        .line_items
        .iter()
        .find(|li| li.unit == "object_storage_egress_gb")
        .expect("object storage egress line item missing");
    assert_eq!(egress.amount_cents, 1);
    let metadata: ObjectStorageEgressMetadata = serde_json::from_value(
        egress
            .metadata
            .clone()
            .expect("metadata should be attached"),
    )
    .expect("metadata should deserialize");
    assert_eq!(metadata.next_cycle_carryforward_cents, dec!(0.1));
}

#[tokio::test]
async fn compute_invoice_with_shared_inputs_retains_sub_cent_remainder() {
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let cold_snapshot_repo = mock_cold_snapshot_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let customer_id = Uuid::new_v4();
    let (start, end) = current_month_bounds();

    let base_card = sample_rate_card(0);
    rate_card_repo.seed_active_card(base_card.clone());

    let one_gb = billing::types::BYTES_PER_GIB;
    let bucket = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id,
                name: "shared-input-bucket".to_string(),
            },
            "garage-shared-input-bucket",
        )
        .await
        .unwrap();
    storage_bucket_repo
        .increment_egress(bucket.id, one_gb / 2)
        .await
        .unwrap();
    let storage_buckets = storage_bucket_repo.list_all().await.unwrap();
    let cold_snapshots = Vec::new();

    let repos = BillingRepos {
        rate_card_repo: rate_card_repo.as_ref(),
        usage_repo: usage_repo.as_ref(),
        cold_snapshot_repo: cold_snapshot_repo.as_ref(),
        storage_bucket_repo: storage_bucket_repo.as_ref(),
    };
    let shared = SharedBillingData {
        base_card: &base_card,
        cold_snapshots: &cold_snapshots,
        storage_buckets: &storage_buckets,
    };
    let invoice = compute_invoice_for_customer_with_shared_inputs(
        &repos,
        &shared,
        customer_id,
        start,
        end,
        BillingPlan::Free,
        dec!(0.2),
    )
    .await
    .unwrap();

    let egress = invoice
        .line_items
        .iter()
        .find(|li| li.unit == "object_storage_egress_gb")
        .expect("object storage egress line item missing");
    assert_eq!(egress.amount_cents, 0);
    let metadata: ObjectStorageEgressMetadata = serde_json::from_value(
        egress
            .metadata
            .clone()
            .expect("metadata should be attached"),
    )
    .expect("metadata should deserialize");
    assert_eq!(metadata.next_cycle_carryforward_cents, dec!(0.7));
    assert_eq!(metadata.watermark_targets.len(), 1);
    assert_eq!(metadata.watermark_targets[0].bucket_id, bucket.id);
    assert_eq!(metadata.watermark_targets[0].egress_bytes, one_gb / 2);
}

#[tokio::test]
async fn compute_invoice_with_shared_inputs_carryforward_only_month_persists_remainder() {
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let cold_snapshot_repo = mock_cold_snapshot_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let customer_id = Uuid::new_v4();
    let (start, end) = current_month_bounds();

    let base_card = sample_rate_card(0);
    rate_card_repo.seed_active_card(base_card.clone());
    let storage_buckets = Vec::new();
    let cold_snapshots = Vec::new();

    let repos = BillingRepos {
        rate_card_repo: rate_card_repo.as_ref(),
        usage_repo: usage_repo.as_ref(),
        cold_snapshot_repo: cold_snapshot_repo.as_ref(),
        storage_bucket_repo: storage_bucket_repo.as_ref(),
    };
    let shared = SharedBillingData {
        base_card: &base_card,
        cold_snapshots: &cold_snapshots,
        storage_buckets: &storage_buckets,
    };
    let invoice = compute_invoice_for_customer_with_shared_inputs(
        &repos,
        &shared,
        customer_id,
        start,
        end,
        BillingPlan::Free,
        dec!(0.7),
    )
    .await
    .unwrap();

    let egress = invoice
        .line_items
        .iter()
        .find(|li| li.unit == "object_storage_egress_gb")
        .expect("carry-forward-only month must produce egress line item with metadata");
    assert_eq!(egress.amount_cents, 0);
    let metadata: ObjectStorageEgressMetadata = serde_json::from_value(
        egress
            .metadata
            .clone()
            .expect("metadata should be attached"),
    )
    .expect("metadata should deserialize");
    assert_eq!(metadata.next_cycle_carryforward_cents, dec!(0.7));
    assert!(
        metadata.watermark_targets.is_empty(),
        "carry-forward-only month should not include watermark targets without buckets"
    );
}

#[tokio::test]
async fn compute_invoice_carryforward_only_month_persists_remainder() {
    // Customer has carry-forward but no buckets/egress — carry-forward-only month
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let cold_snapshot_repo = mock_cold_snapshot_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let customer_id = Uuid::new_v4();
    let (start, end) = current_month_bounds();

    rate_card_repo.seed_active_card(sample_rate_card(0));

    let repos = BillingRepos {
        rate_card_repo: rate_card_repo.as_ref(),
        usage_repo: usage_repo.as_ref(),
        cold_snapshot_repo: cold_snapshot_repo.as_ref(),
        storage_bucket_repo: storage_bucket_repo.as_ref(),
    };
    let invoice = compute_invoice_for_customer(
        &repos,
        customer_id,
        start,
        end,
        BillingPlan::Free,
        dec!(0.7),
    )
    .await
    .unwrap();

    let egress = invoice
        .line_items
        .iter()
        .find(|li| li.unit == "object_storage_egress_gb")
        .expect("carry-forward-only month must produce egress line item with metadata");
    assert_eq!(egress.amount_cents, 0);
    let metadata: ObjectStorageEgressMetadata = serde_json::from_value(
        egress
            .metadata
            .clone()
            .expect("metadata should be attached"),
    )
    .expect("metadata should deserialize");
    assert_eq!(metadata.next_cycle_carryforward_cents, dec!(0.7));
}

#[tokio::test]
async fn compute_invoice_for_customer_rejects_invalid_persisted_rate_override() {
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let cold_snapshot_repo = mock_cold_snapshot_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let customer_id = Uuid::new_v4();
    let (start, end) = current_month_bounds();

    let card = sample_rate_card(0);
    let card_id = card.id;
    rate_card_repo.seed_active_card(card);
    rate_card_repo.seed_override(CustomerRateOverrideRow {
        customer_id,
        rate_card_id: card_id,
        overrides: json!({"storage_rate_per_mb_month": "bad-decimal"}),
        created_at: Utc::now(),
    });

    let repos = BillingRepos {
        rate_card_repo: rate_card_repo.as_ref(),
        usage_repo: usage_repo.as_ref(),
        cold_snapshot_repo: cold_snapshot_repo.as_ref(),
        storage_bucket_repo: storage_bucket_repo.as_ref(),
    };
    let err = match compute_invoice_for_customer(
        &repos,
        customer_id,
        start,
        end,
        BillingPlan::Free,
        dec!(0),
    )
    .await
    {
        Ok(_) => panic!("invalid persisted override should fail"),
        Err(err) => err,
    };

    match err {
        ApiError::Internal(msg) => assert!(msg.contains("storage_rate_per_mb_month")),
        other => panic!("expected Internal, got {other:?}"),
    }
}
