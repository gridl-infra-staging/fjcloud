/**
 */
import type { PageServerLoad } from './$types';
import type { AdminTenant } from '$lib/admin-client';
import { retryTransientAdminApiRequest } from '$lib/server/transient-api-retry';
import {
	redirectIfAdminSessionAuthError,
	requireDurableAdminSession
} from '$lib/server/admin-session';

export interface AdminCustomerListItem extends Omit<AdminTenant, 'index_count'> {
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
		index_count: tenant.index_count
	};
}

export const load: PageServerLoad = async (event) => {
	event.depends('admin:customers:list');
	const { adminClient: client } = await requireDurableAdminSession(event);

	try {
		const tenants = await retryTransientAdminApiRequest(() => client.getTenants());
		const customers = tenants.map(toCustomerListItem);

		return { customers } satisfies AdminCustomersPageData;
	} catch (error) {
		redirectIfAdminSessionAuthError(error);
		return { customers: null } satisfies AdminCustomersPageData;
	}
};
