import type { PageServerLoad, Actions } from './$types';
import { createApiClient } from '$lib/server/api';
import { isBillingServiceNotConfiguredError, isBillingCustomerMissingError } from '$lib/billing';
import { ApiRequestError } from '$lib/api/client';
import {
	DASHBOARD_SESSION_EXPIRED_REDIRECT,
	isDashboardSessionExpiredError,
	mapDashboardSessionFailure
} from '$lib/server/auth-action-errors';
import { fail, redirect } from '@sveltejs/kit';

const BILLING_PAGE_PATH = '/dashboard/billing';
const BILLING_SETUP_ERROR =
	'Billing is being set up for your account. Please contact support@flapjack.foo if this persists.';
const SUBSCRIPTION_RECOVERY_BANNER_TEXT =
	'Payment failed for your subscription. Update your payment method to recover access.';
const DELINQUENT_SUBSCRIPTION_STATUSES = new Set(['past_due', 'unpaid', 'incomplete', 'incomplete_expired']);

export const prerender = false;

function cancelledSubscriptionBannerText(subscription: {
	status: string;
	current_period_end: string;
	cancel_at_period_end: boolean;
}): string | null {
	// The banner is only meaningful once Stripe has recorded a pending or
	// completed cancellation date for the customer-visible subscription.
	if (!subscription.current_period_end) {
		return null;
	}
	if (!subscription.cancel_at_period_end && subscription.status !== 'canceled') {
		return null;
	}
	return `Subscription cancelled, ends ${subscription.current_period_end}`;
}

function recoveryBannerTextForSubscription(subscription: { status: string }): string | null {
	return DELINQUENT_SUBSCRIPTION_STATUSES.has(subscription.status)
		? SUBSCRIPTION_RECOVERY_BANNER_TEXT
		: null;
}

export const load: PageServerLoad = async ({ locals }) => {
	const api = createApiClient(locals.user?.token);
	let billingUnavailable = false;
	let billingCustomerMissing = false;
	try {
		await api.getPaymentMethods();
	} catch (err) {
		if (isDashboardSessionExpiredError(err)) {
			redirect(303, DASHBOARD_SESSION_EXPIRED_REDIRECT);
		}
		if (isBillingServiceNotConfiguredError(err)) {
			billingUnavailable = true;
		}
		if (isBillingCustomerMissingError(err)) {
			billingCustomerMissing = true;
		}
		if (!isBillingServiceNotConfiguredError(err) && !isBillingCustomerMissingError(err)) {
			throw err;
		}
	}

	let subscriptionCancelledBannerText: string | null = null;
	let subscriptionRecoveryBannerText: string | null = null;
	if (!billingUnavailable && !billingCustomerMissing) {
		try {
			const subscription = await api.getSubscription();
			subscriptionCancelledBannerText = cancelledSubscriptionBannerText(subscription);
			subscriptionRecoveryBannerText = recoveryBannerTextForSubscription(subscription);
		} catch (err) {
			if (isDashboardSessionExpiredError(err)) {
				redirect(303, DASHBOARD_SESSION_EXPIRED_REDIRECT);
			}
			if (isBillingCustomerMissingError(err)) {
				subscriptionCancelledBannerText = null;
				subscriptionRecoveryBannerText = null;
			} else if (
				err instanceof ApiRequestError &&
				err.status === 404 &&
				err.message === 'no subscription found'
			) {
				subscriptionCancelledBannerText = null;
				subscriptionRecoveryBannerText = null;
			} else {
				throw err;
			}
		}
	}

	return { billingUnavailable, subscriptionCancelledBannerText, subscriptionRecoveryBannerText };
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
