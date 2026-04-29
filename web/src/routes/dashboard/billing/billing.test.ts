import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { layoutTestDefaults } from '../layout-test-context';

const enhanceMock = vi.fn(() => ({ destroy: () => {} }));

vi.mock('$app/forms', () => ({
	enhance: enhanceMock
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: vi.fn()
}));

import BillingPage from './+page.svelte';

afterEach(cleanup);

describe('Billing page', () => {
	it('renders heading', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				subscriptionCancelledBannerText: null,
				subscriptionRecoveryBannerText: null
			},
			form: null
		});
		expect(screen.getByRole('heading', { name: 'Billing' })).toBeInTheDocument();
	});

	it('renders manage billing form wired to the portal action when available', () => {
		const { container } = render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				subscriptionCancelledBannerText: null,
				subscriptionRecoveryBannerText: null
			},
			form: null
		});
		const form = container.querySelector('form[action="?/manageBilling"]');
		expect(form).not.toBeNull();
		expect(screen.getByRole('button', { name: 'Manage billing' })).toBeInTheDocument();
	});

	it('keeps the manage billing form as a native submit boundary for portal redirects', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				subscriptionCancelledBannerText: null,
				subscriptionRecoveryBannerText: null
			},
			form: null
		});
		expect(enhanceMock).not.toHaveBeenCalled();
	});

	it('renders the exact cancellation banner copy when cancellation state is present', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				subscriptionCancelledBannerText: 'Subscription cancelled, ends 2026-05-31',
				subscriptionRecoveryBannerText: null
			},
			form: null
		});
		expect(screen.getByTestId('subscription-cancelled-banner')).toHaveTextContent(
			'Subscription cancelled, ends 2026-05-31'
		);
	});

	it('renders exactly one cancellation surface and keeps Manage billing as the only action', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				subscriptionCancelledBannerText: 'Subscription cancelled, ends 2026-05-31',
				subscriptionRecoveryBannerText: null
			},
			form: null
		});
		expect(screen.getAllByTestId('subscription-cancelled-banner')).toHaveLength(1);
		expect(screen.getByRole('button', { name: 'Manage billing' })).toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /cancel subscription/i })).not.toBeInTheDocument();
		expect(screen.queryByText('No payment methods on file.')).not.toBeInTheDocument();
	});

	it('displays action error message when portal handoff fails', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				subscriptionCancelledBannerText: null,
				subscriptionRecoveryBannerText: null
			},
			form: { error: 'Failed to open billing portal' }
		});
		expect(screen.getByRole('alert')).toBeInTheDocument();
		expect(screen.getByText('Failed to open billing portal')).toBeInTheDocument();
	});

	it('removes legacy payment-method controls from the billing contract', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				subscriptionCancelledBannerText: null,
				subscriptionRecoveryBannerText: null
			},
			form: null
		});
		expect(screen.queryByRole('link', { name: /add payment method/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Set as default' })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Remove' })).not.toBeInTheDocument();
		expect(screen.queryByText('No payment methods on file.')).not.toBeInTheDocument();
	});

	it('shows billing unavailable state and hides the manage button', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: true,
				subscriptionCancelledBannerText: null,
				subscriptionRecoveryBannerText: null
			},
			form: null
		});
		expect(screen.getByText('Payment method management unavailable')).toBeInTheDocument();
		expect(
			screen.getByText(
				'Stripe is not available in this environment. Payment method management is disabled.'
			)
		).toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Manage billing' })).not.toBeInTheDocument();
	});

	it('renders dunning recovery banner copy with a recovery CTA', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				subscriptionCancelledBannerText: null,
				subscriptionRecoveryBannerText:
					'Payment failed for your subscription. Update your payment method to recover access.'
			},
			form: null
		});
		expect(screen.getByTestId('subscription-recovery-banner')).toHaveTextContent(
			'Payment failed for your subscription. Update your payment method to recover access.'
		);
		expect(screen.getByRole('button', { name: 'Recover payment' })).toBeInTheDocument();
	});
});
