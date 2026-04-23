import type { PageServerLoad, Actions } from './$types';
import { createApiClient } from '$lib/server/api';
import { isBillingServiceNotConfiguredError, isBillingCustomerMissingError } from '$lib/billing';
import { fail } from '@sveltejs/kit';

export const load: PageServerLoad = async ({ locals }) => {
	const api = createApiClient(locals.user?.token);
	try {
		const paymentMethods = await api.getPaymentMethods();
		return { paymentMethods };
	} catch (err) {
		if (isBillingServiceNotConfiguredError(err) || isBillingCustomerMissingError(err)) {
			return { paymentMethods: [], billingUnavailable: true as const };
		}
		throw err;
	}
};

export const actions: Actions = {
	remove: async ({ request, locals }) => {
		const data = await request.formData();
		const pmId = data.get('pmId') as string;
		if (!pmId) return fail(400, { error: 'Missing payment method ID' });

		const api = createApiClient(locals.user?.token);
		try {
			await api.deletePaymentMethod(pmId);
			return { success: true };
		} catch {
			return fail(400, { error: 'Failed to remove payment method' });
		}
	},
	setDefault: async ({ request, locals }) => {
		const data = await request.formData();
		const pmId = data.get('pmId') as string;
		if (!pmId) return fail(400, { error: 'Missing payment method ID' });

		const api = createApiClient(locals.user?.token);
		try {
			await api.setDefaultPaymentMethod(pmId);
			return { success: true };
		} catch {
			return fail(400, { error: 'Failed to set default payment method' });
		}
	}
};
