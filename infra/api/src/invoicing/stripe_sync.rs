use rust_decimal::Decimal;
use uuid::Uuid;

use crate::errors::ApiError;
use crate::models::InvoiceRow;
use crate::state::AppState;

use super::{ObjectStorageEgressMetadata, ObjectStorageEgressWatermarkTarget};

#[derive(Debug, Clone)]
struct ParsedObjectStorageEgressSnapshot {
    watermark_targets: Vec<ObjectStorageEgressWatermarkTarget>,
    next_cycle_carryforward_cents: Decimal,
}

struct FinalizeEgressState {
    snapshot: Option<ParsedObjectStorageEgressSnapshot>,
    carryforward_restore: Option<(Uuid, Decimal)>,
}

impl FinalizeEgressState {
    fn watermark_targets(&self) -> Vec<ObjectStorageEgressWatermarkTarget> {
        self.snapshot
            .as_ref()
            .map(|snapshot| snapshot.watermark_targets.clone())
            .unwrap_or_default()
    }
}

/// Extract egress watermark targets and carry-forward from invoice line items.
///
/// Scans `object_storage_egress_gb` line items for persisted egress metadata.
/// Zero-cent legacy drafts (pre-Stage-4) without metadata are silently skipped;
/// positive-amount items missing metadata are treated as corruption. Validates
/// that all egress items agree on the `next_cycle_carryforward_cents` value.
fn object_storage_egress_metadata(
    line_items: &[crate::models::InvoiceLineItemRow],
) -> Result<Option<ParsedObjectStorageEgressSnapshot>, ApiError> {
    let mut parsed_snapshot: Option<ParsedObjectStorageEgressSnapshot> = None;
    for line_item in line_items
        .iter()
        .filter(|line_item| line_item.unit == "object_storage_egress_gb")
    {
        let Some(metadata) = line_item.metadata.as_ref() else {
            // Pre-Stage-4 zero-cent drafts never persisted egress metadata. Treat those
            // as legacy drafts that cannot advance watermarks yet, rather than blocking
            // finalization forever. Positive-amount egress without metadata is still a
            // corruption bug because we would lose the billed snapshot.
            if line_item.amount_cents == 0 {
                continue;
            }
            return Err(ApiError::Internal(
                "object storage egress invoice line item is missing watermark metadata".into(),
            ));
        };
        let parsed: ObjectStorageEgressMetadata = serde_json::from_value(metadata.clone())
            .map_err(|e| {
                ApiError::Internal(format!(
                    "object storage egress invoice metadata is invalid: {e}"
                ))
            })?;
        if let Some(snapshot) = parsed_snapshot.as_mut() {
            if snapshot.next_cycle_carryforward_cents != parsed.next_cycle_carryforward_cents {
                return Err(ApiError::Internal(
                    "object storage egress invoice metadata has conflicting carry-forward values"
                        .into(),
                ));
            }
            snapshot.watermark_targets.extend(parsed.watermark_targets);
        } else {
            parsed_snapshot = Some(ParsedObjectStorageEgressSnapshot {
                watermark_targets: parsed.watermark_targets,
                next_cycle_carryforward_cents: parsed.next_cycle_carryforward_cents,
            });
        }
    }
    Ok(parsed_snapshot)
}

/// Advance egress watermarks for each billed bucket, attempting rollback on failure.
///
/// Iterates watermark targets from the invoice snapshot. Each bucket's watermark
/// is clamped to `min(target.egress_bytes, bucket.egress_bytes)` and never moved
/// backward. On any per-bucket failure, attempts to roll back all previously
/// applied watermarks. If rollback itself fails, returns a combined error
/// describing both the original failure and the rollback failure.
async fn advance_object_storage_egress_watermarks(
    state: &AppState,
    targets: &[ObjectStorageEgressWatermarkTarget],
) -> Result<Vec<AppliedObjectStorageEgressWatermark>, ApiError> {
    let mut applied = Vec::new();
    for target in targets {
        let apply_result: Result<(), ApiError> = async {
            let bucket = state
                .storage_bucket_repo
                .get(target.bucket_id)
                .await?
                .ok_or_else(|| {
                    ApiError::Internal(format!(
                        "storage bucket {} disappeared before invoice finalization",
                        target.bucket_id
                    ))
                })?;
            let new_watermark = target
                .egress_bytes
                .min(bucket.egress_bytes)
                .max(bucket.egress_watermark_bytes);
            if new_watermark > bucket.egress_watermark_bytes {
                state
                    .storage_bucket_repo
                    .update_egress_watermark(target.bucket_id, new_watermark)
                    .await?;
                applied.push(AppliedObjectStorageEgressWatermark {
                    bucket_id: target.bucket_id,
                    previous_watermark: bucket.egress_watermark_bytes,
                    applied_watermark: new_watermark,
                });
            }
            Ok(())
        }
        .await;

        if let Err(apply_err) = apply_result {
            if let Err(rollback_err) =
                rollback_object_storage_egress_watermarks(state, &applied).await
            {
                tracing::error!(
                    target_bucket_id = %target.bucket_id,
                    ?apply_err,
                    ?rollback_err,
                    "partial object-storage egress watermark advance failed and rollback also failed"
                );
                return Err(ApiError::Internal(format!(
                    "object storage egress watermark advance failed and rollback also failed: {rollback_err:?}"
                )));
            }
            return Err(apply_err);
        }
    }
    Ok(applied)
}

#[derive(Debug, Clone, Copy)]
struct AppliedObjectStorageEgressWatermark {
    bucket_id: Uuid,
    previous_watermark: i64,
    applied_watermark: i64,
}

/// Reverse previously applied watermark advances in reverse order.
///
/// Skips any bucket whose watermark has been advanced further by another write
/// since the finalize attempt, preserving the newer value. Processes in reverse
/// order to unwind in LIFO sequence.
async fn rollback_object_storage_egress_watermarks(
    state: &AppState,
    applied: &[AppliedObjectStorageEgressWatermark],
) -> Result<(), ApiError> {
    for watermark in applied.iter().rev() {
        let Some(bucket) = state.storage_bucket_repo.get(watermark.bucket_id).await? else {
            return Err(ApiError::Internal(format!(
                "storage bucket {} disappeared while rolling back invoice finalization",
                watermark.bucket_id
            )));
        };

        // Only roll back the watermark move from this finalize attempt. If another
        // write has already advanced the bucket further, preserve the newer value.
        if bucket.egress_watermark_bytes == watermark.applied_watermark {
            state
                .storage_bucket_repo
                .update_egress_watermark(watermark.bucket_id, watermark.previous_watermark)
                .await?;
        }
    }
    Ok(())
}

/// Combined rollback of watermark advances and carry-forward update.
///
/// Attempts both rollback operations independently, collecting errors from
/// each. Returns `Ok` only if both succeed; otherwise returns a joined error
/// message so the caller can log or surface the partial-rollback state.
async fn rollback_egress_finalize_mutations(
    state: &AppState,
    applied_watermarks: &[AppliedObjectStorageEgressWatermark],
    carryforward_restore: Option<(Uuid, Decimal)>,
) -> Result<(), ApiError> {
    let mut rollback_errors = Vec::new();

    if let Err(watermark_err) =
        rollback_object_storage_egress_watermarks(state, applied_watermarks).await
    {
        rollback_errors.push(format!("watermark rollback failed: {watermark_err:?}"));
    }

    if let Some((customer_id, previous_carryforward_cents)) = carryforward_restore {
        match state
            .customer_repo
            .set_object_storage_egress_carryforward_cents(customer_id, previous_carryforward_cents)
            .await
        {
            Ok(true) => {}
            Ok(false) => rollback_errors.push(format!(
                "customer {customer_id} disappeared while rolling back egress carry-forward"
            )),
            Err(carryforward_err) => rollback_errors.push(format!(
                "egress carry-forward rollback failed: {carryforward_err:?}"
            )),
        }
    }

    if rollback_errors.is_empty() {
        Ok(())
    } else {
        Err(ApiError::Internal(rollback_errors.join("; ")))
    }
}

/// Load the object storage egress state and current carry-forward value needed to finalize an invoice.
///
/// Extracts egress metadata from invoice line items and captures the customer's current carry-forward amount. The captured value enables rollback if invoice finalization subsequently fails.
///
/// # Arguments
///
/// * `state` - App state containing repository connections
/// * `invoice` - The invoice row
/// * `line_items` - Invoice line items potentially containing egress metadata
///
/// # Returns
///
/// FinalizeEgressState with extracted egress snapshot (if egress line items exist) and the current carry-forward cents for the customer (if a snapshot was found).
async fn load_finalize_egress_state(
    state: &AppState,
    invoice: &InvoiceRow,
    line_items: &[crate::models::InvoiceLineItemRow],
) -> Result<FinalizeEgressState, ApiError> {
    let snapshot = object_storage_egress_metadata(line_items)?;
    let carryforward_restore = if snapshot.is_some() {
        let customer = state
            .customer_repo
            .find_by_id(invoice.customer_id)
            .await?
            .ok_or_else(|| {
                ApiError::Internal("customer disappeared before invoice finalization".into())
            })?;
        Some((
            invoice.customer_id,
            customer.object_storage_egress_carryforward_cents,
        ))
    } else {
        None
    };
    Ok(FinalizeEgressState {
        snapshot,
        carryforward_restore,
    })
}

fn stripe_invoice_line_items(
    line_items: &[crate::models::InvoiceLineItemRow],
) -> Vec<crate::stripe::StripeInvoiceLineItem> {
    line_items
        .iter()
        .map(|li| crate::stripe::StripeInvoiceLineItem {
            description: li.description.clone(),
            amount_cents: li.amount_cents,
        })
        .collect()
}

/// Persist the object storage egress carry-forward amount after watermarks have been advanced, rolling back all mutations if the customer no longer exists.
///
/// # Arguments
///
/// * `state` - App state containing repository connections
/// * `invoice_id` - ID of the invoice being finalized (used for logging)
/// * `invoice` - The invoice row containing the customer ID
/// * `egress_state` - Contains the egress snapshot and original carry-forward value for rollback
/// * `applied_watermarks` - The watermarks that were advanced, required for rollback
///
/// # Returns
///
/// Ok(()) if carry-forward was persisted or no egress snapshot exists. Err if the customer disappeared during update; rollback is always attempted on failure.
async fn persist_finalize_egress_snapshot(
    state: &AppState,
    invoice_id: Uuid,
    invoice: &InvoiceRow,
    egress_state: &FinalizeEgressState,
    applied_watermarks: &[AppliedObjectStorageEgressWatermark],
) -> Result<(), ApiError> {
    let Some(snapshot) = egress_state.snapshot.as_ref() else {
        return Ok(());
    };

    let updated = state
        .customer_repo
        .set_object_storage_egress_carryforward_cents(
            invoice.customer_id,
            snapshot.next_cycle_carryforward_cents,
        )
        .await?;
    if updated {
        return Ok(());
    }

    if let Err(rollback_err) = rollback_egress_finalize_mutations(
        state,
        applied_watermarks,
        egress_state.carryforward_restore,
    )
    .await
    {
        tracing::error!(
            invoice_id = %invoice_id,
            ?rollback_err,
            "invoice finalization failed after carry-forward update reported missing customer and rollback failed"
        );
        return Err(ApiError::Internal(format!(
            "invoice finalization failed after carry-forward update reported missing customer and rollback failed: {rollback_err:?}"
        )));
    }
    Err(ApiError::Internal(
        "customer disappeared before persisting egress carry-forward".into(),
    ))
}

/// Shared logic: push a draft invoice to Stripe and mark it finalized locally.
/// Returns the updated invoice row.
pub(crate) async fn send_to_stripe_and_finalize(
    state: &AppState,
    invoice_id: Uuid,
    stripe_customer_id: &str,
) -> Result<InvoiceRow, ApiError> {
    let invoice = state
        .invoice_repo
        .find_by_id(invoice_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("invoice disappeared".into()))?;

    let line_items = state.invoice_repo.get_line_items(invoice_id).await?;
    let egress_state = load_finalize_egress_state(state, &invoice, &line_items).await?;
    let stripe_line_items = stripe_invoice_line_items(&line_items);

    let mut metadata = std::collections::HashMap::new();
    metadata.insert("fjcloud_invoice_id".to_string(), invoice_id.to_string());
    let idempotency_key = crate::stripe::invoice_create_idempotency_key(
        invoice.customer_id,
        invoice.period_start,
        invoice.period_end,
    );

    let finalized = state
        .stripe_service
        .create_and_finalize_invoice(
            stripe_customer_id,
            &stripe_line_items,
            Some(&metadata),
            Some(idempotency_key.as_str()),
        )
        .await
        .map_err(|e| ApiError::Internal(format!("stripe error: {e}")))?;

    state
        .invoice_repo
        .set_stripe_fields(
            invoice_id,
            &finalized.stripe_invoice_id,
            &finalized.hosted_invoice_url,
            finalized.pdf_url.as_deref(),
        )
        .await?;

    // Watermarks advance from the exact draft snapshot that was billed, so
    // egress written after draft creation remains unbilled for the next invoice.
    let applied_watermarks =
        advance_object_storage_egress_watermarks(state, &egress_state.watermark_targets()).await?;
    persist_finalize_egress_snapshot(
        state,
        invoice_id,
        &invoice,
        &egress_state,
        &applied_watermarks,
    )
    .await?;

    if let Err(finalize_err) = state.invoice_repo.finalize(invoice_id).await {
        if let Err(rollback_err) = rollback_egress_finalize_mutations(
            state,
            &applied_watermarks,
            if egress_state.snapshot.is_some() {
                egress_state.carryforward_restore
            } else {
                None
            },
        )
        .await
        {
            tracing::error!(
                invoice_id = %invoice_id,
                ?finalize_err,
                ?rollback_err,
                "invoice finalization failed after egress state mutation and rollback also failed"
            );
            return Err(ApiError::Internal(format!(
                "invoice finalization failed after egress state mutation and rollback also failed: {rollback_err:?}"
            )));
        }
        return Err(finalize_err.into());
    }

    state
        .invoice_repo
        .find_by_id(invoice_id)
        .await?
        .ok_or_else(|| ApiError::Internal("invoice disappeared".into()))
}

/// Send an invoice-ready notification email, logging warnings on failure.
///
/// Skips entirely if `hosted_invoice_url` is `None` (Stripe did not return a
/// payment page). Email failures are logged as warnings but never propagated —
/// the invoice finalization is already committed at this point.
pub(crate) async fn send_invoice_ready_email_best_effort(
    state: &AppState,
    customer_email: &str,
    invoice_id: Uuid,
    hosted_invoice_url: Option<&str>,
    pdf_url: Option<&str>,
) {
    let Some(invoice_url) = hosted_invoice_url else {
        tracing::warn!(
            invoice_id = %invoice_id,
            to = %customer_email,
            "skipping invoice-ready email: hosted invoice URL is missing"
        );
        return;
    };

    if let Err(e) = state
        .email_service
        .send_invoice_ready_email(
            customer_email,
            &invoice_id.to_string(),
            invoice_url,
            pdf_url,
        )
        .await
    {
        tracing::warn!(
            invoice_id = %invoice_id,
            to = %customer_email,
            error = %e,
            "failed to send invoice-ready email"
        );
    }
}
