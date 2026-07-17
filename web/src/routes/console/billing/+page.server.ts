import type { PageServerLoad, Actions } from './$types';
import { createApiClient } from '$lib/server/api';
import { isBillingServiceNotConfiguredError, isBillingCustomerMissingError } from '$lib/billing';
import { ApiRequestError } from '$lib/api/client';
import type { CustomerUpgradeStatusResponse, PaymentMethod } from '$lib/api/types';
import { SUPPORT_EMAIL } from '$lib/format';
import {
	DASHBOARD_SESSION_EXPIRED_REDIRECT,
	customerFacingErrorMessage,
	isDashboardSessionExpiredError,
	mapDashboardSessionFailure
} from '$lib/server/auth-action-errors';
import { fail, redirect } from '@sveltejs/kit';

const BILLING_SETUP_ERROR = `Billing is being set up for your account. Please contact ${SUPPORT_EMAIL} if this persists.`;
const BILLING_SETUP_INTENT_ERROR = 'Unable to load payment setup. Please try again.';
const BILLING_DEFAULT_PAYMENT_METHOD_ERROR =
	'Unable to update default payment method. Please try again.';
const BILLING_UPGRADE_DECLINED_ERROR = 'Your card was declined. Try a different card and retry.';
const BILLING_UPGRADE_GENERIC_ERROR = 'Upgrade failed. Please try again.';

type BillingUpgradeOutcome =
	| {
			status: 'success';
			activationAmountCents: number;
	  }
	| {
			status: 'declined';
			message: string;
	  }
	| {
			status: 'requires_action';
	  }
	| {
			status: 'missing_payment_method';
	  }
	| {
			status: 'already_shared';
	  }
	| {
			status: 'error';
			message: string;
	  };

type BillingPageData = {
	billingUnavailable: boolean;
	paymentMethods: PaymentMethod[];
	setupIntentClientSecret: string | null;
	setupIntentError: string | null;
	upgradeStatus: CustomerUpgradeStatusResponse | null;
};

function unavailableBillingPageData(
	paymentMethods: PaymentMethod[] = [],
	upgradeStatus: CustomerUpgradeStatusResponse | null = null
): BillingPageData {
	return {
		billingUnavailable: true,
		paymentMethods,
		setupIntentClientSecret: null,
		setupIntentError: null,
		upgradeStatus
	};
}

export const prerender = false;

function mapUpgradeErrorBody(error: ApiRequestError): { code?: string; message?: string } {
	const responseBody = (error.body ?? {}) as Record<string, unknown>;
	const code = typeof responseBody.code === 'string' ? responseBody.code : undefined;
	const message = typeof responseBody.message === 'string' ? responseBody.message : undefined;
	return { code, message };
}

function mapUpgradeFailure(error: ApiRequestError): BillingUpgradeOutcome {
	const { code, message } = mapUpgradeErrorBody(error);

	if (error.status === 402) {
		if (code === 'invoice_payment_intent_requires_action' || code === 'authentication_required') {
			return { status: 'requires_action' };
		}
		return {
			status: 'declined',
			message: message ?? BILLING_UPGRADE_DECLINED_ERROR
		};
	}

	if (
		error.status === 400 &&
		(error.message === 'default payment method required' ||
			error.message === 'no stripe customer linked')
	) {
		return { status: 'missing_payment_method' };
	}

	if (error.status === 409) {
		return { status: 'already_shared' };
	}

	return {
		status: 'error',
		message: customerFacingErrorMessage(error, BILLING_UPGRADE_GENERIC_ERROR)
	};
}

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
				setupIntentError: null,
				upgradeStatus: null
			};
		}
		throw err;
	}

	let upgradeStatus: CustomerUpgradeStatusResponse | null = null;
	try {
		upgradeStatus = await api.getUpgradeStatus();
	} catch (err) {
		if (isDashboardSessionExpiredError(err)) {
			redirect(303, DASHBOARD_SESSION_EXPIRED_REDIRECT);
		}
		if (isBillingServiceNotConfiguredError(err)) {
			return unavailableBillingPageData(paymentMethods);
		}
		if (isBillingCustomerMissingError(err)) {
			upgradeStatus = {
				stripe_customer_id: null,
				has_default_payment_method: false,
				upgrade_ready: false
			};
		} else {
			throw err;
		}
	}

	try {
		const { client_secret } = await api.createSetupIntent();
		return {
			billingUnavailable: false,
			paymentMethods,
			setupIntentClientSecret: client_secret as string | null,
			setupIntentError: null,
			upgradeStatus
		};
	} catch (err) {
		if (isDashboardSessionExpiredError(err)) {
			redirect(303, DASHBOARD_SESSION_EXPIRED_REDIRECT);
		}
		if (isBillingServiceNotConfiguredError(err) || isBillingCustomerMissingError(err)) {
			return unavailableBillingPageData(paymentMethods, upgradeStatus);
		}
		return {
			billingUnavailable: false,
			paymentMethods,
			setupIntentClientSecret: null,
			setupIntentError: BILLING_SETUP_INTENT_ERROR,
			upgradeStatus
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
	},
	upgradeToShared: async ({ locals }) => {
		const api = createApiClient(locals.user?.token);
		try {
			const result = await api.upgradeToShared();
			return {
				upgradeOutcome: {
					status: 'success',
					activationAmountCents: result.activation_amount_cents
				} satisfies BillingUpgradeOutcome
			};
		} catch (err) {
			const sessionFailure = mapDashboardSessionFailure(err);
			if (sessionFailure) return sessionFailure;
			if (isBillingServiceNotConfiguredError(err)) {
				return {
					upgradeOutcome: {
						status: 'error',
						message: BILLING_SETUP_ERROR
					} satisfies BillingUpgradeOutcome
				};
			}
			if (isBillingCustomerMissingError(err)) {
				return {
					upgradeOutcome: {
						status: 'missing_payment_method'
					} satisfies BillingUpgradeOutcome
				};
			}
			if (err instanceof ApiRequestError) {
				return {
					upgradeOutcome: mapUpgradeFailure(err)
				};
			}
			return {
				upgradeOutcome: {
					status: 'error',
					message: BILLING_UPGRADE_GENERIC_ERROR
				} satisfies BillingUpgradeOutcome
			};
		}
	}
};
