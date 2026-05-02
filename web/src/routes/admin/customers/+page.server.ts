/**
 */
import type { PageServerLoad } from './$types';
import { createAdminClient } from '$lib/admin-client';
import type { AdminTenant } from '$lib/admin-client';
import { retryTransientAdminApiRequest } from '$lib/server/transient-api-retry';

/**
 * Enriched tenant row for the admin customer list.
 *
 * `index_count` remains null until a real admin index-count endpoint exists.
 */
export interface AdminCustomerListItem extends AdminTenant {
	index_count: number | null;
}

export type AdminCustomersPageData = {
	customers: AdminCustomerListItem[] | null;
};
function toCustomerListItem(tenant: AdminTenant): AdminCustomerListItem {
	return {
		id: tenant.id,
		name: tenant.name,
		email: tenant.email,
		status: tenant.status,
		billing_plan: tenant.billing_plan,
		last_accessed_at: tenant.last_accessed_at,
		overdue_invoice_count: tenant.overdue_invoice_count,
		billing_health: tenant.billing_health,
		created_at: tenant.created_at,
		updated_at: tenant.updated_at,
		index_count: null
	};
}

export const load: PageServerLoad = async ({ fetch, depends }) => {
	depends('admin:customers:list');

	const client = createAdminClient();
	client.setFetch(fetch);

	try {
		const tenants = await retryTransientAdminApiRequest(() => client.getTenants());
		const customers = tenants.map(toCustomerListItem);

		return { customers } satisfies AdminCustomersPageData;
	} catch {
		return { customers: null } satisfies AdminCustomersPageData;
	}
};
