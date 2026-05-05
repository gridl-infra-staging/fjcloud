import type { PageServerLoad, Actions } from './$types';
import { createApiClient } from '$lib/server/api';
import { isBillingServiceNotConfiguredError, isBillingCustomerMissingError } from '$lib/billing';
import type { PaymentMethod } from '$lib/api/types';
import { SUPPORT_EMAIL } from '$lib/format';
import {
	DASHBOARD_SESSION_EXPIRED_REDIRECT,
	isDashboardSessionExpiredError,
	mapDashboardSessionFailure
} from '$lib/server/auth-action-errors';
import { fail, redirect } from '@sveltejs/kit';

const BILLING_SETUP_ERROR = `Billing is being set up for your account. Please contact ${SUPPORT_EMAIL} if this persists.`;
const BILLING_SETUP_INTENT_ERROR = 'Unable to load payment setup. Please try again.';
const BILLING_DEFAULT_PAYMENT_METHOD_ERROR =
	'Unable to update default payment method. Please try again.';

type BillingPageData = {
	billingUnavailable: boolean;
	paymentMethods: PaymentMethod[];
	setupIntentClientSecret: string | null;
	setupIntentError: string | null;
};

function unavailableBillingPageData(paymentMethods: PaymentMethod[] = []): BillingPageData {
	return {
		billingUnavailable: true,
		paymentMethods,
		setupIntentClientSecret: null,
		setupIntentError: null
	};
}

export const prerender = false;

export const load: PageServerLoad = async ({ locals }) => {
	const api = createApiClient(locals.user?.token);

	let paymentMethods: PaymentMethod[] = [];
	try {
		paymentMethods = await api.getPaymentMethods();
	} catch (err) {
		if (isDashboardSessionExpiredError(err)) {
			redirect(303, DASHBOARD_SESSION_EXPIRED_REDIRECT);
		}
		if (isBillingServiceNotConfiguredError(err)) {
			return unavailableBillingPageData();
		}
		if (isBillingCustomerMissingError(err)) {
			return {
				billingUnavailable: false,
				paymentMethods: [],
				setupIntentClientSecret: null,
				setupIntentError: null
			};
		}
		throw err;
	}

	try {
		const { client_secret } = await api.createSetupIntent();
		return {
			billingUnavailable: false,
			paymentMethods,
			setupIntentClientSecret: client_secret as string | null,
			setupIntentError: null
		};
	} catch (err) {
		if (isDashboardSessionExpiredError(err)) {
			redirect(303, DASHBOARD_SESSION_EXPIRED_REDIRECT);
		}
		if (isBillingServiceNotConfiguredError(err) || isBillingCustomerMissingError(err)) {
			return unavailableBillingPageData(paymentMethods);
		}
		return {
			billingUnavailable: false,
			paymentMethods,
			setupIntentClientSecret: null,
			setupIntentError: BILLING_SETUP_INTENT_ERROR
		};
	}
};

export const actions: Actions = {
	setDefaultPaymentMethod: async ({ locals, request }) => {
		const api = createApiClient(locals.user?.token);
		const formData = await request.formData();
		const paymentMethodId = String(formData.get('paymentMethodId') ?? '').trim();
		if (!paymentMethodId) {
			return fail(400, { error: BILLING_DEFAULT_PAYMENT_METHOD_ERROR });
		}
		try {
			await api.setDefaultPaymentMethod(paymentMethodId);
			return { updatedDefaultPaymentMethodId: paymentMethodId };
		} catch (err) {
			const sessionFailure = mapDashboardSessionFailure(err);
			if (sessionFailure) return sessionFailure;
			if (isBillingServiceNotConfiguredError(err) || isBillingCustomerMissingError(err)) {
				return fail(400, { error: BILLING_SETUP_ERROR });
			}
			return fail(400, { error: BILLING_DEFAULT_PAYMENT_METHOD_ERROR });
		}
	}
};
