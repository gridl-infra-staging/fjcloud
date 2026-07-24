import { fail } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import { createAdminClient } from '$lib/admin-client';
import type { AdminBillingInvoiceRow, AdminBillingSummaryResponse } from '$lib/admin-client';

export type BillingInvoice = AdminBillingInvoiceRow;
type BillingStatusKey = 'paid' | 'draft' | 'finalized' | 'failed' | 'refunded';
type UnknownRecord = Record<string, unknown>;

const BILLING_SORT_COLLATOR = new Intl.Collator('en', {
	sensitivity: 'base',
	numeric: true
});
const BILLING_MONTH_PATTERN = /^\d{4}-(0[1-9]|1[0-2])$/;
const BILLING_INVOICE_ID_PATTERN =
	/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const BILLING_STATUS_KEYS: BillingStatusKey[] = ['paid', 'draft', 'finalized', 'failed', 'refunded'];

function parseBillingMonth(monthValue: FormDataEntryValue | null): string | null {
	if (typeof monthValue !== 'string') return null;

	const normalizedMonth = monthValue.trim();
	if (normalizedMonth.length === 0) return null;
	if (!BILLING_MONTH_PATTERN.test(normalizedMonth)) return null;

	return normalizedMonth;
}

function parseBillingInvoiceIds(formData: FormData): string[] | null {
	const invoiceIds = formData
		.getAll('invoice_ids')
		.filter((id): id is string => typeof id === 'string')
		.map((id) => id.trim())
		.filter((id) => id.length > 0);

	if (invoiceIds.length === 0) {
		return [];
	}

	return invoiceIds.every((id) => BILLING_INVOICE_ID_PATTERN.test(id)) ? invoiceIds : null;
}

function compareBillingInvoices(a: BillingInvoice, b: BillingInvoice): number {
	const createdAtDiff = Date.parse(b.created_at) - Date.parse(a.created_at);
	if (createdAtDiff !== 0) return createdAtDiff;

	const customerNameDiff = BILLING_SORT_COLLATOR.compare(a.customer_name, b.customer_name);
	if (customerNameDiff !== 0) return customerNameDiff;

	return BILLING_SORT_COLLATOR.compare(a.id, b.id);
}

const EMPTY_STATUS_TOTAL = { total_cents: 0, count: 0 };

function objectRecord(value: unknown): UnknownRecord | null {
	return typeof value === 'object' && value !== null ? (value as UnknownRecord) : null;
}

function finiteNumberOrZero(value: unknown): number {
	return typeof value === 'number' && Number.isFinite(value) ? value : 0;
}

function stringOrNull(value: unknown): string | null {
	return typeof value === 'string' ? value : null;
}

function stringOrEmpty(value: unknown): string {
	return typeof value === 'string' ? value : '';
}

function booleanOrFalse(value: unknown): boolean {
	return typeof value === 'boolean' ? value : false;
}

function normalizeStatusTotals(value: unknown): AdminBillingSummaryResponse['status_totals'] {
	const rawTotals = objectRecord(value);
	const normalized = {} as AdminBillingSummaryResponse['status_totals'];

	for (const status of BILLING_STATUS_KEYS) {
		const rawStatusTotal = objectRecord(rawTotals?.[status]);
		normalized[status] = {
			total_cents: finiteNumberOrZero(rawStatusTotal?.total_cents),
			count: finiteNumberOrZero(rawStatusTotal?.count)
		};
	}

	return normalized;
}

function normalizeMonthBuckets(value: unknown): AdminBillingSummaryResponse['by_month'] {
	if (!Array.isArray(value)) {
		return [];
	}

	return value.flatMap((bucket) => {
		const rawBucket = objectRecord(bucket);
		if (!rawBucket) {
			return [];
		}

		const month = stringOrNull(rawBucket.month);
		if (!month || !BILLING_MONTH_PATTERN.test(month)) {
			return [];
		}

		return [{ month, paid_total_cents: finiteNumberOrZero(rawBucket.paid_total_cents) }];
	});
}

function normalizeBillingInvoice(value: unknown): BillingInvoice | null {
	const rawInvoice = objectRecord(value);
	if (!rawInvoice) {
		return null;
	}

	const id = stringOrNull(rawInvoice.id);
	const customer_id = stringOrNull(rawInvoice.customer_id);
	const customer_name = stringOrNull(rawInvoice.customer_name);
	const customer_email = stringOrNull(rawInvoice.customer_email);
	const period_start = stringOrNull(rawInvoice.period_start);
	const period_end = stringOrNull(rawInvoice.period_end);
	const status = stringOrNull(rawInvoice.status);
	const created_at = stringOrNull(rawInvoice.created_at);
	if (
		!id ||
		!customer_id ||
		!customer_name ||
		!customer_email ||
		!period_start ||
		!period_end ||
		!status ||
		!created_at
	) {
		return null;
	}

	return {
		id,
		customer_id,
		customer_name,
		customer_email,
		period_start,
		period_end,
		subtotal_cents: finiteNumberOrZero(rawInvoice.subtotal_cents),
		tax_cents: finiteNumberOrZero(rawInvoice.tax_cents),
		total_cents: finiteNumberOrZero(rawInvoice.total_cents),
		currency: stringOrEmpty(rawInvoice.currency),
		status,
		minimum_applied: booleanOrFalse(rawInvoice.minimum_applied),
		stripe_invoice_id: stringOrNull(rawInvoice.stripe_invoice_id),
		hosted_invoice_url: stringOrNull(rawInvoice.hosted_invoice_url),
		pdf_url: stringOrNull(rawInvoice.pdf_url),
		created_at,
		finalized_at: stringOrNull(rawInvoice.finalized_at),
		paid_at: stringOrNull(rawInvoice.paid_at)
	};
}

function emptyBillingSummary(): AdminBillingSummaryResponse {
	return {
		status_totals: {
			paid: { ...EMPTY_STATUS_TOTAL },
			draft: { ...EMPTY_STATUS_TOTAL },
			finalized: { ...EMPTY_STATUS_TOTAL },
			failed: { ...EMPTY_STATUS_TOTAL },
			refunded: { ...EMPTY_STATUS_TOTAL }
		},
		pending_total_cents: 0,
		pending_count: 0,
		total_count: 0,
		by_month: [],
		mrr_proxy_cents: 0,
		invoices: []
	};
}

function normalizeBillingSummary(value: unknown): AdminBillingSummaryResponse {
	const rawSummary = objectRecord(value);
	if (!rawSummary) {
		return emptyBillingSummary();
	}

	const invoices = Array.isArray(rawSummary.invoices)
		? rawSummary.invoices.flatMap((invoice) => {
				const normalizedInvoice = normalizeBillingInvoice(invoice);
				return normalizedInvoice ? [normalizedInvoice] : [];
			})
		: [];

	return {
		status_totals: normalizeStatusTotals(rawSummary.status_totals),
		pending_total_cents: finiteNumberOrZero(rawSummary.pending_total_cents),
		pending_count: finiteNumberOrZero(rawSummary.pending_count),
		total_count: finiteNumberOrZero(rawSummary.total_count),
		by_month: normalizeMonthBuckets(rawSummary.by_month),
		mrr_proxy_cents: finiteNumberOrZero(rawSummary.mrr_proxy_cents),
		invoices
	};
}

export const load: PageServerLoad = async ({ fetch, depends, platform }) => {
	depends('admin:billing');

	const client = createAdminClient(undefined, platform?.env);
	client.setFetch(fetch);

	try {
		const summary = normalizeBillingSummary(await client.getBillingSummary());
		const invoices = [...summary.invoices].sort(compareBillingInvoices);
		return { summary: { ...summary, invoices }, invoices };
	} catch {
		const summary = emptyBillingSummary();
		return { summary, invoices: summary.invoices };
	}
};

export const actions = {
	runBilling: async ({ request, fetch, platform }) => {
		const formData = await request.formData();
		const month = parseBillingMonth(formData.get('month'));

		if (!month) {
			return fail(400, { success: false, error: 'Month must use YYYY-MM format' });
		}

		const client = createAdminClient(undefined, platform?.env);
		client.setFetch(fetch);

		try {
			const result = await client.runBatchBilling(month);
			return {
				success: true,
				message: `Billing complete: ${result.invoices_created} invoices created, ${result.invoices_skipped} skipped`
			};
		} catch (err) {
			return fail(500, {
				success: false,
				error: err instanceof Error ? err.message : 'Batch billing failed'
			});
		}
	},

	bulkFinalize: async ({ request, fetch, platform }) => {
		const formData = await request.formData();
		const invoiceIds = parseBillingInvoiceIds(formData);

		if (invoiceIds?.length === 0) {
			return fail(400, { success: false, error: 'No invoice IDs provided' });
		}
		if (invoiceIds === null) {
			return fail(400, { success: false, error: 'Invoice IDs must be valid UUIDs' });
		}

		const client = createAdminClient(undefined, platform?.env);
		client.setFetch(fetch);

		let finalized = 0;
		const errors: string[] = [];

		for (const id of invoiceIds) {
			try {
				await client.finalizeInvoice(id);
				finalized++;
			} catch (err) {
				errors.push(`${id}: ${err instanceof Error ? err.message : 'failed'}`);
			}
		}

		if (errors.length > 0) {
			if (finalized > 0) {
				const invoiceLabel = finalized === 1 ? 'invoice' : 'invoices';
				return {
					success: false,
					finalized,
					error: `Bulk finalize partially failed after finalizing ${finalized} ${invoiceLabel}: ${errors.join('; ')}`
				};
			}

			return fail(500, {
				success: false,
				error: `Bulk finalize failed: ${errors.join('; ')}`
			});
		}

		return {
			success: true,
			finalized,
			message: `Bulk finalize complete: ${finalized} invoices finalized`
		};
	}
} satisfies Actions;
