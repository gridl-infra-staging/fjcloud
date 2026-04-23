/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar25_am_4_admin_workflow_depth/fjcloud_dev/web/src/routes/admin/billing/+page.server.ts.
 */
import { fail } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import { createAdminClient } from '$lib/admin-client';
import type { InvoiceListItem } from '$lib/api/types';

export interface BillingInvoice extends InvoiceListItem {
	customer_id: string;
	customer_name: string;
	customer_email: string;
}

const BILLING_SORT_COLLATOR = new Intl.Collator('en', {
	sensitivity: 'base',
	numeric: true
});
const BILLING_MONTH_PATTERN = /^\d{4}-(0[1-9]|1[0-2])$/;

function parseBillingMonth(monthValue: FormDataEntryValue | null): string | null {
	if (typeof monthValue !== 'string') return null;

	const normalizedMonth = monthValue.trim();
	if (normalizedMonth.length === 0) return null;
	if (!BILLING_MONTH_PATTERN.test(normalizedMonth)) return null;

	return normalizedMonth;
}

function compareBillingInvoices(a: BillingInvoice, b: BillingInvoice): number {
	const createdAtDiff = Date.parse(b.created_at) - Date.parse(a.created_at);
	if (createdAtDiff !== 0) return createdAtDiff;

	const customerNameDiff = BILLING_SORT_COLLATOR.compare(a.customer_name, b.customer_name);
	if (customerNameDiff !== 0) return customerNameDiff;

	return BILLING_SORT_COLLATOR.compare(a.id, b.id);
}

export const load: PageServerLoad = async ({ fetch, depends }) => {
	depends('admin:billing');

	const client = createAdminClient();
	client.setFetch(fetch);

	try {
		const tenants = await client.getTenants();
		const invoicesByTenant = await Promise.all(
			tenants.map(async (tenant): Promise<BillingInvoice[]> => {
				try {
					const invoices = await client.getTenantInvoices(tenant.id);
					return invoices.map((invoice) => ({
						...invoice,
						customer_id: tenant.id,
						customer_name: tenant.name,
						customer_email: tenant.email
					}));
				} catch {
					// Skip tenant if invoices fail to load
					return [];
				}
			})
		);

		const allInvoices = invoicesByTenant.flat().sort(compareBillingInvoices);
		return { invoices: allInvoices };
	} catch {
		return { invoices: [] as BillingInvoice[] };
	}
};

export const actions = {
	runBilling: async ({ request, fetch }) => {
		const formData = await request.formData();
		const month = parseBillingMonth(formData.get('month'));

		if (!month) {
			return fail(400, { success: false, error: 'Month must use YYYY-MM format' });
		}

		const client = createAdminClient();
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

	bulkFinalize: async ({ request, fetch }) => {
		const formData = await request.formData();
		const invoiceIds = formData.getAll('invoice_ids').filter(
			(id): id is string => typeof id === 'string' && id.trim().length > 0
		);

		if (invoiceIds.length === 0) {
			return fail(400, { success: false, error: 'No invoice IDs provided' });
		}

		const client = createAdminClient();
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
