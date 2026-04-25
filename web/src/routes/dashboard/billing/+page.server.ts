import type { PageServerLoad, Actions } from './$types';
import { createApiClient } from '$lib/server/api';
import { isBillingServiceNotConfiguredError, isBillingCustomerMissingError } from '$lib/billing';
import {
	DASHBOARD_SESSION_EXPIRED_REDIRECT,
	isDashboardSessionExpiredError,
	mapDashboardSessionFailure
} from '$lib/server/auth-action-errors';
import { fail, redirect } from '@sveltejs/kit';

const BILLING_PAGE_PATH = '/dashboard/billing';
const BILLING_SETUP_ERROR =
	'Billing is being set up for your account. Please contact support@flapjack.foo if this persists.';

export const prerender = false;

export const load: PageServerLoad = async ({ locals }) => {
	const api = createApiClient(locals.user?.token);
	try {
		await api.getPaymentMethods();
		return { billingUnavailable: false as const };
	} catch (err) {
		if (isDashboardSessionExpiredError(err)) {
			redirect(303, DASHBOARD_SESSION_EXPIRED_REDIRECT);
		}
		if (isBillingServiceNotConfiguredError(err)) {
			return { billingUnavailable: true as const };
		}
		if (isBillingCustomerMissingError(err)) {
			return { billingUnavailable: false as const };
		}
		throw err;
	}
};

export const actions: Actions = {
	manageBilling: async ({ locals, url }) => {
		const api = createApiClient(locals.user?.token);
		const portalSessionRequest = {
			return_url: `${url.origin}${BILLING_PAGE_PATH}`
		};

		let portalUrl: string;
		try {
			const { portal_url } = await api.createBillingPortalSession(portalSessionRequest);
			portalUrl = portal_url;
		} catch (err) {
			const sessionFailure = mapDashboardSessionFailure(err);
			if (sessionFailure) return sessionFailure;
			if (isBillingServiceNotConfiguredError(err) || isBillingCustomerMissingError(err)) {
				return fail(400, { error: BILLING_SETUP_ERROR });
			}
			return fail(400, { error: 'Failed to open billing portal' });
		}

		throw redirect(303, portalUrl);
	}
};
