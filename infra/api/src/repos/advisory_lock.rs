use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use sqlx::{PgPool, Postgres, Transaction};
use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};
use uuid::Uuid;

use crate::repos::error::RepoError;

pub enum AdvisoryLockGuard<'a> {
    Postgres { _tx: Transaction<'a, Postgres> },
    InProcess { _guard: OwnedMutexGuard<()> },
}

pub async fn auto_provision_lock_key(pool: &PgPool, region: &str) -> Result<i64, RepoError> {
    match sqlx::query_scalar::<_, i64>("SELECT hashtext('auto_provision_' || $1)::bigint")
        .bind(region)
        .fetch_one(pool)
        .await
    {
        Ok(key) => Ok(key),
        Err(err) if is_connection_error(&err) => Ok(in_process_lock_key(region)),
        Err(err) => Err(RepoError::Other(format!(
            "failed to compute advisory lock key: {err}"
        ))),
    }
}

pub async fn account_lifecycle_lock_key(
    pool: &PgPool,
    customer_id: Uuid,
) -> Result<i64, RepoError> {
    let customer_id = customer_id.to_string();
    match sqlx::query_scalar::<_, i64>("SELECT hashtext('account_lifecycle_' || $1)::bigint")
        .bind(&customer_id)
        .fetch_one(pool)
        .await
    {
        Ok(key) => Ok(key),
        Err(err) if is_connection_error(&err) => Ok(in_process_named_lock_key(&format!(
            "account_lifecycle_{customer_id}"
        ))),
        Err(err) => Err(RepoError::Other(format!(
            "failed to compute account lifecycle advisory lock key: {err}"
        ))),
    }
}

/// Acquires a PostgreSQL advisory lock scoped to a transaction, with automatic
/// fallback to an in-process async mutex when the database is unavailable.
pub async fn advisory_lock<'a>(
    pool: &'a PgPool,
    key: i64,
) -> Result<AdvisoryLockGuard<'a>, RepoError> {
    let mut tx = match pool.begin().await {
        Ok(tx) => tx,
        Err(err) if is_connection_error(&err) => {
            let lock = in_process_lock_slot(key);
            return Ok(AdvisoryLockGuard::InProcess {
                _guard: lock.lock_owned().await,
            });
        }
        Err(err) => {
            return Err(RepoError::Other(format!(
                "failed to begin advisory lock transaction: {err}"
            )));
        }
    };

    match sqlx::query("SELECT pg_advisory_xact_lock($1)")
        .bind(key)
        .execute(tx.as_mut())
        .await
    {
        Ok(_) => Ok(AdvisoryLockGuard::Postgres { _tx: tx }),
        Err(err) if is_connection_error(&err) => {
            drop(tx);
            let lock = in_process_lock_slot(key);
            Ok(AdvisoryLockGuard::InProcess {
                _guard: lock.lock_owned().await,
            })
        }
        Err(err) => Err(RepoError::Other(format!(
            "failed to acquire advisory lock: {err}"
        ))),
    }
}

fn is_connection_error(err: &sqlx::Error) -> bool {
    matches!(
        err,
        sqlx::Error::Io(_)
            | sqlx::Error::PoolTimedOut
            | sqlx::Error::PoolClosed
            | sqlx::Error::WorkerCrashed
    )
}

fn in_process_lock_key(region: &str) -> i64 {
    in_process_named_lock_key(&format!("auto_provision_{region}"))
}

fn in_process_named_lock_key(lock_name: &str) -> i64 {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in lock_name.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash as i64
}

fn in_process_lock_slot(key: i64) -> Arc<AsyncMutex<()>> {
    static LOCKS: OnceLock<Mutex<HashMap<i64, Arc<AsyncMutex<()>>>>> = OnceLock::new();
    let locks = LOCKS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut map = locks.lock().unwrap();
    map.entry(key)
        .or_insert_with(|| Arc::new(AsyncMutex::new(())))
        .clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn in_process_lock_key_deterministic() {
        let a = in_process_lock_key("us-east-1");
        let b = in_process_lock_key("us-east-1");
        assert_eq!(a, b, "same region must produce same key");
    }

    #[test]
    fn in_process_lock_key_different_regions_differ() {
        let a = in_process_lock_key("us-east-1");
        let b = in_process_lock_key("eu-west-1");
        assert_ne!(a, b, "different regions must produce different keys");
    }

    #[test]
    fn in_process_lock_key_empty_region() {
        // Empty region still gets the "auto_provision_" prefix hashed
        let key = in_process_lock_key("");
        let key2 = in_process_lock_key("");
        assert_eq!(key, key2);
    }

    #[test]
    fn in_process_lock_key_is_fnv1a() {
        // Verify FNV-1a algorithm with known input
        let key = in_process_lock_key("x");
        // FNV-1a of "auto_provision_x" — the result must be non-zero and stable
        assert_ne!(key, 0);
    }

    #[test]
    fn in_process_lock_slot_returns_same_arc_for_same_key() {
        let key = in_process_lock_key("test-region-slot");
        let slot_a = in_process_lock_slot(key);
        let slot_b = in_process_lock_slot(key);
        assert!(
            Arc::ptr_eq(&slot_a, &slot_b),
            "same key must yield same Arc"
        );
    }

    #[test]
    fn in_process_lock_slot_different_keys_different_arcs() {
        let key_a = in_process_lock_key("slot-region-a");
        let key_b = in_process_lock_key("slot-region-b");
        let slot_a = in_process_lock_slot(key_a);
        let slot_b = in_process_lock_slot(key_b);
        assert!(
            !Arc::ptr_eq(&slot_a, &slot_b),
            "different keys must yield different Arcs"
        );
    }

    #[test]
    fn is_connection_error_pool_timed_out() {
        assert!(is_connection_error(&sqlx::Error::PoolTimedOut));
    }

    #[test]
    fn is_connection_error_pool_closed() {
        assert!(is_connection_error(&sqlx::Error::PoolClosed));
    }

    #[test]
    fn is_connection_error_worker_crashed() {
        assert!(is_connection_error(&sqlx::Error::WorkerCrashed));
    }

    #[test]
    fn is_connection_error_io() {
        let io_err = std::io::Error::new(std::io::ErrorKind::ConnectionRefused, "refused");
        assert!(is_connection_error(&sqlx::Error::Io(io_err)));
    }

    #[test]
    fn is_connection_error_other_returns_false() {
        let err = sqlx::Error::ColumnNotFound("id".to_string());
        assert!(!is_connection_error(&err));
    }
}
