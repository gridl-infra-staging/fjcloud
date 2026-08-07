use chrono::{DateTime, Duration, Utc};
use serde::Serialize;
use std::collections::HashMap;
use uuid::Uuid;

use crate::models::InvoiceRow;
use crate::repos::invoice_repo::PAID_INVOICE_STATUS;
use crate::repos::{InvoiceRepo, RepoError};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, utoipa::ToSchema)]
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
const DELETED_CUSTOMER_STATUS: &str = "deleted";

/// Whether invoice-derived signals can be skipped for this customer status.
/// Deleted customers are always Grey, regardless of invoice history.
pub fn skips_invoice_signals(customer_status: &str) -> bool {
    customer_status == DELETED_CUSTOMER_STATUS
}

/// Derive tenant billing health from customer status and billing signals.
///
/// Contract:
/// - `customer_status == "deleted"` → `Grey`
/// - `overdue_invoice_count > 0` → `Red`
/// - `has_ever_been_billed && !recent_paid_invoice_within_60_days` → `Yellow`
/// - otherwise → `Green`
pub fn derive(customer_status: &str, signals: &BillingHealthSignals) -> BillingHealth {
    if skips_invoice_signals(customer_status) {
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

/// The paid-invoice cutoff instant: any paid invoice with `paid_at >= cutoff`
/// counts as a recent paid invoice.
fn recent_paid_cutoff(now: DateTime<Utc>) -> DateTime<Utc> {
    now - Duration::days(RECENT_PAID_WINDOW_DAYS)
}

/// Classify an optional payment timestamp against the inclusive recency
/// boundary shared by single-customer and batched invoice signals.
fn paid_at_is_recent(paid_at: Option<DateTime<Utc>>, cutoff: DateTime<Utc>) -> bool {
    paid_at.is_some_and(|paid_at| paid_at >= cutoff)
}

/// Fold one invoice into a customer's running `InvoiceSignals`.
fn fold_invoice_into_signals(
    signals: &mut InvoiceSignals,
    invoice: &InvoiceRow,
    cutoff: DateTime<Utc>,
) {
    if invoice.status == PAID_INVOICE_STATUS {
        signals.has_ever_been_billed = true;
        if paid_at_is_recent(invoice.paid_at, cutoff) {
            signals.recent_paid_invoice_within_60_days = true;
        }
    }
}

/// Compute paid-invoice signals for a customer from the `InvoiceRepo`.
///
/// Walks the customer's invoices and folds them into the two booleans
/// consumed by `derive`. Kept async + repo-bound so `derive` itself
/// remains pure and trivially unit-testable. Retained for single-row callers
/// (`get_tenant`, write paths, snapshots); admin listing uses the batched
/// [`invoice_signals_for_customers`] instead.
pub async fn invoice_signals_for_customer(
    invoice_repo: &(dyn InvoiceRepo + Send + Sync),
    customer_id: Uuid,
    now: DateTime<Utc>,
) -> Result<InvoiceSignals, RepoError> {
    let invoices = invoice_repo.list_by_customer(customer_id).await?;
    let cutoff = recent_paid_cutoff(now);

    let mut signals = InvoiceSignals::default();
    for invoice in &invoices {
        fold_invoice_into_signals(&mut signals, invoice, cutoff);
    }
    Ok(signals)
}

/// Batched variant of [`invoice_signals_for_customer`]: fetch one aggregate
/// payment summary per listed customer and translate it into billing signals.
/// Used by admin tenant listing so N customers cost one bounded invoice read
/// instead of N reads or an unbounded transfer of full invoice histories.
///
/// A customer with invoices but no paid invoice receives default-valued
/// signals. A customer with no invoices is absent from the returned map, and
/// callers treat that missing key as `InvoiceSignals::default()`. Callers must
/// exclude deleted customers because `derive` always classifies them `Grey`.
pub async fn invoice_signals_for_customers(
    invoice_repo: &(dyn InvoiceRepo + Send + Sync),
    customer_ids: &[Uuid],
    now: DateTime<Utc>,
) -> Result<HashMap<Uuid, InvoiceSignals>, RepoError> {
    let payment_summaries = invoice_repo
        .payment_summaries_by_customers(customer_ids)
        .await?;
    let cutoff = recent_paid_cutoff(now);

    Ok(payment_summaries
        .into_iter()
        .map(|summary| {
            let signals = InvoiceSignals {
                has_ever_been_billed: summary.has_ever_been_billed,
                recent_paid_invoice_within_60_days: paid_at_is_recent(
                    summary.latest_paid_at,
                    cutoff,
                ),
            };
            (summary.customer_id, signals)
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::{derive, skips_invoice_signals, BillingHealth, BillingHealthSignals};

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
    fn deleted_status_is_the_only_invoice_signal_skip_status() {
        assert!(skips_invoice_signals("deleted"));
        assert!(!skips_invoice_signals("active"));
        assert!(!skips_invoice_signals("suspended"));
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

#[cfg(test)]
mod batched_signal_tests {
    use super::*;
    use crate::models::{InvoiceLineItemRow, InvoiceRow};
    use crate::repos::invoice_repo::{
        AdminInvoiceSummaryRow, CustomerInvoicePaymentSummary, NewInvoice, NewLineItem,
    };
    use async_trait::async_trait;
    use chrono::{NaiveDate, TimeZone};
    use std::collections::BTreeSet;

    /// Minimal `InvoiceRepo` stub for comparing the batch summary path with the
    /// retained single-customer invoice-row path.
    struct StubInvoiceRepo {
        invoices: Vec<InvoiceRow>,
        payment_summaries: Vec<CustomerInvoicePaymentSummary>,
    }

    #[async_trait]
    impl InvoiceRepo for StubInvoiceRepo {
        async fn payment_summaries_by_customers(
            &self,
            customer_ids: &[Uuid],
        ) -> Result<Vec<CustomerInvoicePaymentSummary>, RepoError> {
            if customer_ids.is_empty() {
                return Ok(Vec::new());
            }
            let wanted: BTreeSet<Uuid> = customer_ids.iter().copied().collect();
            Ok(self
                .payment_summaries
                .iter()
                .filter(|summary| wanted.contains(&summary.customer_id))
                .copied()
                .collect())
        }

        async fn list_by_customer(&self, customer_id: Uuid) -> Result<Vec<InvoiceRow>, RepoError> {
            Ok(self
                .invoices
                .iter()
                .filter(|invoice| invoice.customer_id == customer_id)
                .cloned()
                .collect())
        }

        async fn create_with_line_items(
            &self,
            _invoice: NewInvoice,
            _line_items: Vec<NewLineItem>,
        ) -> Result<(InvoiceRow, Vec<InvoiceLineItemRow>), RepoError> {
            unreachable!("not exercised by batched signal tests")
        }
        async fn revenue_summary(&self) -> Result<Vec<AdminInvoiceSummaryRow>, RepoError> {
            unreachable!("not exercised by batched signal tests")
        }
        async fn find_by_id(&self, _id: Uuid) -> Result<Option<InvoiceRow>, RepoError> {
            unreachable!("not exercised by batched signal tests")
        }
        async fn get_line_items(
            &self,
            _invoice_id: Uuid,
        ) -> Result<Vec<InvoiceLineItemRow>, RepoError> {
            unreachable!("not exercised by batched signal tests")
        }
        async fn finalize(&self, _id: Uuid) -> Result<InvoiceRow, RepoError> {
            unreachable!("not exercised by batched signal tests")
        }
        async fn mark_paid(&self, _id: Uuid) -> Result<InvoiceRow, RepoError> {
            unreachable!("not exercised by batched signal tests")
        }
        async fn mark_failed(&self, _id: Uuid) -> Result<InvoiceRow, RepoError> {
            unreachable!("not exercised by batched signal tests")
        }
        async fn mark_refunded(&self, _id: Uuid) -> Result<InvoiceRow, RepoError> {
            unreachable!("not exercised by batched signal tests")
        }
        async fn set_stripe_fields(
            &self,
            _id: Uuid,
            _stripe_invoice_id: &str,
            _hosted_invoice_url: &str,
            _pdf_url: Option<&str>,
        ) -> Result<(), RepoError> {
            unreachable!("not exercised by batched signal tests")
        }
        async fn find_by_stripe_invoice_id(
            &self,
            _stripe_invoice_id: &str,
        ) -> Result<Option<InvoiceRow>, RepoError> {
            unreachable!("not exercised by batched signal tests")
        }
    }

    fn at(year: i32, month: u32, day: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(year, month, day, 0, 0, 0).unwrap()
    }

    fn invoice_with_status(
        customer_id: Uuid,
        status: &str,
        paid_at: Option<DateTime<Utc>>,
    ) -> InvoiceRow {
        InvoiceRow {
            id: Uuid::new_v4(),
            customer_id,
            period_start: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
            period_end: NaiveDate::from_ymd_opt(2026, 1, 31).unwrap(),
            subtotal_cents: 0,
            tax_cents: 0,
            total_cents: 0,
            currency: "usd".to_string(),
            status: status.to_string(),
            minimum_applied: false,
            stripe_invoice_id: None,
            hosted_invoice_url: None,
            pdf_url: None,
            created_at: paid_at.unwrap_or_else(|| at(2026, 1, 1)),
            finalized_at: paid_at,
            paid_at,
        }
    }

    fn payment_summary(
        customer_id: Uuid,
        has_ever_been_billed: bool,
        latest_paid_at: Option<DateTime<Utc>>,
    ) -> CustomerInvoicePaymentSummary {
        CustomerInvoicePaymentSummary {
            customer_id,
            has_ever_been_billed,
            latest_paid_at,
        }
    }

    #[tokio::test]
    async fn batched_signals_group_paid_stale_and_never_billed_correctly() {
        // Fixed clock: cutoff is now - 60 days = 2026-04-02.
        let now = at(2026, 6, 1);

        let never_billed = Uuid::new_v4(); // only a draft invoice → never paid
        let recent_paid = Uuid::new_v4(); // paid 2026-05-01 → 31 days ago, recent
        let stale_paid = Uuid::new_v4(); // paid 2026-01-15 → >60 days, stale
        let missing = Uuid::new_v4(); // no invoices at all

        let repo = StubInvoiceRepo {
            invoices: Vec::new(),
            payment_summaries: vec![
                payment_summary(never_billed, false, None),
                payment_summary(recent_paid, true, Some(at(2026, 5, 1))),
                payment_summary(stale_paid, true, Some(at(2026, 1, 15))),
            ],
        };

        let ids = [never_billed, recent_paid, stale_paid, missing];
        let signals = invoice_signals_for_customers(&repo, &ids, now)
            .await
            .unwrap();

        // never billed: an entry exists (draft invoice seen) but both flags false.
        let never = signals.get(&never_billed).copied().unwrap_or_default();
        assert!(!never.has_ever_been_billed);
        assert!(!never.recent_paid_invoice_within_60_days);

        // recent paid: billed AND within the 60-day window.
        let recent = signals.get(&recent_paid).copied().unwrap();
        assert!(recent.has_ever_been_billed);
        assert!(recent.recent_paid_invoice_within_60_days);

        // stale paid: billed but the paid invoice predates the window.
        let stale = signals.get(&stale_paid).copied().unwrap();
        assert!(stale.has_ever_been_billed);
        assert!(!stale.recent_paid_invoice_within_60_days);

        // missing customer: absent from the map → callers fall back to default.
        assert!(!signals.contains_key(&missing));
        let defaulted = signals.get(&missing).copied().unwrap_or_default();
        assert!(!defaulted.has_ever_been_billed);
        assert!(!defaulted.recent_paid_invoice_within_60_days);
    }

    #[tokio::test]
    async fn batched_signals_match_single_customer_helper() {
        let now = at(2026, 6, 1);
        let customer = Uuid::new_v4();
        let repo = StubInvoiceRepo {
            invoices: vec![
                invoice_with_status(customer, "paid", Some(at(2026, 5, 20))),
                invoice_with_status(customer, "draft", None),
            ],
            payment_summaries: vec![payment_summary(customer, true, Some(at(2026, 5, 20)))],
        };

        let batched = invoice_signals_for_customers(&repo, &[customer], now)
            .await
            .unwrap();
        let single = invoice_signals_for_customer(&repo, customer, now)
            .await
            .unwrap();
        let batched = batched.get(&customer).copied().unwrap();

        assert_eq!(batched.has_ever_been_billed, single.has_ever_been_billed);
        assert_eq!(
            batched.recent_paid_invoice_within_60_days,
            single.recent_paid_invoice_within_60_days
        );
        assert!(batched.has_ever_been_billed);
        assert!(batched.recent_paid_invoice_within_60_days);
    }

    #[test]
    fn paid_invoice_recency_includes_exact_cutoff_only() {
        let cutoff = recent_paid_cutoff(at(2026, 6, 1));

        assert!(paid_at_is_recent(Some(cutoff), cutoff));
        assert!(!paid_at_is_recent(
            Some(cutoff - Duration::seconds(1)),
            cutoff
        ));
        assert!(!paid_at_is_recent(None, cutoff));
    }

    #[tokio::test]
    async fn single_and_batched_signals_share_exact_cutoff_semantics() {
        let now = at(2026, 6, 1);
        let cutoff = recent_paid_cutoff(now);
        let exact_cutoff = Uuid::new_v4();
        let one_second_stale = Uuid::new_v4();
        let repo = StubInvoiceRepo {
            invoices: vec![
                invoice_with_status(exact_cutoff, "paid", Some(cutoff)),
                invoice_with_status(
                    one_second_stale,
                    "paid",
                    Some(cutoff - Duration::seconds(1)),
                ),
            ],
            payment_summaries: vec![
                payment_summary(exact_cutoff, true, Some(cutoff)),
                payment_summary(one_second_stale, true, Some(cutoff - Duration::seconds(1))),
            ],
        };

        let batched = invoice_signals_for_customers(&repo, &[exact_cutoff, one_second_stale], now)
            .await
            .unwrap();
        let single_exact = invoice_signals_for_customer(&repo, exact_cutoff, now)
            .await
            .unwrap();
        let single_stale = invoice_signals_for_customer(&repo, one_second_stale, now)
            .await
            .unwrap();

        assert!(single_exact.recent_paid_invoice_within_60_days);
        assert!(
            batched[&exact_cutoff].recent_paid_invoice_within_60_days,
            "paid_at equal to the cutoff must be recent on the batch path"
        );
        assert!(!single_stale.recent_paid_invoice_within_60_days);
        assert!(
            !batched[&one_second_stale].recent_paid_invoice_within_60_days,
            "paid_at one second before the cutoff must be stale on the batch path"
        );
    }

    #[tokio::test]
    async fn batched_signals_empty_ids_returns_empty_map() {
        let repo = StubInvoiceRepo {
            invoices: Vec::new(),
            payment_summaries: Vec::new(),
        };
        let signals = invoice_signals_for_customers(&repo, &[], at(2026, 6, 1))
            .await
            .unwrap();
        assert!(signals.is_empty());
    }
}
