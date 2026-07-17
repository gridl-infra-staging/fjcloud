import type { PageServerLoad } from './$types';
import { createApiClient } from '$lib/server/api';
import { error } from '@sveltejs/kit';

export const load: PageServerLoad = async ({ params, locals }) => {
	const api = createApiClient(locals.user?.token);
	try {
		const invoice = await api.getInvoice(params.id);
		return { invoice };
	} catch {
		throw error(404, 'Invoice not found');
	}
};
