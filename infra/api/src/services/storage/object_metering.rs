//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar19_3_load_testing_chaos/fjcloud_dev/infra/api/src/services/storage/object_metering.rs.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::sync::Mutex as StdMutex;

use uuid::Uuid;

use crate::repos::storage_bucket_repo::StorageBucketRepo;

use super::s3_proxy::{GarageProxy, ProxyError, ProxyRequest, ProxyResponse};

pub struct S3ObjectMeteringService {
    bucket_repo: Arc<dyn StorageBucketRepo + Send + Sync>,
    garage_proxy: Arc<GarageProxy>,
    same_key_locks: Arc<SameKeyMutationLocks>,
}

impl S3ObjectMeteringService {
    pub fn new(
        bucket_repo: Arc<dyn StorageBucketRepo + Send + Sync>,
        garage_proxy: Arc<GarageProxy>,
    ) -> Self {
        Self {
            bucket_repo,
            garage_proxy,
            same_key_locks: Arc::new(SameKeyMutationLocks::new()),
        }
    }

    /// Executes a metered object mutation (PUT or DELETE). Acquires a
    /// per-key lock, HEAD-probes the existing object state, forwards the
    /// mutation to Garage, and on a 2xx response records the metering
    /// delta asynchronously.
    pub async fn execute(
        &self,
        mutation: MeteredObjectMutation<'_>,
    ) -> Result<ProxyResponse, ProxyError> {
        let garage_uri = mutation.garage_uri();
        let _guard = self
            .same_key_locks
            .lock(mutation.garage_bucket, mutation.key)
            .await;
        let existing_object = self.load_existing_object(&garage_uri).await;
        let response = self
            .garage_proxy
            .forward(&ProxyRequest {
                method: mutation.kind.http_method(),
                uri: &garage_uri,
                headers: mutation.headers,
                body: mutation.body,
            })
            .await?;

        if response.status < 300 {
            self.record_successful_mutation(&mutation, existing_object);
        }

        Ok(response)
    }

    /// HEAD-probes the object in Garage to determine its pre-mutation state.
    /// Returns [`ExistingObjectState::Present`] with the content length on
    /// 2xx, [`ExistingObjectState::Missing`] on 404, or
    /// [`ExistingObjectState::Unknown`] on any other status or transport
    /// error.
    async fn load_existing_object(&self, garage_uri: &str) -> ExistingObjectState {
        match self
            .garage_proxy
            .forward(&ProxyRequest {
                method: "HEAD",
                uri: garage_uri,
                headers: &[],
                body: &[],
            })
            .await
        {
            Ok(response) if response.status < 300 => ExistingObjectState::Present {
                size_bytes: response.content_length_bytes(),
            },
            Ok(response) if response.status == 404 => ExistingObjectState::Missing,
            Ok(response) => {
                tracing::warn!(
                    garage_uri,
                    status = response.status,
                    "unexpected HEAD status while loading object metering state"
                );
                ExistingObjectState::Unknown
            }
            Err(error) => {
                tracing::warn!(garage_uri, error = %error, "object metering HEAD probe failed");
                ExistingObjectState::Unknown
            }
        }
    }

    /// Computes the size and object-count delta for a successful mutation
    /// and spawns a fire-and-forget task to persist it. Logs a warning
    /// instead when the existing object state is unknown and no delta can
    /// be calculated.
    fn record_successful_mutation(
        &self,
        mutation: &MeteredObjectMutation<'_>,
        existing_object: ExistingObjectState,
    ) {
        match mutation.metering_delta(existing_object) {
            Some(delta) => spawn_size_metering(
                self.bucket_repo.clone(),
                mutation.bucket_id,
                delta.size_bytes,
                delta.object_count,
                mutation.kind.operation_name(),
            ),
            None if matches!(existing_object, ExistingObjectState::Unknown) => {
                tracing::warn!(
                    bucket_id = %mutation.bucket_id,
                    garage_bucket = mutation.garage_bucket,
                    key = mutation.key,
                    operation = mutation.kind.operation_name(),
                    "object metering skipped because existing object state is unknown"
                );
            }
            None => {}
        }
    }
}

pub struct MeteredObjectMutation<'a> {
    pub bucket_id: Uuid,
    pub garage_bucket: &'a str,
    pub key: &'a str,
    pub headers: &'a [(&'a str, &'a str)],
    pub body: &'a [u8],
    pub kind: MeteredMutationKind,
}

impl MeteredObjectMutation<'_> {
    fn garage_uri(&self) -> String {
        format!("/{}/{}", self.garage_bucket, self.key)
    }

    /// Calculates the size-bytes and object-count deltas for this mutation.
    /// PUT on a missing object yields `+body_len / +1`; PUT on an existing
    /// object yields the size difference with count unchanged; DELETE on an
    /// existing object yields `-size / -1`. Returns `None` for DELETE on a
    /// missing object or any operation when the existing state is unknown.
    fn metering_delta(&self, existing_object: ExistingObjectState) -> Option<BucketMeteringDelta> {
        match (self.kind, existing_object) {
            (MeteredMutationKind::Put, ExistingObjectState::Missing) => Some(BucketMeteringDelta {
                size_bytes: self.body.len() as i64,
                object_count: 1,
            }),
            (MeteredMutationKind::Put, ExistingObjectState::Present { size_bytes }) => {
                Some(BucketMeteringDelta {
                    size_bytes: self.body.len() as i64 - size_bytes,
                    object_count: 0,
                })
            }
            (MeteredMutationKind::Delete, ExistingObjectState::Present { size_bytes }) => {
                Some(BucketMeteringDelta {
                    size_bytes: -size_bytes,
                    object_count: -1,
                })
            }
            (MeteredMutationKind::Delete, ExistingObjectState::Missing)
            | (_, ExistingObjectState::Unknown) => None,
        }
    }
}

#[derive(Clone, Copy)]
pub enum MeteredMutationKind {
    Put,
    Delete,
}

impl MeteredMutationKind {
    fn http_method(self) -> &'static str {
        match self {
            Self::Put => "PUT",
            Self::Delete => "DELETE",
        }
    }

    fn operation_name(self) -> &'static str {
        match self {
            Self::Put => "put_object",
            Self::Delete => "delete_object",
        }
    }
}

#[derive(Clone, Copy)]
enum ExistingObjectState {
    Missing,
    Present { size_bytes: i64 },
    Unknown,
}

struct BucketMeteringDelta {
    size_bytes: i64,
    object_count: i64,
}

struct SameKeyMutationLocks {
    entries: StdMutex<HashMap<String, Arc<SameKeyMutationEntry>>>,
}

impl SameKeyMutationLocks {
    fn new() -> Self {
        Self {
            entries: StdMutex::new(HashMap::new()),
        }
    }

    /// Acquires an async mutex scoped to a `(garage_bucket, key)` pair.
    /// Creates the entry on first access and tracks a holder count so the
    /// entry can be removed from the registry when the last guard drops,
    /// preventing unbounded memory growth.
    async fn lock(self: &Arc<Self>, garage_bucket: &str, key: &str) -> SameKeyMutationGuard {
        let lock_key = format!("{garage_bucket}/{key}");
        let entry = {
            let mut entries = self
                .entries
                .lock()
                .expect("same-key mutation lock registry poisoned");
            let entry = entries
                .entry(lock_key.clone())
                .or_insert_with(|| Arc::new(SameKeyMutationEntry::new()))
                .clone();
            entry.holders.fetch_add(1, Ordering::SeqCst);
            entry
        };

        let guard = entry.mutex.clone().lock_owned().await;
        SameKeyMutationGuard {
            registry: Arc::clone(self),
            lock_key,
            entry,
            guard: Some(guard),
        }
    }
}

struct SameKeyMutationEntry {
    mutex: Arc<tokio::sync::Mutex<()>>,
    holders: AtomicUsize,
}

impl SameKeyMutationEntry {
    fn new() -> Self {
        Self {
            mutex: Arc::new(tokio::sync::Mutex::new(())),
            holders: AtomicUsize::new(0),
        }
    }
}

struct SameKeyMutationGuard {
    registry: Arc<SameKeyMutationLocks>,
    lock_key: String,
    entry: Arc<SameKeyMutationEntry>,
    guard: Option<tokio::sync::OwnedMutexGuard<()>>,
}

impl Drop for SameKeyMutationGuard {
    fn drop(&mut self) {
        self.guard.take();

        if self.entry.holders.fetch_sub(1, Ordering::SeqCst) == 1 {
            let mut entries = self
                .registry
                .entries
                .lock()
                .expect("same-key mutation lock registry poisoned");
            if self.entry.holders.load(Ordering::SeqCst) == 0 {
                entries.remove(&self.lock_key);
            }
        }
    }
}

/// Spawns a fire-and-forget tokio task that calls
/// [`StorageBucketRepo::increment_size`] with the given size and count
/// deltas. Logs a warning on failure but does not propagate errors.
fn spawn_size_metering(
    repo: Arc<dyn StorageBucketRepo + Send + Sync>,
    bucket_id: Uuid,
    size_delta: i64,
    count_delta: i64,
    operation: &'static str,
) {
    tokio::spawn(async move {
        if let Err(error) = repo
            .increment_size(bucket_id, size_delta, count_delta)
            .await
        {
            tracing::warn!(error = %error, bucket_id = %bucket_id, operation, "object metering failed");
        }
    });
}
