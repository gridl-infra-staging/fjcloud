//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/pg_invoice_repo.rs.
use async_trait::async_trait;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::{InvoiceLineItemRow, InvoiceRow};
use crate::repos::error::{is_unique_violation, RepoError};
use crate::repos::invoice_repo::{InvoiceRepo, NewInvoice, NewLineItem};

pub struct PgInvoiceRepo {
    pool: PgPool,
}

impl PgInvoiceRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl InvoiceRepo for PgInvoiceRepo {
    /// Inserts an invoice and its line items in a single transaction.
    /// Returns `Conflict` if an invoice already exists for the same period.
    async fn create_with_line_items(
        &self,
        invoice: NewInvoice,
        line_items: Vec<NewLineItem>,
    ) -> Result<(InvoiceRow, Vec<InvoiceLineItemRow>), RepoError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| RepoError::Other(e.to_string()))?;

        let row = sqlx::query_as::<_, InvoiceRow>(
            "INSERT INTO invoices (customer_id, period_start, period_end, subtotal_cents, total_cents, minimum_applied) \
             VALUES ($1, $2, $3, $4, $5, $6) RETURNING *",
        )
        .bind(invoice.customer_id)
        .bind(invoice.period_start)
        .bind(invoice.period_end)
        .bind(invoice.subtotal_cents)
        .bind(invoice.total_cents)
        .bind(invoice.minimum_applied)
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| {
            if is_unique_violation(&e) {
                RepoError::Conflict("invoice already exists for this period".into())
            } else {
                RepoError::Other(e.to_string())
            }
        })?;

        let mut created_items = Vec::with_capacity(line_items.len());
        for li in &line_items {
            let item = sqlx::query_as::<_, InvoiceLineItemRow>(
                "INSERT INTO invoice_line_items (invoice_id, description, quantity, unit, unit_price_cents, amount_cents, region, metadata) \
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING *",
            )
            .bind(row.id)
            .bind(&li.description)
            .bind(li.quantity)
            .bind(&li.unit)
            .bind(li.unit_price_cents)
            .bind(li.amount_cents)
            .bind(&li.region)
            .bind(&li.metadata)
            .fetch_one(&mut *tx)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))?;
            created_items.push(item);
        }

        tx.commit()
            .await
            .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok((row, created_items))
    }

    async fn list_by_customer(&self, customer_id: Uuid) -> Result<Vec<InvoiceRow>, RepoError> {
        sqlx::query_as::<_, InvoiceRow>(
            "SELECT * FROM invoices WHERE customer_id = $1 ORDER BY period_start DESC",
        )
        .bind(customer_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<InvoiceRow>, RepoError> {
        sqlx::query_as::<_, InvoiceRow>("SELECT * FROM invoices WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn get_line_items(&self, invoice_id: Uuid) -> Result<Vec<InvoiceLineItemRow>, RepoError> {
        sqlx::query_as::<_, InvoiceLineItemRow>(
            "SELECT * FROM invoice_line_items WHERE invoice_id = $1 ORDER BY region, unit",
        )
        .bind(invoice_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn finalize(&self, id: Uuid) -> Result<InvoiceRow, RepoError> {
        sqlx::query_as::<_, InvoiceRow>(
            "UPDATE invoices SET status = 'finalized', finalized_at = NOW() \
             WHERE id = $1 AND status = 'draft' RETURNING *",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?
        .ok_or(RepoError::Conflict(
            "invoice not found or not in draft status".into(),
        ))
    }

    async fn mark_paid(&self, id: Uuid) -> Result<InvoiceRow, RepoError> {
        sqlx::query_as::<_, InvoiceRow>(
            "UPDATE invoices SET status = 'paid', paid_at = NOW() \
             WHERE id = $1 AND status IN ('finalized', 'failed') RETURNING *",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?
        .ok_or(RepoError::Conflict(
            "invoice not found or not in finalized/failed status".into(),
        ))
    }

    async fn mark_failed(&self, id: Uuid) -> Result<InvoiceRow, RepoError> {
        sqlx::query_as::<_, InvoiceRow>(
            "UPDATE invoices SET status = 'failed' \
             WHERE id = $1 AND status = 'finalized' RETURNING *",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?
        .ok_or(RepoError::Conflict(
            "invoice not found or not in finalized status".into(),
        ))
    }

    async fn mark_refunded(&self, id: Uuid) -> Result<InvoiceRow, RepoError> {
        sqlx::query_as::<_, InvoiceRow>(
            "UPDATE invoices SET status = 'refunded' \
             WHERE id = $1 AND status = 'paid' RETURNING *",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?
        .ok_or(RepoError::Conflict(
            "invoice not found or not in paid status".into(),
        ))
    }

    /// Sets the Stripe invoice id, hosted URL, and optional PDF URL.
    /// Returns `NotFound` if the invoice does not exist.
    async fn set_stripe_fields(
        &self,
        id: Uuid,
        stripe_invoice_id: &str,
        hosted_invoice_url: &str,
        pdf_url: Option<&str>,
    ) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE invoices SET stripe_invoice_id = $2, hosted_invoice_url = $3, pdf_url = $4 \
             WHERE id = $1",
        )
        .bind(id)
        .bind(stripe_invoice_id)
        .bind(hosted_invoice_url)
        .bind(pdf_url)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    async fn find_by_stripe_invoice_id(
        &self,
        stripe_invoice_id: &str,
    ) -> Result<Option<InvoiceRow>, RepoError> {
        sqlx::query_as::<_, InvoiceRow>("SELECT * FROM invoices WHERE stripe_invoice_id = $1")
            .bind(stripe_invoice_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }
}
