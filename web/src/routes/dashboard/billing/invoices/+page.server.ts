import type { PageServerLoad } from './$types';
import { createApiClient } from '$lib/server/api';

export const load: PageServerLoad = async ({ locals }) => {
	const api = createApiClient(locals.user?.token);
	try {
		const invoices = await api.getInvoices();
		return { invoices };
	} catch {
		return { invoices: [] };
	}
};
