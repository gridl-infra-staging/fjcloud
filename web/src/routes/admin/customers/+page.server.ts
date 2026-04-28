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
		...tenant,
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
