use serde_json::Value;
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

use super::{
    active_reservation_predicate, customer_generation_admission_error, repo_error,
    ActiveReservationRow, PgAlgoliaImportJobRepo, ReservationPlan, VmCapacityRow,
    DEFAULT_ACTIVE_CUSTOMER_IMPORT_BYTES_LIMIT, DEFAULT_ACTIVE_CUSTOMER_IMPORT_JOB_LIMIT,
    DEFAULT_ACTIVE_NODE_IMPORT_JOB_LIMIT, DEFAULT_ACTIVE_NODE_TRANSIENT_BYTES_LIMIT,
    DEFAULT_INDEX_LIMIT, DEFAULT_STORAGE_LIMIT_BYTES,
};
use crate::models::algolia_import_job::{
    AlgoliaImportDestinationKind, AlgoliaImportErrorCode, AlgoliaImportJob, AlgoliaImportJobRow,
    NewAlgoliaImportJob,
};
use crate::repos::{AlgoliaImportJobAdmissionError, RepoError};

impl PgAlgoliaImportJobRepo {
    /// Count each active catalog target or unpublished create reservation once.
    ///
    /// A promoted create remains an active reservation until engine ACK. The
    /// logical target already exists in the catalog at that point, so the
    /// reservation must not consume a second slot.
    pub async fn count_logical_index_slots(&self, customer_id: Uuid) -> Result<i64, RepoError> {
        sqlx::query_scalar(&logical_index_slot_count_sql())
            .bind(customer_id)
            .fetch_one(&self.pool)
            .await
            .map_err(repo_error)
    }

    pub(super) async fn build_reservation_plan(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        job: &NewAlgoliaImportJob,
    ) -> Result<ReservationPlan, AlgoliaImportJobAdmissionError> {
        let lifecycle_generation = self
            .lock_active_customer_generation(tx, job.customer_id())
            .await
            .map_err(customer_generation_admission_error)?;
        job.validate_target_binding(lifecycle_generation)
            .map_err(AlgoliaImportJobAdmissionError::Refused)?;
        let overrides = self
            .customer_quota_overrides_for_update(tx, job.customer_id())
            .await?;
        let active_logical_index_count = self
            .logical_index_slot_count_for_update(tx, job.customer_id())
            .await?;
        let active_reservations = self
            .active_reservations_for_update(tx, job.customer_id())
            .await?;
        let active_reserved = active_reserved_totals(&active_reservations);
        let current_storage = self
            .current_customer_storage_bytes(tx, job.customer_id())
            .await?;
        let index_limit = quota_limit(&overrides, concat!("max", "_indexes"), DEFAULT_INDEX_LIMIT);
        let storage_limit = quota_limit(
            &overrides,
            concat!("max", "_storage_bytes"),
            DEFAULT_STORAGE_LIMIT_BYTES,
        );

        let current_target_size =
            if job.destination().kind() == AlgoliaImportDestinationKind::Replace {
                self.current_target_storage_bytes(
                    tx,
                    job.customer_id(),
                    job.destination().logical_target(),
                )
                .await?
            } else {
                0
            };
        let reserved_index_count =
            i64::from(job.destination().kind() == AlgoliaImportDestinationKind::Create);
        let reserved_customer_storage_bytes =
            (job.source_size_bytes() - current_target_size).max(0);
        let reserved_node_transient_bytes = match job.destination().vm_id() {
            Some(_) => job.source_size_bytes() + current_target_size.saturating_mul(2),
            None => 0,
        };
        let reservation = ReservationPlan {
            lifecycle_generation,
            reserved_index_count,
            reserved_customer_storage_bytes,
            reserved_node_transient_bytes,
        };

        if active_logical_index_count + reserved_index_count > index_limit {
            return Err(AlgoliaImportJobAdmissionError::Refused(
                AlgoliaImportErrorCode::QuotaExceeded,
            ));
        }
        if current_storage
            + active_reserved.reserved_customer_storage_bytes
            + reserved_customer_storage_bytes
            > storage_limit
        {
            return Err(AlgoliaImportJobAdmissionError::Refused(
                AlgoliaImportErrorCode::QuotaExceeded,
            ));
        }
        enforce_active_import_limits(
            &active_reservations,
            DEFAULT_ACTIVE_CUSTOMER_IMPORT_JOB_LIMIT,
            DEFAULT_ACTIVE_CUSTOMER_IMPORT_BYTES_LIMIT,
            &reservation,
        )?;
        if let Some(vm_id) = job.destination().vm_id() {
            let node_reservations = self.node_active_reservations_for_update(tx, vm_id).await?;
            enforce_active_node_import_limits(
                &node_reservations,
                DEFAULT_ACTIVE_NODE_IMPORT_JOB_LIMIT,
                DEFAULT_ACTIVE_NODE_TRANSIENT_BYTES_LIMIT,
                &reservation,
            )?;
            let node_reserved = active_reserved_totals(&node_reservations);
            let headroom = self.node_disk_headroom_for_update(tx, vm_id).await?;
            if node_reserved.reserved_node_transient_bytes + reserved_node_transient_bytes
                > headroom
            {
                return Err(AlgoliaImportJobAdmissionError::Refused(
                    AlgoliaImportErrorCode::BackendUnavailable,
                ));
            }
        }

        Ok(reservation)
    }

    pub(super) async fn insert_with_reservation(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        job: &NewAlgoliaImportJob,
        reservation: &ReservationPlan,
    ) -> Result<AlgoliaImportJob, sqlx::Error> {
        sqlx::query_as::<_, AlgoliaImportJobRow>(
            "INSERT INTO algolia_import_jobs
             (customer_id, tenant_id, algolia_app_id, destination_kind, logical_target,
              destination_region,
              destination_deployment_id, destination_vm_id, physical_uid, source_name,
              idempotency_key, canonical_fingerprint, routing_identity, source_size_bytes,
              reserved_index_count, reserved_customer_storage_bytes,
              reserved_node_transient_bytes, lifecycle_generation)
             VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18)
             RETURNING *",
        )
        .bind(job.customer_id())
        .bind(job.tenant_id())
        .bind(job.algolia_app_id())
        .bind(job.destination().kind().as_str())
        .bind(job.destination().logical_target())
        .bind(job.destination().region())
        .bind(job.destination().deployment_id())
        .bind(job.destination().vm_id())
        .bind(job.destination().physical_uid())
        .bind(job.source_name())
        .bind(job.idempotency_key())
        .bind(job.canonical_fingerprint())
        .bind(job.destination().routing_identity())
        .bind(job.source_size_bytes())
        .bind(reservation.reserved_index_count)
        .bind(reservation.reserved_customer_storage_bytes)
        .bind(reservation.reserved_node_transient_bytes)
        .bind(reservation.lifecycle_generation)
        .fetch_one(&mut **tx)
        .await
        .map(Into::into)
    }

    async fn active_reservations_for_update(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        customer_id: Uuid,
    ) -> Result<Vec<ActiveReservationRow>, RepoError> {
        sqlx::query_as::<_, ActiveReservationRow>(&format!(
            "SELECT reserved_index_count, reserved_customer_storage_bytes,
                    reserved_node_transient_bytes
             FROM algolia_import_jobs
             WHERE customer_id = $1 AND ({})
             FOR UPDATE",
            active_reservation_predicate()
        ))
        .bind(customer_id)
        .fetch_all(&mut **tx)
        .await
        .map_err(repo_error)
    }

    async fn customer_quota_overrides_for_update(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        customer_id: Uuid,
    ) -> Result<Vec<Value>, RepoError> {
        sqlx::query_scalar(
            "SELECT resource_quota
             FROM customer_tenants
             WHERE customer_id = $1
             ORDER BY created_at ASC, tenant_id ASC
             FOR UPDATE",
        )
        .bind(customer_id)
        .fetch_all(&mut **tx)
        .await
        .map_err(repo_error)
    }

    async fn logical_index_slot_count_for_update(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        customer_id: Uuid,
    ) -> Result<i64, RepoError> {
        sqlx::query_scalar(&logical_index_slot_count_sql())
            .bind(customer_id)
            .fetch_one(&mut **tx)
            .await
            .map_err(repo_error)
    }

    async fn current_customer_storage_bytes(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        customer_id: Uuid,
    ) -> Result<i64, RepoError> {
        sqlx::query_scalar(
            "SELECT COALESCE(SUM(storage_bytes_avg), 0)::BIGINT
             FROM usage_daily
             WHERE customer_id = $1
               AND date = COALESCE((SELECT MAX(date) FROM usage_daily WHERE customer_id = $1), CURRENT_DATE)",
        )
        .bind(customer_id)
        .fetch_one(&mut **tx)
        .await
        .map_err(repo_error)
    }

    async fn current_target_storage_bytes(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        customer_id: Uuid,
        target: &str,
    ) -> Result<i64, RepoError> {
        let latest_target: Option<i64> = sqlx::query_scalar(
            "SELECT value
             FROM usage_records
             WHERE customer_id = $1
               AND tenant_id = $2
               AND event_type = 'storage_bytes'
               AND value >= 0
             ORDER BY recorded_at DESC, id DESC
             LIMIT 1",
        )
        .bind(customer_id)
        .bind(target)
        .fetch_optional(&mut **tx)
        .await
        .map_err(repo_error)?;
        match latest_target {
            Some(value) => Ok(value),
            None => self.current_customer_storage_bytes(tx, customer_id).await,
        }
    }

    async fn node_active_reservations_for_update(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        vm_id: Uuid,
    ) -> Result<Vec<ActiveReservationRow>, RepoError> {
        sqlx::query_as::<_, ActiveReservationRow>(&format!(
            "SELECT reserved_index_count, reserved_customer_storage_bytes,
                    reserved_node_transient_bytes
             FROM algolia_import_jobs
             WHERE destination_vm_id = $1 AND ({})
             FOR UPDATE",
            active_reservation_predicate()
        ))
        .bind(vm_id)
        .fetch_all(&mut **tx)
        .await
        .map_err(repo_error)
    }

    async fn node_disk_headroom_for_update(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        vm_id: Uuid,
    ) -> Result<i64, RepoError> {
        let row = sqlx::query_as::<_, VmCapacityRow>(
            "SELECT capacity, current_load
             FROM vm_inventory
             WHERE id = $1
             FOR UPDATE",
        )
        .bind(vm_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(repo_error)?
        .ok_or(RepoError::NotFound)?;
        Ok(json_disk_bytes(&row.capacity) - json_disk_bytes(&row.current_load))
    }
}

fn logical_index_slot_count_sql() -> String {
    format!(
        "SELECT
             (SELECT COUNT(*)
              FROM customer_tenants ct
              JOIN customer_deployments cd ON cd.id = ct.deployment_id
              WHERE ct.customer_id = $1 AND cd.status != 'terminated')
             +
             (SELECT COALESCE(SUM(j.reserved_index_count), 0)::BIGINT
              FROM algolia_import_jobs j
              WHERE j.customer_id = $1
                AND ({})
                AND NOT EXISTS (
                    SELECT 1
                    FROM customer_tenants ct
                    JOIN customer_deployments cd ON cd.id = ct.deployment_id
                    WHERE ct.customer_id = j.customer_id
                      AND ct.tenant_id = j.logical_target
                      AND cd.status != 'terminated'
                ))",
        active_reservation_predicate()
    )
}

fn positive_i64(value: Option<&Value>) -> Option<i64> {
    value
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .or_else(|| {
            value
                .and_then(Value::as_u64)
                .and_then(|raw| i64::try_from(raw).ok())
                .filter(|value| *value > 0)
        })
}

fn quota_limit(overrides: &[Value], key: &str, default: i64) -> i64 {
    overrides
        .iter()
        .find(|value| value.as_object().is_some_and(|fields| !fields.is_empty()))
        .and_then(|value| positive_i64(value.get(key)))
        .unwrap_or(default)
}

fn json_disk_bytes(value: &Value) -> i64 {
    positive_i64(value.get("disk_bytes")).unwrap_or(0)
}

fn active_reserved_totals(rows: &[ActiveReservationRow]) -> ReservationPlan {
    rows.iter().fold(
        ReservationPlan {
            lifecycle_generation: 0,
            reserved_index_count: 0,
            reserved_customer_storage_bytes: 0,
            reserved_node_transient_bytes: 0,
        },
        |mut total, row| {
            total.reserved_index_count += row.reserved_index_count;
            total.reserved_customer_storage_bytes += row.reserved_customer_storage_bytes;
            total.reserved_node_transient_bytes += row.reserved_node_transient_bytes;
            total
        },
    )
}

fn backend_unavailable() -> AlgoliaImportJobAdmissionError {
    AlgoliaImportJobAdmissionError::Refused(AlgoliaImportErrorCode::BackendUnavailable)
}

fn enforce_active_import_limits(
    active: &[ActiveReservationRow],
    job_limit: i64,
    bytes_limit: i64,
    incoming: &ReservationPlan,
) -> Result<(), AlgoliaImportJobAdmissionError> {
    let active_totals = active_reserved_totals(active);
    if active.len() as i64 + 1 > job_limit {
        return Err(backend_unavailable());
    }
    if active_totals.reserved_customer_storage_bytes + incoming.reserved_customer_storage_bytes
        > bytes_limit
    {
        return Err(backend_unavailable());
    }
    Ok(())
}

fn enforce_active_node_import_limits(
    active: &[ActiveReservationRow],
    job_limit: i64,
    bytes_limit: i64,
    incoming: &ReservationPlan,
) -> Result<(), AlgoliaImportJobAdmissionError> {
    let active_totals = active_reserved_totals(active);
    if active.len() as i64 + 1 > job_limit {
        return Err(backend_unavailable());
    }
    if active_totals.reserved_node_transient_bytes + incoming.reserved_node_transient_bytes
        > bytes_limit
    {
        return Err(backend_unavailable());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn active_row(index_count: i64, customer_bytes: i64, node_bytes: i64) -> ActiveReservationRow {
        ActiveReservationRow {
            reserved_index_count: index_count,
            reserved_customer_storage_bytes: customer_bytes,
            reserved_node_transient_bytes: node_bytes,
        }
    }

    #[test]
    fn active_import_limit_rejections_use_backend_unavailable() {
        let active = vec![active_row(1, 1_000, 2_000), active_row(1, 1_500, 2_500)];
        let incoming = ReservationPlan {
            lifecycle_generation: 1,
            reserved_index_count: 1,
            reserved_customer_storage_bytes: 500,
            reserved_node_transient_bytes: 1_000,
        };

        let result = enforce_active_import_limits(&active, 2, 10_000, &incoming);

        assert!(matches!(
            result,
            Err(AlgoliaImportJobAdmissionError::Refused(
                AlgoliaImportErrorCode::BackendUnavailable
            ))
        ));
    }

    #[test]
    fn active_import_byte_limit_counts_existing_reservations_and_incoming_plan() {
        let active = vec![active_row(1, 4_000, 0), active_row(1, 3_000, 0)];
        let incoming = ReservationPlan {
            lifecycle_generation: 1,
            reserved_index_count: 1,
            reserved_customer_storage_bytes: 3_001,
            reserved_node_transient_bytes: 0,
        };

        let result = enforce_active_import_limits(&active, 10, 10_000, &incoming);

        assert!(matches!(
            result,
            Err(AlgoliaImportJobAdmissionError::Refused(
                AlgoliaImportErrorCode::BackendUnavailable
            ))
        ));
    }

    #[test]
    fn active_node_limit_rejections_use_backend_unavailable() {
        let active = vec![active_row(0, 0, 2_000), active_row(0, 0, 3_000)];
        let incoming = ReservationPlan {
            lifecycle_generation: 1,
            reserved_index_count: 0,
            reserved_customer_storage_bytes: 0,
            reserved_node_transient_bytes: 1_000,
        };

        let result = enforce_active_node_import_limits(&active, 2, 10_000, &incoming);

        assert!(matches!(
            result,
            Err(AlgoliaImportJobAdmissionError::Refused(
                AlgoliaImportErrorCode::BackendUnavailable
            ))
        ));
    }

    #[test]
    fn active_node_byte_limit_counts_existing_reservations_and_incoming_plan() {
        let active = vec![active_row(0, 0, 4_000), active_row(0, 0, 3_000)];
        let incoming = ReservationPlan {
            lifecycle_generation: 1,
            reserved_index_count: 0,
            reserved_customer_storage_bytes: 0,
            reserved_node_transient_bytes: 3_001,
        };

        let result = enforce_active_node_import_limits(&active, 10, 10_000, &incoming);

        assert!(matches!(
            result,
            Err(AlgoliaImportJobAdmissionError::Refused(
                AlgoliaImportErrorCode::BackendUnavailable
            ))
        ));
    }
}
