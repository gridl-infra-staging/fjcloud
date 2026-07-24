/**
 */
import { redirect } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { createAdminClient } from '$lib/admin-client';
import type { AdminTenant } from '$lib/admin-client';
import { retryTransientAdminApiRequest } from '$lib/server/transient-api-retry';
import {
	ADMIN_SESSION_COOKIE,
	getAdminSession,
	purgeExpiredAdminSessions
} from '$lib/server/admin-session';
import { privateEnvValue, type RuntimeEnv } from '$lib/server/runtime-env';

export interface AdminCustomerListItem extends Omit<AdminTenant, 'index_count'> {
	index_count: number | null;
}

export type AdminCustomersPageData = {
	customers: AdminCustomerListItem[] | null;
};

type AdminCookieReader = { get(name: string): string | undefined };

function requireAdminSession(cookies: AdminCookieReader, runtimeEnv?: RuntimeEnv): void {
	purgeExpiredAdminSessions();

	if (
		!getAdminSession(
			cookies.get(ADMIN_SESSION_COOKIE),
			privateEnvValue('ADMIN_KEY', { env: runtimeEnv })
		)
	) {
		redirect(303, '/admin/login');
	}
}

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

export const load: PageServerLoad = async ({ fetch, depends, cookies, platform }) => {
	depends('admin:customers:list');
	requireAdminSession(cookies, platform?.env);

	const client = createAdminClient(undefined, platform?.env);
	client.setFetch(fetch);

	try {
		const tenants = await retryTransientAdminApiRequest(() => client.getTenants());
		const customers = tenants.map(toCustomerListItem);

		return { customers } satisfies AdminCustomersPageData;
	} catch {
		return { customers: null } satisfies AdminCustomersPageData;
	}
};
