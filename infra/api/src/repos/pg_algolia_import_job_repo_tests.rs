use super::*;
use crate::models::algolia_import_job::{
    AlgoliaImportCreateDestination, AlgoliaImportSource, AlgoliaImportSourceMetadata,
};

fn job(customer_id: Uuid, key: &str, canonical_fingerprint: &str) -> NewAlgoliaImportJob {
    NewAlgoliaImportJob::create(
        customer_id,
        AlgoliaImportCreateDestination::new("products", "us-east-1"),
        AlgoliaImportSource::from_final_key_metadata(
            "AB12CD34EF",
            "Products",
            AlgoliaImportSourceMetadata::new(Some(100), Some(10), canonical_fingerprint),
        ),
        key,
    )
}

#[test]
fn idempotent_create_accepts_only_matching_canonical_fingerprint() {
    let customer_id = Uuid::new_v4();
    let original = job(customer_id, "same-key", "sha256:canonical-request");
    let replay = job(customer_id, "same-key", "sha256:canonical-request");
    let changed = job(customer_id, "same-key", "sha256:changed-request");

    assert!(support::idempotent_create_replay_is_allowed(
        original.customer_id(),
        original.idempotency_key(),
        original.canonical_fingerprint(),
        &replay
    ));
    assert!(!support::idempotent_create_replay_is_allowed(
        original.customer_id(),
        original.idempotency_key(),
        original.canonical_fingerprint(),
        &changed
    ));
}

#[test]
fn canonical_fingerprint_includes_destination_semantics() {
    let customer_id = Uuid::new_v4();
    let east = job(customer_id, "same-key", "same-source");
    let west = NewAlgoliaImportJob::create(
        customer_id,
        AlgoliaImportCreateDestination::new("products", "us-west-2"),
        AlgoliaImportSource::from_final_key_metadata(
            "AB12CD34EF",
            "Products",
            AlgoliaImportSourceMetadata::new(Some(100), Some(10), "same-source"),
        ),
        "same-key",
    );

    assert_ne!(east.canonical_fingerprint(), west.canonical_fingerprint());
    assert!(!support::idempotent_create_replay_is_allowed(
        east.customer_id(),
        east.idempotency_key(),
        east.canonical_fingerprint(),
        &west,
    ));
}
