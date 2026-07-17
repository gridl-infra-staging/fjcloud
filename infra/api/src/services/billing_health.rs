use chrono::{DateTime, Duration, Utc};
use serde::Serialize;
use uuid::Uuid;

use crate::repos::{InvoiceRepo, RepoError};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum BillingHealth {
    Red,
    Yellow,
    Grey,
    Green,
}

/// Inputs that drive billing-health classification. SSOT for the field set
/// consumed by `derive`; gathering of these signals from persistent storage
/// belongs in `invoice_signals_for_customer`.
#[derive(Debug, Clone, Copy)]
pub struct BillingHealthSignals {
    pub overdue_invoice_count: i64,
    /// True if at least one invoice has ever reached `paid` status for the customer.
    pub has_ever_been_billed: bool,
    /// True if any paid invoice has `paid_at` within the last 60 days.
    pub recent_paid_invoice_within_60_days: bool,
}

/// Window after which a customer who has been billed but has no recent paid
/// invoice is treated as `Yellow` (stale billing relationship).
const RECENT_PAID_WINDOW_DAYS: i64 = 60;

/// Derive tenant billing health from customer status and billing signals.
///
/// Contract:
/// - `customer_status == "deleted"` → `Grey`
/// - `overdue_invoice_count > 0` → `Red`
/// - `has_ever_been_billed && !recent_paid_invoice_within_60_days` → `Yellow`
/// - otherwise → `Green`
pub fn derive(customer_status: &str, signals: &BillingHealthSignals) -> BillingHealth {
    if customer_status == "deleted" {
        return BillingHealth::Grey;
    }

    if signals.overdue_invoice_count > 0 {
        return BillingHealth::Red;
    }

    if signals.has_ever_been_billed && !signals.recent_paid_invoice_within_60_days {
        return BillingHealth::Yellow;
    }

    BillingHealth::Green
}

/// Two-value pair returned by `invoice_signals_for_customer`. The
/// `overdue_invoice_count` lives on the customer row and is supplied
/// separately at the callsite.
#[derive(Debug, Clone, Copy, Default)]
pub struct InvoiceSignals {
    pub has_ever_been_billed: bool,
    pub recent_paid_invoice_within_60_days: bool,
}

/// Compute paid-invoice signals for a customer from the `InvoiceRepo`.
///
/// Walks the customer's invoices and folds them into the two booleans
/// consumed by `derive`. Kept async + repo-bound so `derive` itself
/// remains pure and trivially unit-testable.
pub async fn invoice_signals_for_customer(
    invoice_repo: &(dyn InvoiceRepo + Send + Sync),
    customer_id: Uuid,
    now: DateTime<Utc>,
) -> Result<InvoiceSignals, RepoError> {
    let invoices = invoice_repo.list_by_customer(customer_id).await?;
    let cutoff = now - Duration::days(RECENT_PAID_WINDOW_DAYS);

    let mut signals = InvoiceSignals::default();
    for invoice in invoices {
        if invoice.status == "paid" {
            signals.has_ever_been_billed = true;
            if let Some(paid_at) = invoice.paid_at {
                if paid_at >= cutoff {
                    signals.recent_paid_invoice_within_60_days = true;
                }
            }
        }
    }
    Ok(signals)
}

#[cfg(test)]
mod tests {
    use super::{derive, BillingHealth, BillingHealthSignals};

    fn signals(
        overdue_invoice_count: i64,
        has_ever_been_billed: bool,
        recent_paid_invoice_within_60_days: bool,
    ) -> BillingHealthSignals {
        BillingHealthSignals {
            overdue_invoice_count,
            has_ever_been_billed,
            recent_paid_invoice_within_60_days,
        }
    }

    #[test]
    fn deleted_status_overrides_other_inputs_to_grey() {
        assert_eq!(
            derive("deleted", &signals(4, true, true)),
            BillingHealth::Grey
        );
        assert_eq!(
            derive("deleted", &signals(0, false, false)),
            BillingHealth::Grey
        );
    }

    #[test]
    fn positive_overdue_invoice_count_is_red() {
        assert_eq!(
            derive("active", &signals(1, true, true)),
            BillingHealth::Red
        );
        assert_eq!(
            derive("active", &signals(5, false, false)),
            BillingHealth::Red
        );
    }

    #[test]
    fn ever_billed_without_recent_paid_invoice_is_yellow() {
        assert_eq!(
            derive("active", &signals(0, true, false)),
            BillingHealth::Yellow
        );
    }

    #[test]
    fn ever_billed_with_recent_paid_invoice_is_green() {
        assert_eq!(
            derive("active", &signals(0, true, true)),
            BillingHealth::Green
        );
    }

    #[test]
    fn never_billed_active_customer_with_no_overdue_is_green() {
        assert_eq!(
            derive("active", &signals(0, false, false)),
            BillingHealth::Green
        );
    }

    #[test]
    fn overdue_takes_precedence_over_yellow_signals() {
        // A customer who has been billed, has no recent paid invoice, AND has
        // overdue invoices should surface Red, not Yellow — overdue is the
        // higher-severity classification.
        assert_eq!(
            derive("active", &signals(2, true, false)),
            BillingHealth::Red
        );
    }
}
