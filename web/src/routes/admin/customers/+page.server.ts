/**
 */
import type { PageServerLoad } from './$types';
import { createAdminClient } from '$lib/admin-client';
import type { AdminTenant } from '$lib/admin-client';
import { retryTransientAdminApiRequest } from '$lib/server/transient-api-retry';

/**
 * Enriched tenant row for the admin customer list.
 *
 * `last_invoice_status` three-state semantic:
 *   - string  → real status from the most-recent invoice (e.g. "paid", "failed", "draft")
 *   - "none"  → tenant has zero invoices
 *   - null    → invoice data unavailable (API error)
 *
 * `index_count` is null until a real admin index-count endpoint exists.
 */
export interface AdminCustomerListItem extends AdminTenant {
	index_count: number | null;
	last_invoice_status: string | null;
}

export type AdminCustomersPageData = {
	customers: AdminCustomerListItem[] | null;
};

/** Extract the status of the most-recent invoice by `created_at`, or "none" if empty. */
function latestInvoiceStatus(invoices: Array<{ status: string; created_at: string }>): string {
	if (invoices.length === 0) return 'none';

	let latestInvoice = invoices[0];
	let latestCreatedAt = new Date(latestInvoice.created_at).getTime();

	for (const invoice of invoices.slice(1)) {
		const createdAt = new Date(invoice.created_at).getTime();
		if (createdAt > latestCreatedAt) {
			latestInvoice = invoice;
			latestCreatedAt = createdAt;
		}
	}

	return latestInvoice.status;
}

async function loadLastInvoiceStatus(
	client: ReturnType<typeof createAdminClient>,
	tenantId: string
): Promise<string | null> {
	try {
		return latestInvoiceStatus(
			await retryTransientAdminApiRequest(() => client.getTenantInvoices(tenantId))
		);
	} catch {
		// API unavailable for this tenant — null sentinel
		return null;
	}
}

function toCustomerListItem(
	tenant: AdminTenant,
	lastInvoiceStatus: string | null
): AdminCustomerListItem {
	return {
		...tenant,
		index_count: null,
		last_invoice_status: lastInvoiceStatus
	};
}

export const load: PageServerLoad = async ({ fetch, depends }) => {
	depends('admin:customers:list');

	const client = createAdminClient();
	client.setFetch(fetch);

	try {
		const tenants = await retryTransientAdminApiRequest(() => client.getTenants());

		// Fan out invoice lookups in parallel; each tenant gets its own
		// try/catch so one failure doesn't poison the whole list.
		const customers = await Promise.all(
			tenants.map(
				async (tenant: AdminTenant): Promise<AdminCustomerListItem> =>
					toCustomerListItem(tenant, await loadLastInvoiceStatus(client, tenant.id))
			)
		);

		return { customers } satisfies AdminCustomersPageData;
	} catch {
		return { customers: null } satisfies AdminCustomersPageData;
	}
};
