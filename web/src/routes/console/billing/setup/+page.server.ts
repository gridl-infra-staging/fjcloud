import type { PageServerLoad } from './$types';
import { isBillingServiceNotConfiguredError, isBillingCustomerMissingError } from '$lib/billing';
import { createApiClient } from '$lib/server/api';

export const load: PageServerLoad = async ({ locals }) => {
	const api = createApiClient(locals.user?.token);
	try {
		const { client_secret } = await api.createSetupIntent();
		return { clientSecret: client_secret as string | null, error: null as string | null };
	} catch (err) {
		if (isBillingServiceNotConfiguredError(err) || isBillingCustomerMissingError(err)) {
			return {
				clientSecret: null as string | null,
				error: null as string | null,
				billingUnavailable: true as const
			};
		}
		return {
			clientSecret: null as string | null,
			error: 'Unable to load payment setup. Please try again.' as string | null
		};
	}
};
